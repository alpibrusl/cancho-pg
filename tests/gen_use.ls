edition 5;

import std.buffer;
import std.io;
import pg;
import queries;

// Uses the functions `pgen` wrote for tests/queries.sql, against the database tests/e2e.py seeded.
//
//     gen_use <host> <port> <user> <database> <password|-> <id of a user with a NULL age and nickname>
//
// What it prints is checked line by line in tests/e2e.py, and the table it leaves behind is checked
// with `psql`.

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

fn put[&i, &t](io: &!i Io, text: &t [byte]) -> [io_write] int {
    return io.write_all(io, text);
}

fn num[&i](io: &!i Io, n: int) -> [io_write] int {
    return io.print_nat(io, n);
}

// A text column: its bytes, or `NULL`.
fn text_or_null[&i, &m](io: &!i Io, m: &m [byte], range: (int, int)) -> [io_write] int {
    let (from, to) = range;
    if from < 0 {
        put(io, "NULL");
    } else {
        put(io, m[from..to]);
    }
    return 0;
}

fn failed[&i, &m](io: &!i Io, what: &static [byte], m: &m [byte]) -> [io_write] int {
    let at = pg.failure(m);
    if at < 0 {
        return 0;
    }
    let (cf, ct) = pg.error_field(m, at, 67);
    put(io, what);
    put(io, " ERROR ");
    put(io, m[cf..ct]);
    put(io, "\n");
    return 1;
}

fn user_line[&h, &c, &i](heap: &!h Heap, conn: &!c Conn, io: &!i Io, id: int) -> [heap, conn_read, conn_write, io_write] int {
    let (reply, status) = queries.user_by_id(heap, conn, id);
    borrow reply as &rr in {
        let m = buffer.bytes(rr);
        let row = pg.first_row(m);
        put(io, "user ");
        num(io, id);
        put(io, ": ");
        if status != 0 {
            put(io, "status ");
            num(io, status);
        } else if row < 0 {
            put(io, "no row");
        } else {
            text_or_null(io, m, queries.user_by_id_name(m, row));
            put(io, " age=");
            if queries.user_by_id_age_is_null(m, row) {
                put(io, "NULL");
            } else {
                num(io, queries.user_by_id_age(m, row));
            }
            if queries.user_by_id_active(m, row) {
                put(io, " active");
            } else {
                put(io, " inactive");
            }
            put(io, " nickname=");
            if queries.user_by_id_nickname_is_null(m, row) {
                put(io, "NULL");
            } else {
                text_or_null(io, m, queries.user_by_id_nickname(m, row));
            }
        }
        put(io, "\n");
    }
    buffer.drop(heap, reply);
    return 0;
}

