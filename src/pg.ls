edition 5;

module pg;

// `pg` -- a PostgreSQL client for lex-sys, in lex-sys: the v3 frontend/backend wire
// protocol over a `Conn`. No C, no foreign call: `lex-sys authority` on a program using
// it reports `net_out` (to the one host the program narrowed it to), `conn_read`,
// `conn_write`, `heap`.
//
// Three layers, so each can be tested alone and a caller can take only what it needs:
//
//   1. Encoders that build the bytes a client sends: `startup`, `password`, `query`
//      (simple protocol), `execute` (extended protocol: Parse, Bind, Describe, Execute,
//      Sync, with parameters sent as data and never spliced into the SQL), `describe`
//      (the types of a statement's parameters and columns, without running it), `terminate`.
//   2. Decoders over the bytes a server answers with: `size` frames one message at `at`,
//      and `kind`, `fields`, `value`, `column_name`, `column_oid`, `param_count`, `param_oid`,
//      `error_field`, `tag`, `auth_code`, `status` read it. A reply is the accumulated bytes of every message up
//      to ReadyForQuery; nothing is copied out of it, a value is a `(from, to)` into it.
//   3. Blocking helpers over a `Conn`: `send`, `receive`, `login`, `simple`, `extended`,
//      `describing`.
//
// What is not here yet: SCRAM-SHA-256 and MD5 authentication (`login` answers 5: the
// server asked for one it cannot do; trust and cleartext password work), TLS, binary
// result formats, `COPY`, notifications, and a non-blocking connection (every helper
// here waits for the server -- see docs/design.md for why that matters in an event loop).
//
// Status codes the helpers answer with: 0 ok; 1 the server closed the connection;
// 2 a read or write would block; 3 a read failed; 4 the server answered a login with an
// error (the reply holds the ErrorResponse); 5 the server asked for authentication
// this cannot do; 6 a write failed.

import std.buffer;
import std.bytes;

// ---------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------

fn put_be32[&h](heap: &!h Heap, b: buffer.Buffer, n: int) -> [heap] buffer.Buffer {
    var o = buffer.push(heap, b, byte_of(n / 16777216 % 256));
    o = buffer.push(heap, o, byte_of(n / 65536 % 256));
    o = buffer.push(heap, o, byte_of(n / 256 % 256));
    return buffer.push(heap, o, byte_of(n % 256));
}

fn put_be16[&h](heap: &!h Heap, b: buffer.Buffer, n: int) -> [heap] buffer.Buffer {
    let o = buffer.push(heap, b, byte_of(n / 256 % 256));
    return buffer.push(heap, o, byte_of(n % 256));
}

// `s` and its terminating NUL.
fn put_cstr[&h, &s](heap: &!h Heap, b: buffer.Buffer, s: &s [byte]) -> [heap] buffer.Buffer {
    return buffer.push(heap, buffer.append(heap, b, s), byte_of(0));
}

// A tagged message: the type byte, a length that counts itself and the body, the body.
fn header[&h](heap: &!h Heap, b: buffer.Buffer, tag: int, body: int) -> [heap] buffer.Buffer {
    return put_be32(heap, buffer.push(heap, b, byte_of(tag)), 4 + body);
}

// The first message of a connection: no type byte, protocol 3.0, `user` and `database`.
pub fn startup[&h, &u, &d](heap: &!h Heap, user: &u [byte], database: &d [byte]) -> [heap] buffer.Buffer {
    // length (4) + protocol (4) + "user\0" + user\0 + "database\0" + database\0 + final \0
    var m = put_be32(heap, buffer.empty(heap, 64), 25 + len(user) + len(database));
    m = put_be32(heap, m, 196608);
    m = put_cstr(heap, m, "user");
    m = put_cstr(heap, m, user);
    m = put_cstr(heap, m, "database");
    m = put_cstr(heap, m, database);
    return buffer.push(heap, m, byte_of(0));
}

// The answer to a cleartext-password authentication request.
pub fn password[&h, &s](heap: &!h Heap, secret: &s [byte]) -> [heap] buffer.Buffer {
    return put_cstr(heap, header(heap, buffer.empty(heap, 32), 112, len(secret) + 1), secret);
}

