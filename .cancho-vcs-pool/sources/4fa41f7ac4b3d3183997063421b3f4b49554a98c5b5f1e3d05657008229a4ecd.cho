edition 5;

module pg.pool;

// `pg.pool` -- connections that do not wait (`docs/nonblocking.md` §4.2), and that come back
// (`docs/reconnect.md`).
//
// A `Pool` owns a few logged-in, non-blocking connections and pipelines requests over them:
// `submit` queues one encoded request (`pg.bind_named`: Bind, Execute, Sync) and returns at
// once, `flush` sends what was queued, `pump` does the I/O the poller said was ready, and `next_done` hands back the tag of
// each request whose answer has arrived, in the order each connection answers, with
// `reply` the bytes `pg.run_named` would have returned. Nothing here waits for the server:
// the application's loop owns the poller, registers the pool's connections in it with `start`,
// and calls `pump` for the tokens the poller reports that `owns` says are the pool's.
//
//     var pool = pool.empty(heap, 4, 64, 65536, 65536);
//     (pool, slot) = pool.add(heap, pool, conn);               // logged in, statements prepared
//     pool.start(pool, poller, first_token);                   // watch them all, under tokens from here
//     ...
//     pool.submit(pool, tag, request);                          // 0, or why not
//     pool.flush(pool, poller);                                 // once per turn: one write per connection
//     pool.pump(pool, poller, token, readiness);                // for a token `owns`
//     while pool.next_done(pool) >= 0 { ... pool.reply(pool), pool.status(pool) ... }
//
// Logging in and preparing statements are the caller's, with the blocking helpers of `pg`, before
// `add`: a connection is added idle, with nothing unread, and is made non-blocking here. Nothing
// is watched until `start`.
//
// A request that cannot be answered -- its connection was closed by the server, failed, or sent
// something that is not the protocol -- is handed back by `next_done` all the same, with a
// `status` that is not 0 and an empty reply, in its place in the order. None is lost and none
// is delivered twice; whether to try one again is the caller's (a write may have reached the
// server). `lost(status)` says that the connection was lost, so that the outcome is unknown; a
// request the server refused is a reply with status 0 and `pg.failure(reply) >= 0`.
//
// Coming back. A pool that has been given `reconnect` also makes the connections: a connection
// that fails is replaced, with the statements prepared again, and a pool that starts with none
// dials them, all without ever waiting. The pool does not dial itself (a library cannot name the
// one host its caller narrowed the network to): the loop calls `tick` once a turn, which advances
// every login in progress and answers how many connections are due, dials that many with
// `tcp_connect_start` and hands each to `adopt` (`revive` is those three steps for a program that
// has the whole network). `next_wake` is how long the loop may sleep, and `live`, `reconnects`
// and the other counters say how it is going. Every step is a state machine on the poller's
// events and the loop's clock: SCRAM's key derivation is done 128 iterations a turn.
//
// Sizes are fixed when the pool is made (and `reconnect` makes the one copy of the login and the
// statements it needs) and nothing is allocated afterwards: per connection an
// input slab (`in_cap`: the replies waiting to be taken, and a reply that does not fit is a
// failure, status 8), an output slab (`out_cap`) and `depth` requests in flight.
//
// Status codes, as in `pg`: 0 ok; 1 the server closed the connection; 3 a read failed; 6 a write
// failed; 8 a reply larger than `in_cap`; 10 a message that is not the protocol; and 11 the server
// ended the connection with a FATAL error (shutdown, a backend terminated, an idle timeout), 12
// no answer within the `request_ms` of `reconnect`. All of 1, 3, 6, 8, 10, 11 and 12 are `lost`.

import std.buffer;
import std.bytes;
import std.conns;
import pg;

// Per connection `k`, `st[28k..28k+28]` is:
//
//      0  bytes of input accumulated
//      1  how much of that is framed already (looked through for ReadyForQuery)
//      2  complete replies in the input that `next_done` has not given out
//      3  bytes of output queued
//      4  how much of that the kernel has taken
//      5  requests in flight (queued or sent, and not yet given out)
//      6  0 never used, 1 live, 2 down, 3 logging in
//      7  what it is watched for: 1 readable, 3 readable and writable, 2 writable (dialing)
//      8  where the ring of tags starts
//      9  why it died
//     10  the connection's slot in the table, or -1
//     11  while logging in: what it is waiting for or has to do next (`ph_*`)
//     12  down: when the next attempt may start (clock ms), or -1 for "decide at the next tick"
//     13  the wait that follows the next failed attempt
//     14  logging in: the attempt's deadline
//     15  failed attempts in a row
//     16  logging in: statements prepared so far
//     17  logging in: bytes of the server signature expected
//     18  live: when it came up (clock ms), or -1 until the next tick has seen it
//     19  logging in: SCRAM iterations still to do
//     20  1 once this connection has been live
//     21  logging in: where the server's challenge starts in the input
//     22  and where it ends
//     23  live: since when a request has been waiting (clock ms), or -1
//     24  1 if it was live and has just died
fn stride() -> [] int {
    return 28;
}

// Per connection, `scr[192k..192k+192]`: 0..24 the client nonce, 32..96 the server signature expected,
// 96..160 the PBKDF2 state of `pg.pbkdf2_begin`.
fn scr_size() -> [] int {
    return 192;
}

// What a login waits for or has to do (state 3). The ones that have something to send or compute are done by `tick`.
fn ph_connect() -> [] int {
    return 1;
}

fn ph_startup() -> [] int {
    return 2;
}

fn ph_auth() -> [] int {
    return 3;
}

fn ph_password() -> [] int {
    return 4;
}

fn ph_scram_first() -> [] int {
    return 5;
}

fn ph_scram_challenge() -> [] int {
    return 6;
}

fn ph_scram_salt() -> [] int {
    return 7;
}

fn ph_scram_work() -> [] int {
    return 8;
}

fn ph_scram_verify() -> [] int {
    return 9;
}

fn ph_authok() -> [] int {
    return 10;
}

fn ph_ready() -> [] int {
    return 11;
}

fn ph_setup_send() -> [] int {
    return 12;
}

fn ph_setup() -> [] int {
    return 13;
}

// Whether `tick` has something to do for a login in this phase, at once.
fn ph_is_work(ph: int) -> [] bool {
    return ph == 2 || ph == 4 || ph == 5 || ph == 7 || ph == 8 || ph == 12;
}

// PBKDF2 iterations done per `tick`: about half a millisecond.
fn work_chunk() -> [] int {
    return 128;
}

// A connection that stayed up this long (ms) and then died is retried at once; one that did not is a flapping one and
// waits out its backoff.
fn stable_ms() -> [] int {
    return 1000;
}

// `ci[..]`: 0 reconnect was given; 1 user, 2 password, 3 database, 4 seed, 5 setup script: their lengths in `cfg`, in
// that order; 6 statements in the script; 7 first wait (ms), 8 longest wait, 9 an attempt's deadline, 10 the
// longest a request may wait (0: for ever); and the counters: 11 reconnects, 12 attempts, 13 failed attempts, 14
// connections lost, 15 changes of any lane's state, 16 nonces made, 17 connections the pool made, 18 why the
// last attempt failed, 19 the errno of the last connect that failed, 20..24 the SQLSTATE of the last refusal, 26 why the
// last connection was lost.
fn ci_size() -> [] int {
    return 32;
}

