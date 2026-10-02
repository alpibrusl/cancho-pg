edition 5;

import std.buffer;
import std.bytes;
import std.io;
import pg;

// `pgen` -- typed queries from SQL, by asking the database.
//
//     pgen <host> <port> <user> <database> <password|-> <queries.sql>
//
// The SQL file is a list of queries, each introduced by a line
//
//     -- name: user_by_id id
//
// (the query's name, then optionally a name for each `$n`) followed by one statement. For each,
// `pgen` sends the statement to the server's *describe* -- the server parses and plans it and
// answers with the type of every `$n` and of every result column, without running it -- and writes
// a lex-sys module on standard output: one function that runs the query with typed parameters, and
// one accessor per result column. A statement the server rejects, a column whose name is not a
// plain identifier, and a name used twice are each an error, and nothing is written: a query that
// does not compile against the schema never reaches a build.
//
//   * `$n` of type bool, int2, int4, int8 or oid is a `bool` or an `int` parameter; every other
//     type is `&[byte]`, the text the server parses (a uuid, a timestamp, a numeric).
//   * A result column of those types is read as a `bool` or an `int`; every other type is read as
//     the `(from, to)` range of its text form in the reply, which is what the server sent.
//   * A column that is a plain reference to a table column which is NOT NULL gets no `_is_null`
//     accessor; every other column does. A query that joins is treated as having no such column,
//     because an outer join makes a NOT NULL column NULL and the server does not say.
//
// `lex-sys authority` on it reports `args`, `heap`, `fs_read("")` (the file, and the random nonce
// of the login), the console and the network.

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

// An unpredictable client nonce for SCRAM: 18 bytes from the kernel, as base64 (printable, no
// comma). Empty if the read came up short, and `pg.login` then refuses a SCRAM server (status 7).
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

fn ident_ok[&t](text: &t [byte]) -> [] bool {
    if len(text) == 0 || len(text) > 60 {
        return false;
    }
    var i = 0;
    while i < len(text) {
        let c = int_of(text[i]);
        var ok = c == 95 || bytes.is_lower(c);
        if i > 0 && bytes.is_digit(c) {
            ok = true;
        }
        if !ok {
            return false;
        }
        i = i + 1;
    }
    return true;
}

fn is_space(c: int) -> [] bool {
    return c == 32 || c == 9 || c == 10 || c == 13;
}

// The `n`th (from 0) run of non-blank bytes in `text`, as `(from, to)`; `(-1, -1)` if there is none.
fn token[&t](text: &t [byte], n: int) -> [] (int, int) {
    var at = 0;
    var seen = 0;
    while at < len(text) {
        while at < len(text) && is_space(int_of(text[at])) {
            at = at + 1;
        }
        if at >= len(text) {
            return (0 - 1, 0 - 1);
        }
        let from = at;
        while at < len(text) && !is_space(int_of(text[at])) {
            at = at + 1;
        }
        if seen == n {
            return (from, at);
        }
        seen = seen + 1;
    }
    return (0 - 1, 0 - 1);
}

fn token_count[&t](text: &t [byte]) -> [] int {
    var n = 0;
    var from = 0;
    while from >= 0 {
        let (f, t) = token(text, n);
        from = f;
        if f >= 0 {
            n = n + 1;
        }
    }
    return n;
}

fn word_byte(c: int) -> [] bool {
    return c == 95 || bytes.is_lower(c) || bytes.is_digit(c);
}

// Whether `text` contains `needle` (lower-case) as a whole word, ignoring case: `join` in
// `left join` and not in `joined`.
fn contains_word[&h, &t](heap: &!h Heap, text: &t [byte], needle: &static [byte]) -> [heap] bool {
    var lower = buffer.empty(heap, len(text));
    var i = 0;
    while i < len(text) {
        lower = buffer.push(heap, lower, byte_of(bytes.to_lower(int_of(text[i]))));
        i = i + 1;
    }
    var found = false;
    borrow lower as &lr in {
        let l = buffer.bytes(lr);
        var at = 0;
        while at + len(needle) <= len(l) && !found {
            if bytes.starts_with(l[at..len(l)], needle) {
                let end = at + len(needle);
                var before = at == 0 || !word_byte(int_of(l[at - 1]));
                var after = end == len(l) || !word_byte(int_of(l[end]));
                if before && after {
                    found = true;
                }
            }
            at = at + 1;
        }
    }
    buffer.drop(heap, lower);
    return found;
}