// A simple query: one message, the SQL as text, results in text. Several statements
// separated by `;` are answered one after the other.
pub fn query[&h, &s](heap: &!h Heap, sql: &s [byte]) -> [heap] buffer.Buffer {
    return put_cstr(heap, header(heap, buffer.empty(heap, 64), 81, len(sql) + 1), sql);
}

// Ask the server what a statement would take and give back, without running it: Parse
// (unnamed statement), Describe the statement, Sync. The reply is a ParameterDescription
// (`param_count`, `param_oid`) and a RowDescription (`fields`, `column_name`, `column_oid`),
// or NoData for a statement that returns no rows. This is how a program learns the types of
// `$1`, `$2` and of every result column from the database itself.
pub fn describe[&h, &s](heap: &!h Heap, sql: &s [byte]) -> [heap] buffer.Buffer {
    var m = header(heap, buffer.empty(heap, 64), 80, 1 + len(sql) + 1 + 2);
    m = put_cstr(heap, m, "");
    m = put_cstr(heap, m, sql);
    m = put_be16(heap, m, 0);
    m = header(heap, m, 68, 2);
    m = buffer.push(heap, m, byte_of(83));
    m = buffer.push(heap, m, byte_of(0));
    return header(heap, m, 83, 0);
}

pub fn terminate[&h](heap: &!h Heap) -> [heap] buffer.Buffer {
    return header(heap, buffer.empty(heap, 8), 88, 0);
}

// Parameters for `execute`, each one a length and its bytes (a length of -1 is NULL).
pub res struct Params {
    count: int,
    packed: buffer.Buffer,
}

pub fn params[&h](heap: &!h Heap) -> [heap] Params {
    return Params { count: 0, packed: buffer.empty(heap, 64) };
}

// A text-format parameter. The server infers its type from where `$n` is used.
pub fn param[&h, &v](heap: &!h Heap, p: Params, value: &v [byte]) -> [heap] Params {
    let Params { count, packed } = p;
    let b = buffer.append(heap, put_be32(heap, packed, len(value)), value);
    return Params { count: count + 1, packed: b };
}

pub fn param_null[&h](heap: &!h Heap, p: Params) -> [heap] Params {
    let Params { count, packed } = p;
    return Params { count: count + 1, packed: put_be32(heap, packed, 4294967295) };
}

pub fn drop_params[&h](heap: &!h Heap, p: Params) -> [heap] int {
    let Params { count, packed } = p;
    buffer.drop(heap, packed);
    return count;
}

// An extended-protocol query with parameters `$1`, `$2`, ...: Parse (unnamed statement),
// Bind (unnamed portal, text parameters, text results), Describe the portal, Execute, Sync.
// The SQL and the values travel separately, so a value is never parsed as SQL.
pub fn execute[&h, &s, &p](heap: &!h Heap, sql: &s [byte], ps: &p Params) -> [heap] buffer.Buffer {
    var m = header(heap, buffer.empty(heap, 128), 80, 1 + len(sql) + 1 + 2);
    m = put_cstr(heap, m, "");
    m = put_cstr(heap, m, sql);
    m = put_be16(heap, m, 0);
    // Bind: portal "", statement "", 0 format codes (text), the parameters, 0 result codes
    m = header(heap, m, 66, 1 + 1 + 2 + 2 + buffer.size(ps.packed) + 2);
    m = put_cstr(heap, m, "");
    m = put_cstr(heap, m, "");
    m = put_be16(heap, m, 0);
    m = put_be16(heap, m, ps.count);
    m = buffer.append(heap, m, buffer.bytes(ps.packed));
    m = put_be16(heap, m, 0);
    // Describe the portal, Execute it without a row limit, Sync
    m = header(heap, m, 68, 2);
    m = buffer.push(heap, m, byte_of(80));
    m = buffer.push(heap, m, byte_of(0));
    m = header(heap, m, 69, 1 + 4);
    m = buffer.push(heap, m, byte_of(0));
    m = put_be32(heap, m, 0);
    return header(heap, m, 83, 0);
}

