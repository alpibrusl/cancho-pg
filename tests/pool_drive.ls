edition 5;

import std.buffer;
import std.io;
import pg;
import pg.pool;

// Drives `pg.pool` against a server: `tests/e2e.py` runs it against PostgreSQL and against a mock
// that answers in pieces, late, or not at all, and reads what it prints.
//
//     pool_drive <host> <port> <user> <database> <lanes> <count> <mode> [<depth> [<ms to wait for silence> [<output slab> <bytes of the parameter in `big`>]]]
//
// Opens `lanes` connections (logged in, the statements prepared), submits `count` requests, tag
// `i` asking for `i * 2` (`dbl`), or for `i * 2` after a 0.4 s sleep (`slow`), and runs the pool's
// own loop until every one has an answer, printing one line per answer in the order they come:
//
//     done <tag> <status> <value or ->
//
// Modes: `plain` (all `dbl`), `slow0` (request 0 is `slow`, the rest `dbl`: with two lanes the
// others come back first), `slowall` (all `slow`: kill the server's backends meanwhile), `err`
// (request 1 is a statement that does not exist), `big` (each asks the server for the length of a text
// parameter of the given size, which is what the answer holds), `lazy` (all `dbl`, but the answers are only
// taken once the poller has been quiet, so a connection can fail with replies nobody has taken yet). Ends with `finished <answers> <loops>`: how
// many answers and how many times the loop woke, which a loop that is not waiting would run up.
// It gives up, and says so with `finished`, after the given silence (6000 ms if none).

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