res struct Core {
    st: Box[[int]],
    // One input slab per connection.
    acc: Box[[byte]],
    // One output slab per connection.
    outq: Box[[byte]],
    // `depth` tags per connection, a ring.
    tags: Box[[int]],
    // Which connection each answer to hand out belongs to, in the order they became
    // answers (a ring of `lanes * depth`).
    ring: Box[[int]],
    // Scratch for a login in progress, per connection.
    scr: Box[[byte]],
    // The login, the seed of the nonces and the statements, from `reconnect`.
    cfg: Box[[byte]],
    ci: Box[[int]],
    lanes: int,
    depth: int,
    in_cap: int,
    out_cap: int,
    // The poller token of connection 0; connection `k` is `base + k`. -1 until `start`.
    base: int,
    ring_head: int,
    ring_count: int,
    // The connection and the answer `next_done` last handed out, which `reply` and `status`
    // describe: its reply is still at the front of the input, and goes at the next call.
    cur: int,
    cur_len: int,
    cur_status: int,
    cur_tag: int,
}

pub res struct Pool {
    tab: conns.Table,
    core: Core,
}

// A pool with room for `lanes` connections, each `depth` requests deep, none connected yet.
pub fn empty[&h](heap: &!h Heap, lanes: int, depth: int, in_cap: int, out_cap: int) -> [heap] Pool {
    let core = Core { st: box_slice(heap, stride() * lanes, 0), acc: box_slice(heap, lanes * in_cap, byte_of(0)), outq: box_slice(heap, lanes * out_cap, byte_of(0)), tags: box_slice(heap, lanes * depth, 0), ring: box_slice(heap, lanes * depth, 0), scr: box_slice(heap, lanes * scr_size(), byte_of(0)), cfg: box_slice(heap, 1, byte_of(0)), ci: box_slice(heap, ci_size(), 0), lanes: lanes, depth: depth, in_cap: in_cap, out_cap: out_cap, base: 0 - 1, ring_head: 0, ring_count: 0, cur: 0 - 1, cur_len: 0, cur_status: 0, cur_tag: 0 - 1 };
    var made = core;
    borrow mut made as &!cw in {
        let st = contents(cw.st);
        var k = 0;
        while k < lanes {
            st[stride() * k + 10] = 0 - 1;
            st[stride() * k + 18] = 0 - 1;
            st[stride() * k + 23] = 0 - 1;
            k = k + 1;
        }
    }
    return Pool { tab: conns.empty(heap, lanes), core: made };
}

// End the pool: every connection still open is closed and the slabs freed.
pub fn close[&h](heap: &!h Heap, pool: Pool) -> [heap] int {
    let Pool { tab, core } = pool;
    conns.drop(heap, tab);
    let Core { st, acc, outq, tags, ring, scr, cfg, ci, lanes, depth, in_cap, out_cap, base, ring_head, ring_count, cur, cur_len, cur_status, cur_tag } = core;
    unbox_slice(heap, st);
    unbox_slice(heap, acc);
    unbox_slice(heap, outq);
    unbox_slice(heap, tags);
    unbox_slice(heap, ring);
    unbox_slice(heap, scr);
    unbox_slice(heap, cfg);
    unbox_slice(heap, ci);
    return 0;
}

// Whether `status` (of `status(pool)`) says the connection was lost with the request on it: the server may or may
// not have run it. A request the server refused has status 0, and an ErrorResponse in its reply.
pub fn lost(status: int) -> [] bool {
    return status == 1 || status == 3 || status == 6 || status == 8 || status == 10 || status == 11 || status == 12;
}

// Add a connection that is logged in, has its statements prepared and has nothing unread; it is made
// non-blocking. Answers the pool and the connection's number (the lowest connection not in use), or -1 if there is no
// room (the connection is closed) or it could not be set up (closed too), or -2 if every number
// free still has answers waiting on it from a connection that died (try again once `next_done` has
// given them out; the connection is closed). It is not watched until `start`.
pub fn add[&h](heap: &!h Heap, pool: Pool, conn: Conn) -> [heap] (Pool, int) {
    let Pool { tab, core } = pool;
    var table = tab;
    var state = core;
    var lane = 0 - 1;
    var waiting = false;
    borrow state as &cr in {
        let st = contents(cr.st);
        var k = 0;
        while k < cr.lanes && lane < 0 {
            let p = stride() * k;
            if st[p + 6] == 0 {
                lane = k;
            } else if st[p + 6] == 2 {
                if st[p + 5] == 0 && cr.cur != k {
                    lane = k;
                } else {
                    waiting = true;
                }
            }
            k = k + 1;
        }
    }
    if lane < 0 {
        conn_close(conn);
        if waiting {
            return (Pool { tab: table, core: state }, 0 - 2);
        }
        return (Pool { tab: table, core: state }, 0 - 1);
    }
    let (grown, number) = conns.put(heap, table, conn);
    table = grown;
    if number < 0 {
        return (Pool { tab: table, core: state }, 0 - 1);
    }
    borrow mut table as &!tw in {
        borrow mut state as &!cw in {
            let st = contents(cw.st);
            let p = stride() * lane;
            if conns.nonblocking(tw, number) != 0 {
                conns.close(tw, number);
                lane = 0 - 1;
            } else {
                st[p] = 0;
                st[p + 1] = 0;
                st[p + 2] = 0;
                st[p + 3] = 0;
                st[p + 4] = 0;
                st[p + 5] = 0;
                st[p + 6] = 1;
                st[p + 7] = 0;
                st[p + 8] = 0;
                st[p + 9] = 0;
                st[p + 10] = number;
                st[p + 11] = 0;
                st[p + 12] = 0;
                st[p + 13] = contents(cw.ci)[7];
                st[p + 15] = 0;
                st[p + 18] = 0 - 1;
                st[p + 20] = 1;
                st[p + 23] = 0 - 1;
                st[p + 24] = 0;
            }
        }
    }
    return (Pool { tab: table, core: state }, lane);
}

// Watch every connection that is not watched yet in `poller`, for reading, under the tokens
// `first_token` and up (connection `k` is `first_token + k`; the pool takes `lanes` tokens). Call
// it once after the first `add`s (or none, for a pool that dials all its connections), and again after any later one. Answers how many it could not
// register: those are closed, and their requests (none yet) fail as any dead connection's do.
pub fn start[&q, &p](pool: &!q Pool, poller: &!p Poller, first_token: int) -> [poll] int {
    return start_in(pool.tab, pool.core, poller, first_token);
}

fn start_in[&t, &c, &p](tab: &!t conns.Table, core: &!c Core, poller: &!p Poller, first_token: int) -> [poll] int {
    core.base = first_token;
    let st = contents(core.st);
    var failed = 0;
    var k = 0;
    while k < core.lanes {
        let p = stride() * k;
        if st[p + 6] == 1 && st[p + 7] == 0 {
            if conns.watch(tab, poller, st[p + 10], first_token + k, 1) == 0 {
                st[p + 7] = 1;
            } else {
                kill(tab, core, k, 3);
                failed = failed + 1;
            }
        }
        k = k + 1;
    }
    return failed;
}

// Whether `token` is one of this pool's connections.
pub fn owns[&q](pool: &q Pool, token: int) -> [] bool {
    return pool.core.base >= 0 && token >= pool.core.base && token < pool.core.base + pool.core.lanes;
}

fn count_state[&q](pool: &q Pool, state: int) -> [] int {
    let st = contents(pool.core.st);
    var n = 0;
    var k = 0;
    while k < pool.core.lanes {
        if st[stride() * k + 6] == state {
            n = n + 1;
        }
        k = k + 1;
    }
    return n;
}

// How many connections are live.
pub fn live[&q](pool: &q Pool) -> [] int {
    return count_state(pool, 1);
}

// How many connections are being made: dialed, or logging in.
pub fn connecting[&q](pool: &q Pool) -> [] int {
    return count_state(pool, 3);
}