// ---------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------

// An unsigned big-endian 32-bit integer. A length of -1 (NULL) reads as 4294967295.
fn be32[&b](m: &b [byte], at: int) -> [] int {
    return int_of(m[at]) * 16777216 + int_of(m[at + 1]) * 65536 + int_of(m[at + 2]) * 256 + int_of(m[at + 3]);
}

fn be16[&b](m: &b [byte], at: int) -> [] int {
    return int_of(m[at]) * 256 + int_of(m[at + 1]);
}

// The bytes a NULL length (-1) reads as through `be32`: nothing follows it.
fn null_length() -> [] int {
    return 2147483648;
}

// The type byte of the message at `at` ('R' 82, 'T' 84, 'D' 68, 'C' 67, 'E' 69, 'Z' 90, ...).
pub fn kind[&b](m: &b [byte], at: int) -> [] int {
    return int_of(m[at]);
}

// The whole size of the message at `at` (type byte, length, body): `-1` if not all of it
// is in `m` yet, `-2` if its length is impossible. Walk a reply with `at = at + size(m, at)`
// while it is positive.
pub fn size[&b](m: &b [byte], at: int) -> [] int {
    if at + 5 > len(m) {
        return 0 - 1;
    }
    let n = be32(m, at + 1);
    if n < 4 {
        return 0 - 2;
    }
    if at + 1 + n > len(m) {
        return 0 - 1;
    }
    return 1 + n;
}

// ReadyForQuery's transaction status: 'I' 73 idle, 'T' 84 in a transaction, 'E' 69 failed.
pub fn status[&b](m: &b [byte], at: int) -> [] int {
    return int_of(m[at + 5]);
}

// The request code of an Authentication message: 0 ok, 3 cleartext password, 5 MD5, 10 SASL.
pub fn auth_code[&b](m: &b [byte], at: int) -> [] int {
    return be32(m, at + 5);
}

// The column or value count of a RowDescription or DataRow.
pub fn fields[&b](m: &b [byte], at: int) -> [] int {
    return be16(m, at + 5);
}

// Where column `i` of the RowDescription at `at` starts (its name), or -1.
fn column_at[&b](m: &b [byte], at: int, i: int) -> [] int {
    if i < 0 || i >= fields(m, at) {
        return 0 - 1;
    }
    var p = at + 7;
    var j = 0;
    while j < i {
        while int_of(m[p]) != 0 {
            p = p + 1;
        }
        p = p + 1 + 18;
        j = j + 1;
    }
    return p;
}

// The name of column `i`, as `(from, to)` in `m`; `(-1, -1)` if there is no such column.
pub fn column_name[&b](m: &b [byte], at: int, i: int) -> [] (int, int) {
    let p = column_at(m, at, i);
    if p < 0 {
        return (0 - 1, 0 - 1);
    }
    var q = p;
    while int_of(m[q]) != 0 {
        q = q + 1;
    }
    return (p, q);
}

// The type oid of column `i` (23 int4, 25 text, 16 bool, 20 int8, 1700 numeric, ...), or -1.
pub fn column_oid[&b](m: &b [byte], at: int, i: int) -> [] int {
    let p = column_at(m, at, i);
    if p < 0 {
        return 0 - 1;
    }
    var q = p;
    while int_of(m[q]) != 0 {
        q = q + 1;
    }
    return be32(m, q + 1 + 6);
}

// ParameterDescription ('t' 116): how many parameters the statement takes, and the oid of
// parameter `i` (1-based like `$1`: `param_oid(m, at, 1)` is the type of `$1`), or -1.
pub fn param_count[&b](m: &b [byte], at: int) -> [] int {
    return be16(m, at + 5);
}

pub fn param_oid[&b](m: &b [byte], at: int, i: int) -> [] int {
    if i < 1 || i > param_count(m, at) {
        return 0 - 1;
    }
    return be32(m, at + 7 + 4 * (i - 1));
}

