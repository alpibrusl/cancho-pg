edition 5;

module pg.pool;

// `pg.pool` -- connections that do not wait (`docs/nonblocking.md` §4.2).
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
// server).
//
// Sizes are fixed when the pool is made and nothing is allocated afterwards: per connection an
// input slab (`in_cap`: the replies waiting to be taken, and a reply that does not fit is a
// failure, status 8), an output slab (`out_cap`) and `depth` requests in flight.
//
// Status codes, as in `pg`: 0 ok; 1 the server closed the connection; 3 a read failed; 6 a write
// failed; 8 a reply larger than `in_cap`; 10 a message that is not the protocol.

import std.conns;
import pg;

// Per connection `k`, `st[12k..12k+12]` is:
//
//      0  bytes of input accumulated
//      1  how much of that is framed already (looked through for ReadyForQuery)
//      2  complete replies in the input that `next_done` has not given out
//      3  bytes of output queued
//      4  how much of that the kernel has taken
//      5  requests in flight (queued or sent, and not yet given out)
//      6  0 never used, 1 live, 2 dead
//      7  what it is watched for: 1 readable, 3 readable and writable
//      8  where the ring of tags starts
//      9  why it died
fn stride() -> [] int {
    return 12;
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
    let core = Core { st: box_slice(heap, stride() * lanes, 0), acc: box_slice(heap, lanes * in_cap, byte_of(0)), outq: box_slice(heap, lanes * out_cap, byte_of(0)), tags: box_slice(heap, lanes * depth, 0), ring: box_slice(heap, lanes * depth, 0), lanes: lanes, depth: depth, in_cap: in_cap, out_cap: out_cap, base: 0 - 1, ring_head: 0, ring_count: 0, cur: 0 - 1, cur_len: 0, cur_status: 0, cur_tag: 0 - 1 };
    return Pool { tab: conns.empty(heap, lanes), core: core };
}

// End the pool: every connection still open is closed and the slabs freed.
pub fn close[&h](heap: &!h Heap, pool: Pool) -> [heap] int {
    let Pool { tab, core } = pool;
    conns.drop(heap, tab);
    let Core { st, acc, outq, tags, ring, lanes, depth, in_cap, out_cap, base, ring_head, ring_count, cur, cur_len, cur_status, cur_tag } = core;
    unbox_slice(heap, st);
    unbox_slice(heap, acc);
    unbox_slice(heap, outq);
    unbox_slice(heap, tags);
    unbox_slice(heap, ring);
    return 0;
}

// Add a connection that is logged in, has its statements prepared and has nothing unread; it is made
// non-blocking. Answers the pool and the connection's number, or -1 if there is no room (the
// connection is closed) or it could not be set up (closed too), or -2 if the number it would take
// still has answers waiting on it from a connection that died (try again once `next_done` has
// given them out; the connection is closed). It is not watched until `start`.
pub fn add[&h](heap: &!h Heap, pool: Pool, conn: Conn) -> [heap] (Pool, int) {
    let Pool { tab, core } = pool;
    var table = tab;
    var state = core;
    var slot = 0 - 1;
    var full = false;
    borrow table as &tr in {
        borrow state as &cr in {
            full = conns.live(tr) >= cr.lanes;
        }
    }
    if full {
        conn_close(conn);
        return (Pool { tab: table, core: state }, 0 - 1);
    }
    let (grown, number) = conns.put(heap, table, conn);
    table = grown;
    slot = number;
    if slot >= 0 {
        borrow mut table as &!tw in {
            borrow mut state as &!cw in {
                let st = contents(cw.st);
                let p = stride() * slot;
                if slot >= cw.lanes {
                    conns.close(tw, slot);
                    slot = 0 - 1;
                } else if st[p] != 0 || st[p + 5] != 0 || st[p + 2] != 0 {
                    conns.close(tw, slot);
                    slot = 0 - 2;
                } else if conns.nonblocking(tw, slot) != 0 {
                    conns.close(tw, slot);
                    slot = 0 - 1;
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
                }
            }
        }
    }
    return (Pool { tab: table, core: state }, slot);
}

// Watch every connection that is not watched yet in `poller`, for reading, under the tokens
// `first_token` and up (connection `k` is `first_token + k`; the pool takes `lanes` tokens). Call
// it once after the first `add`s, and again after any later one. Answers how many it could not
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
            if conns.watch(tab, poller, k, first_token + k, 1) == 0 {
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

// How many connections are live.
pub fn live[&q](pool: &q Pool) -> [] int {
    let st = contents(pool.core.st);
    var n = 0;
    var k = 0;
    while k < pool.core.lanes {
        if st[stride() * k + 6] == 1 {
            n = n + 1;
        }
        k = k + 1;
    }
    return n;
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
// reply yet an answer of its own, behind the replies it did get.
fn kill[&t, &c](tab: &!t conns.Table, core: &!c Core, k: int, code: int) -> [] int {
    let st = contents(core.st);
    let p = stride() * k;
    if st[p + 6] != 1 {
        return 0;
    }
    st[p + 6] = 2;
    st[p + 9] = code;
    conns.close(tab, k);
    var lost = st[p + 5] - st[p + 2];
    while lost > 0 {
        push_done(core, k);
        lost = lost - 1;
    }
    return 0;
}

// Look through connection `k`'s new input for ReadyForQuery: every one is a reply that is
// whole. -1 if what is there is not the protocol.
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
    while st[p + 4] < st[p + 3] && !blocked && st[p + 6] == 1 {
        match conns.write(tab, k, q[base + st[p + 4]..base + st[p + 3]]) {
            Sent::Wrote(w) => {
                st[p + 4] = st[p + 4] + w;
            }
            Sent::Again => {
                blocked = true;
            }
            Sent::Failed(e) => {
                kill(tab, core, k, 6);
            }
        }
    }
    if st[p + 6] == 1 {
        if st[p + 4] == st[p + 3] {
            st[p + 3] = 0;
            st[p + 4] = 0;
            if st[p + 7] != 1 {
                if conns.rewatch(tab, poller, k, core.base + k, 1) == 0 {
                    st[p + 7] = 1;
                } else {
                    kill(tab, core, k, 6);
                }
            }
        } else if st[p + 7] != 3 {
            if conns.rewatch(tab, poller, k, core.base + k, 3) == 0 {
                st[p + 7] = 3;
            } else {
                kill(tab, core, k, 6);
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
// `out_cap` (it could never be queued), -3 if no connection is live.
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
// connection that fails is closed and its requests answered with a status (`next_done`).
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
            match conns.read(tab, k, contents(core.acc)[base + st[p]..base + core.in_cap]) {
                Received::Data(got) => {
                    st[p] = st[p] + got;
                    if frame(core, k) < 0 {
                        kill(tab, core, k, 10);
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

// The reply to the request `next_done` last answered: every message the server sent for it, up to
// and including ReadyForQuery, as `pg.run_named` returns them. Empty when `status` is not 0.
pub fn reply[&q](pool: &q Pool) -> [] &q [byte] {
    let core = pool.core;
    if core.cur < 0 {
        return contents(core.acc)[0..0];
    }
    let base = core.cur * core.in_cap;
    return contents(core.acc)[base..base + core.cur_len];
}

// 0 if the request `next_done` last answered has its reply; otherwise why not (see the top).
pub fn status[&q](pool: &q Pool) -> [] int {
    return pool.core.cur_status;
}
