edition 5;

import std.buffer;
import std.io;
import pg;
import pg.pool;

// Drives `pg.pool` that makes its own connections (`pool.reconnect`, `pool.revive`) against a server, for
// `tests/reconnect_test.py`, which cuts and restores the network, kills backends and reads what this prints.
//
//     reconnect_drive <host> <port> <user> <database> <password|-> <lanes> <seconds> <mode> <min ms> <max ms> <attempt ms> <request ms> [<period ms> [noseed]]
//
// There is no blocking login: the pool starts with no connection and the loop dials them, so the first line is
// printed at once whatever the server is doing. The loop wakes at least every 10 ms (less if the pool says it need
// not), calls `pool.revive` every turn, and for `seconds` of the clock submits a request every `period` ms
// (default 20): `dbl` (tag * 2), or `slow` (the same after 0.4 s) in mode `slow`; in mode `idle` none; in mode `lazy` as `dbl`,
// but the answers are only taken every 300 ms. Lines, each
// beginning with the milliseconds since the start:
//
//     ev <t> live <n> connecting <n> reconnects <n> attempts <n> failures <n> losses <n> last <code> errno <e>
//         whenever `pool.changes` moved (and once at the start)
//     done <t> <tag> <status> <value, or - for no row, then the SQLSTATE if the server refused>
//     finished <t> maxbusy <ms> maxgap <ms> turns <n> done <n> ok <n> refused3 <n> full <n> live <n> reconnects <n> ...
//
// `maxbusy` is the longest the loop spent between one return of `poller_wait` and the next call of it: what a
// request to the loop would wait for, on top of the sleep. `maxgap` is the longest between two turns.
// A line `stop` on a line of its own is printed when the run is over; `ready` once the first connection is live.

fn number_of[&t](text: &t [byte]) -> [] int {
    if len(text) == 0 || len(text) > 17 {
        return 0 - 1;
    }
    var n = 0;
    var i = 0;
    while i < len(text) {
        let c = int_of(text[i]);
        if c < 48 || c > 57 {
            return 0 - 1;
        }
        n = n * 10 + (c - 48);
        i = i + 1;
    }
    return n;
}

// The lines go to standard error, which is not buffered when the other end is a pipe (standard output is, and the test
// reads them as they come).
fn word[&h, &r](heap: &!h Heap, b: buffer.Buffer, w: &r [byte]) -> [heap] buffer.Buffer {
    return buffer.append(heap, b, w);
}

fn field[&h](heap: &!h Heap, b: buffer.Buffer, name: &static [byte], n: int) -> [heap] buffer.Buffer {
    var o = buffer.append(heap, b, " ");
    o = buffer.append(heap, o, name);
    o = buffer.append(heap, o, " ");
    return buffer.push_nat(heap, o, n);
}

fn emit[&h, &i](heap: &!h Heap, io: &!i Io, b: buffer.Buffer) -> [heap, err_write] int {
    borrow b as &br in {
        io.error_all(io, buffer.bytes(br));
    }
    buffer.drop(heap, b);
    return 0;
}

fn counters[&h, &q](heap: &!h Heap, b: buffer.Buffer, pl: &q pool.Pool) -> [heap] buffer.Buffer {
    var o = field(heap, b, "live", pool.live(pl));
    o = field(heap, o, "connecting", pool.connecting(pl));
    o = field(heap, o, "made", pool.made(pl));
    o = field(heap, o, "reconnects", pool.reconnects(pl));
    o = field(heap, o, "attempts", pool.attempts(pl));
    o = field(heap, o, "failures", pool.failures(pl));
    o = field(heap, o, "losses", pool.losses(pl));
    o = field(heap, o, "last", pool.last_failure(pl));
    o = field(heap, o, "errno", pool.last_errno(pl));
    o = field(heap, o, "loss", pool.last_loss(pl));
    region a {
        let out = alloc_slice[a](5, byte_of(0));
        if pool.sqlstate(pl, out) == 5 {
            o = buffer.append(heap, o, " sqlstate ");
            o = buffer.append(heap, o, out);
        }
    }
    return o;
}