// Value `i` of the DataRow at `at`, as `(from, to)` in `m`. A NULL is `(-1, -1)`; an empty
// string is `(n, n)`, which is not the same thing.
pub fn value[&b](m: &b [byte], at: int, i: int) -> [] (int, int) {
    if i < 0 || i >= fields(m, at) {
        return (0 - 1, 0 - 1);
    }
    var p = at + 7;
    var j = 0;
    while j < i {
        let l = be32(m, p);
        if l >= null_length() {
            p = p + 4;
        } else {
            p = p + 4 + l;
        }
        j = j + 1;
    }
    let l = be32(m, p);
    if l >= null_length() {
        return (0 - 1, 0 - 1);
    }
    return (p + 4, p + 4 + l);
}

// A field of the ErrorResponse (or NoticeResponse) at `at`, by its code byte: 'S' 83 severity,
// 'C' 67 SQLSTATE, 'M' 77 message, 'D' 68 detail, 'H' 72 hint, 'P' 80 position. `(-1, -1)` if absent.
pub fn error_field[&b](m: &b [byte], at: int, code: int) -> [] (int, int) {
    let end = at + size(m, at);
    var p = at + 5;
    while p < end - 1 && int_of(m[p]) != 0 {
        let c = int_of(m[p]);
        var q = p + 1;
        while q < end && int_of(m[q]) != 0 {
            q = q + 1;
        }
        if c == code {
            return (p + 1, q);
        }
        p = q + 1;
    }
    return (0 - 1, 0 - 1);
}

// The command tag of the CommandComplete at `at` ("SELECT 3", "INSERT 0 1"), as `(from, to)`.
pub fn tag[&b](m: &b [byte], at: int) -> [] (int, int) {
    return (at + 5, at + size(m, at) - 1);
}

// Whether `m` holds a complete ReadyForQuery.
pub fn ready[&b](m: &b [byte]) -> [] bool {
    var at = 0;
    while size(m, at) > 0 {
        if kind(m, at) == 90 {
            return true;
        }
        at = at + size(m, at);
    }
    return false;
}

// ---------------------------------------------------------------------
// Over a connection (blocking)
// ---------------------------------------------------------------------

// Write all of `bytes`; false if the connection would block or failed.
pub fn send[&c, &b](conn: &!c Conn, bytes: &b [byte]) -> [conn_write] bool {
    var at = 0;
    while at < len(bytes) {
        match conn_write(conn, bytes[at..len(bytes)]) {
            Sent::Wrote(w) => {
                at = at + w;
            }
            Sent::Again => {
                return false;
            }
            Sent::Failed(e) => {
                return false;
            }
        }
    }
    return true;
}

// Read into `acc` until it holds a ReadyForQuery. With `login` set, also stop at an
// Authentication request the client must answer (code other than 0) and at an
// ErrorResponse, neither of which is followed by a ReadyForQuery. Answers the reply so far
// and a status code.
fn read_until[&h, &c](heap: &!h Heap, conn: &!c Conn, acc: buffer.Buffer, login: bool) -> [heap, conn_read] (buffer.Buffer, int) {
    var a = acc;
    var scanned = 0;
    var done = false;
    var status = 0;
    while !done {
        region r {
            var buf = alloc_slice[r](4096, byte_of(0));
            match conn_read(conn, buf) {
                Received::Data(k) => {
                    a = buffer.append(heap, a, buf[0..k]);
                }
                Received::End => {
                    status = 1;
                    done = true;
                }
                Received::Again => {
                    status = 2;
                    done = true;
                }
                Received::Failed(e) => {
                    status = 3;
                    done = true;
                }
            }
        }
        borrow a as &ar in {
            let m = buffer.bytes(ar);
            while size(m, scanned) > 0 && !done {
                let k = kind(m, scanned);
                if k == 90 {
                    done = true;
                }
                if login && k == 69 {
                    done = true;
                }
                if login && k == 82 && auth_code(m, scanned) != 0 {
                    done = true;
                }
                scanned = scanned + size(m, scanned);
            }
        }
    }
    return (a, status);
}

