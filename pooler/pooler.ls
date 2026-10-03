edition 5;

import std.buffer;
import std.bytes;
import std.conns;
import std.io;
import frame;
import pg;

// `pooler` -- slice P1 of the connection pooler (`docs/pooler.md`): transaction pooling.
//
//     pooler <listen port> <server host> <server port> <user> <database> <password | -> <pool size>
//
// A pool of `pool size` connections to the server is logged in when it starts (`pg.login`: trust, cleartext or SCRAM, whatever the server
// asks), and a client is lent one for the length of one transaction. A client that connects is answered by the pooler itself (the
// authentication is "ok", the parameters are the ones the first server connection reported), holds no server connection while it is
// idle, is given one when it sends its first message of a request, and gives it back when the server answers `ReadyForQuery` with
// status idle and the pooler is not waiting for another. Clients that find none free wait, in order, with what they have sent
// held back. Messages are not copied or rewritten: what the client sent goes to the server and what the server sent goes to the client,
// and `pooler/frame.ls` is how the pooler knows where one ends and what the server answered with.
//
// What it refuses, in the protocol's own words: a prepared statement with a name (it would outlive the transaction on a connection the
// client will not get back), a client whose user or database is not the pool's. What it does not do yet: authenticate clients (P2: it
// is for a trusted network), map `CancelRequest`, time anything out (P3), open its connections without blocking (a connection that is
// replaced is logged in while the loop waits).
//
// One thread, one poller. Sizes are fixed at start.

// Clients at once, at most.
fn max_clients() -> [] int {
    return 200;
}

// Server connections, at most.
fn max_pool() -> [] int {
    return 64;
}

// Slots in the table: clients, the pool, and the few that are being replaced.
fn max_slots() -> [] int {
    return 200 + 2 * 64;
}

// What is read from a connection at a time, what a client's input buffer holds, and what may wait to be sent to one connection.
fn chunk() -> [] int {
    return 32768;
}

fn input_size() -> [] int {
    return 32768;
}

fn queue_size() -> [] int {
    return 131072;
}

// Per connection `k`, `state[24k..24k+24]` is:
//
//      0  1 if the slot is in use
//      1  1 for a client, 2 for a server
//      2  the slot it is paired with (a client's server, a server's client), or -1
//      3  a client's bytes buffered
//      4  bytes waiting to be sent to it
//      5  what it is watched for (1 read, 2 write, 3 both, 0 neither)
//      6  1 if it closes once what is queued for it has gone
//      7  a client: 0 before its startup message has been answered, 1 after. A server: 1 if it is idle
//      8  a client: how much of the message being passed on is still to come
//      9  a client: 1 while its messages are dropped up to a Sync
//     10  a client: the ReadyForQuerys the server still owes it
//     11  a client: 1 if it is in the queue for a server
//     12  a client: its number
//     13  a server: the scan of what it sends (`frame.scan_size()` ints)
fn stride() -> [] int {
    return 24;
}

// `meta`:
//
//     0  servers idle      1  the queue's head   2  clients queued   3  bytes of parameters to replay   4  the next client number
//     5  servers in the pool   6  the size asked for   7  the server's port   8  user's length   9  password's   10  database's   11  host's
fn meta_size() -> [] int {
    return 16;
}

// `config`: the user at 0, the password at 128, the database at 384, the host at 512.
fn config_size() -> [] int {
    return 640;
}

res struct Core {
    poller: Poller,
    events: Box[[int]],
    state: Box[[int]],
    meta: Box[[int]],
    // Servers idle (a stack of slots) and clients waiting (a ring of slots).
    idle: Box[[int]],
    queue: Box[[int]],
    inbuf: Box[[byte]],
    rbuf: Box[[byte]],
    pends: Box[[byte]],
    // The ParameterStatus messages every client is told, and a scratch for the messages the pooler writes itself.
    hello: Box[[byte]],
    scratch: Box[[byte]],
    config: Box[[byte]],
}

// ---------------------------------------------------------------------
// Bytes to a connection
// ---------------------------------------------------------------------

// Hand `data` to the kernel without waiting for room, and keep what it did not take. Answers the new number of bytes queued,
// or -1 if the queue cannot hold the rest or the connection has failed.
fn emit[&c, &d, &e](table: &!c conns.Table, slot: int, data: &d [byte], pend: &!e [byte], pending: int) -> [conn_write] int {
    var at = 0;
    if pending == 0 {
        match conns.write(table, slot, data) {
            Sent::Wrote(n) => {
                at = n;
            }
            Sent::Again => {
            }
            Sent::Failed(e) => {
                return 0 - 1;
            }
        }
    }
    if at >= len(data) {
        return pending;
    }
    if pending + len(data) - at > len(pend) {
        return 0 - 1;
    }
    var i = at;
    while i < len(data) {
        pend[pending + i - at] = data[i];
        i = i + 1;
    }
    return pending + len(data) - at;
}