// `text` as the body of a string literal. False if it holds a control character that has no escape.
fn literal[&h, &t](heap: &!h Heap, out: buffer.Buffer, text: &t [byte]) -> [heap] (buffer.Buffer, bool) {
    var o = buffer.push(heap, out, byte_of(34));
    var ok = true;
    var i = 0;
    while i < len(text) {
        let c = int_of(text[i]);
        if c == 34 {
            o = buffer.append(heap, o, "\\\"");
        } else if c == 92 {
            o = buffer.append(heap, o, "\\\\");
        } else if c == 10 {
            o = buffer.append(heap, o, "\\n");
        } else if c == 13 {
            o = buffer.append(heap, o, "\\r");
        } else if c == 9 {
            o = buffer.append(heap, o, "\\t");
        } else if c < 32 || c == 127 {
            ok = false;
        } else {
            o = buffer.push(heap, o, text[i]);
        }
        i = i + 1;
    }
    o = buffer.push(heap, o, byte_of(34));
    return (o, ok);
}

// 1 for a type read and written as an `int`, 2 for `bool`, 0 for text.
fn oid_kind(oid: int) -> [] int {
    if oid == 16 {
        return 2;
    }
    if oid == 20 || oid == 21 || oid == 23 || oid == 26 {
        return 1;
    }
    return 0;
}

// Record `name` as taken: false if it already was. `seen` holds each taken name between newlines.
fn claim[&h, &t](heap: &!h Heap, seen: buffer.Buffer, name: &t [byte]) -> [heap] (buffer.Buffer, bool) {
    var needle = buffer.append(heap, buffer.push(heap, buffer.empty(heap, 64), byte_of(10)), name);
    needle = buffer.push(heap, needle, byte_of(10));
    var taken = false;
    borrow seen as &sr in {
        borrow needle as &nr in {
            taken = bytes.find(buffer.bytes(sr), buffer.bytes(nr)) >= 0;
        }
    }
    var s = seen;
    if !taken {
        s = buffer.append(heap, s, name);
        s = buffer.push(heap, s, byte_of(10));
    }
    buffer.drop(heap, needle);
    return (s, !taken);
}

// Whether the server says column `attnum` of table `table` is NOT NULL.
fn not_null[&h, &c](heap: &!h Heap, conn: &!c Conn, table: int, attnum: int) -> [heap, conn_read, conn_write] bool {
    var ps = pg.params(heap);
    ps = pg.param_int(heap, ps, table);
    ps = pg.param_int(heap, ps, attnum);
    var answer = false;
    borrow ps as &pr in {
        let (r, s) = pg.extended(heap, conn, "select attnotnull from pg_attribute where attrelid = $1::oid and attnum = $2::int2", pr);
        borrow r as &rr in {
            let m = buffer.bytes(rr);
            let row = pg.first_row(m);
            if s == 0 && row >= 0 {
                let (from, to) = pg.value(m, row, 0);
                answer = pg.bool_text(m, from, to);
            }
        }
        buffer.drop(heap, r);
    }
    pg.drop_params(heap, ps);
    return answer;
}

fn complain[&i, &n, &w](io: &!i Io, name: &n [byte], what: &w [byte]) -> [err_write] int {
    io.error_all(io, "pgen: ");
    io.error_all(io, name);
    io.error_all(io, ": ");
    io.error_all(io, what);
    io.error_all(io, "\n");
    return 1;
}

// The server's own error, from a reply that has one.
fn complain_server[&i, &n, &m](io: &!i Io, name: &n [byte], reply: &m [byte], at: int) -> [err_write] int {
    let (cf, ct) = pg.error_field(reply, at, 67);
    let (mf, mt) = pg.error_field(reply, at, 77);
    io.error_all(io, "pgen: ");
    io.error_all(io, name);
    io.error_all(io, ": ");
    io.error_all(io, reply[cf..ct]);
    io.error_all(io, ": ");
    io.error_all(io, reply[mf..mt]);
    io.error_all(io, "\n");
    return 1;
}