// Read the server's answer to what was just sent: everything up to ReadyForQuery.
// Answers the reply (every message, in order) and a status code.
pub fn receive[&h, &c](heap: &!h Heap, conn: &!c Conn) -> [heap, conn_read] (buffer.Buffer, int) {
    return read_until(heap, conn, buffer.empty(heap, 256), false);
}

// Connect-time exchange: send the startup message, answer a cleartext password request
// with `secret`, and read to ReadyForQuery. Answers the server's reply (the parameter
// statuses and backend key, or the ErrorResponse) and a status code.
pub fn login[&h, &c, &u, &s, &d](heap: &!h Heap, conn: &!c Conn, user: &u [byte], secret: &s [byte], database: &d [byte]) -> [heap, conn_read, conn_write] (buffer.Buffer, int) {
    let hello = startup(heap, user, database);
    var ok = false;
    borrow hello as &hb in {
        ok = send(conn, buffer.bytes(hb));
    }
    buffer.drop(heap, hello);
    if !ok {
        return (buffer.empty(heap, 8), 6);
    }
    let (first, s1) = read_until(heap, conn, buffer.empty(heap, 256), true);
    if s1 != 0 {
        return (first, s1);
    }
    var asked = 0;
    var failed = false;
    borrow first as &fb in {
        let m = buffer.bytes(fb);
        // the reply may begin with the request; find the last message read
        var at = 0;
        while size(m, at) > 0 {
            if kind(m, at) == 82 {
                asked = auth_code(m, at);
            }
            if kind(m, at) == 69 {
                failed = true;
            }
            at = at + size(m, at);
        }
    }
    if failed {
        return (first, 4);
    }
    if asked == 0 {
        return (first, 0);
    }
    if asked != 3 {
        return (first, 5);
    }
    buffer.drop(heap, first);
    let reply = password(heap, secret);
    var sent = false;
    borrow reply as &rb in {
        sent = send(conn, buffer.bytes(rb));
    }
    buffer.drop(heap, reply);
    if !sent {
        return (buffer.empty(heap, 8), 6);
    }
    let (second, s2) = read_until(heap, conn, buffer.empty(heap, 256), true);
    if s2 != 0 {
        return (second, s2);
    }
    var bad = false;
    borrow second as &sb in {
        let m = buffer.bytes(sb);
        var at = 0;
        while size(m, at) > 0 {
            if kind(m, at) == 69 {
                bad = true;
            }
            at = at + size(m, at);
        }
    }
    if bad {
        return (second, 4);
    }
    return (second, 0);
}

// Run one simple-protocol query and read everything up to ReadyForQuery.
pub fn simple[&h, &c, &s](heap: &!h Heap, conn: &!c Conn, sql: &s [byte]) -> [heap, conn_read, conn_write] (buffer.Buffer, int) {
    let q = query(heap, sql);
    var ok = false;
    borrow q as &qb in {
        ok = send(conn, buffer.bytes(qb));
    }
    buffer.drop(heap, q);
    if !ok {
        return (buffer.empty(heap, 8), 6);
    }
    return receive(heap, conn);
}

// Describe a statement (see `describe`) and read the reply up to ReadyForQuery.
pub fn describing[&h, &c, &s](heap: &!h Heap, conn: &!c Conn, sql: &s [byte]) -> [heap, conn_read, conn_write] (buffer.Buffer, int) {
    let q = describe(heap, sql);
    var ok = false;
    borrow q as &qb in {
        ok = send(conn, buffer.bytes(qb));
    }
    buffer.drop(heap, q);
    if !ok {
        return (buffer.empty(heap, 8), 6);
    }
    return receive(heap, conn);
}

// Run one extended-protocol query with parameters and read everything up to ReadyForQuery.
pub fn extended[&h, &c, &s, &p](heap: &!h Heap, conn: &!c Conn, sql: &s [byte], ps: &p Params) -> [heap, conn_read, conn_write] (buffer.Buffer, int) {
    let q = execute(heap, sql, ps);
    var ok = false;
    borrow q as &qb in {
        ok = send(conn, buffer.bytes(qb));
    }
    buffer.drop(heap, q);
    if !ok {
        return (buffer.empty(heap, 8), 6);
    }
    return receive(heap, conn);
}