// Send `data` to connection `k` (behind what is already queued for it). False if that failed.
fn send_to[&t, &c, &d](tab: &!t conns.Table, core: &!c Core, k: int, data: &d [byte]) -> [conn_write] bool {
    let st = contents(core.state);
    let pd = contents(core.pends);
    let p = stride() * k;
    let pending = emit(tab, k, data, pd[k * queue_size()..k * queue_size() + queue_size()], st[p + 4]);
    if pending < 0 {
        return false;
    }
    st[p + 4] = pending;
    return true;
}

fn put_be32[&b](buf: &!b [byte], at: int, n: int) -> [] int {
    buf[at] = byte_of(n / 16777216 % 256);
    buf[at + 1] = byte_of(n / 65536 % 256);
    buf[at + 2] = byte_of(n / 256 % 256);
    buf[at + 3] = byte_of(n % 256);
    return at + 4;
}

fn put_text[&b, &t](buf: &!b [byte], at: int, text: &t [byte]) -> [] int {
    var i = 0;
    while i < len(text) {
        buf[at + i] = text[i];
        i = i + 1;
    }
    buf[at + len(text)] = byte_of(0);
    return at + len(text) + 1;
}

// An ErrorResponse into `buf` at `at`: severity, SQLSTATE and message. Answers where it ends.
fn put_error[&b, &s, &c, &m](buf: &!b [byte], at: int, severity: &s [byte], code: &c [byte], message: &m [byte]) -> [] int {
    buf[at] = byte_of('E');
    var o = at + 5;
    buf[o] = byte_of('S');
    o = put_text(buf, o + 1, severity);
    buf[o] = byte_of('V');
    o = put_text(buf, o + 1, severity);
    buf[o] = byte_of('C');
    o = put_text(buf, o + 1, code);
    buf[o] = byte_of('M');
    o = put_text(buf, o + 1, message);
    buf[o] = byte_of(0);
    o = o + 1;
    put_be32(buf, at + 1, o - at - 1);
    return o;
}

// ReadyForQuery with `status` into `buf` at `at`.
fn put_ready[&b](buf: &!b [byte], at: int, status: int) -> [] int {
    buf[at] = byte_of('Z');
    put_be32(buf, at + 1, 5);
    buf[at + 5] = byte_of(status);
    return at + 6;
}

// ---------------------------------------------------------------------
// Closing, watching, queueing
// ---------------------------------------------------------------------

fn shut[&t, &c](tab: &!t conns.Table, core: &!c Core, k: int) -> [] int {
    let st = contents(core.state);
    conns.close(tab, k);
    st[stride() * k] = 0;
    return 0;
}

// Take server `s` out of the pool (it is closed; the loop logs another in).
fn drop_server[&t, &c](tab: &!t conns.Table, core: &!c Core, s: int) -> [] int {
    let st = contents(core.state);
    let mt = contents(core.meta);
    if st[stride() * s] == 1 {
        // If it was idle it is on the stack.
        if st[stride() * s + 7] == 1 {
            var i = 0;
            let id = contents(core.idle);
            while i < mt[0] {
                if id[i] == s {
                    id[i] = id[mt[0] - 1];
                    mt[0] = mt[0] - 1;
                } else {
                    i = i + 1;
                }
            }
        }
        shut(tab, core, s);
        mt[5] = mt[5] - 1;
    }
    return 0;
}

// Watch `k` for what it now waits on.
fn settle[&t, &c](tab: &!t conns.Table, core: &!c Core, k: int) -> [poll] int {
    let st = contents(core.state);
    let p = stride() * k;
    if k < 0 || st[p] == 0 {
        return 0;
    }
    var want = 0;
    if st[p + 1] == 1 {
        // A client is read while it has room for more and is not on its way out.
        if st[p + 6] == 0 && st[p + 3] < input_size() {
            want = 1;
        }
    } else if st[p + 7] == 1 {
        // An idle server is read to notice it has gone.
        want = 1;
    } else if st[p + 2] >= 0 && st[stride() * st[p + 2] + 4] + chunk() <= queue_size() {
        // A busy one while its client's queue has room for what it would say.
        want = 1;
    }
    if st[p + 4] > 0 {
        want = want + 2;
    }
    if want != st[p + 5] {
        conns.rewatch(tab, core.poller, k, k + 1, want);
        st[p + 5] = want;
    }
    return 0;
}

fn queue_push[&c](core: &!c Core, k: int) -> [] int {
    let mt = contents(core.meta);
    let q = contents(core.queue);
    let st = contents(core.state);
    if mt[2] < len(q) {
        q[(mt[1] + mt[2]) % len(q)] = k;
        mt[2] = mt[2] + 1;
        st[stride() * k + 11] = 1;
    }
    return 0;
}

