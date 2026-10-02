edition 5;

import std.buffer;
import std.io;
import pg;

// `psql` -- a minimal PostgreSQL command-line client, over `pg`.
//
//     psql <host> <port> <user> <database> <password|-> <sql> [parameter ...]
//
// With no parameters the SQL goes as a simple query (several statements are fine); with
// parameters it goes through the extended protocol, `$1`, `$2`, ... bound as data (a
// parameter spelled `\N` is NULL). Output: one line per row, values separated by `|`
// (NULL is `\N`), `# <tag>` for each completed command, `ERROR <sqlstate>: <message>`
// for an error. Exit status 0 if the server answered, otherwise the `pg` status code.
//
// `lex-sys authority` on it reports `args`, `heap`, the console and the network (any host:
// a program for one database would narrow `net` to that host, and the report would say so).

// A decimal number, or -1 for empty text or a non-digit.
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

// Print every message of the reply that is a row, a completed command or an error.
fn show[&i, &m](io: &!i Io, m: &m [byte]) -> [io_write] int {
    var at = 0;
    while pg.size(m, at) > 0 {
        let k = pg.kind(m, at);
        if k == 68 {
            var j = 0;
            while j < pg.fields(m, at) {
                if j > 0 {
                    io.write_all(io, "|");
                }
                let (from, to) = pg.value(m, at, j);
                if from < 0 {
                    io.write_all(io, "\\N");
                } else {
                    io.write_all(io, m[from..to]);
                }
                j = j + 1;
            }
            io.write_all(io, "\n");
        } else if k == 67 {
            let (from, to) = pg.tag(m, at);
            io.write_all(io, "# ");
            io.write_all(io, m[from..to]);
            io.write_all(io, "\n");
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

// Print a reply and end it.
fn finish[&h, &i](heap: &!h Heap, io: &!i Io, reply: buffer.Buffer) -> [heap, io_write] int {
    borrow reply as &rb in {
        show(io, buffer.bytes(rb));
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
    if arg_count(args) <= 7 {
        let (r, s) = pg.simple(heap, conn, arg(args, 6));
        finish(heap, io, r);
        return s;
    }
    var ps = pg.params(heap);
    var k = 7;
    while k < arg_count(args) {
        let a = arg(args, k);
        if len(a) == 2 && int_of(a[0]) == 92 && int_of(a[1]) == 78 {
            ps = pg.param_null(heap, ps);
        } else {
            ps = pg.param(heap, ps, a);
        }
        k = k + 1;
    }
    var out = 0;
    borrow ps as &pr in {
        let (r, s) = pg.extended(heap, conn, arg(args, 6), pr);
        finish(heap, io, r);
        out = s;
    }
    pg.drop_params(heap, ps);
    return out;
}

fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock } = split(world);
    release(ffi);
    release(fs);
    release(clock);
    var status = 100;
    borrow args as &g in {
        if arg_count(g) >= 7 {
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