// The function that runs the query: typed parameters in, the server's whole reply and a status out.
fn emit_runner[&h, &n, &d, &r, &l](heap: &!h Heap, out: buffer.Buffer, name: &n [byte], pnames: &d [byte], m: &r [byte], tpos: int, sql_literal: &l [byte]) -> [heap] buffer.Buffer {
    let count = pg.param_count(m, tpos);
    var o = buffer.append(heap, out, "\n// ");
    o = buffer.append(heap, o, name);
    o = buffer.append(heap, o, ": the whole reply, and a status (0 ok); `pg.failure(reply)` is the server's error, if any\npub fn ");
    o = buffer.append(heap, o, name);
    o = buffer.append(heap, o, "[&h, &c");
    var k = 1;
    while k <= count {
        if oid_kind(pg.param_oid(m, tpos, k)) == 0 {
            o = buffer.append(heap, o, ", &a");
            o = buffer.push_nat(heap, o, k);
        }
        k = k + 1;
    }
    o = buffer.append(heap, o, "](heap: &!h Heap, conn: &!c Conn");
    k = 1;
    while k <= count {
        let kind = oid_kind(pg.param_oid(m, tpos, k));
        o = buffer.append(heap, o, ", ");
        o = buffer.append(heap, o, bytes.field(pnames, 10, k));
        if kind == 1 {
            o = buffer.append(heap, o, ": int");
        } else if kind == 2 {
            o = buffer.append(heap, o, ": bool");
        } else {
            o = buffer.append(heap, o, ": &a");
            o = buffer.push_nat(heap, o, k);
            o = buffer.append(heap, o, " [byte]");
        }
        k = k + 1;
    }
    o = buffer.append(heap, o, ") -> [heap, conn_read, conn_write] (buffer.Buffer, int) {\n    var ps = pg.params(heap);\n");
    k = 1;
    while k <= count {
        let kind = oid_kind(pg.param_oid(m, tpos, k));
        o = buffer.append(heap, o, "    ps = ");
        if kind == 1 {
            o = buffer.append(heap, o, "pg.param_int");
        } else if kind == 2 {
            o = buffer.append(heap, o, "pg.param_bool");
        } else {
            o = buffer.append(heap, o, "pg.param");
        }
        o = buffer.append(heap, o, "(heap, ps, ");
        o = buffer.append(heap, o, bytes.field(pnames, 10, k));
        o = buffer.append(heap, o, ");\n");
        k = k + 1;
    }
    o = buffer.append(heap, o, "    var reply = buffer.empty(heap, 1);\n    var status = 0;\n    borrow ps as &pr in {\n        let (r, s) = pg.extended(heap, conn, ");
    o = buffer.append(heap, o, sql_literal);
    o = buffer.append(heap, o, ", pr);\n        buffer.drop(heap, reply);\n        reply = r;\n        status = s;\n    }\n    pg.drop_params(heap, ps);\n    return (reply, status);\n}\n");
    return o;
}

// The accessors of one result column: its value in a row, and whether it is NULL if it can be.
// `row` is what `pg.first_row` and `pg.next_row` answer.
fn emit_column[&h, &q, &c](heap: &!h Heap, out: buffer.Buffer, query: &q [byte], column: &c [byte], index: int, kind: int, nullable: bool) -> [heap] buffer.Buffer {
    var o = buffer.append(heap, out, "\npub fn ");
    o = buffer.append(heap, o, query);
    o = buffer.push(heap, o, byte_of(95));
    o = buffer.append(heap, o, column);
    if kind == 1 {
        o = buffer.append(heap, o, "[&m](m: &m [byte], row: int) -> [] int {\n    let (from, to) = pg.value(m, row, ");
    } else if kind == 2 {
        o = buffer.append(heap, o, "[&m](m: &m [byte], row: int) -> [] bool {\n    let (from, to) = pg.value(m, row, ");
    } else {
        o = buffer.append(heap, o, "[&m](m: &m [byte], row: int) -> [] (int, int) {\n    return pg.value(m, row, ");
    }
    o = buffer.push_nat(heap, o, index);
    o = buffer.append(heap, o, ");\n");
    if kind == 1 {
        o = buffer.append(heap, o, "    return pg.int_text(m, from, to);\n");
    } else if kind == 2 {
        o = buffer.append(heap, o, "    return pg.bool_text(m, from, to);\n");
    }
    o = buffer.append(heap, o, "}\n");
    if nullable {
        o = buffer.append(heap, o, "\npub fn ");
        o = buffer.append(heap, o, query);
        o = buffer.push(heap, o, byte_of(95));
        o = buffer.append(heap, o, column);
        o = buffer.append(heap, o, "_is_null[&m](m: &m [byte], row: int) -> [] bool {\n    let (from, to) = pg.value(m, row, ");
        o = buffer.push_nat(heap, o, index);
        o = buffer.append(heap, o, ");\n    return from < 0;\n}\n");
    }
    return o;
}