// The next client still waiting, or -1.
fn queue_pop[&c](core: &!c Core) -> [] int {
    let mt = contents(core.meta);
    let q = contents(core.queue);
    let st = contents(core.state);
    while mt[2] > 0 {
        let k = q[mt[1]];
        mt[1] = (mt[1] + 1) % len(q);
        mt[2] = mt[2] - 1;
        if st[stride() * k] == 1 && st[stride() * k + 11] == 1 {
            st[stride() * k + 11] = 0;
            return k;
        }
    }
    return 0 - 1;
}

// Pair client `c` with idle server `s`.
fn assign[&t, &x](tab: &!t conns.Table, core: &!x Core, c: int, s: int) -> [poll] int {
    let st = contents(core.state);
    st[stride() * c + 2] = s;
    st[stride() * s + 2] = c;
    st[stride() * s + 7] = 0;
    var i = 0;
    while i < frame.scan_size() {
        st[stride() * s + 13 + i] = 0;
        i = i + 1;
    }
    settle(tab, core, s);
    settle(tab, core, c);
    return 0;
}

// Take an idle server off the stack, or -1.
fn take_idle[&c](core: &!c Core) -> [] int {
    let mt = contents(core.meta);
    if mt[0] == 0 {
        return 0 - 1;
    }
    mt[0] = mt[0] - 1;
    return contents(core.idle)[mt[0]];
}

// ---------------------------------------------------------------------
// A client's messages
// ---------------------------------------------------------------------

// The big-endian int32 at `at`.
fn be32[&b](m: &b [byte], at: int) -> [] int {
    return int_of(m[at]) * 16777216 + int_of(m[at + 1]) * 65536 + int_of(m[at + 2]) * 256 + int_of(m[at + 3]);
}

// Whether the C string at `at` in `m` is `want`; answers where it ends (after its 0), or -1 if it is not terminated.
fn cstr_end[&b](m: &b [byte], at: int) -> [] int {
    var i = at;
    while i < len(m) {
        if int_of(m[i]) == 0 {
            return i + 1;
        }
        i = i + 1;
    }
    return 0 - 1;
}

fn same_text[&a, &b](x: &a [byte], y: &b [byte]) -> [] bool {
    if len(x) != len(y) {
        return false;
    }
    var i = 0;
    while i < len(x) {
        if x[i] != y[i] {
            return false;
        }
        i = i + 1;
    }
    return true;
}

// Check a startup message's parameters (`m` is the message after its code): the user, and the database (the user's name if there is none) must be
// the pool's. 0 if they are, 1 if not the user, 2 if not the database, 3 if the message is malformed.
fn check_startup[&b, &c](m: &b [byte], config: &c [byte], user_len: int, db_len: int) -> [] int {
    var user = 0 - 1;
    var user_to = 0;
    var db = 0 - 1;
    var db_to = 0;
    var at = 0;
    while at < len(m) && int_of(m[at]) != 0 {
        let k_end = cstr_end(m, at);
        if k_end < 0 {
            return 3;
        }
        let v_end = cstr_end(m, k_end);
        if v_end < 0 {
            return 3;
        }
        let key = m[at..k_end - 1];
        if same_text(key, "user") {
            user = k_end;
            user_to = v_end - 1;
        }
        if same_text(key, "database") {
            db = k_end;
            db_to = v_end - 1;
        }
        at = v_end;
    }
    if user < 0 {
        return 3;
    }
    if !same_text(m[user..user_to], config[0..user_len]) {
        return 1;
    }
    if db >= 0 {
        if !same_text(m[db..db_to], config[384..384 + db_len]) {
            return 2;
        }
    } else if !same_text(config[0..user_len], config[384..384 + db_len]) {
        return 2;
    }
    return 0;
}

// Put the client on its way out: it is closed once what is queued for it has gone, with its server (if it holds one) dropped from the pool, because
// what state the client left it in is not known.
fn finish_client[&t, &c](tab: &!t conns.Table, core: &!c Core, k: int) -> [poll] int {
    let st = contents(core.state);
    let p = stride() * k;
    if st[p] == 0 {
        return 0;
    }
    let s = st[p + 2];
    if s >= 0 {
        st[p + 2] = 0 - 1;
        st[stride() * s + 2] = 0 - 1;
        drop_server(tab, core, s);
    }
    st[p + 11] = 0;
    if st[p + 4] > 0 && st[p + 6] == 0 {
        st[p + 6] = 1;
        settle(tab, core, k);
    } else {
        shut(tab, core, k);
    }
    return 0;
}