// The state of connection `lane`: 0 never used, 1 live, 2 down (waiting to be remade), 3 being made; -1 if there is none.
pub fn lane_state[&q](pool: &q Pool, lane: int) -> [] int {
    if lane < 0 || lane >= pool.core.lanes {
        return 0 - 1;
    }
    return contents(pool.core.st)[stride() * lane + 6];
}

// How many requests are in flight: submitted and not yet given out by `next_done`.
pub fn in_flight[&q](pool: &q Pool) -> [] int {
    let st = contents(pool.core.st);
    var n = 0;
    var k = 0;
    while k < pool.core.lanes {
        n = n + st[stride() * k + 5];
        k = k + 1;
    }
    return n;
}

// How many times a connection that was lost has been replaced (the first connections the pool makes are not counted).
pub fn reconnects[&q](pool: &q Pool) -> [] int {
    return contents(pool.core.ci)[11];
}

// How many connections the pool has made itself (not the ones `add` was given), the first of each lane included; `reconnects`
// is those that replaced a connection that had been live.
pub fn made[&q](pool: &q Pool) -> [] int {
    return contents(pool.core.ci)[17];
}

// How many attempts to make a connection have been started (a dial that failed at once counts).
pub fn attempts[&q](pool: &q Pool) -> [] int {
    return contents(pool.core.ci)[12];
}

// How many of those failed.
pub fn failures[&q](pool: &q Pool) -> [] int {
    return contents(pool.core.ci)[13];
}

// How many live connections have been lost.
pub fn losses[&q](pool: &q Pool) -> [] int {
    return contents(pool.core.ci)[14];
}

// A number that goes up whenever any connection goes live, dies, or an attempt fails: a loop that wants to know whether
// anything happened to the pool compares it with the last it saw.
pub fn changes[&q](pool: &q Pool) -> [] int {
    return contents(pool.core.ci)[15];
}

// Why the last attempt failed: 1 the server closed the connection, 3 a read failed, 4 the server refused the login (see
// `sqlstate`), 5 it asked for a login this cannot do, 6 a write failed, 7 SCRAM failed on the client's side, 8 a message
// larger than the slabs, 9 the server refused a statement, 10 not the protocol, 20 the connect failed (`last_errno`), 21 the
// attempt ran out of time. 0 if none has.
pub fn last_failure[&q](pool: &q Pool) -> [] int {
    return contents(pool.core.ci)[18];
}

// Why the last live connection was lost: the code the requests on it were answered with (1 the server closed it, 3 a read
// failed, 6 a write failed, 8 a reply larger than the slab, 10 not the protocol, 11 the server said FATAL, 12 the
// request timeout). 0 if none has been.
pub fn last_loss[&q](pool: &q Pool) -> [] int {
    return contents(pool.core.ci)[26];
}

// The `errno` of the last connect that failed.
pub fn last_errno[&q](pool: &q Pool) -> [] int {
    return contents(pool.core.ci)[19];
}

// Write the SQLSTATE of the last error the server answered a login or a statement with (5 bytes, `28P01` for a wrong password)
// into `out`; answers how many bytes (0 if there was none, or `out` is too small).
pub fn sqlstate[&q, &o](pool: &q Pool, out: &!o [byte]) -> [] int {
    let ci = contents(pool.core.ci);
    if ci[20] == 0 || len(out) < 5 {
        return 0;
    }
    var i = 0;
    while i < 5 {
        out[i] = byte_of(ci[20 + i]);
        i = i + 1;
    }
    return 5;
}

// ---------------------------------------------------------------------
// Failing, answering
// ---------------------------------------------------------------------

fn push_done[&c](core: &!c Core, k: int) -> [] int {
    let ring = contents(core.ring);
    ring[(core.ring_head + core.ring_count) % (core.lanes * core.depth)] = k;
    core.ring_count = core.ring_count + 1;
    return 0;
}

// Connection `k` is gone: close it, and make every request still in flight on it that has no
// reply yet an answer of its own, behind the replies it did get. It is then waiting to be remade.
fn kill[&t, &c](tab: &!t conns.Table, core: &!c Core, k: int, code: int) -> [] int {
    let st = contents(core.st);
    let p = stride() * k;
    if st[p + 6] != 1 {
        return 0;
    }
    st[p + 6] = 2;
    st[p + 9] = code;
    st[p + 7] = 0;
    st[p + 12] = 0 - 1;
    st[p + 23] = 0 - 1;
    st[p + 24] = 1;
    st[p + 3] = 0;
    st[p + 4] = 0;
    if st[p + 10] >= 0 {
        conns.close(tab, st[p + 10]);
        st[p + 10] = 0 - 1;
    }
    let ci = contents(core.ci);
    ci[14] = ci[14] + 1;
    ci[15] = ci[15] + 1;
    ci[26] = code;
    var lost = st[p + 5] - st[p + 2];
    while lost > 0 {
        push_done(core, k);
        lost = lost - 1;
    }
    return 0;
}

// An attempt to make connection `k` has failed for `code` (see `last_failure`): close it; it is retried after the
// backoff that the next `tick` works out.
fn fail_attempt[&t, &c](tab: &!t conns.Table, core: &!c Core, k: int, code: int) -> [] int {
    let st = contents(core.st);
    let p = stride() * k;
    if st[p + 6] != 3 {
        return 0;
    }
    if st[p + 10] >= 0 {
        conns.close(tab, st[p + 10]);
        st[p + 10] = 0 - 1;
    }
    st[p + 6] = 2;
    st[p + 7] = 0;
    st[p + 11] = 0;
    st[p] = 0;
    st[p + 1] = 0;
    st[p + 2] = 0;
    st[p + 3] = 0;
    st[p + 4] = 0;
    st[p + 12] = 0 - 1;
    st[p + 15] = st[p + 15] + 1;
    let ci = contents(core.ci);
    ci[13] = ci[13] + 1;
    ci[15] = ci[15] + 1;
    ci[18] = code;
    return 0;
}

// Whichever of the two connection `k` is in.
fn fail_lane[&t, &c](tab: &!t conns.Table, core: &!c Core, k: int, code: int) -> [] int {
    if contents(core.st)[stride() * k + 6] == 3 {
        return fail_attempt(tab, core, k, code);
    }
    return kill(tab, core, k, code);
}

// Connection `k` is down and has not been given a time to try again: give it one. A connection that was up long enough to
// be called stable is tried again at once, any other waits its turn: the wait is doubled for the one after, up to the
// longest.
fn reschedule[&c](core: &!c Core, k: int, now: int) -> [] int {
    let st = contents(core.st);
    let ci = contents(core.ci);
    let p = stride() * k;
    if st[p + 24] == 1 {
        st[p + 24] = 0;
        if st[p + 18] >= 0 && now - st[p + 18] >= stable_ms() {
            st[p + 13] = ci[7];
            st[p + 12] = now;
            return 0;
        }
    }
    st[p + 12] = now + st[p + 13];
    st[p + 13] = st[p + 13] * 2;
    if st[p + 13] > ci[8] {
        st[p + 13] = ci[8];
    }
    return 0;
}

// Connection `k`, logged in and prepared, takes requests.
fn go_live[&c](core: &!c Core, k: int) -> [] int {
    let st = contents(core.st);
    let ci = contents(core.ci);
    let p = stride() * k;
    st[p] = 0;
    st[p + 1] = 0;
    st[p + 2] = 0;
    st[p + 3] = 0;
    st[p + 4] = 0;
    st[p + 5] = 0;
    st[p + 6] = 1;
    st[p + 9] = 0;
    st[p + 11] = 0;
    st[p + 15] = 0;
    st[p + 18] = 0 - 1;
    st[p + 23] = 0 - 1;
    ci[17] = ci[17] + 1;
    ci[15] = ci[15] + 1;
    if st[p + 20] == 1 {
        ci[11] = ci[11] + 1;
    }
    st[p + 20] = 1;
    return 0;
}

