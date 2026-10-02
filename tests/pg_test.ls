import std.buffer;
import std.bytes;
import std.test;
import pg;

// What `pg` encodes and decodes, with no server: encoders checked byte for byte, decoders
// run over replies built here from the protocol's documented layout.

fn b32[&h](heap: &!h Heap, b: buffer.Buffer, n: int) -> [heap] buffer.Buffer {
    var o = buffer.push(heap, b, byte_of(n / 16777216 % 256));
    o = buffer.push(heap, o, byte_of(n / 65536 % 256));
    o = buffer.push(heap, o, byte_of(n / 256 % 256));
    return buffer.push(heap, o, byte_of(n % 256));
}

fn b16[&h](heap: &!h Heap, b: buffer.Buffer, n: int) -> [heap] buffer.Buffer {
    let o = buffer.push(heap, b, byte_of(n / 256 % 256));
    return buffer.push(heap, o, byte_of(n % 256));
}

fn cstr[&h, &s](heap: &!h Heap, b: buffer.Buffer, s: &s [byte]) -> [heap] buffer.Buffer {
    return buffer.push(heap, buffer.append(heap, b, s), byte_of(0));
}

// Append the message `kind` + `body` to `out`, consuming `body`.
fn frame[&h](heap: &!h Heap, out: buffer.Buffer, kind: int, body: buffer.Buffer) -> [heap] buffer.Buffer {
    var n = 0;
    borrow body as &sb in {
        n = buffer.size(sb);
    }
    var o = b32(heap, buffer.push(heap, out, byte_of(kind)), 4 + n);
    borrow body as &bb in {
        o = buffer.append(heap, o, buffer.bytes(bb));
    }
    buffer.drop(heap, body);
    return o;
}

fn expect_bytes[&a, &w](got: &a [byte], want: &w [byte]) -> [] int {
    test.assert_eq(len(got), len(want));
    test.assert(bytes.equal(got, want));
    return 0;
}

// ------------------------------------------------------------------ encoding

fn test_startup_message[&h](heap: &!h Heap) -> [heap] int {
    let m = pg.startup(heap, "u", "d");
    borrow m as &mr in {
        let g = buffer.bytes(mr);
        // length 27, protocol 3.0 = 0x00030000, then the parameters
        test.assert_eq(len(g), 27);
        test.assert_eq(int_of(g[3]), 27);
        test.assert_eq(int_of(g[5]), 3);
        test.assert_eq(int_of(g[6]) + int_of(g[7]), 0);
        expect_bytes(g[8..27], "user\0u\0database\0d\0\0");
    }
    buffer.drop(heap, m);
    return 0;
}

fn test_query_password_and_terminate[&h](heap: &!h Heap) -> [heap] int {
    let q = pg.query(heap, "SELECT 1");
    borrow q as &qr in {
        let g = buffer.bytes(qr);
        test.assert_eq(int_of(g[0]), 81);
        test.assert_eq(int_of(g[4]), 4 + 8 + 1);
        expect_bytes(g[5..14], "SELECT 1\0");
    }
    buffer.drop(heap, q);
    let p = pg.password(heap, "s3cret");
    borrow p as &pr in {
        let g = buffer.bytes(pr);
        test.assert_eq(int_of(g[0]), 112);
        test.assert_eq(int_of(g[4]), 4 + 6 + 1);
        expect_bytes(g[5..12], "s3cret\0");
    }
    buffer.drop(heap, p);
    let t = pg.terminate(heap);
    borrow t as &tr in {
        let g = buffer.bytes(tr);
        test.assert_eq(len(g), 5);
        test.assert_eq(int_of(g[0]), 88);
        test.assert_eq(int_of(g[4]), 4);
    }
    buffer.drop(heap, t);
    return 0;
}

// Parse, Bind, Describe, Execute, Sync -- in that order, every length consistent, and the
// parameters in the Bind exactly as sent: "ab", NULL (-1), "" (0, not -1).
fn test_extended_query_message_sequence_and_parameters[&h](heap: &!h Heap) -> [heap] int {
    var ps = pg.params(heap);
    ps = pg.param(heap, ps, "ab");
    ps = pg.param_null(heap, ps);
    ps = pg.param(heap, ps, "");
    var q = buffer.empty(heap, 8);
    borrow ps as &pr in {
        buffer.drop(heap, q);
        q = pg.execute(heap, "SELECT $1, $2, $3", pr);
    }
    test.assert_eq(pg.drop_params(heap, ps), 3);
    borrow q as &qr in {
        let m = buffer.bytes(qr);
        var at = 0;
        var kinds = 0;
        while pg.size(m, at) > 0 {
            kinds = kinds * 256 + pg.kind(m, at);
            if pg.kind(m, at) == 66 {
                // Bind body: portal "", statement "", 0 formats, 3 parameters, then each
                let body = at + 5;
                test.assert_eq(int_of(m[body]), 0);
                test.assert_eq(int_of(m[body + 1]), 0);
                test.assert_eq(int_of(m[body + 2]) + int_of(m[body + 3]), 0);
                test.assert_eq(int_of(m[body + 4]) * 256 + int_of(m[body + 5]), 3);
                test.assert_eq(int_of(m[body + 9]), 2);
                expect_bytes(m[body + 10..body + 12], "ab");
                test.assert_eq(int_of(m[body + 12]), 255);
                test.assert_eq(int_of(m[body + 15]), 255);
                test.assert_eq(int_of(m[body + 16]), 0);
                test.assert_eq(int_of(m[body + 19]), 0);
            }
            at = at + pg.size(m, at);
        }
        // the messages tile the buffer exactly: 'P' 'B' 'D' 'E' 'S'
        test.assert_eq(at, len(m));
        test.assert_eq(kinds, 80 * 4294967296 + 66 * 16777216 + 68 * 65536 + 69 * 256 + 83);
    }
    buffer.drop(heap, q);
    return 0;
}