// Hand server `s`, which has finished a transaction (or is new), to the next client waiting, or to the stack.
fn give_back[&t, &c](tab: &!t conns.Table, core: &!c Core, s: int) -> [conn_write, poll] int {
    let st = contents(core.state);
    let mt = contents(core.meta);
    let k = st[stride() * s + 2];
    if k >= 0 {
        st[stride() * k + 2] = 0 - 1;
    }
    st[stride() * s + 2] = 0 - 1;
    st[stride() * s + 7] = 1;
    contents(core.idle)[mt[0]] = s;
    mt[0] = mt[0] + 1;
    settle(tab, core, s);
    // The clients that were waiting, in the order they came.
    var more = true;
    while more && mt[0] > 0 {
        let q = queue_pop(core);
        if q < 0 {
            more = false;
        } else {
            let server = take_idle(core);
            assign(tab, core, q, server);
            process(tab, core, q);
        }
    }
    return 0;
}

// Everything the client in slot `k` has sent that can be dealt with: its startup message, then its messages, decided by `frame.client_step`.
fn process[&t, &c](tab: &!t conns.Table, core: &!c Core, k: int) -> [conn_write, poll] int {
    let st = contents(core.state);
    let mt = contents(core.meta);
    let bf = contents(core.inbuf);
    let pd = contents(core.pends);
    let sc = contents(core.scratch);
    let cf = contents(core.config);
    let p = stride() * k;
    let base = k * input_size();
    var used = 0;
    // The bytes just before `used` that have been decided on and not yet sent to the server: messages that arrived together go together, in one write
    // (a write per message is what Nagle's algorithm waits on an acknowledgement for).
    var batch = 0;
    var going = true;
    while going && st[p] == 1 && st[p + 6] == 0 {
        let view = bf[base + used..base + st[p + 3]];
        if st[p + 7] == 0 {
            // Before it is answered: SSLRequest, GSSENCRequest, CancelRequest or the startup message itself.
            if len(view) < 8 {
                going = false;
            } else {
                let size = be32(view, 0);
                let code = be32(view, 4);
                if size < 8 || size > 8192 {
                    finish_client(tab, core, k);
                    going = false;
                } else if len(view) < size {
                    going = false;
                } else if code == 80877103 || code == 80877104 {
                    sc[0] = byte_of('N');
                    send_to(tab, core, k, sc[0..1]);
                    used = used + size;
                } else if code == 80877102 {
                    finish_client(tab, core, k);
                    going = false;
                } else if code / 65536 != 3 {
                    var o = put_error(sc, 0, "FATAL", "0A000", "unsupported frontend protocol");
                    send_to(tab, core, k, sc[0..o]);
                    finish_client(tab, core, k);
                    going = false;
                } else {
                    let verdict = check_startup(view[8..size], cf, mt[8], mt[10]);
                    if verdict != 0 {
                        var o = 0;
                        if verdict == 1 {
                            o = put_error(sc, 0, "FATAL", "28000", "this pooler serves one user: the one it is configured with");
                        } else if verdict == 2 {
                            o = put_error(sc, 0, "FATAL", "3D000", "this pooler serves one database: the one it is configured with");
                        } else {
                            o = put_error(sc, 0, "FATAL", "08P01", "invalid startup message");
                        }
                        send_to(tab, core, k, sc[0..o]);
                        finish_client(tab, core, k);
                        going = false;
                    } else if mt[3] == 0 || mt[5] == 0 {
                        let o = put_error(sc, 0, "FATAL", "08006", "the pooler has no connection to the server");
                        send_to(tab, core, k, sc[0..o]);
                        finish_client(tab, core, k);
                        going = false;
                    } else {
                        // AuthenticationOk, the parameters, a BackendKeyData of its own, ReadyForQuery idle.
                        let hl = contents(core.hello);
                        var o = 0;
                        sc[o] = byte_of('R');
                        put_be32(sc, o + 1, 8);
                        put_be32(sc, o + 5, 0);
                        o = o + 9;
                        var i = 0;
                        while i < mt[3] {
                            sc[o + i] = hl[i];
                            i = i + 1;
                        }
                        o = o + mt[3];
                        sc[o] = byte_of('K');
                        put_be32(sc, o + 1, 12);
                        put_be32(sc, o + 5, st[p + 12]);
                        put_be32(sc, o + 9, 0);
                        o = o + 13;
                        o = put_ready(sc, o, 73);
                        send_to(tab, core, k, sc[0..o]);
                        st[p + 7] = 1;
                        used = used + size;
                    }
                }
            }
        } else {
            let (act, n, rest, owed) = frame.client_step(view, st[p + 8], st[p + 9]);
            if act != frame.forward() && batch > 0 {
                send_to(tab, core, st[p + 2], bf[base + used - batch..base + used]);
                settle(tab, core, st[p + 2]);
                batch = 0;
            }
            if act == frame.need_more() {
                going = false;
            } else if act == frame.forward() {
                if st[p + 2] < 0 {
                    let s = take_idle(core);
                    if s < 0 {
                        // Wait for one, with what the client has sent held back.
                        if st[p + 11] == 0 {
                            queue_push(core, k);
                        }
                        going = false;
                    } else {
                        assign(tab, core, k, s);
                    }
                }
                if going {
                    let s = st[p + 2];
                    if st[stride() * s + 4] + batch + n > queue_size() {
                        // The server is not taking what is being sent; try again when it does.
                        going = false;
                    } else {
                        batch = batch + n;
                        st[p + 10] = st[p + 10] + owed;
                        st[p + 8] = rest;
                        used = used + n;
                    }
                }
            } else if act == frame.terminate() {
                used = used + n;
                finish_client(tab, core, k);
                going = false;
            } else if act == frame.refuse_named() {
                // The error a server would give, and then, as it would, nothing until the Sync.
                let o = put_error(sc, 0, "ERROR", "0A000", "prepared statements with a name are not supported by this pooler (transaction pooling)");
                send_to(tab, core, k, sc[0..o]);
                st[p + 9] = 1;
                st[p + 8] = rest;
                used = used + n;
            } else if act == frame.drop_bytes() {
                st[p + 8] = rest;
                used = used + n;
            } else if act == frame.synced() {
                // 'E': if the client holds a server it is in a transaction that, as far as the client knows, has failed.
                var status = 73;
                if st[p + 2] >= 0 {
                    status = 69;
                }
                let o = put_ready(sc, 0, status);
                send_to(tab, core, k, sc[0..o]);
                st[p + 9] = 0;
                used = used + n;
            } else {
                finish_client(tab, core, k);
                going = false;
            }
        }
    }
    if batch > 0 && st[p] == 1 && st[p + 2] >= 0 {
        send_to(tab, core, st[p + 2], bf[base + used - batch..base + used]);
        settle(tab, core, st[p + 2]);
        batch = 0;
    }
    if st[p] == 1 {
        var at = 0;
        while at < st[p + 3] - used {
            bf[base + at] = bf[base + used + at];
            at = at + 1;
        }
        st[p + 3] = st[p + 3] - used;
        if st[p + 4] < 0 {
            finish_client(tab, core, k);
        } else {
            settle(tab, core, k);
        }
    }
    return 0;
}

