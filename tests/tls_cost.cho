edition 5;

import std.buffer;
import std.io;
import pg;
import pg.ssl;

// What opening a connection costs, with and without TLS (docs/tls.md section 11), for `tests/tls_measure.py`:
//
//     tls_cost <sslmode> <ca file|-> <server name> <host> <port> <user> <database> <password|-> <connections>
//
// `connections` times, one after the other: dial, `ssl.open` (for `verify-full`: SSLRequest and the handshake), `ssl.login`,
// one query (`select 1`), Terminate and close. Prints on standard error one line:
//
//     cost n <connections> failed <n> total_ms <ms> open_ms <ms> login_ms <ms> query_ms <ms>
//
// with the milliseconds summed over the connections (the clock reads milliseconds, so a part is a sum of whole ones; the
// total is the one to divide). The trust store is read once; the entropy is read for each connection, as a program would.

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

fn pem_max() -> [] int {
    return 2097152;
}

fn field[&h](heap: &!h Heap, b: buffer.Buffer, name: &static [byte], n: int) -> [heap] buffer.Buffer {
    var o = buffer.append(heap, b, " ");
    o = buffer.append(heap, o, name);
    o = buffer.append(heap, o, " ");
    return buffer.push_nat(heap, o, n);
}

// One connection: 0, or the status that stopped it. `times` gets the milliseconds of the open, the login and the query added.
fn one[&h, &g, &k, &e, &p, &t](heap: &!h Heap, args: &g Args, clock: &k Clock, conn: Conn, mode: int, entropy: &e [byte], pem: &p [byte], times: &!t [int]) -> [heap, args, clock] int {
    let t0 = clock_ms(clock);
    let (made, s0) = ssl.open(heap, conn, mode, arg(args, 3), entropy, pem, clock_unix_ms(clock));
    var link = made;
    let t1 = clock_ms(clock);
    times[0] = times[0] + t1 - t0;
    var status = s0;
    borrow mut link as &!lw in {
        if status == 0 {
            var secret = arg(args, 8);
            if len(secret) == 1 && int_of(secret[0]) == 45 {
                secret = "";
            }
            let (hello, s1) = ssl.login(heap, lw, arg(args, 6), secret, arg(args, 7), "bm9uY2Vub25jZW5vbmNlbm9u");
            buffer.drop(heap, hello);
            status = s1;
            let t2 = clock_ms(clock);
            times[1] = times[1] + t2 - t1;
            if status == 0 {
                let (reply, s2) = ssl.simple(heap, lw, "select 1");
                buffer.drop(heap, reply);
                status = s2;
                times[2] = times[2] + clock_ms(clock) - t2;
                let bye = pg.terminate(heap);
                borrow bye as &br in {
                    ssl.send(lw, buffer.bytes(br));
                }
                buffer.drop(heap, bye);
            }
        }
    }
    conn_close(ssl.close(heap, link));
    return status;
}

fn run[&h, &g, &i, &n, &f, &k](heap: &!h Heap, args: &g Args, io: &!i Io, net: &n Net(""), fs: &f Fs(""), clock: &k Clock, mode: int, port: int, count: int) -> [heap, args, err_write, net_out(""), fs_read(""), clock] int {
    var pem = box_slice(heap, pem_max(), byte_of(0));
    var pem_len = 0;
    let cafile = arg(args, 2);
    if !(len(cafile) == 1 && int_of(cafile[0]) == 45) {
        borrow mut pem as &!pw in {
            let got = fs_read(fs, cafile, contents(pw));
            if got > 0 && got < pem_max() {
                pem_len = got;
            }
        }
    }
    var times = box_slice(heap, 3, 0);
    var entropy = box_slice(heap, 32, byte_of(0));
    var failed = 0;
    let started = clock_ms(clock);
    var k = 0;
    while k < count {
        borrow mut entropy as &!ew in {
            let got = fs_read(fs, "/dev/urandom", contents(ew));
        }
        match tcp_connect(net, arg(args, 4), port) {
            Dialed::Ok(c) => {
                var st = 0;
                borrow entropy as &er in {
                    borrow pem as &pr in {
                        borrow mut times as &!tw in {
                            st = one(heap, args, clock, c, mode, contents(er), contents(pr)[0..pem_len], contents(tw));
                        }
                    }
                }
                if st != 0 {
                    failed = failed + 1;
                }
            }
            Dialed::Failed(e) => {
                failed = failed + 1;
            }
        }
        k = k + 1;
    }
    let total = clock_ms(clock) - started;
    var line = buffer.append(heap, buffer.empty(heap, 128), "cost");
    line = field(heap, line, "n", count);
    line = field(heap, line, "failed", failed);
    line = field(heap, line, "total_ms", total);
    borrow times as &tr in {
        line = field(heap, line, "open_ms", contents(tr)[0]);
        line = field(heap, line, "login_ms", contents(tr)[1]);
        line = field(heap, line, "query_ms", contents(tr)[2]);
    }
    line = buffer.append(heap, line, "\n");
    borrow line as &lr in {
        io.error_all(io, buffer.bytes(lr));
    }
    buffer.drop(heap, line);
    unbox_slice(heap, times);
    unbox_slice(heap, entropy);
    unbox_slice(heap, pem);
    return failed;
}

fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock } = split(world);
    release(ffi);
    var status = 100;
    borrow args as &g in {
        if arg_count(g) >= 10 {
            let mode = pg.sslmode(arg(g, 1));
            let port = number_of(arg(g, 5));
            let count = number_of(arg(g, 9));
            if mode >= 0 && port > 0 && count > 0 {
                borrow mut io as &!i in {
                    borrow net as &n in {
                        borrow fs as &f in {
                            borrow clock as &k in {
                                borrow mut heap as &!h in {
                                    status = run(h, g, i, n, f, k, mode, port, count);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    release(fs);
    release(clock);
    release(net);
    release(args);
    release(io);
    release(heap);
    return status;
}
