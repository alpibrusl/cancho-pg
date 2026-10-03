import std.buffer;
import std.crypto;
import std.test;
import pg;
import scram;

// `pooler/scram.ls`, the server's half of SCRAM-SHA-256 over plain slices, against the RFC 7677 exchange and against the driver's own
// (heap-using) HMAC and base64, which have their RFC vectors in `tests/pg_test.ls`.

fn same_bytes[&a, &b](x: &a [byte], y: &b [byte]) -> [] bool {
    if len(x) != len(y) {
        return false;
    }
    var i = 0;
    while i < len(x) {
        if x[i] != y[i] {
            return false;
        }
        i = i + 1;
    }
    return true;
}

// A deterministic byte sequence to feed both implementations.
fn fill[&b](buf: &!b [byte], seed: int) -> [] int {
    var x = (seed * 7919 + 12345) % 2147483648;
    var i = 0;
    while i < len(buf) {
        x = (x * 1103515245 + 12345) % 2147483648;
        buf[i] = byte_of(x / 65536 % 256);
        i = i + 1;
    }
    return 0;
}

fn test_base64_agrees_with_the_drivers_at_every_length[&h](heap: &!h Heap) -> [heap] int {
    region a {
        let data = alloc_slice[a](64, byte_of(0));
        let out = alloc_slice[a](100, byte_of(0));
        let back = alloc_slice[a](100, byte_of(0));
        var n = 0;
        while n <= 40 {
            fill(data, n);
            let enc = scram.b64_encode(data[0..n], out);
            let theirs = pg.base64_encode(heap, data[0..n]);
            borrow theirs as &tr in {
                test.assert(same_bytes(out[0..enc], buffer.bytes(tr)));
            }
            buffer.drop(heap, theirs);
            test.assert_eq(scram.b64_decode(out[0..enc], back), n);
            test.assert(same_bytes(back[0..n], data[0..n]));
            n = n + 1;
        }
    }
    return 0;
}

fn test_base64_refuses_what_is_not_base64() -> [] int {
    region a {
        let out = alloc_slice[a](64, byte_of(0));
        test.assert_eq(scram.b64_decode("abc", out), 0 - 1);
        test.assert_eq(scram.b64_decode("ab=d", out), 0 - 1);
        test.assert_eq(scram.b64_decode("a===", out), 0 - 1);
        test.assert_eq(scram.b64_decode("=abc", out), 0 - 1);
        test.assert_eq(scram.b64_decode("ab!d", out), 0 - 1);
        test.assert_eq(scram.b64_decode("YQ==YQ==", out), 0 - 1);
        test.assert_eq(scram.b64_decode("YWJj", out), 3);
        test.assert_eq(scram.b64_decode("", out), 0);
    }
    return 0;
}

fn test_hmac_agrees_with_the_drivers_for_every_key_and_message_length[&h](heap: &!h Heap) -> [heap] int {
    region a {
        let key = alloc_slice[a](64, byte_of(0));
        let msg = alloc_slice[a](200, byte_of(0));
        let out = alloc_slice[a](32, byte_of(0));
        var k = 0;
        while k <= 64 {
            fill(key, k + 1000);
            var m = 0;
            while m <= 200 {
                fill(msg, m);
                test.assert_eq(scram.hmac(key[0..k], msg[0..m], out), 0);
                let theirs = pg.hmac_sha256(heap, key[0..k], msg[0..m]);
                borrow theirs as &tr in {
                    test.assert(same_bytes(out, buffer.bytes(tr)));
                }
                buffer.drop(heap, theirs);
                m = m + 13;
            }
            k = k + 1;
        }
        test.assert_eq(scram.hmac(key[0..64], "x", out), 0);
    }
    return 0;
}

fn test_hmac_refuses_a_key_longer_than_a_block() -> [] int {
    region a {
        let key = alloc_slice[a](65, byte_of(1));
        let out = alloc_slice[a](32, byte_of(0));
        test.assert_eq(scram.hmac(key, "x", out), 0 - 1);
    }
    return 0;
}

// RFC 7677 section 3: user "user", password "pencil", salt W22ZaJ0SNY7soEsUEjb6gQ==, 4096 iterations.
fn rfc_auth_message() -> [] &static [byte] {
    return "n=user,r=rOprNGfwEbeRWgbNEkqO,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096,c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0";
}