// The offset of the first message of `kind` in a reply, or -1.
fn find_kind[&m](reply: &m [byte], want: int) -> [] int {
    var p = 0;
    while pg.size(reply, p) > 0 {
        if pg.kind(reply, p) == want {
            return p;
        }
        p = p + pg.size(reply, p);
    }
    return 0 - 1;
}

// The names to give the parameters, one per line: the ones the annotation lists, or `p1`, `p2`, ...
// Answers the names and a nonzero code (after a message) if they are not usable.
fn parameter_names[&h, &i, &n, &d](heap: &!h Heap, io: &!i Io, name: &n [byte], given: &d [byte], count: int) -> [heap, err_write] (buffer.Buffer, int) {
    var names = buffer.empty(heap, 64);
    var taken = buffer.append(heap, buffer.empty(heap, 64), "\nheap\nconn\n");
    var code = 0;
    let listed = token_count(given);
    if listed != 0 && listed != count {
        code = complain(io, name, "the annotation names a different number of parameters than the statement takes");
    }
    var k = 1;
    while k <= count && code == 0 {
        var one = buffer.empty(heap, 16);
        if listed == 0 {
            one = buffer.push_nat(heap, buffer.push(heap, one, byte_of(112)), k);
        } else {
            let (f, t) = token(given, k - 1);
            one = buffer.append(heap, one, given[f..t]);
        }
        borrow one as &oneref in {
            let word = buffer.bytes(oneref);
            let (nt, fresh) = claim(heap, taken, word);
            taken = nt;
            if !ident_ok(word) || !fresh {
                code = complain(io, name, "a parameter name is lower-case letters, digits and underscores, and is not repeated, `heap` or `conn`");
            } else {
                names = buffer.append(heap, names, word);
                names = buffer.push(heap, names, byte_of(10));
            }
        }
        buffer.drop(heap, one);
        k = k + 1;
    }
    buffer.drop(heap, taken);
    return (names, code);
}

