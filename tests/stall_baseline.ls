edition 5;

import std.buffer;
import std.io;
import pg;

// The baseline `tests/reconnect_test.py` compares the pool with: a loop that prints a line every 10 ms and, after half a
// second, reconnects the blocking way (`tcp_connect` and `pg.login`), as a service without `pg.pool`'s reconnecting would
// have to. Against a server that does not answer, the lines stop and stay stopped.
//
//     stall_baseline <host> <port> <user> <database>

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

fn relogin[&h, &i, &n, &g](heap: &!h Heap, io: &!i Io, net: &n Net(""), args: &g Args, port: int) -> [heap, err_write, net_out(""), conn_read, conn_write, args] int {
    match tcp_connect(net, arg(args, 1), port) {
        Dialed::Ok(c) => {
            var conn = c;
            borrow mut conn as &!ch in {
                let (reply, s) = pg.login(heap, ch, arg(args, 3), "", arg(args, 4), "AAAAAAAAAAAAAAAAAAAAAAAA");
                buffer.drop(heap, reply);
                io.error_all(io, "login returned\n");
            }
            conn_close(conn);
        }
        Dialed::Failed(e) => {
            io.error_all(io, "connect failed\n");
        }
    }
    return 0;
}

fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock } = split(world);
    release(ffi);
    release(fs);
    var status = 100;
    borrow args as &g in {
        if arg_count(g) >= 5 {
            let port = number_of(arg(g, 2));
            borrow clock as &kk in {
                borrow net as &nn in {
                    borrow mut heap as &!h in {
                        borrow mut io as &!i in {
                            let started = clock_ms(kk);
                            var next = started;
                            var ticks = 0;
                            var went = false;
                            while ticks < 100000 {
                                let now = clock_ms(kk);
                                if now >= next {
                                    var line = buffer.append(h, buffer.empty(h, 32), "tick ");
                                    line = buffer.push_nat(h, line, now - started);
                                    line = buffer.push(h, line, byte_of(10));
                                    borrow line as &lr in {
                                        io.error_all(i, buffer.bytes(lr));
                                    }
                                    buffer.drop(h, line);
                                    next = next + 10;
                                    ticks = ticks + 1;
                                }
                                if !went && now - started >= 500 {
                                    went = true;
                                    relogin(h, i, nn, g, port);
                                }
                            }
                            status = 0;
                        }
                    }
                }
            }
        }
    }
    release(clock);
    release(net);
    release(args);
    release(io);
    release(heap);
    return status;
}
