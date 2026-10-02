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

// ---------------------------------------------------------------------- SCRAM

fn hex_digit(n: int) -> [] byte {
    if n < 10 {
        return byte_of(48 + n);
    }
    return byte_of(87 + n);
}

// `data` as lower-case hex, to compare with a published vector.
fn hex[&h, &d](heap: &!h Heap, data: &d [byte]) -> [heap] buffer.Buffer {
    var out = buffer.empty(heap, len(data) * 2);
    var i = 0;
    while i < len(data) {
        let v = int_of(data[i]);
        out = buffer.push(heap, out, hex_digit(v / 16));
        out = buffer.push(heap, out, hex_digit(v % 16));
        i = i + 1;
    }
    return out;
}

fn expect_hex[&h, &d, &w](heap: &!h Heap, got: &d [byte], want: &w [byte]) -> [heap] int {
    let x = hex(heap, got);
    borrow x as &xr in {
        expect_bytes(buffer.bytes(xr), want);
    }
    buffer.drop(heap, x);
    return 0;
}

fn expect_b64[&h, &d, &w](heap: &!h Heap, data: &d [byte], want: &w [byte]) -> [heap] int {
    let e = pg.base64_encode(heap, data);
    borrow e as &er in {
        expect_bytes(buffer.bytes(er), want);
    }
    buffer.drop(heap, e);
    return 0;
}

// RFC 4648 section 10, every remainder length.
fn test_base64_rfc4648_vectors[&h](heap: &!h Heap) -> [heap] int {
    expect_b64(heap, "", "");
    expect_b64(heap, "f", "Zg==");
    expect_b64(heap, "fo", "Zm8=");
    expect_b64(heap, "foo", "Zm9v");
    expect_b64(heap, "foob", "Zm9vYg==");
    expect_b64(heap, "fooba", "Zm9vYmE=");
    expect_b64(heap, "foobar", "Zm9vYmFy");
    // decode is the inverse, and refuses what is not base64
    let (d, ok) = pg.base64_decode(heap, "Zm9vYmE=");
    test.assert(ok);
    borrow d as &dr in {
        expect_bytes(buffer.bytes(dr), "fooba");
    }
    buffer.drop(heap, d);
    let (d2, ok2) = pg.base64_decode(heap, "Zm9vYmE");
    test.assert(!ok2);
    buffer.drop(heap, d2);
    let (d3, ok3) = pg.base64_decode(heap, "Zm9v!mE=");
    test.assert(!ok3);
    buffer.drop(heap, d3);
    return 0;
}

fn repeated[&h](heap: &!h Heap, value: int, n: int) -> [heap] buffer.Buffer {
    var out = buffer.empty(heap, n);
    var i = 0;
    while i < n {
        out = buffer.push(heap, out, byte_of(value));
        i = i + 1;
    }
    return out;
}

fn expect_mac[&h, &k, &m, &w](heap: &!h Heap, key: &k [byte], message: &m [byte], want: &w [byte]) -> [heap] int {
    let t = pg.hmac_sha256(heap, key, message);
    borrow t as &tr in {
        expect_hex(heap, buffer.bytes(tr), want);
    }
    buffer.drop(heap, t);
    return 0;
}