// One query: describe it, append its runner and accessors to `out`. Answers the output, the names
// taken so far, and 0 -- or a nonzero code after a message on standard error.
fn generate[&h, &c, &i, &n, &d, &s](heap: &!h Heap, conn: &!c Conn, io: &!i Io, out: buffer.Buffer, seen: buffer.Buffer, name: &n [byte], given: &d [byte], sql: &s [byte]) -> [heap, conn_read, conn_write, err_write] (buffer.Buffer, buffer.Buffer, int) {
    if !ident_ok(name) {
        complain(io, name, "a query name is lower-case letters, digits and underscores, not starting with a digit");
        return (out, seen, 1);
    }
    let joins = contains_word(heap, sql, "join");
    let (reply, status) = pg.describing(heap, conn, sql);
    var o = out;
    var sn = seen;
    var code = 0;
    borrow reply as &rr in {
        let m = buffer.bytes(rr);
        let bad = pg.failure(m);
        let tpos = find_kind(m, 116);
        let npos = find_kind(m, 84);
        if bad >= 0 {
            code = complain_server(io, name, m, bad);
        } else if status != 0 || tpos < 0 {
            code = complain(io, name, "the server did not answer the describe");
        } else {
            let (s1, fresh) = claim(heap, sn, name);
            sn = s1;
            if !fresh {
                code = complain(io, name, "this name is used twice");
            }
            let (pnames, pcode) = parameter_names(heap, io, name, given, pg.param_count(m, tpos));
            if pcode != 0 {
                code = pcode;
            }
            var sql_literal = buffer.empty(heap, len(sql) + 8);
            let (lit, lit_ok) = literal(heap, sql_literal, sql);
            sql_literal = lit;
            if !lit_ok && code == 0 {
                code = complain(io, name, "the statement holds a control character other than a tab or a line break");
            }
            if code == 0 {
                borrow pnames as &pr in {
                    borrow sql_literal as &lr in {
                        o = emit_runner(heap, o, name, buffer.bytes(pr), m, tpos, buffer.bytes(lr));
                    }
                }
            }
            buffer.drop(heap, sql_literal);
            buffer.drop(heap, pnames);
            var j = 0;
            var columns = 0;
            if npos >= 0 {
                columns = pg.fields(m, npos);
            }
            while j < columns && code == 0 {
                let (cf, ct) = pg.column_name(m, npos, j);
                let column = m[cf..ct];
                let table = pg.column_table(m, npos, j);
                var nullable = true;
                if table > 0 && !joins {
                    nullable = !not_null(heap, conn, table, pg.column_attnum(m, npos, j));
                }
                var full = buffer.append(heap, buffer.empty(heap, 64), name);
                full = buffer.push(heap, full, byte_of(95));
                full = buffer.append(heap, full, column);
                if !ident_ok(column) {
                    code = complain(io, name, "a result column is not a plain identifier; give it an alias in the SQL");
                }
                borrow full as &fr in {
                    let (s2, fresh2) = claim(heap, sn, buffer.bytes(fr));
                    sn = s2;
                    if !fresh2 && code == 0 {
                        code = complain(io, name, "two result columns, or a column and a query, would have the same function name");
                    }
                }
                if nullable && code == 0 {
                    var nullname = buffer.append(heap, buffer.empty(heap, 64), name);
                    nullname = buffer.push(heap, nullname, byte_of(95));
                    nullname = buffer.append(heap, nullname, column);
                    nullname = buffer.append(heap, nullname, "_is_null");
                    borrow nullname as &nr in {
                        let (s3, fresh3) = claim(heap, sn, buffer.bytes(nr));
                        sn = s3;
                        if !fresh3 {
                            code = complain(io, name, "a column's `_is_null` accessor would have the same name as another function");
                        }
                    }
                    buffer.drop(heap, nullname);
                }
                if code == 0 {
                    o = emit_column(heap, o, name, column, j, oid_kind(pg.column_oid(m, npos, j)), nullable);
                }
                buffer.drop(heap, full);
                j = j + 1;
            }
        }
    }
    buffer.drop(heap, reply);
    return (o, sn, code);
}

// The line of `text` that starts at `at`: where it ends (at its newline, or the end of the text).
fn line_end[&t](text: &t [byte], at: int) -> [] int {
    var e = at;
    while e < len(text) && int_of(text[e]) != 10 {
        e = e + 1;
    }
    return e;
}

// The start of the first line at or after `from` that begins `-- name:`, or -1.
fn next_header[&t](text: &t [byte], from: int) -> [] int {
    var at = from;
    while at < len(text) {
        let e = line_end(text, at);
        if bytes.starts_with(text[at..e], "-- name:") {
            return at;
        }
        at = e + 1;
    }
    return 0 - 1;
}

// The file name without its directory and its last extension: `db/queries.sql` is `queries`.
fn stem[&t](path: &t [byte]) -> [] &t [byte] {
    var from = 0;
    var i = 0;
    while i < len(path) {
        if int_of(path[i]) == 47 {
            from = i + 1;
        }
        i = i + 1;
    }
    var to = len(path);
    var k = len(path);
    while k > from {
        if int_of(path[k - 1]) == 46 {
            to = k - 1;
            k = from;
        } else {
            k = k - 1;
        }
    }
    return path[from..to];
}

// A statement as the server wants it: no surrounding blanks and no closing `;`.
fn statement[&t](text: &t [byte]) -> [] &t [byte] {
    var s = bytes.trim(text);
    while len(s) > 0 && int_of(s[len(s) - 1]) == 59 {
        s = bytes.trim(s[0..len(s) - 1]);
    }
    return s;
}