// Whether the ErrorResponse at `at` in `m` is FATAL or PANIC, which end the session (a shutdown, a terminated backend, an
// idle timeout): the severity `V` is not translated, `S` is the one older servers have.
fn is_fatal[&b](m: &b [byte], at: int) -> [] bool {
    var f = 0 - 1;
    var t = 0 - 1;
    let (vf, vt) = pg.error_field(m, at, 86);
    f = vf;
    t = vt;
    if f < 0 {
        let (sf, st) = pg.error_field(m, at, 83);
        f = sf;
        t = st;
    }
    if f < 0 {
        return false;
    }
    return bytes.equal(m[f..t], "FATAL") || bytes.equal(m[f..t], "PANIC");
}

// Look through connection `k`'s new input for ReadyForQuery: every one is a reply that is
// whole. -1 if what is there is not the protocol, -2 if the server says it is ending the session.
fn frame[&c](core: &!c Core, k: int) -> [] int {
    let st = contents(core.st);
    let p = stride() * k;
    let base = k * core.in_cap;
    let m = contents(core.acc)[base..base + st[p]];
    var at = st[p + 1];
    var ok = 0;
    var going = true;
    while going {
        let n = pg.size(m, at);
        if n == 0 - 2 {
            ok = 0 - 1;
            going = false;
        } else if n < 0 {
            going = false;
        } else {
            if pg.kind(m, at) == 90 {
                st[p + 2] = st[p + 2] + 1;
                push_done(core, k);
            }
            if pg.kind(m, at) == 69 && is_fatal(m, at) {
                ok = 0 - 2;
                going = false;
            }
            at = at + n;
        }
    }
    st[p + 1] = at;
    if st[p + 2] > st[p + 5] {
        ok = 0 - 1;
    }
    return ok;
}

// Send what is queued on `k` until the kernel will take no more; watch for writing while some
// is left, and for reading alone when none is.
fn flush_lane[&t, &c, &p](tab: &!t conns.Table, core: &!c Core, poller: &!p Poller, k: int) -> [conn_write, poll] int {
    let st = contents(core.st);
    let q = contents(core.outq);
    let p = stride() * k;
    let base = k * core.out_cap;
    var blocked = false;
    while st[p + 4] < st[p + 3] && !blocked && (st[p + 6] == 1 || st[p + 6] == 3) {
        match conns.write(tab, st[p + 10], q[base + st[p + 4]..base + st[p + 3]]) {
            Sent::Wrote(w) => {
                st[p + 4] = st[p + 4] + w;
            }
            Sent::Again => {
                blocked = true;
            }
            Sent::Failed(e) => {
                fail_lane(tab, core, k, 6);
            }
        }
    }
    if st[p + 6] == 1 || st[p + 6] == 3 {
        if st[p + 4] == st[p + 3] {
            st[p + 3] = 0;
            st[p + 4] = 0;
            if st[p + 7] != 1 {
                if conns.rewatch(tab, poller, st[p + 10], core.base + k, 1) == 0 {
                    st[p + 7] = 1;
                } else {
                    fail_lane(tab, core, k, 6);
                }
            }
        } else if st[p + 7] != 3 {
            if conns.rewatch(tab, poller, st[p + 10], core.base + k, 3) == 0 {
                st[p + 7] = 3;
            } else {
                fail_lane(tab, core, k, 6);
            }
        }
    }
    return 0;
}

// ---------------------------------------------------------------------
// Submitting
// ---------------------------------------------------------------------

// Queue `request` (an encoded Bind/Execute/Sync, `pg.bind_named`) on the live connection with
// the fewest requests in flight; nothing is sent until `flush`, so that what a loop turn queues goes
// out in one write per connection, not one per request. `tag` comes back from `next_done` with its answer. Answers 0, or -1 if every connection is full (as deep as `depth`,
// or without room to queue it: say 503, or keep it for later), -2 if the request is larger than
// `out_cap` (it could never be queued), -3 if no connection is live (it was not queued, so it did not run).
pub fn submit[&q, &m](pool: &!q Pool, tag: int, request: &m [byte]) -> [] int {
    return submit_in(pool.core, tag, request);
}

fn submit_in[&c, &m](core: &!c Core, tag: int, request: &m [byte]) -> [] int {
    if len(request) > core.out_cap {
        return 0 - 2;
    }
    let st = contents(core.st);
    let q = contents(core.outq);
    var best = 0 - 1;
    var anywhere = false;
    var k = 0;
    while k < core.lanes {
        let p = stride() * k;
        if st[p + 6] == 1 {
            anywhere = true;
            if st[p + 5] < core.depth && st[p + 3] - st[p + 4] + len(request) <= core.out_cap {
                if best < 0 || st[p + 5] < st[stride() * best + 5] {
                    best = k;
                }
            }
        }
        k = k + 1;
    }
    if best < 0 {
        if anywhere {
            return 0 - 1;
        }
        return 0 - 3;
    }
    let p = stride() * best;
    let base = best * core.out_cap;
    // Room is at the end, or, once what was sent is dropped from the front, there.
    if st[p + 3] + len(request) > core.out_cap {
        var at = 0;
        while at < st[p + 3] - st[p + 4] {
            q[base + at] = q[base + st[p + 4] + at];
            at = at + 1;
        }
        st[p + 3] = st[p + 3] - st[p + 4];
        st[p + 4] = 0;
    }
    var i = 0;
    while i < len(request) {
        q[base + st[p + 3] + i] = request[i];
        i = i + 1;
    }
    st[p + 3] = st[p + 3] + len(request);
    contents(core.tags)[best * core.depth + (st[p + 8] + st[p + 5]) % core.depth] = tag;
    st[p + 5] = st[p + 5] + 1;
    return 0;
}

// Send what `submit` queued, on every connection that has some: one write each if the kernel takes it
// all, otherwise the rest goes as the poller reports the socket writable. Call it once per turn of the
// loop, after the turn's `submit`s.
pub fn flush[&q, &p](pool: &!q Pool, poller: &!p Poller) -> [conn_write, poll] int {
    return flush_all(pool.tab, pool.core, poller);
}

fn flush_all[&t, &c, &p](tab: &!t conns.Table, core: &!c Core, poller: &!p Poller) -> [conn_write, poll] int {
    let st = contents(core.st);
    var k = 0;
    while k < core.lanes {
        let p = stride() * k;
        if st[p + 6] == 1 && st[p + 4] < st[p + 3] {
            flush_lane(tab, core, poller, k);
        }
        k = k + 1;
    }
    return 0;
}

// ---------------------------------------------------------------------
// The poller's events
// ---------------------------------------------------------------------

// The poller reported `token` (`owns` says it is the pool's) ready for `readiness` (1 reading,
// 2 writing): send what was waiting, read what has come, and find the replies it completed. A
// connection that fails is closed and its requests answered with a status (`next_done`); one that is
// being made moves one step on (the steps that send something are `tick`'s).
pub fn pump[&q, &p](pool: &!q Pool, poller: &!p Poller, token: int, readiness: int) -> [conn_read, conn_write, poll] int {
    return pump_in(pool.tab, pool.core, poller, token, readiness);
}