// RFC 4231 test cases 1, 2 and 6 (6: a key longer than the block size, hashed first).
fn test_hmac_sha256_rfc4231_vectors[&h](heap: &!h Heap) -> [heap] int {
    let k1 = repeated(heap, 11, 20);
    borrow k1 as &k1r in {
        expect_mac(heap, buffer.bytes(k1r), "Hi There", "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");
    }
    buffer.drop(heap, k1);
    expect_mac(heap, "Jefe", "what do ya want for nothing?", "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
    let k6 = repeated(heap, 170, 131);
    borrow k6 as &k6r in {
        expect_mac(heap, buffer.bytes(k6r), "Test Using Larger Than Block-Size Key - Hash Key First", "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54");
    }
    buffer.drop(heap, k6);
    return 0;
}

fn expect_pbkdf2[&h, &w](heap: &!h Heap, iterations: int, want: &w [byte]) -> [heap] int {
    let k = pg.pbkdf2_sha256(heap, "password", "salt", iterations);
    borrow k as &kr in {
        expect_hex(heap, buffer.bytes(kr), want);
    }
    buffer.drop(heap, k);
    return 0;
}

// Reference values from Python's hashlib.pbkdf2_hmac, which is OpenSSL's.
fn test_pbkdf2_sha256_vectors[&h](heap: &!h Heap) -> [heap] int {
    expect_pbkdf2(heap, 1, "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b");
    expect_pbkdf2(heap, 4096, "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a");
    return 0;
}

fn test_scram_client_first_message[&h](heap: &!h Heap) -> [heap] int {
    let m = pg.scram_client_first(heap, "user", "rOprNGfwEbeRWgbNEkqO");
    borrow m as &mr in {
        expect_bytes(buffer.bytes(mr), "n,,n=user,r=rOprNGfwEbeRWgbNEkqO");
    }
    buffer.drop(heap, m);
    return 0;
}

fn scram_answer[&h, &s](heap: &!h Heap, server_first: &s [byte]) -> [heap] (buffer.Buffer, buffer.Buffer, int) {
    return pg.scram_client_final(heap, "pencil", "user", "rOprNGfwEbeRWgbNEkqO", server_first);
}

// RFC 7677 section 3: the exchange for user "user", password "pencil".
fn test_scram_rfc7677_example[&h](heap: &!h Heap) -> [heap] int {
    let (final, expected, status) = scram_answer(heap, "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096");
    test.assert_eq(status, 0);
    borrow final as &fr in {
        expect_bytes(buffer.bytes(fr), "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=");
    }
    borrow expected as &er in {
        expect_bytes(buffer.bytes(er), "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=");
    }
    buffer.drop(heap, final);
    buffer.drop(heap, expected);
    return 0;
}

fn expect_scram_refused[&h, &s](heap: &!h Heap, server_first: &s [byte], want: int) -> [heap] int {
    let (final, expected, status) = scram_answer(heap, server_first);
    test.assert_eq(status, want);
    borrow final as &fr in {
        test.assert_eq(buffer.size(fr), 0);
    }
    borrow expected as &er in {
        test.assert_eq(buffer.size(er), 0);
    }
    buffer.drop(heap, final);
    buffer.drop(heap, expected);
    return 0;
}

// A server that is wrong or hostile is refused, never answered: a message missing a part, a
// nonce that does not extend ours (or only equals it), an undecodable salt, and an iteration
// count that is zero, not a number, or large enough to make the client compute for hours.
fn test_scram_refuses_a_bad_server_first[&h](heap: &!h Heap) -> [heap] int {
    expect_scram_refused(heap, "r=rOprNGfwEbeRWgbNEkqOabc,s=W22ZaJ0SNY7soEsUEjb6gQ==", 1);
    expect_scram_refused(heap, "s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096", 1);
    expect_scram_refused(heap, "r=otherNonceXXXXXXXXXXabc,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096", 2);
    expect_scram_refused(heap, "r=rOprNGfwEbeRWgbNEkqO,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096", 2);
    expect_scram_refused(heap, "r=rOprNGfwEbeRWgbNEkqOabc,s=!!notbase64!!,i=4096", 3);
    expect_scram_refused(heap, "r=rOprNGfwEbeRWgbNEkqOabc,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=0", 4);
    expect_scram_refused(heap, "r=rOprNGfwEbeRWgbNEkqOabc,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=x", 4);
    expect_scram_refused(heap, "r=rOprNGfwEbeRWgbNEkqOabc,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=1000001", 4);
    expect_scram_refused(heap, "r=rOprNGfwEbeRWgbNEkqOabc,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=99999999999", 4);
    return 0;
}

// ------------------------------------------------------- what generated code uses

fn test_rows_are_visited_once_each_and_a_failure_is_found[&h](heap: &!h Heap) -> [heap] int {
    let r = canned(heap);
    borrow r as &rr in {
        let m = buffer.bytes(rr);
        var seen = 0;
        var at = pg.first_row(m);
        while at >= 0 {
            seen = seen + 1;
            at = pg.next_row(m, at);
        }
        test.assert_eq(seen, 2);
        test.assert_eq(pg.failure(m), 0 - 1);
        test.assert_eq(pg.affected(m), 2);
    }
    buffer.drop(heap, r);
    // no rows: first_row is -1, and a reply with only a failure reports where it is
    let e = frame(heap, buffer.empty(heap, 64), 69, cstr(heap, buffer.push(heap, buffer.empty(heap, 16), byte_of(67)), "42P01"));
    let e2 = frame(heap, e, 90, buffer.push(heap, buffer.empty(heap, 1), byte_of(73)));
    borrow e2 as &er in {
        let m = buffer.bytes(er);
        test.assert_eq(pg.first_row(m), 0 - 1);
        test.assert_eq(pg.failure(m), 0);
        test.assert_eq(pg.affected(m), 0 - 1);
    }
    buffer.drop(heap, e2);
    return 0;
}

fn tag_reply[&h, &t](heap: &!h Heap, text: &t [byte]) -> [heap] buffer.Buffer {
    return frame(heap, buffer.empty(heap, 32), 67, cstr(heap, buffer.empty(heap, 16), text));
}

fn expect_affected[&h, &t](heap: &!h Heap, text: &t [byte], want: int) -> [heap] int {
    let r = tag_reply(heap, text);
    borrow r as &rr in {
        test.assert_eq(pg.affected(buffer.bytes(rr)), want);
    }
    buffer.drop(heap, r);
    return 0;
}

fn test_the_row_count_in_a_command_tag[&h](heap: &!h Heap) -> [heap] int {
    expect_affected(heap, "INSERT 0 1", 1);
    expect_affected(heap, "INSERT 0 250", 250);
    expect_affected(heap, "UPDATE 0", 0);
    expect_affected(heap, "DELETE 17", 17);
    expect_affected(heap, "SELECT 3", 3);
    expect_affected(heap, "CREATE TABLE", 0 - 1);
    expect_affected(heap, "BEGIN", 0 - 1);
    return 0;
}

fn expect_int[&t](text: &t [byte], want: int) -> [] int {
    test.assert_eq(pg.int_text(text, 0, len(text)), want);
    return 0;
}

fn test_integers_read_from_text_exactly() -> [] int {
    expect_int("0", 0);
    expect_int("7", 7);
    expect_int("-7", 0 - 7);
    expect_int("2147483647", 2147483647);
    expect_int("-2147483648", 0 - 2147483648);
    expect_int("9223372036854775807", 9223372036854775807);
    expect_int("-9223372036854775808", 0 - 9223372036854775807 - 1);
    // not a number: 0, never garbage
    expect_int("12x", 0);
    test.assert(pg.bool_text("t", 0, 1));
    test.assert(!pg.bool_text("f", 0, 1));
    test.assert(!pg.bool_text("true", 0, 4));
    return 0;
}

fn expect_param[&h, &w](heap: &!h Heap, value: int, want: &w [byte]) -> [heap] int {
    var ps = pg.params(heap);
    ps = pg.param_int(heap, ps, value);
    borrow ps as &pr in {
        let sql = pg.execute(heap, "select $1", pr);
        borrow sql as &sr in {
            let m = buffer.bytes(sr);
            // Bind is the second message; its parameter is length(4) + digits, after the two empty
            // names (2), the format count (2) and the parameter count (2)
            let parse = pg.size(m, 0);
            let at = parse + 5 + 1 + 1 + 2 + 2;
            test.assert_eq(int_of(m[at - 2]) * 256 + int_of(m[at - 1]), 1);
            test.assert_eq(int_of(m[at + 3]), len(want));
            expect_bytes(m[at + 4..at + 4 + len(want)], want);
        }
        buffer.drop(heap, sql);
    }
    pg.drop_params(heap, ps);
    return 0;
}

fn test_integer_parameters_are_written_in_decimal[&h](heap: &!h Heap) -> [heap] int {
    expect_param(heap, 0, "0");
    expect_param(heap, 5, "5");
    expect_param(heap, 0 - 5, "-5");
    expect_param(heap, 1234567890, "1234567890");
    expect_param(heap, 9223372036854775807, "9223372036854775807");
    expect_param(heap, 0 - 9223372036854775807 - 1, "-9223372036854775808");
    return 0;
}

fn test_a_column_that_is_a_table_column_says_which[&h](heap: &!h Heap) -> [heap] int {
    // one column "id": table oid 16385, attnum 3, type int4; and one expression column: 0, 0
    var t = b16(heap, buffer.empty(heap, 64), 2);
    t = b16(heap, b32(heap, b16(heap, b32(heap, cstr(heap, t, "id"), 16385), 3), 23), 4);
    t = b16(heap, b32(heap, t, 4294967295), 0);
    t = b16(heap, b32(heap, b16(heap, b32(heap, cstr(heap, t, "n"), 0), 0), 23), 4);
    t = b16(heap, b32(heap, t, 4294967295), 0);
    let r = frame(heap, buffer.empty(heap, 64), 84, t);
    borrow r as &rr in {
        let m = buffer.bytes(rr);
        test.assert_eq(pg.column_table(m, 0, 0), 16385);
        test.assert_eq(pg.column_attnum(m, 0, 0), 3);
        test.assert_eq(pg.column_oid(m, 0, 0), 23);
        test.assert_eq(pg.column_table(m, 0, 1), 0);
        test.assert_eq(pg.column_attnum(m, 0, 1), 0);
        test.assert_eq(pg.column_oid(m, 0, 1), 23);
        test.assert_eq(pg.column_table(m, 0, 2), 0 - 1);
    }
    buffer.drop(heap, r);
    return 0;
}

// ------------------------------------------------------- prepared statements

fn be32_at[&b](g: &b [byte], at: int) -> [] int {
    return int_of(g[at]) * 16777216 + int_of(g[at + 1]) * 65536 + int_of(g[at + 2]) * 256 + int_of(g[at + 3]);
}

// Parse, then Sync: 'P' length "name\0" "sql\0" 0 parameter types.
fn test_parse_named_message[&h](heap: &!h Heap) -> [heap] int {
    let m = pg.parse_named(heap, "s1", "select 1");
    borrow m as &mr in {
        let g = buffer.bytes(mr);
        test.assert_eq(len(g), 1 + 18 + 5);
        test.assert_eq(int_of(g[0]), 80);
        test.assert_eq(be32_at(g, 1), 4 + 3 + 9 + 2);
        expect_bytes(g[5..8], "s1\0");
        expect_bytes(g[8..17], "select 1\0");
        test.assert_eq(int_of(g[17]) + int_of(g[18]), 0);
        // Sync
        test.assert_eq(int_of(g[19]), 83);
        test.assert_eq(be32_at(g, 20), 4);
    }
    buffer.drop(heap, m);
    // a name of a different length moves everything after it, and the lengths follow
    let m2 = pg.parse_named(heap, "a_longer_name", "x");
    borrow m2 as &m2r in {
        let g = buffer.bytes(m2r);
        test.assert_eq(be32_at(g, 1), 4 + 14 + 2 + 2);
        test.assert_eq(len(g), 1 + (4 + 14 + 2 + 2) + 5);
    }
    buffer.drop(heap, m2);
    return 0;
}

// Bind the named statement, Execute, Sync: no Parse, no Describe.
fn test_bind_named_message[&h](heap: &!h Heap) -> [heap] int {
    var ps = pg.params(heap);
    ps = pg.param(heap, ps, "7");
    ps = pg.param_null(heap, ps);
    borrow ps as &pr in {
        let m = pg.bind_named(heap, "s1", pr);
        borrow m as &mr in {
            let g = buffer.bytes(mr);
            // Bind: portal "" , statement "s1", 0 format codes, 2 parameters ("7" and NULL), 0 result codes
            test.assert_eq(int_of(g[0]), 66);
            let body = 1 + 3 + 2 + 2 + (4 + 1) + 4 + 2;
            test.assert_eq(be32_at(g, 1), 4 + body);
            test.assert_eq(int_of(g[5]), 0);
            expect_bytes(g[6..9], "s1\0");
            test.assert_eq(int_of(g[9]) + int_of(g[10]), 0);
            test.assert_eq(int_of(g[11]) * 256 + int_of(g[12]), 2);
            test.assert_eq(be32_at(g, 13), 1);
            expect_bytes(g[17..18], "7");
            test.assert_eq(be32_at(g, 18), 4294967295);
            // Execute: portal "", no row limit
            let e = 1 + 4 + body;
            test.assert_eq(int_of(g[e]), 69);
            test.assert_eq(be32_at(g, e + 1), 9);
            test.assert_eq(be32_at(g, e + 6), 0);
            // Sync, and nothing else: no Parse and no Describe
            test.assert_eq(int_of(g[e + 10]), 83);
            test.assert_eq(len(g), e + 10 + 5);
        }
        buffer.drop(heap, m);
    }
    pg.drop_params(heap, ps);
    return 0;
}