// The keys the pooler derives at start from a password and salt: StoredKey (SHA-256 of ClientKey) into `stored`, ServerKey into `server_key`.
fn derive[&h, &p, &s, &a, &b](heap: &!h Heap, password: &p [byte], salt: &s [byte], iterations: int, stored: &!a [byte], server_key: &!b [byte]) -> [heap] int {
    let salted = pg.pbkdf2_sha256(heap, password, salt, iterations);
    borrow salted as &sr in {
        region r {
            let client_key = alloc_slice[r](32, byte_of(0));
            scram.hmac(buffer.bytes(sr), "Client Key", client_key);
            crypto.sha256(client_key, stored);
            scram.hmac(buffer.bytes(sr), "Server Key", server_key);
        }
    }
    buffer.drop(heap, salted);
    return 0;
}

fn test_the_rfc_7677_proof_is_accepted_and_the_server_signature_is_the_rfcs[&h](heap: &!h Heap) -> [heap] int {
    region a {
        let salt = alloc_slice[a](16, byte_of(0));
        test.assert_eq(scram.b64_decode("W22ZaJ0SNY7soEsUEjb6gQ==", salt), 16);
        let stored = alloc_slice[a](32, byte_of(0));
        let server_key = alloc_slice[a](32, byte_of(0));
        derive(heap, "pencil", salt, 4096, stored, server_key);
        let sig = alloc_slice[a](32, byte_of(0));
        test.assert(scram.verify(stored, server_key, rfc_auth_message(), "dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=", sig));
        let text = alloc_slice[a](64, byte_of(0));
        let n = scram.b64_encode(sig, text);
        test.assert(same_bytes(text[0..n], "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="));
    }
    return 0;
}

fn test_any_change_to_the_proof_the_message_or_the_keys_is_refused[&h](heap: &!h Heap) -> [heap] int {
    region a {
        let salt = alloc_slice[a](16, byte_of(0));
        scram.b64_decode("W22ZaJ0SNY7soEsUEjb6gQ==", salt);
        let stored = alloc_slice[a](32, byte_of(0));
        let server_key = alloc_slice[a](32, byte_of(0));
        derive(heap, "pencil", salt, 4096, stored, server_key);
        let sig = alloc_slice[a](32, byte_of(0));
        let proof = alloc_slice[a](44, byte_of(0));
        let good = "dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=";
        // Each of the 44 characters replaced by another valid one (and, at the padding, by a letter).
        var i = 0;
        while i < 44 {
            var j = 0;
            while j < 44 {
                proof[j] = good[j];
                j = j + 1;
            }
            if int_of(good[i]) == 65 {
                proof[i] = byte_of(66);
            } else {
                proof[i] = byte_of(65);
            }
            test.assert(!scram.verify(stored, server_key, rfc_auth_message(), proof, sig));
            i = i + 1;
        }
        // The right proof for another message, another password, another salt, and shapes that are not a proof.
        test.assert(!scram.verify(stored, server_key, "n=user,r=x", good, sig));
        let stored2 = alloc_slice[a](32, byte_of(0));
        let server2 = alloc_slice[a](32, byte_of(0));
        derive(heap, "pencil2", salt, 4096, stored2, server2);
        test.assert(!scram.verify(stored2, server2, rfc_auth_message(), good, sig));
        derive(heap, "pencil", salt, 4095, stored2, server2);
        test.assert(!scram.verify(stored2, server2, rfc_auth_message(), good, sig));
        test.assert(!scram.verify(stored, server_key, rfc_auth_message(), "", sig));
        test.assert(!scram.verify(stored, server_key, rfc_auth_message(), "dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ", sig));
        test.assert(!scram.verify(stored, server_key, rfc_auth_message(), "dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=", sig));
        test.assert(!scram.verify(stored[0..31], server_key, rfc_auth_message(), good, sig));
        // No signature is written for a refusal.
        var k = 0;
        while k < 32 {
            sig[k] = byte_of(0);
            k = k + 1;
        }
        scram.verify(stored, server_key, rfc_auth_message(), "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", sig);
        k = 0;
        var zeros = 0;
        while k < 32 {
            if int_of(sig[k]) == 0 {
                zeros = zeros + 1;
            }
            k = k + 1;
        }
        test.assert_eq(zeros, 32);
    }
    return 0;
}