fn pump_in[&t, &c, &p](tab: &!t conns.Table, core: &!c Core, poller: &!p Poller, token: int, readiness: int) -> [conn_read, conn_write, poll] int {
    let k = token - core.base;
    if k < 0 || k >= core.lanes {
        return 0 - 1;
    }
    let st = contents(core.st);
    let p = stride() * k;
    if st[p + 6] == 3 {
        return pump_login(tab, core, poller, k, readiness);
    }
    if st[p + 6] != 1 {
        return 0;
    }
    if readiness % 4 >= 2 {
        flush_lane(tab, core, poller, k);
    }
    if readiness % 2 == 1 && st[p + 6] == 1 {
        let base = k * core.in_cap;
        if st[p] >= core.in_cap {
            // Nothing to read into. Replies waiting to be taken make room when they are; a
            // single reply that fills it all will never be whole.
            if st[p + 2] == 0 {
                kill(tab, core, k, 8);
            }
        } else {
            match conns.read(tab, st[p + 10], contents(core.acc)[base + st[p]..base + core.in_cap]) {
                Received::Data(got) => {
                    st[p] = st[p] + got;
                    st[p + 23] = 0 - 1;
                    let framed = frame(core, k);
                    if framed == 0 - 1 {
                        kill(tab, core, k, 10);
                    } else if framed == 0 - 2 {
                        kill(tab, core, k, 11);
                    }
                }
                Received::End => {
                    kill(tab, core, k, 1);
                }
                Received::Again => {
                }
                Received::Failed(e) => {
                    kill(tab, core, k, 3);
                }
            }
        }
    }
    return 0;
}

// ---------------------------------------------------------------------
// Logging in
// ---------------------------------------------------------------------

// Connection `k` is being made and the poller reported it.
fn pump_login[&t, &c, &p](tab: &!t conns.Table, core: &!c Core, poller: &!p Poller, k: int, readiness: int) -> [conn_read, conn_write, poll] int {
    let st = contents(core.st);
    let ci = contents(core.ci);
    let p = stride() * k;
    if st[p + 11] == ph_connect() {
        // Writable, or an error, or hung up: the kernel has an answer to the connect.
        let e = conns.connect_status(tab, st[p + 10]);
        if e != 0 {
            ci[19] = e;
            fail_attempt(tab, core, k, 20);
            return 0;
        }
        // Connected: watch for reading alone from here, or the writable socket wakes the loop for ever.
        if conns.rewatch(tab, poller, st[p + 10], core.base + k, 1) != 0 {
            ci[19] = 0;
            fail_attempt(tab, core, k, 20);
            return 0;
        }
        st[p + 7] = 1;
        st[p + 11] = ph_startup();
        return 0;
    }
    if readiness % 4 >= 2 {
        flush_lane(tab, core, poller, k);
    }
    if readiness % 2 == 1 && st[p + 6] == 3 {
        let base = k * core.in_cap;
        if st[p] >= core.in_cap {
            fail_attempt(tab, core, k, 8);
        } else {
            match conns.read(tab, st[p + 10], contents(core.acc)[base + st[p]..base + core.in_cap]) {
                Received::Data(got) => {
                    st[p] = st[p] + got;
                    let code = scan_login(core, k);
                    if code != 0 {
                        fail_attempt(tab, core, k, code);
                    }
                }
                Received::End => {
                    fail_attempt(tab, core, k, 1);
                }
                Received::Again => {
                }
                Received::Failed(e) => {
                    fail_attempt(tab, core, k, 3);
                }
            }
        }
    }
    return 0;
}

// Go through the messages that have come since the last look: each moves the login on. 0, or why the attempt failed.
fn scan_login[&c](core: &!c Core, k: int) -> [] int {
    let st = contents(core.st);
    let ci = contents(core.ci);
    let p = stride() * k;
    let base = k * core.in_cap;
    let m = contents(core.acc)[base..base + st[p]];
    var at = st[p + 1];
    var code = 0;
    var going = true;
    while going {
        let n = pg.size(m, at);
        if n == 0 - 2 {
            code = 10;
            going = false;
        } else if n < 0 {
            going = false;
        } else {
            let kind = pg.kind(m, at);
            if kind == 69 {
                // ErrorResponse: the server refuses the login, or a statement; keep its SQLSTATE.
                let (cf, ct) = pg.error_field(m, at, 67);
                var i = 0;
                while i < 5 {
                    ci[20 + i] = 0;
                    if cf >= 0 && cf + i < ct {
                        ci[20 + i] = int_of(m[cf + i]);
                    }
                    i = i + 1;
                }
                code = 4;
                if st[p + 11] == ph_setup() {
                    code = 9;
                }
                going = false;
            } else if kind == 82 {
                code = on_auth(core, k, m, at, n);
                if code != 0 {
                    going = false;
                }
            } else if kind == 90 {
                code = on_ready(core, k);
                if st[p + 6] != 3 {
                    going = false;
                }
            }
            at = at + n;
        }
    }
    if st[p + 6] == 3 {
        st[p + 1] = at;
    }
    return code;
}

// An Authentication message at `at` (`n` bytes). 0, or why the attempt fails.
fn on_auth[&c, &b](core: &!c Core, k: int, m: &b [byte], at: int, n: int) -> [] int {
    let st = contents(core.st);
    let ci = contents(core.ci);
    let scr = contents(core.scr);
    let p = stride() * k;
    let ph = st[p + 11];
    let a = pg.auth_code(m, at);
    if a == 0 {
        if ph == ph_auth() || ph == ph_authok() {
            st[p + 11] = ph_ready();
            return 0;
        }
        if ph == ph_scram_verify() {
            // AuthOk before the server proved it knows the password
            return 7;
        }
        return 10;
    }
    if a == 3 {
        if ph == ph_auth() {
            st[p + 11] = ph_password();
            return 0;
        }
        return 10;
    }
    if a == 10 {
        if ph != ph_auth() {
            return 10;
        }
        // the list is names ended by a NUL each, so "SCRAM-SHA-256-PLUS" does not offer it
        if bytes.find(m[at + 9..at + n], "SCRAM-SHA-256\0") < 0 {
            return 5;
        }
        if ci[4] == 0 {
            return 7;
        }
        st[p + 11] = ph_scram_first();
        return 0;
    }
    if a == 11 {
        if ph != ph_scram_challenge() {
            return 10;
        }
        st[p + 21] = at + 9;
        st[p + 22] = at + n;
        st[p + 11] = ph_scram_salt();
        return 0;
    }
    if a == 12 {
        if ph != ph_scram_verify() {
            return 10;
        }
        let want = scr[k * scr_size() + 32..k * scr_size() + 32 + st[p + 17]];
        if !bytes.equal(m[at + 9..at + n], want) {
            return 7;
        }
        st[p + 11] = ph_authok();
        return 0;
    }
    return 5;
}

// ReadyForQuery during a login: the login is over, or one more statement is prepared.
fn on_ready[&c](core: &!c Core, k: int) -> [] int {
    let st = contents(core.st);
    let ci = contents(core.ci);
    let p = stride() * k;
    let ph = st[p + 11];
    if ph == ph_ready() {
        if ci[6] > 0 {
            st[p + 11] = ph_setup_send();
        } else {
            go_live(core, k);
        }
        return 0;
    }
    if ph == ph_setup() {
        st[p + 16] = st[p + 16] + 1;
        if st[p + 16] >= ci[6] {
            go_live(core, k);
        }
        return 0;
    }
    return 10;
}

// ---------------------------------------------------------------------
// Making connections
// ---------------------------------------------------------------------