// ---------------------------------------------------------------------
// The poller's events
// ---------------------------------------------------------------------

// Connection `k` can be written to: send what is queued for it.
fn drain[&t, &c](tab: &!t conns.Table, core: &!c Core, k: int) -> [conn_write, poll] int {
    let st = contents(core.state);
    let pd = contents(core.pends);
    let p = stride() * k;
    let obase = k * queue_size();
    match conns.write(tab, k, pd[obase..obase + st[p + 4]]) {
        Sent::Wrote(sent) => {
            var at = 0;
            while at < st[p + 4] - sent {
                pd[obase + at] = pd[obase + sent + at];
                at = at + 1;
            }
            st[p + 4] = st[p + 4] - sent;
            if st[p + 4] == 0 && st[p + 6] == 1 {
                shut(tab, core, k);
            } else {
                settle(tab, core, k);
                let peer = st[p + 2];
                if peer >= 0 {
                    settle(tab, core, peer);
                    if st[p + 1] == 2 {
                        // A server took what was queued: its client's held-back input may go now.
                        process(tab, core, peer);
                    }
                }
            }
        }
        Sent::Again => {
        }
        Sent::Failed(e) => {
            if st[p + 1] == 1 {
                st[p + 4] = 0;
                finish_client(tab, core, k);
            } else {
                let client = st[p + 2];
                drop_server(tab, core, k);
                if client >= 0 {
                    st[stride() * client + 2] = 0 - 1;
                    finish_client(tab, core, client);
                }
            }
        }
    }
    return 0;
}