// Every query in `text`, as one module. Nothing is answered but an error if any query is refused.
fn generate_all[&h, &c, &i, &t, &f](heap: &!h Heap, conn: &!c Conn, io: &!i Io, text: &t [byte], file: &f [byte], database: &f [byte]) -> [heap, conn_read, conn_write, err_write] (buffer.Buffer, int) {
    var out = buffer.append(heap, buffer.empty(heap, 4096), "// Generated by pgen from ");
    out = buffer.append(heap, out, file);
    out = buffer.append(heap, out, " against ");
    out = buffer.append(heap, out, database);
    out = buffer.append(heap, out, ". Do not edit: change the SQL and run pgen again.\n//\n// Each query is a function that runs it (`<name>`: the whole reply and a status, 0 for ok) and one\n// accessor per result column (`<name>_<column>`, read from a row as `pg.first_row`/`pg.next_row` give\n// it; `_is_null` where the column can be NULL).\nedition 5;\n\nmodule ");
    out = buffer.append(heap, out, stem(file));
    out = buffer.append(heap, out, ";\n\nimport std.buffer;\nimport pg;\n");
    var seen = buffer.push(heap, buffer.empty(heap, 256), byte_of(10));
    var code = 0;
    if !ident_ok(stem(file)) {
        code = complain(io, file, "the file name, without its extension, becomes the module name: lower-case letters, digits and underscores");
    }
    var queries = 0;
    var h = next_header(text, 0);
    while h >= 0 && code == 0 {
        let e = line_end(text, h);
        var next = next_header(text, e + 1);
        var stop = next;
        if next < 0 {
            stop = len(text);
            next = 0 - 1;
        }
        let header = text[h + 8..e];
        let (nf, nt) = token(header, 0);
        if nf < 0 {
            code = complain(io, file, "a `-- name:` line with no name");
        } else {
            var rest = header[nt..len(header)];
            let sql = statement(text[e + 1..stop]);
            if len(sql) == 0 {
                code = complain(io, header[nf..nt], "no statement after the name");
            } else {
                let (o, s, c) = generate(heap, conn, io, out, seen, header[nf..nt], rest, sql);
                out = o;
                seen = s;
                code = c;
                queries = queries + 1;
            }
        }
        h = next;
    }
    if code == 0 && queries == 0 {
        code = complain(io, file, "no `-- name:` line, so no queries");
    }
    buffer.drop(heap, seen);
    return (out, code);
}

// The queries file, then the generated module on standard output.
fn run[&h, &g, &i, &c, &z](heap: &!h Heap, args: &g Args, io: &!i Io, conn: &!c Conn, fs: &z Fs("")) -> [heap, args, io_write, err_write, conn_read, conn_write, fs_read("")] int {
    let source = box_slice(heap, 1048577, byte_of(0));
    var got = 0 - 1;
    if bytes.find(arg(args, 6), "..") < 0 {
        borrow mut source as &!sw in {
            got = fs_read(fs, arg(args, 6), contents(sw));
        }
    }
    var status = 1;
    if bytes.find(arg(args, 6), "..") >= 0 {
        complain(io, arg(args, 6), "a path with `..` in it is refused (the file capability traps on it); give the path without");
    } else if got < 0 {
        complain(io, arg(args, 6), "cannot read that file");
    } else if got > 1048576 {
        complain(io, arg(args, 6), "the queries file is over 1 MiB");
    } else {
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
        if s0 != 0 {
            complain(io, arg(args, 1), "the server refused the login");
            borrow hello as &hr in {
                let bad = pg.failure(buffer.bytes(hr));
                if bad >= 0 {
                    complain_server(io, arg(args, 1), buffer.bytes(hr), bad);
                }
            }
            buffer.drop(heap, hello);
            status = 1;
        } else {
            buffer.drop(heap, hello);
            borrow source as &sr in {
                let (out, code) = generate_all(heap, conn, io, contents(sr)[0..got], arg(args, 6), arg(args, 4));
                if code == 0 {
                    borrow out as &or in {
                        buffer.write(io, or);
                    }
                    status = 0;
                }
                buffer.drop(heap, out);
            }
        }
    }
    unbox_slice(heap, source);
    return status;
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
