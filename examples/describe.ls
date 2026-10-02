edition 5;

import std.buffer;
import std.io;
import pg;

// `describe` -- ask the server what a statement takes and gives back, without running it.
//
//     describe <host> <port> <user> <database> <password|-> <sql>
//
// Prints one line `$n <oid>` per parameter and one line `<name> <oid>` per result column
// (oid 23 is int4, 25 text, 1184 timestamptz, 16 bool; `select oid, typname from pg_type`).
// This is the question a code generator asks of a real database to give every query a typed
// signature: nothing here is guessed, and a statement the server rejects is reported as it
// rejects it, `ERROR <sqlstate>: <message>`.

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

fn line_number[&h, &i](heap: &!h Heap, io: &!i Io, prefix: int, n: int) -> [heap, io_write] int {
    var b = buffer.empty(heap, 16);
    if prefix == 36 {
        b = buffer.push(heap, b, byte_of(36));
    }
    b = buffer.push_nat(heap, b, n);
    borrow b as &bb in {
        io.write_all(io, buffer.bytes(bb));
    }
    buffer.drop(heap, b);
    return 0;
}

fn show[&h, &i, &m](heap: &!h Heap, io: &!i Io, m: &m [byte]) -> [heap, io_write] int {
    var at = 0;
    while pg.size(m, at) > 0 {
        let k = pg.kind(m, at);
        if k == 116 {
            var j = 1;
            while j <= pg.param_count(m, at) {
                line_number(heap, io, 36, j);
                io.write_all(io, " ");
                line_number(heap, io, 0, pg.param_oid(m, at, j));
                io.write_all(io, "\n");
                j = j + 1;
            }
        } else if k == 84 {
            var j = 0;
            while j < pg.fields(m, at) {
                let (from, to) = pg.column_name(m, at, j);
                io.write_all(io, m[from..to]);
                io.write_all(io, " ");
                line_number(heap, io, 0, pg.column_oid(m, at, j));
                io.write_all(io, "\n");
                j = j + 1;
            }
        } else if k == 69 {
            let (cf, ct) = pg.error_field(m, at, 67);
            let (mf, mt) = pg.error_field(m, at, 77);
            io.write_all(io, "ERROR ");
            io.write_all(io, m[cf..ct]);
            io.write_all(io, ": ");
            io.write_all(io, m[mf..mt]);
            io.write_all(io, "\n");
        }
        at = at + pg.size(m, at);
    }
    return 0;
}

fn finish[&h, &i](heap: &!h Heap, io: &!i Io, reply: buffer.Buffer) -> [heap, io_write] int {
    borrow reply as &rb in {
        show(heap, io, buffer.bytes(rb));
    }
    buffer.drop(heap, reply);
    return 0;
}

fn run[&h, &g, &i, &c](heap: &!h Heap, args: &g Args, io: &!i Io, conn: &!c Conn) -> [heap, args, io_write, conn_read, conn_write] int {
    let (hello, s0) = pg.login(heap, conn, arg(args, 3), arg(args, 5), arg(args, 4));
    if s0 != 0 {
        finish(heap, io, hello);
        return s0;
    }
    buffer.drop(heap, hello);
    let (r, s) = pg.describing(heap, conn, arg(args, 6));
    finish(heap, io, r);
    return s;
}

fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock } = split(world);
    release(ffi);
    release(fs);
    release(clock);
    var status = 100;
    borrow args as &g in {
        if arg_count(g) == 7 {
            status = 101;
            let port = number_of(arg(g, 2));
            if port > 0 && port < 65536 {
                status = 102;
                borrow net as &nn in {
                    match tcp_connect(nn, arg(g, 1), port) {
                        Dialed::Ok(c) => {
                            var conn = c;
                            borrow mut conn as &!ch in {
                                borrow mut heap as &!h in {
                                    borrow mut io as &!i in {
                                        status = run(h, g, i, ch);
                                    }
                                }
                            }
                            conn_close(conn);
                        }
                        Dialed::Failed(e) => {
                            status = 103;
                        }
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