fn stamp[&h](heap: &!h Heap, w: &static [byte], t: int) -> [heap] buffer.Buffer {
    var o = buffer.append(heap, buffer.empty(heap, 128), w);
    o = buffer.append(heap, o, " ");
    return buffer.push_nat(heap, o, t);
}

fn fresh_seed[&h, &f](heap: &!h Heap, fs: &f Fs("/dev/urandom")) -> [heap, fs_read("/dev/urandom")] buffer.Buffer {
    var seed = buffer.empty(heap, 32);
    region a {
        let raw = alloc_slice[a](32, byte_of(0));
        let got = fs_read(fs, "/dev/urandom", raw);
        if got == 32 {
            seed = buffer.append(heap, seed, raw);
        }
    }
    return seed;
}

fn request[&h](heap: &!h Heap, name: &static [byte], n: int) -> [heap] buffer.Buffer {
    var ps = pg.params(heap);
    ps = pg.param_int(heap, ps, n);
    var m = buffer.empty(heap, 1);
    borrow ps as &pr in {
        buffer.drop(heap, m);
        m = pg.bind_named(heap, name, pr);
    }
    pg.drop_params(heap, ps);
    return m;
}

fn show[&h, &i, &q](heap: &!h Heap, io: &!i Io, pl: &q pool.Pool, t: int, tag: int) -> [heap, err_write] int {
    var o = stamp(heap, "done", t);
    o = buffer.append(heap, o, " ");
    o = buffer.push_nat(heap, o, tag);
    o = buffer.append(heap, o, " ");
    o = buffer.push_nat(heap, o, pool.status(pl));
    o = buffer.append(heap, o, " ");
    let m = pool.reply(pl);
    let row = pg.first_row(m);
    if row < 0 {
        o = buffer.append(heap, o, "-");
        let at = pg.failure(m);
        if at >= 0 {
            let (from, to) = pg.error_field(m, at, 67);
            o = buffer.append(heap, o, " ");
            o = buffer.append(heap, o, m[from..to]);
        }
    } else {
        let (from, to) = pg.value(m, row, 0);
        o = buffer.append(heap, o, m[from..to]);
    }
    o = buffer.append(heap, o, "\n");
    emit(heap, io, o);
    return 0;
}