fn scenario[&h, &c, &i](heap: &!h Heap, conn: &!c Conn, io: &!i Io, null_user: int) -> [heap, conn_read, conn_write, io_write] int {
    // a count: an expression, so it carries an `_is_null` it never needs
    let (r1, s1) = queries.count_users(heap, conn);
    borrow r1 as &r1r in {
        let m = buffer.bytes(r1r);
        put(io, "count ");
        num(io, queries.count_users_n(m, pg.first_row(m)));
        put(io, "\n");
    }
    buffer.drop(heap, r1);

    user_line(heap, conn, io, 1);
    user_line(heap, conn, io, null_user);
    user_line(heap, conn, io, 99999);

    // a text parameter is data: the SQL in it is just a name
    let (r2, s2) = queries.add_user(heap, conn, "dee'; drop table gen_users; --", 41);
    var added = 0 - 1;
    borrow r2 as &r2r in {
        let m = buffer.bytes(r2r);
        added = queries.add_user_id(m, pg.first_row(m));
        put(io, "added ");
        num(io, added);
        put(io, " affected ");
        num(io, pg.affected(m));
        put(io, "\n");
    }
    buffer.drop(heap, r2);
    user_line(heap, conn, io, added);

    let (r3, s3) = queries.rename_user(heap, conn, added, "renamed");
    borrow r3 as &r3r in {
        put(io, "renamed affected ");
        num(io, pg.affected(buffer.bytes(r3r)));
        put(io, "\n");
    }
    buffer.drop(heap, r3);
    user_line(heap, conn, io, added);

    // rows in a loop, with the integer and the text read as what they are
    let (r4, s4) = queries.users_older_than(heap, conn, 29);
    borrow r4 as &r4r in {
        let m = buffer.bytes(r4r);
        var at = pg.first_row(m);
        while at >= 0 {
            put(io, "older ");
            num(io, queries.users_older_than_id(m, at));
            put(io, " ");
            text_or_null(io, m, queries.users_older_than_name(m, at));
            put(io, "\n");
            at = pg.next_row(m, at);
        }
    }
    buffer.drop(heap, r4);

    // a lookup that finds one row, and one that finds none
    let (r5, s5) = queries.find_by_nickname(heap, conn, "zed");
    borrow r5 as &r5r in {
        let m = buffer.bytes(r5r);
        let row = pg.first_row(m);
        put(io, "nickname zed: ");
        if row < 0 {
            put(io, "none");
        } else {
            num(io, queries.find_by_nickname_id(m, row));
        }
        put(io, "\n");
    }
    buffer.drop(heap, r5);
    let (r6, s6) = queries.find_by_nickname(heap, conn, "nobody");
    borrow r6 as &r6r in {
        let m = buffer.bytes(r6r);
        put(io, "nickname nobody: ");
        if pg.first_row(m) < 0 {
            put(io, "none");
        } else {
            put(io, "found");
        }
        put(io, "\n");
    }
    buffer.drop(heap, r6);

    // a column that is NOT NULL has no `_is_null`; timestamps come back as the server's text
    let (r7, s7) = queries.user_details(heap, conn, 1);
    borrow r7 as &r7r in {
        let m = buffer.bytes(r7r);
        let row = pg.first_row(m);
        put(io, "details balance=");
        num(io, queries.user_details_balance(m, row));
        put(io, " joined=");
        text_or_null(io, m, queries.user_details_joined(m, row));
        put(io, " next_age=");
        if queries.user_details_next_age_is_null(m, row) {
            put(io, "NULL");
        } else {
            num(io, queries.user_details_next_age(m, row));
        }
        put(io, "\n");
    }
    buffer.drop(heap, r7);
    let (r8, s8) = queries.user_details(heap, conn, null_user);
    borrow r8 as &r8r in {
        let m = buffer.bytes(r8r);
        put(io, "details next_age=");
        if queries.user_details_next_age_is_null(m, pg.first_row(m)) {
            put(io, "NULL");
        } else {
            put(io, "not null");
        }
        put(io, "\n");
    }
    buffer.drop(heap, r8);

    // a server error comes back as the server's error
    let (r9, s9) = queries.add_post(heap, conn, 99999, "orphan");
    borrow r9 as &r9r in {
        failed(io, "add_post", buffer.bytes(r9r));
    }
    buffer.drop(heap, r9);
    let (r10, s10) = queries.add_post(heap, conn, 1, "first post");
    borrow r10 as &r10r in {
        put(io, "add_post affected ");
        num(io, pg.affected(buffer.bytes(r10r)));
        put(io, "\n");
    }
    buffer.drop(heap, r10);
    let (r11, s11) = queries.posts_with_authors(heap, conn);
    borrow r11 as &r11r in {
        let m = buffer.bytes(r11r);
        var at = pg.first_row(m);
        while at >= 0 {
            put(io, "post ");
            text_or_null(io, m, queries.posts_with_authors_title(m, at));
            put(io, " by ");
            text_or_null(io, m, queries.posts_with_authors_author(m, at));
            put(io, "\n");
            at = pg.next_row(m, at);
        }
    }
    buffer.drop(heap, r11);

    // SQL with quotes, a backslash and a line break in it reaches the server as written
    let (r12, s12) = queries.tricky(heap, conn);
    borrow r12 as &r12r in {
        let m = buffer.bytes(r12r);
        let row = pg.first_row(m);
        put(io, "tricky [");
        text_or_null(io, m, queries.tricky_quoted(m, row));
        put(io, "] [");
        text_or_null(io, m, queries.tricky_two(m, row));
        put(io, "]\n");
    }
    buffer.drop(heap, r12);
    return 0;
}

fn run[&h, &g, &i, &c, &z](heap: &!h Heap, args: &g Args, io: &!i Io, conn: &!c Conn, fs: &z Fs("")) -> [heap, args, io_write, conn_read, conn_write, fs_read("")] int {
    let nonce = fresh_nonce(heap, fs);
    var hello = buffer.empty(heap, 1);
    var s0 = 0;
    borrow nonce as &nr in {
        let (reply, st) = pg.login(heap, conn, arg(args, 3), arg(args, 5), arg(args, 4), buffer.bytes(nr));
        buffer.drop(heap, hello);
        hello = reply;
        s0 = st;
    }
    buffer.drop(heap, nonce);
    buffer.drop(heap, hello);
    if s0 != 0 {
        return s0;
    }
    return scenario(heap, conn, io, number_of(arg(args, 6)));
}

fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock } = split(world);
    release(ffi);
    release(clock);
    var status = 100;
    borrow fs as &z in {
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
                                            status = run(h, g, i, ch, z);
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
    }
    release(fs);
    release(net);
    release(args);
    release(io);
    release(heap);
    return status;
}