// Make the pool keep its connections. Without this the pool is the one of `add`, which does not replace a connection it loses.
// With it every connection that is not in use is made by the loop (`tick`, `adopt`, `revive`): at the start, for a
// pool with none, and whenever one fails.
//
//   user, password, database   the login (trust, cleartext or SCRAM-SHA-256, as `pg.login`)
//   seed                       16 or more unpredictable bytes, read once from `/dev/urandom` by the caller: each SCRAM
//                              login gets a nonce that is a keyed hash of a counter under it. Empty: a SCRAM
//                              server is refused (status 7), as `pg.login` with no nonce does
//   setup, statements          what to send after the login, `statements` ReadyForQuery's worth: `statement` below
//                              builds it, `prepare_script` of a `pgen` module is one, empty if there is nothing to prepare
//   min_ms, max_ms             the wait after a failed attempt: `min_ms`, doubling to `max_ms`
//   attempt_ms                 the longest one attempt (dial, login, statements) may take
//   request_ms                 the longest a request may wait for its answer before the connection is given up
//                              (status 12); 0 for ever. Longer than the slowest query, or it kills the connection under it
//
// Answers the pool and 0, or -1 if an argument is not usable (the pool is returned as it was): a wait that is not 1 or
// more, `max_ms` below `min_ms`, a seed of 1 to 15 bytes, a script longer than `out_cap`.
pub fn reconnect[&h, &u, &w, &d, &s, &x](heap: &!h Heap, pool: Pool, user: &u [byte], password: &w [byte], database: &d [byte], seed: &s [byte], setup: &x [byte], statements: int, min_ms: int, max_ms: int, attempt_ms: int, request_ms: int) -> [heap] (Pool, int) {
    let Pool { tab, core } = pool;
    var state = core;
    var bad = min_ms < 1 || max_ms < min_ms || attempt_ms < 1 || request_ms < 0 || statements < 0 || len(seed) > 0 && len(seed) < 16;
    borrow state as &cr in {
        if len(setup) > cr.out_cap || len(user) > 4096 || len(database) > 4096 {
            bad = true;
        }
    }
    if bad {
        return (Pool { tab: tab, core: state }, 0 - 1);
    }
    let Core { st, acc, outq, tags, ring, scr, cfg, ci, lanes, depth, in_cap, out_cap, base, ring_head, ring_count, cur, cur_len, cur_status, cur_tag } = state;
    unbox_slice(heap, cfg);
    var fresh = box_slice(heap, len(user) + len(password) + len(database) + len(seed) + len(setup) + 1, byte_of(0));
    borrow mut fresh as &!fw in {
        let all = contents(fw);
        var at = 0;
        var i = 0;
        while i < len(user) {
            all[at + i] = user[i];
            i = i + 1;
        }
        at = at + len(user);
        i = 0;
        while i < len(password) {
            all[at + i] = password[i];
            i = i + 1;
        }
        at = at + len(password);
        i = 0;
        while i < len(database) {
            all[at + i] = database[i];
            i = i + 1;
        }
        at = at + len(database);
        i = 0;
        while i < len(seed) {
            all[at + i] = seed[i];
            i = i + 1;
        }
        at = at + len(seed);
        i = 0;
        while i < len(setup) {
            all[at + i] = setup[i];
            i = i + 1;
        }
    }
    var numbers = ci;
    var states = st;
    borrow mut numbers as &!nw in {
        let n = contents(nw);
        n[0] = 1;
        n[1] = len(user);
        n[2] = len(password);
        n[3] = len(database);
        n[4] = len(seed);
        n[5] = len(setup);
        n[6] = statements;
        n[7] = min_ms;
        n[8] = max_ms;
        n[9] = attempt_ms;
        n[10] = request_ms;
    }
    // every connection not in use is due now, with the first wait ahead of it
    borrow mut states as &!sw in {
        let s = contents(sw);
        var k = 0;
        while k < lanes {
            let p = stride() * k;
            s[p + 13] = min_ms;
            if s[p + 6] == 0 || s[p + 6] == 2 {
                s[p + 12] = 0;
            }
            k = k + 1;
        }
    }
    let rebuilt = Core { st: states, acc: acc, outq: outq, tags: tags, ring: ring, scr: scr, cfg: fresh, ci: numbers, lanes: lanes, depth: depth, in_cap: in_cap, out_cap: out_cap, base: base, ring_head: ring_head, ring_count: ring_count, cur: cur, cur_len: cur_len, cur_status: cur_status, cur_tag: cur_tag };
    return (Pool { tab: tab, core: rebuilt }, 0);
}

// Add a statement to the script `reconnect` takes: Parse `sql` as `name`, then Sync (`pg.parse_named`). Start from
// `buffer.empty` and count the calls.
pub fn statement[&h, &n, &s](heap: &!h Heap, script: buffer.Buffer, name: &n [byte], sql: &s [byte]) -> [heap] buffer.Buffer {
    return pg.parse_append(heap, script, name, sql);
}

// Whether connection `k` may start an attempt at `now`: the pool makes its connections, the loop has started it, the connection is down
// (or was never up), its wait is over, and the answers of the request it lost have all been taken.
fn due[&c](core: &c Core, k: int, now: int) -> [] bool {
    let st = contents(core.st);
    let p = stride() * k;
    if contents(core.ci)[0] != 1 || core.base < 0 {
        return false;
    }
    if st[p + 6] != 0 && st[p + 6] != 2 {
        return false;
    }
    return st[p + 12] >= 0 && st[p + 12] <= now && st[p + 5] == 0 && core.cur != k;
}

fn first_due[&c](core: &c Core, now: int) -> [] int {
    var k = 0;
    while k < core.lanes {
        if due(core, k, now) {
            return k;
        }
        k = k + 1;
    }
    return 0 - 1;
}

// The loop's turn: `now` is its clock (`clock_ms`, any origin, never going back). Works out the waits of connections that
// failed, gives up the logins that have run out of time and the connections whose requests have waited too long, and
// does the steps of a login that have something to send or compute (the poller's events do the rest, in `pump`).
// Call it once a turn, after the turn's `pump`s. Answers how many connections are due to be dialed now: make that many
// with `tcp_connect_start` and give each to `adopt` (or `dial_failed` if the dial failed), or call `revive` instead of
// both. A turn does at most about half a millisecond of work for each login that is computing a key.
pub fn tick[&h, &q, &p](heap: &!h Heap, pool: &!q Pool, poller: &!p Poller, now: int) -> [heap, conn_write, poll] int {
    return tick_in(heap, pool.tab, pool.core, poller, now);
}

fn tick_in[&h, &t, &c, &p](heap: &!h Heap, tab: &!t conns.Table, core: &!c Core, poller: &!p Poller, now: int) -> [heap, conn_write, poll] int {
    let st = contents(core.st);
    let ci = contents(core.ci);
    var want = 0;
    var k = 0;
    while k < core.lanes {
        let p = stride() * k;
        if st[p + 6] == 3 {
            if now >= st[p + 14] {
                fail_attempt(tab, core, k, 21);
            } else if ph_is_work(st[p + 11]) {
                step(heap, tab, core, poller, k);
            }
        } else if st[p + 6] == 1 {
            if st[p + 18] < 0 {
                st[p + 18] = now;
            }
            if ci[10] > 0 {
                if st[p + 5] > st[p + 2] {
                    if st[p + 23] < 0 {
                        st[p + 23] = now;
                    } else if now - st[p + 23] >= ci[10] {
                        kill(tab, core, k, 12);
                    }
                } else {
                    st[p + 23] = 0 - 1;
                }
            }
        }
        if (st[p + 6] == 2 || st[p + 6] == 0) && ci[0] == 1 && st[p + 12] < 0 {
            reschedule(core, k, now);
        }
        if due(core, k, now) {
            want = want + 1;
        }
        k = k + 1;
    }
    return want;
}