fn run[&h, &i, &n, &k, &z, &g](heap: &!h Heap, io: &!i Io, net: &n Net(""), clock: &k Clock, rng: &z Fs("/dev/urandom"), args: &g Args, lanes: int, seconds: int, min_ms: int, max_ms: int, attempt_ms: int, request_ms: int, period: int) -> [heap, err_write, net_out(""), conn_read, conn_write, poll, clock, args, fs_read("/dev/urandom")] int {
    let slow = int_of(arg(args, 8)[0]) == 115;
    let idle = int_of(arg(args, 8)[0]) == 105;
    let lazy = int_of(arg(args, 8)[0]) == 108;
    let port = number_of(arg(args, 2));
    let started = clock_ms(clock);
    var pl = pool.empty(heap, lanes, 64, 65536, 65536);
    var script = buffer.empty(heap, 256);
    script = pool.statement(heap, script, "dbl", "select ($1::int8 * 2)::text");
    script = pool.statement(heap, script, "slow", "select ($1::int8 * 2)::text from pg_sleep(0.4)");
    script = pool.statement(heap, script, "len", "select length($1::text)::text");
    var seed = fresh_seed(heap, rng);
    if arg_count(args) >= 15 {
        // a fifteenth argument: no seed, so that a SCRAM login cannot be made
        buffer.drop(heap, seed);
        seed = buffer.empty(heap, 1);
    }
    var secret = arg(args, 5);
    if len(secret) == 1 && int_of(secret[0]) == 45 {
        secret = "";
    }
    var code = 0;
    borrow seed as &sr in {
        borrow script as &cr in {
            let (made, rc) = pool.reconnect(heap, pl, arg(args, 3), secret, arg(args, 4), buffer.bytes(sr), buffer.bytes(cr), 3, min_ms, max_ms, attempt_ms, request_ms);
            pl = made;
            if rc != 0 {
                code = 105;
            }
        }
    }
    buffer.drop(heap, seed);
    buffer.drop(heap, script);
    match poller_new() {
        Polling::Ok(po) => {
            var poller = po;
            borrow mut poller as &!pw in {
                borrow mut pl as &!sw in {
                    pool.start(sw, pw, 1);
                }
            }
            var events = box_slice(heap, 64, 0);
            var seen = 0 - 1;
            var next_tag = 0;
            var next_at = started;
            var last_take = started;
            var last_turn = started;
            var woke = started;
            var maxbusy = 0;
            var over1 = 0;
            var over2 = 0;
            var over5 = 0;
            var over10 = 0;
            var maxgap = 0;
            var turns = 0;
            var answered = 0;
            var ok = 0;
            var refused3 = 0;
            var full = 0;
            var announced = false;
            var finished = false;
            var over = false;
            while !finished {
                let now = clock_ms(clock);
                let t = now - started;
                // the loop's own clock: the longest between two turns, and the longest a turn kept the loop from waiting
                if now - last_turn > maxgap {
                    maxgap = now - last_turn;
                }
                last_turn = now;
                borrow mut poller as &!pw in {
                    pl = pool.revive(heap, pl, net, arg(args, 1), port, pw, now);
                }
                var changed = false;
                borrow pl as &qr in {
                    if pool.changes(qr) != seen {
                        seen = pool.changes(qr);
                        changed = true;
                    }
                }
                if changed || turns == 0 {
                    var line = stamp(heap, "ev", t);
                    line = field(heap, line, "turns", turns);
                    borrow pl as &qr in {
                        line = counters(heap, line, qr);
                    }
                    line = word(heap, line, "\n");
                    emit(heap, io, line);
                }
                var wait = 10;
                borrow pl as &qr in {
                    let w = pool.next_wake(qr, now);
                    if w >= 0 && w < wait {
                        wait = w;
                    }
                    if !announced && pool.live(qr) > 0 {
                        announced = true;
                        emit(heap, io, word(heap, buffer.empty(heap, 8), "ready\n"));
                    }
                }
                var ready = 0;
                borrow mut poller as &!pw in {
                    borrow mut events as &!ew in {
                        woke = clock_ms(clock);
                        if woke - now > maxbusy {
                            maxbusy = woke - now;
                        }
                        if woke - now >= 1 {
                            over1 = over1 + 1;
                        }
                        if woke - now >= 2 {
                            over2 = over2 + 1;
                        }
                        if woke - now >= 5 {
                            over5 = over5 + 1;
                        }
                        if woke - now >= 10 {
                            over10 = over10 + 1;
                        }
                        ready = poller_wait(pw, contents(ew), wait);
                        woke = clock_ms(clock);
                    }
                }
                var j = 0;
                while j < ready {
                    var token = 0 - 1;
                    var readiness = 0;
                    borrow events as &er in {
                        token = contents(er)[2 * j];
                        readiness = contents(er)[2 * j + 1];
                    }
                    borrow mut poller as &!pw in {
                        borrow mut pl as &!qw in {
                            if pool.owns(qw, token) {
                                pool.pump(qw, pw, token, readiness);
                            }
                        }
                    }
                    j = j + 1;
                }
                let after = clock_ms(clock);
                over = after - started >= seconds * 1000;
                if !over && !idle && after >= next_at {
                    next_at = next_at + period;
                    var name = "dbl";
                    if slow {
                        name = "slow";
                    }
                    let m = request(heap, name, next_tag);
                    var r = 0 - 9;
                    borrow m as &mb in {
                        borrow mut pl as &!qw in {
                            r = pool.submit(qw, next_tag, buffer.bytes(mb));
                        }
                    }
                    buffer.drop(heap, m);
                    if r == 0 {
                        next_tag = next_tag + 1;
                    } else if r == 0 - 3 {
                        refused3 = refused3 + 1;
                    } else {
                        full = full + 1;
                    }
                }
                borrow mut poller as &!pw in {
                    borrow mut pl as &!qw in {
                        pool.flush(qw, pw);
                    }
                }
                var tag = 0 - 1;
                // mode `lazy`: the answers are taken every 300 ms, so that those of a lost connection wait to be taken
                let take = !lazy || over || after - last_take >= 300;
                if take {
                    last_take = after;
                    borrow mut pl as &!qw in {
                        tag = pool.next_done(qw);
                    }
                }
                while tag >= 0 {
                    answered = answered + 1;
                    borrow pl as &qr in {
                        show(heap, io, qr, after - started, tag);
                        if pool.status(qr) == 0 && pg.failure(pool.reply(qr)) < 0 {
                            ok = ok + 1;
                        }
                    }
                    borrow mut pl as &!qw in {
                        tag = pool.next_done(qw);
                    }
                }
                turns = turns + 1;
                var pending = 0;
                borrow pl as &qr in {
                    pending = pool.in_flight(qr);
                }
                if over && pending == 0 {
                    finished = true;
                }
                if over && after - started > seconds * 1000 + 3000 {
                    finished = true;
                }
            }
            var line = stamp(heap, "finished", clock_ms(clock) - started);
            line = field(heap, line, "maxbusy", maxbusy);
            line = field(heap, line, "maxgap", maxgap);
            line = field(heap, line, "busy1", over1);
            line = field(heap, line, "busy2", over2);
            line = field(heap, line, "busy5", over5);
            line = field(heap, line, "busy10", over10);
            line = field(heap, line, "turns", turns);
            line = field(heap, line, "done", answered);
            line = field(heap, line, "ok", ok);
            line = field(heap, line, "refused3", refused3);
            line = field(heap, line, "full", full);
            borrow pl as &qr in {
                line = counters(heap, line, qr);
            }
            line = word(heap, line, "\nstop\n");
            emit(heap, io, line);
            unbox_slice(heap, events);
            pool.close(heap, pl);
            poller_close(poller);
        }
        Polling::Failed(e) => {
            code = 104;
            pool.close(heap, pl);
        }
    }
    return code;
}

fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock } = split(world);
    release(ffi);
    let rng = narrow(fs, "/dev/urandom");
    var status = 100;
    borrow args as &g in {
        if arg_count(g) >= 13 {
            status = 101;
            let port = number_of(arg(g, 2));
            let lanes = number_of(arg(g, 6));
            let seconds = number_of(arg(g, 7));
            let min_ms = number_of(arg(g, 9));
            let max_ms = number_of(arg(g, 10));
            let attempt_ms = number_of(arg(g, 11));
            let request_ms = number_of(arg(g, 12));
            var period = 20;
            if arg_count(g) >= 14 {
                period = number_of(arg(g, 13));
            }
            if port > 0 && lanes > 0 && seconds > 0 && min_ms > 0 && max_ms > 0 && attempt_ms > 0 && request_ms >= 0 && period > 0 {
                status = 102;
                borrow rng as &z in {
                    borrow net as &nn in {
                        borrow clock as &kk in {
                            borrow mut heap as &!h in {
                                borrow mut io as &!i in {
                                    status = run(h, i, nn, kk, z, g, lanes, seconds, min_ms, max_ms, attempt_ms, request_ms, period);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    release(rng);
    release(clock);
    release(net);
    release(args);
    release(io);
    release(heap);
    return status;
}