// Server `s` can be read: an idle one is noticed leaving, a busy one's bytes go to its client.
fn from_server[&t, &c](tab: &!t conns.Table, core: &!c Core, s: int) -> [conn_read, conn_write, poll] int {
    let st = contents(core.state);
    let rb = contents(core.rbuf);
    let p = stride() * s;
    match conns.read(tab, s, rb[0..chunk()]) {
        Received::Data(got) => {
            let k = st[p + 2];
            if k >= 0 {
                let boundary = frame.scan(rb[0..got], st[p + 13..p + 13 + frame.scan_size()]);
                if !send_to(tab, core, k, rb[0..got]) {
                    drop_server(tab, core, s);
                    st[stride() * k + 2] = 0 - 1;
                    finish_client(tab, core, k);
                } else {
                    let q = stride() * k;
                    if boundary && st[p + 18] > 0 {
                        // `ReadyForQuery`s seen, and the status of the last. Back to the pool when the client is owed no more and the transaction is over.
                        st[q + 10] = st[q + 10] - st[p + 18];
                        if st[q + 10] < 0 {
                            st[q + 10] = 0;
                        }
                        let status = st[p + 16];
                        st[p + 16] = 0;
                        st[p + 18] = 0;
                        if st[q + 10] == 0 && status == 73 {
                            give_back(tab, core, s);
                        }
                    }
                    settle(tab, core, k);
                    settle(tab, core, s);
                }
            }
            // An idle server that says something (an asynchronous message) is not listened to.
        }
        Received::End => {
            let k = st[p + 2];
            drop_server(tab, core, s);
            if k >= 0 {
                st[stride() * k + 2] = 0 - 1;
                finish_client(tab, core, k);
            }
        }
        Received::Again => {
        }
        Received::Failed(e) => {
            let k = st[p + 2];
            drop_server(tab, core, s);
            if k >= 0 {
                st[stride() * k + 2] = 0 - 1;
                finish_client(tab, core, k);
            }
        }
    }
    return 0;
}

// The client in `k` can be read.
fn from_client[&t, &c](tab: &!t conns.Table, core: &!c Core, k: int) -> [conn_read, conn_write, poll] int {
    let st = contents(core.state);
    let bf = contents(core.inbuf);
    let p = stride() * k;
    let base = k * input_size();
    match conns.read(tab, k, bf[base + st[p + 3]..base + input_size()]) {
        Received::Data(got) => {
            st[p + 3] = st[p + 3] + got;
            process(tab, core, k);
        }
        Received::End => {
            finish_client(tab, core, k);
        }
        Received::Again => {
        }
        Received::Failed(e) => {
            finish_client(tab, core, k);
        }
    }
    return 0;
}

// The poller said connection `k` is ready.
fn step[&t, &c](tab: &!t conns.Table, core: &!c Core, k: int, readiness: int) -> [conn_read, conn_write, poll] int {
    let st = contents(core.state);
    let p = stride() * k;
    if readiness % 4 >= 2 && st[p + 4] > 0 {
        drain(tab, core, k);
    }
    if st[p] == 1 && readiness % 2 == 1 {
        if st[p + 5] % 2 == 1 {
            if st[p + 1] == 1 {
                from_client(tab, core, k);
            } else {
                from_server(tab, core, k);
            }
        } else if st[p + 1] == 1 {
            // Said something while it was not being listened to: on its way out.
            finish_client(tab, core, k);
        } else {
            let client = st[p + 2];
            drop_server(tab, core, k);
            if client >= 0 {
                st[stride() * client + 2] = 0 - 1;
                finish_client(tab, core, client);
            }
        }
    }
    return 0;
}

// Take every client waiting on the listener, up to the limit.
fn accept_all[&h, &l, &c](heap: &!h Heap, conn: conns.Table, listener: &!l Listener, core: &!c Core) -> [heap, conn_accept, poll] conns.Table {
    let st = contents(core.state);
    let mt = contents(core.meta);
    var table = conn;
    var more = true;
    while more {
        match tcp_accept(listener) {
            Accepted::Ok(client) => {
                var clients = 0;
                var k = 0;
                while k < max_slots() {
                    if st[stride() * k] == 1 && st[stride() * k + 1] == 1 {
                        clients = clients + 1;
                    }
                    k = k + 1;
                }
                if clients >= max_clients() {
                    conn_close(client);
                } else {
                    let (grown, slot) = conns.put(heap, table, client);
                    table = grown;
                    if slot >= 0 && slot < max_slots() {
                        let p = stride() * slot;
                        var i = 0;
                        while i < stride() {
                            st[p + i] = 0;
                            i = i + 1;
                        }
                        st[p] = 1;
                        st[p + 1] = 1;
                        st[p + 2] = 0 - 1;
                        st[p + 5] = 1;
                        mt[4] = mt[4] + 1;
                        st[p + 12] = mt[4];
                        borrow mut table as &!ct in {
                            if conns.nonblocking(ct, slot) != 0 || conns.nodelay(ct, slot) != 0 || conns.watch(ct, core.poller, slot, slot + 1, 1) != 0 {
                                shut(ct, core, slot);
                            }
                        }
                    } else if slot >= 0 {
                        borrow mut table as &!ct in {
                            conns.close(ct, slot);
                        }
                    }
                }
            }
            Accepted::Again => {
                more = false;
            }
            Accepted::Failed(e) => {
                more = false;
            }
        }
    }
    return table;
}

// ---------------------------------------------------------------------
// The pool
// ---------------------------------------------------------------------