// Queue `msg` (consumed) as the whole of connection `k`'s output and send it. 0, or 8 if it is larger than `out_cap`.
fn send_message[&h, &t, &c, &p](heap: &!h Heap, tab: &!t conns.Table, core: &!c Core, poller: &!p Poller, k: int, msg: buffer.Buffer) -> [heap, conn_write, poll] int {
    var fits = false;
    borrow msg as &mr in {
        let m = buffer.bytes(mr);
        if len(m) <= core.out_cap {
            fits = true;
            let st = contents(core.st);
            let q = contents(core.outq);
            let p = stride() * k;
            let base = k * core.out_cap;
            var i = 0;
            while i < len(m) {
                q[base + i] = m[i];
                i = i + 1;
            }
            st[p + 3] = len(m);
            st[p + 4] = 0;
        }
    }
    buffer.drop(heap, msg);
    if !fits {
        return 8;
    }
    flush_lane(tab, core, poller, k);
    return 0;
}

// A nonce for connection `k`'s SCRAM login: 18 bytes of a keyed hash of a counter, in base64 (24 characters, no comma), into
// its scratch.
fn make_nonce[&h, &c](heap: &!h Heap, core: &!c Core, k: int) -> [heap] int {
    let ci = contents(core.ci);
    let cfg = contents(core.cfg);
    let seed_at = ci[1] + ci[2] + ci[3];
    ci[16] = ci[16] + 1;
    var data = buffer.append(heap, buffer.empty(heap, 40), "lexsys-pg scram nonce ");
    data = buffer.push(heap, data, byte_of(k));
    var n = ci[16];
    var i = 0;
    while i < 8 {
        data = buffer.push(heap, data, byte_of(n % 256));
        n = n / 256;
        i = i + 1;
    }
    var mac = buffer.empty(heap, 8);
    borrow data as &dr in {
        buffer.drop(heap, mac);
        mac = pg.hmac_sha256(heap, cfg[seed_at..seed_at + ci[4]], buffer.bytes(dr));
    }
    buffer.drop(heap, data);
    var text = buffer.empty(heap, 8);
    borrow mac as &mr in {
        buffer.drop(heap, text);
        text = pg.base64_encode(heap, buffer.bytes(mr)[0..18]);
    }
    buffer.drop(heap, mac);
    let scr = contents(core.scr);
    borrow text as &tr in {
        let t = buffer.bytes(tr);
        var j = 0;
        while j < 24 && j < len(t) {
            scr[k * scr_size() + j] = t[j];
            j = j + 1;
        }
    }
    buffer.drop(heap, text);
    return 0;
}

// The step of connection `k`'s login that `tick` does, in the phase it is in. A failure ends the attempt.
fn step[&h, &t, &c, &p](heap: &!h Heap, tab: &!t conns.Table, core: &!c Core, poller: &!p Poller, k: int) -> [heap, conn_write, poll] int {
    let st = contents(core.st);
    let ci = contents(core.ci);
    let cfg = contents(core.cfg);
    let scr = contents(core.scr);
    let p = stride() * k;
    let ph = st[p + 11];
    let user = cfg[0..ci[1]];
    let secret = cfg[ci[1]..ci[1] + ci[2]];
    let database = cfg[ci[1] + ci[2]..ci[1] + ci[2] + ci[3]];
    let setup = cfg[ci[1] + ci[2] + ci[3] + ci[4]..ci[1] + ci[2] + ci[3] + ci[4] + ci[5]];
    let nonce = scr[k * scr_size()..k * scr_size() + 24];
    var code = 0;
    var next = 0;
    if ph == ph_startup() {
        let hello = pg.startup(heap, user, database);
        code = send_message(heap, tab, core, poller, k, hello);
        next = ph_auth();
    } else if ph == ph_password() {
        let reply = pg.password(heap, secret);
        code = send_message(heap, tab, core, poller, k, reply);
        next = ph_authok();
    } else if ph == ph_scram_first() {
        make_nonce(heap, core, k);
        let first = pg.scram_client_first(heap, "", nonce);
        var msg = buffer.empty(heap, 8);
        borrow first as &fr in {
            buffer.drop(heap, msg);
            msg = pg.sasl_initial(heap, buffer.bytes(fr));
        }
        buffer.drop(heap, first);
        code = send_message(heap, tab, core, poller, k, msg);
        next = ph_scram_challenge();
    } else if ph == ph_scram_salt() {
        let base = k * core.in_cap;
        let challenge = contents(core.acc)[base + st[p + 21]..base + st[p + 22]];
        let (iterations, checked) = pg.scram_iterations(challenge, nonce);
        let (salt, ok) = pg.scram_salt(heap, challenge);
        if checked != 0 || !ok {
            code = 7;
        } else {
            borrow salt as &sr in {
                pg.pbkdf2_begin(heap, secret, buffer.bytes(sr), scr[k * scr_size() + 96..k * scr_size() + 160]);
            }
            st[p + 19] = iterations - 1;
            next = ph_scram_work();
        }
        buffer.drop(heap, salt);
    } else if ph == ph_scram_work() {
        var now_do = st[p + 19];
        if now_do > work_chunk() {
            now_do = work_chunk();
        }
        pg.pbkdf2_more(heap, secret, scr[k * scr_size() + 96..k * scr_size() + 160], now_do);
        st[p + 19] = st[p + 19] - now_do;
        if st[p + 19] > 0 {
            next = ph_scram_work();
        } else {
            let base = k * core.in_cap;
            let challenge = contents(core.acc)[base + st[p + 21]..base + st[p + 22]];
            let (final, expected, status) = pg.scram_client_final_with(heap, scr[k * scr_size() + 96 + 32..k * scr_size() + 160], "", nonce, challenge);
            var msg = buffer.empty(heap, 8);
            if status != 0 {
                code = 7;
            } else {
                borrow expected as &er in {
                    let want = buffer.bytes(er);
                    if len(want) > 64 {
                        code = 7;
                    } else {
                        var i = 0;
                        while i < len(want) {
                            scr[k * scr_size() + 32 + i] = want[i];
                            i = i + 1;
                        }
                        st[p + 17] = len(want);
                    }
                }
                borrow final as &fr in {
                    buffer.drop(heap, msg);
                    msg = pg.sasl_response(heap, buffer.bytes(fr));
                }
            }
            buffer.drop(heap, final);
            buffer.drop(heap, expected);
            if code == 0 {
                code = send_message(heap, tab, core, poller, k, msg);
                next = ph_scram_verify();
            } else {
                buffer.drop(heap, msg);
            }
        }
    } else if ph == ph_setup_send() {
        let script = buffer.append(heap, buffer.empty(heap, len(setup) + 1), setup);
        code = send_message(heap, tab, core, poller, k, script);
        st[p + 16] = 0;
        next = ph_setup();
    }
    if code != 0 {
        fail_attempt(tab, core, k, code);
    } else if st[p + 6] == 3 && next > 0 {
        st[p + 11] = next;
    }
    return 0;
}