// ------------------------------------------------------------------ decoding

// R(ok) S("a","b") K Z('I'), then T(2 columns: id int4, name text), D("7","héllo"),
// D(NULL,""), C("SELECT 2"), Z('T').
fn canned[&h](heap: &!h Heap) -> [heap] buffer.Buffer {
    var out = frame(heap, buffer.empty(heap, 256), 82, b32(heap, buffer.empty(heap, 4), 0));
    out = frame(heap, out, 83, cstr(heap, cstr(heap, buffer.empty(heap, 8), "a"), "b"));
    out = frame(heap, out, 75, b32(heap, b32(heap, buffer.empty(heap, 8), 1), 2));
    out = frame(heap, out, 90, buffer.push(heap, buffer.empty(heap, 1), byte_of(73)));

    // RowDescription: count, then per column name\0 table-oid(4) attnum(2) type-oid(4) size(2) mod(4) format(2)
    var t = b16(heap, buffer.empty(heap, 64), 2);
    t = b16(heap, b32(heap, b16(heap, b32(heap, cstr(heap, t, "id"), 0), 0), 23), 4);
    t = b16(heap, b32(heap, t, 4294967295), 0);
    t = b16(heap, b32(heap, b16(heap, b32(heap, cstr(heap, t, "name"), 0), 0), 25), 65535);
    t = b16(heap, b32(heap, t, 4294967295), 0);
    out = frame(heap, out, 84, t);

    // DataRow: count, then per value length(4) + bytes (-1: NULL)
    var d1 = b16(heap, buffer.empty(heap, 32), 2);
    d1 = buffer.append(heap, b32(heap, d1, 1), "7");
    d1 = buffer.append(heap, b32(heap, d1, 6), "héllo");
    out = frame(heap, out, 68, d1);
    var d2 = b16(heap, buffer.empty(heap, 32), 2);
    d2 = b32(heap, d2, 4294967295);
    d2 = b32(heap, d2, 0);
    out = frame(heap, out, 68, d2);

    out = frame(heap, out, 67, cstr(heap, buffer.empty(heap, 16), "SELECT 2"));
    return frame(heap, out, 90, buffer.push(heap, buffer.empty(heap, 1), byte_of(84)));
}

fn test_walking_a_reply_and_reading_each_message[&h](heap: &!h Heap) -> [heap] int {
    let r = canned(heap);
    borrow r as &rr in {
        let m = buffer.bytes(rr);
        test.assert(pg.ready(m));
        var at = 0;
        // R
        test.assert_eq(pg.kind(m, at), 82);
        test.assert_eq(pg.auth_code(m, at), 0);
        at = at + pg.size(m, at);
        // S, S?  (one S here), K
        test.assert_eq(pg.kind(m, at), 83);
        at = at + pg.size(m, at);
        test.assert_eq(pg.kind(m, at), 75);
        at = at + pg.size(m, at);
        // Z idle
        test.assert_eq(pg.kind(m, at), 90);
        test.assert_eq(pg.status(m, at), 73);
        at = at + pg.size(m, at);
        // T
        test.assert_eq(pg.kind(m, at), 84);
        test.assert_eq(pg.fields(m, at), 2);
        let (n0, n0e) = pg.column_name(m, at, 0);
        expect_bytes(m[n0..n0e], "id");
        let (n1, n1e) = pg.column_name(m, at, 1);
        expect_bytes(m[n1..n1e], "name");
        test.assert_eq(pg.column_oid(m, at, 0), 23);
        test.assert_eq(pg.column_oid(m, at, 1), 25);
        test.assert_eq(pg.column_oid(m, at, 2), 0 - 1);
        let (none, nonee) = pg.column_name(m, at, 5);
        test.assert_eq(none, 0 - 1);
        at = at + pg.size(m, at);
        // D "7", "héllo"
        test.assert_eq(pg.kind(m, at), 68);
        test.assert_eq(pg.fields(m, at), 2);
        let (a, ae) = pg.value(m, at, 0);
        expect_bytes(m[a..ae], "7");
        let (b, be) = pg.value(m, at, 1);
        test.assert_eq(be - b, 6);
        expect_bytes(m[b..be], "héllo");
        at = at + pg.size(m, at);
        // D NULL, "" -- a NULL is (-1, -1); an empty string is a real, empty range
        let (c, ce) = pg.value(m, at, 0);
        test.assert_eq(c, 0 - 1);
        test.assert_eq(ce, 0 - 1);
        let (e, ee) = pg.value(m, at, 1);
        test.assert(e > 0);
        test.assert_eq(ee - e, 0);
        let (x, xe) = pg.value(m, at, 2);
        test.assert_eq(x, 0 - 1);
        at = at + pg.size(m, at);
        // C
        test.assert_eq(pg.kind(m, at), 67);
        let (tf, tt) = pg.tag(m, at);
        expect_bytes(m[tf..tt], "SELECT 2");
        at = at + pg.size(m, at);
        // Z in a transaction
        test.assert_eq(pg.status(m, at), 84);
        at = at + pg.size(m, at);
        test.assert_eq(at, len(m));
        test.assert_eq(pg.size(m, at), 0 - 1);
    }
    buffer.drop(heap, r);
    return 0;
}

