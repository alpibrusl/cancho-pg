edition 5;

import std.buffer;
import std.conns;
import std.io;

// `proxy` -- slice P0 of the connection pooler (`docs/pooler.md`): a transparent proxy. Each client connection is paired
// with one connection to the server, opened when the client arrives, and bytes are forwarded both ways untouched, so the
// startup exchange (including the `SSLRequest` the server answers `N` to), authentication and every message are the
// server's own. It understands nothing of the protocol yet; that is P1.
//
//     proxy <listen port> <server host> <server port>
//
// One thread, one poller, every connection (client or server) in one `std.conns` table. A connection that is
// readable is read into a shared chunk and the chunk is offered to its peer at once; what the kernel will not take
// is queued for the peer, and a connection is read from only while its peer's queue has room for another chunk,
// so a client that does not read stops the server being read from, and the reverse. Sizes are fixed at start.
//
// The connection to the server is made with a blocking `tcp_connect` when a client is accepted (P0: the server is
// local and the connect does not wait on anything but the kernel; P1 opens its connections ahead of need).

// Clients at once, at most (each is two connections).
fn max_clients() -> [] int {
    return 200;
}

// What is read from a connection at a time.
fn chunk() -> [] int {
    return 32768;
}

// What may wait to be sent to one connection.
fn queue_size() -> [] int {
    return 262144;
}

// Per connection `k`, `state[6k..6k+6]` is:
//
//     0  1 if the slot is in use
//     1  its peer's slot (the other half of the pair)
//     2  bytes waiting to be sent to it
//     3  what it is watched for (1 to read, 2 to write, 3 both, 0 neither)
//     4  1 if it closes once its queue has gone (its peer has)
fn stride() -> [] int {
    return 6;
}

res struct Core {
    poller: Poller,
    events: Box[[int]],
    state: Box[[int]],
    // The chunk being forwarded.
    rbuf: Box[[byte]],
    pends: Box[[byte]],
}

// Hand `data` to the kernel without waiting for room, and keep what it did not take (as `cache`'s `emit`). Answers the
// new number of bytes queued, or -1 if the queue cannot hold the rest or the connection has failed.
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

fn shut[&t, &c](tab: &!t conns.Table, core: &!c Core, k: int) -> [] int {
    let st = contents(core.state);
    conns.close(tab, k);
    st[stride() * k] = 0;
    return 0;
}

// Watch `k` for what it now waits on: room to write if output is queued for it, and input while its peer's queue has
// room for what would be read.
fn settle[&t, &c](tab: &!t conns.Table, core: &!c Core, k: int) -> [poll] int {
    let st = contents(core.state);
    let p = stride() * k;
    if st[p] == 0 {
        return 0;
    }
    var want = 0;
    if st[p + 4] == 0 && st[stride() * st[p + 1] + 2] + chunk() <= queue_size() {
        want = 1;
    }
    if st[p + 2] > 0 {
        want = want + 2;
    }
    if want != st[p + 3] {
        conns.rewatch(tab, core.poller, k, k + 1, want);
        st[p + 3] = want;
    }
    return 0;
}

// `k` is finished (the peer closed, or it failed). Close it; the peer goes once what is queued for it has been sent.
fn finish[&t, &c](tab: &!t conns.Table, core: &!c Core, k: int) -> [poll] int {
    let st = contents(core.state);
    let peer = st[stride() * k + 1];
    shut(tab, core, k);
    if st[stride() * peer] == 1 {
        if st[stride() * peer + 2] > 0 {
            st[stride() * peer + 4] = 1;
            settle(tab, core, peer);
        } else {
            shut(tab, core, peer);
        }
    }
    return 0;
}

// Connection `k` can be written to: send what is queued for it.
fn drain[&t, &c](tab: &!t conns.Table, core: &!c Core, k: int) -> [conn_write, poll] int {
    let st = contents(core.state);
    let pd = contents(core.pends);
    let p = stride() * k;
    let obase = k * queue_size();
    match conns.write(tab, k, pd[obase..obase + st[p + 2]]) {
        Sent::Wrote(sent) => {
            var at = 0;
            while at < st[p + 2] - sent {
                pd[obase + at] = pd[obase + sent + at];
                at = at + 1;
            }
            st[p + 2] = st[p + 2] - sent;
            if st[p + 2] == 0 && st[p + 4] == 1 {
                // Its peer is gone and everything it said has been delivered.
                shut(tab, core, k);
            } else {
                settle(tab, core, k);
                // The peer may read again now that there is room.
                settle(tab, core, st[p + 1]);
            }
        }
        Sent::Again => {
        }
        Sent::Failed(e) => {
            finish(tab, core, k);
        }
    }
    return 0;
}

// Connection `k` can be read: take a chunk and pass it to the peer.
fn forward[&t, &c](tab: &!t conns.Table, core: &!c Core, k: int) -> [conn_read, conn_write, poll] int {
    let st = contents(core.state);
    let rb = contents(core.rbuf);
    let pd = contents(core.pends);
    let p = stride() * k;
    let peer = st[p + 1];
    match conns.read(tab, k, rb[0..chunk()]) {
        Received::Data(got) => {
            let q = stride() * peer;
            let pending = emit(tab, peer, rb[0..got], pd[peer * queue_size()..peer * queue_size() + queue_size()], st[q + 2]);
            if pending < 0 {
                finish(tab, core, peer);
            } else {
                st[q + 2] = pending;
                settle(tab, core, peer);
                settle(tab, core, k);
            }
        }
        Received::End => {
            finish(tab, core, k);
        }
        Received::Again => {
        }
        Received::Failed(e) => {
            finish(tab, core, k);
        }
    }
    return 0;
}