// A dialed connection `conn` (from `tcp_connect_start`, so that it is not yet connected) for the connection that is due
// first at `now`: it is put in the pool, watched for the connect to finish, and the login begins; the attempt has
// `attempt_ms` from `now`. Answers the pool and the number of the connection, or -1 if none is due (the connection is
// closed), or the connection could not be taken (closed, and the attempt counted as failed).
pub fn adopt[&h, &p](heap: &!h Heap, pool: Pool, poller: &!p Poller, now: int, conn: Conn) -> [heap, poll] (Pool, int) {
    let Pool { tab, core } = pool;
    var table = tab;
    var state = core;
    var lane = 0 - 1;
    borrow state as &cr in {
        lane = first_due(cr, now);
    }
    if lane < 0 {
        conn_close(conn);
        return (Pool { tab: table, core: state }, 0 - 1);
    }
    let (grown, number) = conns.put(heap, table, conn);
    table = grown;
    var out = lane;
    borrow mut state as &!cw in {
        let st = contents(cw.st);
        let ci = contents(cw.ci);
        let p = stride() * lane;
        ci[12] = ci[12] + 1;
        var watched = 0 - 1;
        if number >= 0 {
            borrow mut table as &!tw in {
                conns.nonblocking(tw, number);
                watched = conns.watch(tw, poller, number, cw.base + lane, 2);
                if watched != 0 {
                    conns.close(tw, number);
                }
            }
        }
        if watched == 0 {
            st[p] = 0;
            st[p + 1] = 0;
            st[p + 2] = 0;
            st[p + 3] = 0;
            st[p + 4] = 0;
            st[p + 5] = 0;
            st[p + 6] = 3;
            st[p + 7] = 2;
            st[p + 10] = number;
            st[p + 11] = ph_connect();
            st[p + 14] = now + ci[9];
            st[p + 16] = 0;
        } else {
            ci[13] = ci[13] + 1;
            ci[15] = ci[15] + 1;
            ci[18] = 20;
            ci[19] = 0;
            st[p + 10] = 0 - 1;
            st[p + 15] = st[p + 15] + 1;
            st[p + 12] = 0 - 1;
            reschedule(cw, lane, now);
            out = 0 - 1;
        }
    }
    return (Pool { tab: table, core: state }, out);
}

// A dial for the connection that is due first at `now` failed at once, with `errno` (`Dialed::Failed`): count it, and
// make the connection wait its backoff. Answers the connection, or -1 if none was due.
pub fn dial_failed[&q](pool: &!q Pool, now: int, errno: int) -> [] int {
    return dial_failed_in(pool.core, now, errno);
}

fn dial_failed_in[&c](core: &!c Core, now: int, errno: int) -> [] int {
    let lane = first_due(core, now);
    if lane < 0 {
        return 0 - 1;
    }
    let st = contents(core.st);
    let ci = contents(core.ci);
    let p = stride() * lane;
    ci[12] = ci[12] + 1;
    ci[13] = ci[13] + 1;
    ci[15] = ci[15] + 1;
    ci[18] = 20;
    ci[19] = errno;
    st[p + 15] = st[p + 15] + 1;
    st[p + 12] = 0 - 1;
    reschedule(core, lane, now);
    return lane;
}

// `tick`, then a `tcp_connect_start` and `adopt` for each connection that is due: the pool keeping itself full, for a
// program that holds the whole network (`Net("")`; a program narrowed to one host calls the three itself, so that its
// authority says so). `host` is best an IP address: a name is resolved by a call that waits. Answers the pool.
pub fn revive[&h, &n, &t, &p](heap: &!h Heap, pool: Pool, net: &n Net(""), host: &t [byte], port: int, poller: &!p Poller, now: int) -> [heap, net_out(""), conn_write, poll] Pool {
    var pl = pool;
    var want = 0;
    borrow mut pl as &!w in {
        want = tick(heap, w, poller, now);
    }
    while want > 0 {
        match tcp_connect_start(net, host, port) {
            Dialed::Ok(c) => {
                let (grown, lane) = adopt(heap, pl, poller, now, c);
                pl = grown;
            }
            Dialed::Failed(e) => {
                borrow mut pl as &!w in {
                    dial_failed(w, now, e);
                }
            }
        }
        want = want - 1;
    }
    return pl;
}

// How long (ms) the loop may sleep before the pool needs a turn: 0 if there is work to do now (a login with something to
// send or a key to compute, or a connection that is due); the time to the nearest deadline or retry otherwise; -1 if
// there is nothing the clock has to wake the loop for. The poller's events wake it for the rest. Use the smaller of
// this and the loop's own timeout.
pub fn next_wake[&q](pool: &q Pool, now: int) -> [] int {
    let core = pool.core;
    let st = contents(core.st);
    let ci = contents(core.ci);
    var best = 0 - 1;
    var k = 0;
    while k < core.lanes {
        let p = stride() * k;
        var at = 0 - 1;
        if st[p + 6] == 3 {
            if ph_is_work(st[p + 11]) {
                at = now;
            } else {
                at = st[p + 14];
            }
        } else if (st[p + 6] == 0 || st[p + 6] == 2) && ci[0] == 1 && core.base >= 0 {
            if st[p + 12] < 0 {
                at = now;
            } else if st[p + 5] == 0 && core.cur != k {
                at = st[p + 12];
            }
        } else if st[p + 6] == 1 && ci[10] > 0 && st[p + 5] > st[p + 2] {
            if st[p + 23] < 0 {
                at = now;
            } else {
                at = st[p + 23] + ci[10];
            }
        }
        if at >= 0 {
            var wait = at - now;
            if wait < 0 {
                wait = 0;
            }
            if best < 0 || wait < best {
                best = wait;
            }
        }
        k = k + 1;
    }
    return best;
}

// ---------------------------------------------------------------------
// Taking answers
// ---------------------------------------------------------------------

// Drop the answer last handed out from the front of its connection's input.
fn consume[&c](core: &!c Core) -> [] int {
    let k = core.cur;
    if k < 0 {
        return 0;
    }
    core.cur = 0 - 1;
    let n = core.cur_len;
    if n > 0 {
        let st = contents(core.st);
        let acc = contents(core.acc);
        let p = stride() * k;
        let base = k * core.in_cap;
        var at = 0;
        while at < st[p] - n {
            acc[base + at] = acc[base + n + at];
            at = at + 1;
        }
        st[p] = st[p] - n;
        st[p + 1] = st[p + 1] - n;
    }
    return 0;
}

// The tag of the next request that has an answer, or -1 if none has. `reply` and `status` then
// describe it, until the next call. Answers come in the order the connections gave them, and in
// the order submitted on each connection.
pub fn next_done[&q](pool: &!q Pool) -> [] int {
    return next_in(pool.core);
}

fn next_in[&c](core: &!c Core) -> [] int {
    consume(core);
    if core.ring_count == 0 {
        return 0 - 1;
    }
    let st = contents(core.st);
    let k = contents(core.ring)[core.ring_head];
    core.ring_head = (core.ring_head + 1) % (core.lanes * core.depth);
    core.ring_count = core.ring_count - 1;
    let p = stride() * k;
    let tag = contents(core.tags)[k * core.depth + st[p + 8]];
    st[p + 8] = (st[p + 8] + 1) % core.depth;
    st[p + 5] = st[p + 5] - 1;
    core.cur = k;
    core.cur_tag = tag;
    if st[p + 2] > 0 {
        // The reply ends at the first ReadyForQuery.
        st[p + 2] = st[p + 2] - 1;
        let m = contents(core.acc)[k * core.in_cap..k * core.in_cap + st[p]];
        var at = 0;
        var end = 0;
        while end == 0 {
            let n = pg.size(m, at);
            if n > 0 {
                at = at + n;
                if pg.kind(m, at - n) == 90 {
                    end = at;
                }
            } else {
                end = at;
            }
        }
        core.cur_len = end;
        core.cur_status = 0;
    } else {
        core.cur_len = 0;
        core.cur_status = st[p + 9];
    }
    return tag;
}

// The reply to the request `next_done` last answered: every message the server sent for it, up to and including
// ReadyForQuery, as `pg.run_named` returns them. Empty when `status` is not 0.
pub fn reply[&q](pool: &q Pool) -> [] &q [byte] {
    let core = pool.core;
    if core.cur < 0 {
        return contents(core.acc)[0..0];
    }
    let base = core.cur * core.in_cap;
    return contents(core.acc)[base..base + core.cur_len];
}

// 0 if the request `next_done` last answered has its reply; otherwise why not (see the top, and `lost`).
pub fn status[&q](pool: &q Pool) -> [] int {
    return pool.core.cur_status;
}