// A message whose bytes have not all arrived is "not yet" (-1), and so is a reply
// missing its ReadyForQuery -- a reader keeps reading; a length that cannot be is -2.
fn test_partial_replies_and_impossible_lengths[&h](heap: &!h Heap) -> [heap] int {
    let r = canned(heap);
    borrow r as &rr in {
        let m = buffer.bytes(rr);
        test.assert(pg.ready(m));
        // the canned reply holds two ReadyForQuery messages; cut after the first
        // message that is not one and no Z is left to see
        test.assert(!pg.ready(m[0..9]));
        test.assert_eq(pg.size(m[0..3], 0), 0 - 1);
        test.assert_eq(pg.size(m[0..8], 0), 0 - 1);
        test.assert_eq(pg.size(m[0..9], 0), 9);
    }
    buffer.drop(heap, r);
    let bad = frame(heap, buffer.empty(heap, 8), 90, buffer.empty(heap, 1));
    borrow bad as &br in {
        // a frame with a length field of 4 is a message with an empty body: fine
        test.assert_eq(pg.size(buffer.bytes(br), 0), 5);
    }
    buffer.drop(heap, bad);
    let weird = b32(heap, buffer.push(heap, buffer.empty(heap, 8), byte_of(90)), 3);
    borrow weird as &wr in {
        test.assert_eq(pg.size(buffer.bytes(wr), 0), 0 - 2);
    }
    buffer.drop(heap, weird);
    return 0;
}

// ErrorResponse: field code byte + cstring, repeated, ended by a 0 byte.
fn test_error_fields[&h](heap: &!h Heap) -> [heap] int {
    var b = cstr(heap, buffer.push(heap, buffer.empty(heap, 64), byte_of(83)), "ERROR");
    b = cstr(heap, buffer.push(heap, b, byte_of(67)), "42601");
    b = cstr(heap, buffer.push(heap, b, byte_of(77)), "syntax error");
    b = buffer.push(heap, b, byte_of(0));
    let e = frame(heap, buffer.empty(heap, 64), 69, b);
    borrow e as &er in {
        let m = buffer.bytes(er);
        let (sf, st) = pg.error_field(m, 0, 83);
        expect_bytes(m[sf..st], "ERROR");
        let (cf, ct) = pg.error_field(m, 0, 67);
        expect_bytes(m[cf..ct], "42601");
        let (mf, mt) = pg.error_field(m, 0, 77);
        expect_bytes(m[mf..mt], "syntax error");
        let (hf, ht) = pg.error_field(m, 0, 72);
        test.assert_eq(hf, 0 - 1);
        test.assert_eq(pg.size(m, 0), len(m));
    }
    buffer.drop(heap, e);
    return 0;
}

// Describe is Parse (unnamed), Describe 'S' (statement), Sync -- and its answer is a
// ParameterDescription then a RowDescription.
fn test_describe_message_and_a_parameter_description[&h](heap: &!h Heap) -> [heap] int {
    let q = pg.describe(heap, "select $1::int, $2::text");
    borrow q as &qr in {
        let m = buffer.bytes(qr);
        test.assert_eq(pg.kind(m, 0), 80);
        var at = pg.size(m, 0);
        test.assert_eq(pg.kind(m, at), 68);
        test.assert_eq(int_of(m[at + 5]), 83);
        at = at + pg.size(m, at);
        test.assert_eq(pg.kind(m, at), 83);
        at = at + pg.size(m, at);
        test.assert_eq(at, len(m));
    }
    buffer.drop(heap, q);
    // 't': count, then an oid per parameter
    var body = b16(heap, buffer.empty(heap, 16), 2);
    body = b32(heap, b32(heap, body, 23), 25);
    let reply = frame(heap, buffer.empty(heap, 32), 116, body);
    borrow reply as &rr in {
        let m = buffer.bytes(rr);
        test.assert_eq(pg.param_count(m, 0), 2);
        test.assert_eq(pg.param_oid(m, 0, 1), 23);
        test.assert_eq(pg.param_oid(m, 0, 2), 25);
        test.assert_eq(pg.param_oid(m, 0, 0), 0 - 1);
        test.assert_eq(pg.param_oid(m, 0, 3), 0 - 1);
    }
    buffer.drop(heap, reply);
    return 0;
}