fn fresh_nonce[&h, &f](heap: &!h Heap, fs: &f Fs("")) -> [heap, fs_read("")] buffer.Buffer {
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

// Log in and prepare the statements the driver uses.
fn ready_for_use[&h, &c, &f, &u, &d](heap: &!h Heap, conn: &!c Conn, fs: &f Fs(""), user: &u [byte], database: &d [byte]) -> [heap, conn_read, conn_write, fs_read("")] int {
    let nonce = fresh_nonce(heap, fs);
    var status = 1;
    borrow nonce as &nb in {
        let (reply, s) = pg.login(heap, conn, user, "", database, buffer.bytes(nb));
        buffer.drop(heap, reply);
        status = s;
    }
    buffer.drop(heap, nonce);
    if status != 0 {
        return status;
    }
    let (r1, s1) = pg.prepare(heap, conn, "dbl", "select ($1::int8 * 2)::text");
    buffer.drop(heap, r1);
    if s1 != 0 {
        return s1;
    }
    let (r2, s2) = pg.prepare(heap, conn, "slow", "select ($1::int8 * 2)::text from pg_sleep(0.4)");
    buffer.drop(heap, r2);
    if s2 != 0 {
        return s2;
    }
    let (r3, s3) = pg.prepare(heap, conn, "len", "select length($1::text)::text");
    buffer.drop(heap, r3);
    return s3;
}

fn request[&h](heap: &!h Heap, name: &static [byte], n: int, nbytes: int) -> [heap] buffer.Buffer {
    var ps = pg.params(heap);
    if nbytes > 0 {
        var text = buffer.empty(heap, nbytes);
        var i = 0;
        while i < nbytes {
            text = buffer.push(heap, text, byte_of(120));
            i = i + 1;
        }
        borrow text as &tr in {
            ps = pg.param(heap, ps, buffer.bytes(tr));
        }
        buffer.drop(heap, text);
    } else {
        ps = pg.param_int(heap, ps, n);
    }
    var m = buffer.empty(heap, 1);
    borrow ps as &pr in {
        buffer.drop(heap, m);
        m = pg.bind_named(heap, name, pr);
    }
    pg.drop_params(heap, ps);
    return m;
}

// Submit as many of the requests from `next` on as the pool takes. Answers the next to submit.
fn submit_some[&h, &q, &p](heap: &!h Heap, pl: &!q pool.Pool, poller: &!p Poller, next: int, count: int, mode: int, nbytes: int) -> [heap, conn_write, poll] int {
    var n = next;
    var going = true;
    while going && n < count {
        var name = "dbl";
        if mode == 1 && n == 0 {
            name = "slow";
        }
        if mode == 2 {
            name = "slow";
        }
        if mode == 3 && n == 1 {
            name = "nothing_was_prepared_under_this_name";
        }
        if mode == 4 {
            name = "len";
        }
        let m = request(heap, name, n, nbytes);
        var r = 0 - 9;
        borrow m as &mb in {
            r = pool.submit(pl, poller, n, buffer.bytes(mb));
        }
        buffer.drop(heap, m);
        if r == 0 {
            n = n + 1;
        } else {
            going = false;
        }
    }
    return n;
}

fn show[&i, &q](io: &!i Io, pl: &q pool.Pool, tag: int) -> [io_write] int {
    io.write_all(io, "done ");
    io.print_nat(io, tag);
    io.write_all(io, " ");
    io.print_nat(io, pool.status(pl));
    io.write_all(io, " ");
    let m = pool.reply(pl);
    let row = pg.first_row(m);
    if row < 0 {
        io.write_all(io, "-");
        let at = pg.failure(m);
        if at >= 0 {
            let (from, to) = pg.error_field(m, at, 67);
            io.write_all(io, " ");
            io.write_all(io, m[from..to]);
        }
    } else {
        let (from, to) = pg.value(m, row, 0);
        io.write_all(io, m[from..to]);
    }
    io.write_all(io, "\n");
    return 0;
}

fn run[&h, &i, &q, &p](heap: &!h Heap, io: &!i Io, pl: &!q pool.Pool, poller: &!p Poller, count: int, mode: int, budget_ms: int, nbytes: int) -> [heap, conn_read, conn_write, io_write, poll] int {
    var next = submit_some(heap, pl, poller, 0, count, mode, nbytes);
    var answered = 0;
    var wakes = 0;
    var events = box_slice(heap, 64, 0);
    var idle = 0;
    while answered < count && idle < budget_ms / 50 {
        var ready = 0;
        borrow mut events as &!ew in {
            ready = poller_wait(poller, contents(ew), 50);
        }
        if ready == 0 {
            idle = idle + 1;
        } else {
            idle = 0;
            wakes = wakes + 1;
        }
        var j = 0;
        while j < ready {
            var token = 0 - 1;
            var readiness = 0;
            borrow events as &er in {
                token = contents(er)[2 * j];
                readiness = contents(er)[2 * j + 1];
            }
            if pool.owns(pl, token) {
                pool.pump(pl, poller, token, readiness);
            }
            j = j + 1;
        }
        if mode != 5 || ready == 0 {
            var tag = pool.next_done(pl);
            while tag >= 0 {
                show(io, pl, tag);
                answered = answered + 1;
                tag = pool.next_done(pl);
            }
        }
        if next < count {
            next = submit_some(heap, pl, poller, next, count, mode, nbytes);
        }
    }
    unbox_slice(heap, events);
    io.write_all(io, "finished ");
    io.print_nat(io, answered);
    io.write_all(io, " ");
    io.print_nat(io, wakes);
    io.write_all(io, "\n");
    return 0;
}

fn mode_of[&t](text: &t [byte]) -> [] int {
    if text[0] == byte_of(115) && len(text) == 5 {
        return 1;
    }
    if text[0] == byte_of(115) {
        return 2;
    }
    if text[0] == byte_of(101) {
        return 3;
    }
    if text[0] == byte_of(98) {
        return 4;
    }
    if text[0] == byte_of(108) {
        return 5;
    }
    return 0;
}

fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock } = split(world);
    release(ffi);
    release(clock);
    var status = 100;
    borrow fs as &z in {
        borrow args as &g in {
            if arg_count(g) >= 8 {
                status = 101;
                let port = number_of(arg(g, 2));
                let lanes = number_of(arg(g, 5));
                let count = number_of(arg(g, 6));
                var depth = 64;
                var budget = 6000;
                if arg_count(g) >= 9 {
                    depth = number_of(arg(g, 8));
                }
                if arg_count(g) >= 10 {
                    budget = number_of(arg(g, 9));
                }
                var out_cap = 65536;
                var nbytes = 0;
                if arg_count(g) >= 12 {
                    out_cap = number_of(arg(g, 10));
                    nbytes = number_of(arg(g, 11));
                }
                if port > 0 && lanes > 0 && count > 0 && depth > 0 && budget > 0 && out_cap > 0 && nbytes >= 0 {
                    status = 102;
                    match poller_new() {
                        Polling::Ok(pl0) => {
                            var poller = pl0;
                            borrow mut heap as &!h in {
                                var pl = pool.empty(h, lanes, depth, 65536, out_cap);
                                var added = 0;
                                var n = 0;
                                while n < lanes {
                                    borrow net as &nn in {
                                        match tcp_connect(nn, arg(g, 1), port) {
                                            Dialed::Ok(c) => {
                                                var conn = c;
                                                var s = 1;
                                                borrow mut conn as &!ch in {
                                                    s = ready_for_use(h, ch, z, arg(g, 3), arg(g, 4));
                                                }
                                                if s == 0 {
                                                    let (grown, slot) = pool.add(h, pl, conn);
                                                    pl = grown;
                                                    if slot >= 0 {
                                                        added = added + 1;
                                                    }
                                                } else {
                                                    conn_close(conn);
                                                }
                                            }
                                            Dialed::Failed(e) => {
                                            }
                                        }
                                    }
                                    n = n + 1;
                                }
                                if added == lanes {
                                    status = 0;
                                    let mode = mode_of(arg(g, 7));
                                    borrow mut poller as &!pw in {
                                        borrow mut pl as &!sw in {
                                            pool.start(sw, pw, 1);
                                        }
                                        borrow mut io as &!i in {
                                            borrow mut pl as &!qw in {
                                                run(h, i, qw, pw, count, mode, budget, nbytes);
                                            }
                                        }
                                    }
                                } else {
                                    status = 103;
                                }
                                pool.close(h, pl);
                            }
                            poller_close(poller);
                        }
                        Polling::Failed(e) => {
                            status = 104;
                        }
                    }
                }
            }
        }
    }
    release(fs);
    release(net);
    release(args);
    release(io);
    release(heap);
    return status;
}