// An unpredictable client nonce for SCRAM: 18 bytes from the kernel, as base64 (as `examples/psql.ls`).
fn fresh_nonce[&h, &f](heap: &!h Heap, fs: &f Fs("/dev/urandom")) -> [heap, fs_read("/dev/urandom")] buffer.Buffer {
    var nonce = buffer.empty(heap, 1);
    region a {
        let raw = alloc_slice[a](18, byte_of(0));
        let got = fs_read(fs, "/dev/urandom", raw);
        if got == 18 {
            buffer.drop(heap, nonce);
            nonce = pg.base64_encode(heap, raw);
        }
    }
    return nonce;
}

// Keep, from the first login's reply, the ParameterStatus messages every client will be told.
fn keep_parameters[&c, &r](core: &!c Core, reply: &r [byte]) -> [] int {
    let mt = contents(core.meta);
    let hl = contents(core.hello);
    var at = 0;
    var o = 0;
    while pg.size(reply, at) > 0 {
        let size = pg.size(reply, at);
        if pg.kind(reply, at) == 83 && o + size <= len(hl) {
            var i = 0;
            while i < size {
                hl[o + i] = reply[at + i];
                i = i + 1;
            }
            o = o + size;
        }
        at = at + size;
    }
    mt[3] = o;
    return 0;
}

// Log in connections until the pool is the size asked for, or one cannot be made (tried again on the next turn).
fn refill[&h, &n, &z, &c](heap: &!h Heap, conn: conns.Table, net: &n Net(""), rng: &z Fs("/dev/urandom"), core: &!c Core) -> [heap, net_out(""), conn_read, conn_write, fs_read("/dev/urandom"), poll] conns.Table {
    let mt = contents(core.meta);
    let st = contents(core.state);
    let cf = contents(core.config);
    var table = conn;
    var trying = true;
    while trying && mt[5] < mt[6] {
        trying = false;
        match tcp_connect(net, cf[512..512 + mt[11]], mt[7]) {
            Dialed::Ok(c) => {
                var server = c;
                let nonce = fresh_nonce(heap, rng);
                var status = 1;
                borrow nonce as &nr in {
                    borrow mut server as &!sh in {
                        let (reply, s) = pg.login(heap, sh, cf[0..mt[8]], cf[128..128 + mt[9]], cf[384..384 + mt[10]], buffer.bytes(nr));
                        status = s;
                        if s == 0 && mt[3] == 0 {
                            borrow reply as &rb in {
                                keep_parameters(core, buffer.bytes(rb));
                            }
                        }
                        buffer.drop(heap, reply);
                    }
                }
                buffer.drop(heap, nonce);
                if status != 0 {
                    conn_close(server);
                } else {
                    let (grown, slot) = conns.put(heap, table, server);
                    table = grown;
                    if slot >= 0 && slot < max_slots() {
                        let p = stride() * slot;
                        var i = 0;
                        while i < stride() {
                            st[p + i] = 0;
                            i = i + 1;
                        }
                        st[p] = 1;
                        st[p + 1] = 2;
                        st[p + 2] = 0 - 1;
                        st[p + 5] = 1;
                        st[p + 7] = 1;
                        borrow mut table as &!ct in {
                            if conns.nonblocking(ct, slot) != 0 || conns.nodelay(ct, slot) != 0 || conns.watch(ct, core.poller, slot, slot + 1, 1) != 0 {
                                shut(ct, core, slot);
                            } else {
                                contents(core.idle)[mt[0]] = slot;
                                mt[0] = mt[0] + 1;
                                mt[5] = mt[5] + 1;
                                trying = true;
                            }
                        }
                    } else if slot >= 0 {
                        borrow mut table as &!ct in {
                            conns.close(ct, slot);
                        }
                    }
                }
            }
            Dialed::Failed(e) => {
            }
        }
    }
    return table;
}