// The poller said connection `k` is ready.
fn step[&t, &c](tab: &!t conns.Table, core: &!c Core, k: int, readiness: int) -> [conn_read, conn_write, poll] int {
    let st = contents(core.state);
    let p = stride() * k;
    if readiness % 4 >= 2 && st[p + 2] > 0 {
        drain(tab, core, k);
    }
    if st[p] == 1 && readiness % 2 == 1 {
        if st[p + 3] % 2 == 1 {
            forward(tab, core, k);
        } else {
            // Said something (or hung up) while it was not being listened to.
            finish(tab, core, k);
        }
    }
    return 0;
}

// Take every client waiting on the listener, up to the limit: each is paired with a new connection to the server.
fn accept_all[&h, &l, &c, &n](heap: &!h Heap, conn: conns.Table, listener: &!l Listener, core: &!c Core, net: &n Net(""), host: &n [byte], port: int) -> [heap, conn_accept, net_out(""), poll] conns.Table {
    let st = contents(core.state);
    var table = conn;
    var more = true;
    while more {
        match tcp_accept(listener) {
            Accepted::Ok(client) => {
                var held = 0;
                borrow table as &tt in {
                    held = conns.live(tt);
                }
                if held + 2 > 2 * max_clients() {
                    conn_close(client);
                } else {
                    match tcp_connect(net, host, port) {
                        Dialed::Ok(server) => {
                            let (t1, a) = conns.put(heap, table, client);
                            let (t2, b) = conns.put(heap, t1, server);
                            table = t2;
                            if a >= 0 && b >= 0 {
                                st[stride() * a] = 1;
                                st[stride() * a + 1] = b;
                                st[stride() * a + 2] = 0;
                                st[stride() * a + 3] = 1;
                                st[stride() * a + 4] = 0;
                                st[stride() * b] = 1;
                                st[stride() * b + 1] = a;
                                st[stride() * b + 2] = 0;
                                st[stride() * b + 3] = 1;
                                st[stride() * b + 4] = 0;
                                borrow mut table as &!ct in {
                                    if conns.nonblocking(ct, a) != 0 || conns.nonblocking(ct, b) != 0 || conns.nodelay(ct, a) != 0 || conns.nodelay(ct, b) != 0 || conns.watch(ct, core.poller, a, a + 1, 1) != 0 || conns.watch(ct, core.poller, b, b + 1, 1) != 0 {
                                        shut(ct, core, a);
                                        shut(ct, core, b);
                                    }
                                }
                            } else {
                                borrow mut table as &!ct in {
                                    if a >= 0 {
                                        conns.close(ct, a);
                                    }
                                    if b >= 0 {
                                        conns.close(ct, b);
                                    }
                                }
                            }
                        }
                        Dialed::Failed(e) => {
                            conn_close(client);
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

fn run[&h, &l, &n](heap: &!h Heap, listener: &!l Listener, net: &n Net(""), host: &n [byte], port: int) -> [heap, conn_accept, conn_read, conn_write, net_out(""), poll] int {
    match poller_new() {
        Polling::Ok(p) => {
            var poller = p;
            borrow mut poller as &!pw in {
                poller_add_listener(pw, listener, 0);
            }
            let slots = 2 * max_clients();
            var core = Core { poller: poller, events: box_slice(heap, 128, 0), state: box_slice(heap, stride() * slots + 2 * stride(), 0), rbuf: box_slice(heap, chunk(), byte_of(0)), pends: box_slice(heap, slots * queue_size() + queue_size(), byte_of(0)) };
            var tab = conns.empty(heap, 64);
            while true {
                var ready = 0 - 1;
                borrow mut core as &!cw in {
                    ready = poller_wait(cw.poller, contents(cw.events), 1000);
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
                            tab = accept_all(heap, tab, listener, cw, net, host, port);
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
            let Core { poller, events, state, rbuf, pends } = core;
            poller_close(poller);
            unbox_slice(heap, events);
            unbox_slice(heap, state);
            unbox_slice(heap, rbuf);
            unbox_slice(heap, pends);
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
    release(fs);
    release(ffi);
    release(clock);
    var listen_port = 0 - 1;
    var server_port = 0 - 1;
    borrow args as &g in {
        if arg_count(g) == 4 {
            listen_port = number_of(arg(g, 1));
            server_port = number_of(arg(g, 3));
        }
    }
    var status = 2;
    if listen_port > 0 && listen_port < 65536 && server_port > 0 && server_port < 65536 {
        status = 3;
        borrow args as &g in {
            borrow net as &nn in {
                match tcp_listen(nn, listen_port, 1024, 0) {
                    Listening::Ok(l) => {
                        var listener = l;
                        borrow mut listener as &!lh in {
                            listener_nonblocking(lh);
                            borrow mut heap as &!h in {
                                status = run(h, lh, nn, arg(g, 2), server_port);
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
    release(net);
    release(args);
    release(io);
    release(heap);
    return status;
}