fn run[&h, &l, &n, &z, &g](heap: &!h Heap, listener: &!l Listener, net: &n Net(""), rng: &z Fs("/dev/urandom"), args: &g Args) -> [heap, conn_accept, conn_read, conn_write, net_out(""), fs_read("/dev/urandom"), poll, args] int {
    match poller_new() {
        Polling::Ok(p) => {
            var poller = p;
            borrow mut poller as &!pw in {
                poller_add_listener(pw, listener, 0);
            }
            let slots = max_slots() + 2;
            var core = Core { poller: poller, events: box_slice(heap, 128, 0), state: box_slice(heap, stride() * slots, 0), meta: box_slice(heap, meta_size(), 0), idle: box_slice(heap, max_pool() + 2, 0), queue: box_slice(heap, max_clients() + 2, 0), inbuf: box_slice(heap, slots * input_size(), byte_of(0)), rbuf: box_slice(heap, chunk(), byte_of(0)), pends: box_slice(heap, slots * queue_size(), byte_of(0)), hello: box_slice(heap, 4096, byte_of(0)), scratch: box_slice(heap, 4096, byte_of(0)), config: box_slice(heap, config_size(), byte_of(0)) };
            borrow mut core as &!cw in {
                // The configuration: where the server is, who to be, how many connections.
                let cf = contents(cw.config);
                let mt = contents(cw.meta);
                let host = arg(args, 2);
                let user = arg(args, 4);
                let database = arg(args, 5);
                let secret = arg(args, 6);
                var i = 0;
                while i < len(user) {
                    cf[i] = user[i];
                    i = i + 1;
                }
                i = 0;
                while i < len(secret) && !(len(secret) == 1 && int_of(secret[0]) == 45) {
                    cf[128 + i] = secret[i];
                    i = i + 1;
                }
                if len(secret) == 1 && int_of(secret[0]) == 45 {
                    mt[9] = 0;
                } else {
                    mt[9] = len(secret);
                }
                i = 0;
                while i < len(database) {
                    cf[384 + i] = database[i];
                    i = i + 1;
                }
                i = 0;
                while i < len(host) {
                    cf[512 + i] = host[i];
                    i = i + 1;
                }
                mt[8] = len(user);
                mt[10] = len(database);
                mt[11] = len(host);
                mt[7] = number_of(arg(args, 3));
                mt[6] = number_of(arg(args, 7));
            }
            var tab = conns.empty(heap, 64);
            while true {
                borrow mut core as &!cw in {
                    tab = refill(heap, tab, net, rng, cw);
                }
                var ready = 0 - 1;
                borrow mut core as &!cw in {
                    var wait_ms = 1000;
                    if contents(cw.meta)[5] < contents(cw.meta)[6] {
                        wait_ms = 200;
                    }
                    ready = poller_wait(cw.poller, contents(cw.events), wait_ms);
                }
                var j = 0;
                while j < ready {
                    var token = 0 - 1;
                    var readiness = 0;
                    borrow core as &cr in {
                        token = contents(cr.events)[2 * j];
                        readiness = contents(cr.events)[2 * j + 1];
                    }
                    if token == 0 {
                        borrow mut core as &!cw in {
                            tab = accept_all(heap, tab, listener, cw);
                        }
                    } else {
                        borrow mut tab as &!tw in {
                            borrow mut core as &!cw in {
                                if contents(cw.state)[stride() * (token - 1)] == 1 {
                                    step(tw, cw, token - 1, readiness);
                                }
                            }
                        }
                    }
                    j = j + 1;
                }
            }
            conns.drop(heap, tab);
            let Core { poller, events, state, meta, idle, queue, inbuf, rbuf, pends, hello, scratch, config } = core;
            poller_close(poller);
            unbox_slice(heap, events);
            unbox_slice(heap, state);
            unbox_slice(heap, meta);
            unbox_slice(heap, idle);
            unbox_slice(heap, queue);
            unbox_slice(heap, inbuf);
            unbox_slice(heap, rbuf);
            unbox_slice(heap, pends);
            unbox_slice(heap, hello);
            unbox_slice(heap, scratch);
            unbox_slice(heap, config);
            return 0;
        }
        Polling::Failed(e) => {
            return 4;
        }
    }
}

fn number_of[&t](text: &t [byte]) -> [] int {
    if len(text) == 0 || len(text) > 5 {
        return 0 - 1;
    }
    var n = 0;
    var i = 0;
    while i < len(text) {
        let c = int_of(text[i]);
        if c < '0' || c > '9' {
            return 0 - 1;
        }
        n = n * 10 + (c - '0');
        i = i + 1;
    }
    return n;
}

fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock } = split(world);
    release(ffi);
    release(clock);
    let rng = narrow(fs, "/dev/urandom");
    var listen_port = 0 - 1;
    var pool = 0 - 1;
    var server_port = 0 - 1;
    borrow args as &g in {
        if arg_count(g) == 8 {
            listen_port = number_of(arg(g, 1));
            server_port = number_of(arg(g, 3));
            pool = number_of(arg(g, 7));
        }
    }
    var status = 2;
    if listen_port > 0 && listen_port < 65536 && server_port > 0 && server_port < 65536 && pool > 0 && pool <= max_pool() {
        status = 3;
        borrow args as &g in {
            borrow rng as &z in {
                borrow net as &nn in {
                    match tcp_listen(nn, listen_port, 1024, 0) {
                        Listening::Ok(l) => {
                            var listener = l;
                            borrow mut listener as &!lh in {
                                listener_nonblocking(lh);
                                borrow mut heap as &!h in {
                                    status = run(h, lh, nn, z, g);
                                }
                            }
                            listener_close(listener);
                        }
                        Listening::Failed(e) => {
                            status = 3;
                        }
                    }
                }
            }
        }
    }
    release(rng);
    release(net);
    release(args);
    release(io);
    release(heap);
    return status;
}
