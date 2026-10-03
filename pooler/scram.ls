edition 5;

module scram;

import std.crypto;

// `scram` -- the server's half of SCRAM-SHA-256 (RFC 5802, RFC 7677) for the pooler's client authentication (`docs/pooler.md` P2), over plain slices:
// no heap, because the pooler's request loop has none. Base64, HMAC-SHA-256 and the check of a client's proof. The key derivation (PBKDF2) is done once
// at start with `pg.pbkdf2_sha256`; what is here runs once per login.
//
// What it does not do: channel binding (the pooler offers only `SCRAM-SHA-256`, not `-PLUS`), and a password longer than the 64 bytes of an HMAC block is not its
// concern (it works on keys the pooler derived, 32 bytes).

fn b64_char(v: int) -> [] int {
    if v < 26 {
        return 65 + v;
    }
    if v < 52 {
        return 97 + v - 26;
    }
    if v < 62 {
        return 48 + v - 52;
    }
    if v == 62 {
        return 43;
    }
    return 47;
}

// The value of a base64 character, or -1.
fn b64_value(c: int) -> [] int {
    if c >= 65 && c <= 90 {
        return c - 65;
    }
    if c >= 97 && c <= 122 {
        return c - 97 + 26;
    }
    if c >= 48 && c <= 57 {
        return c - 48 + 52;
    }
    if c == 43 {
        return 62;
    }
    if c == 47 {
        return 63;
    }
    return 0 - 1;
}

// Base64 (RFC 4648, padded) of `data` into `out`, which must hold `4 * ((len + 2) / 3)` bytes. Answers how many it wrote.
pub fn b64_encode[&d, &o](data: &d [byte], out: &!o [byte]) -> [] int {
    var i = 0;
    var n = 0;
    while i + 3 <= len(data) {
        let v = int_of(data[i]) * 65536 + int_of(data[i + 1]) * 256 + int_of(data[i + 2]);
        out[n] = byte_of(b64_char(v / 262144 % 64));
        out[n + 1] = byte_of(b64_char(v / 4096 % 64));
        out[n + 2] = byte_of(b64_char(v / 64 % 64));
        out[n + 3] = byte_of(b64_char(v % 64));
        i = i + 3;
        n = n + 4;
    }
    if len(data) - i == 1 {
        let v = int_of(data[i]) * 65536;
        out[n] = byte_of(b64_char(v / 262144 % 64));
        out[n + 1] = byte_of(b64_char(v / 4096 % 64));
        out[n + 2] = byte_of(61);
        out[n + 3] = byte_of(61);
        n = n + 4;
    } else if len(data) - i == 2 {
        let v = int_of(data[i]) * 65536 + int_of(data[i + 1]) * 256;
        out[n] = byte_of(b64_char(v / 262144 % 64));
        out[n + 1] = byte_of(b64_char(v / 4096 % 64));
        out[n + 2] = byte_of(b64_char(v / 64 % 64));
        out[n + 3] = byte_of(61);
        n = n + 4;
    }
    return n;
}

// The bytes `text` is the padded base64 of, written to `out` (which must hold `3 * len(text) / 4`), and how many; -1 if it is not valid (a length that is
// not a multiple of 4, a character outside the alphabet, padding anywhere but the end).
pub fn b64_decode[&t, &o](text: &t [byte], out: &!o [byte]) -> [] int {
    if len(text) % 4 != 0 {
        return 0 - 1;
    }
    var i = 0;
    var n = 0;
    while i < len(text) {
        let a = b64_value(int_of(text[i]));
        let b = b64_value(int_of(text[i + 1]));
        if a < 0 || b < 0 {
            return 0 - 1;
        }
        let last = i + 4 == len(text);
        let c3 = int_of(text[i + 2]);
        let c4 = int_of(text[i + 3]);
        if c3 == 61 {
            if !last || c4 != 61 {
                return 0 - 1;
            }
            out[n] = byte_of((a * 4 + b / 16) % 256);
            n = n + 1;
        } else if c4 == 61 {
            if !last {
                return 0 - 1;
            }
            let c = b64_value(c3);
            if c < 0 {
                return 0 - 1;
            }
            out[n] = byte_of((a * 4 + b / 16) % 256);
            out[n + 1] = byte_of((b * 16 + c / 4) % 256);
            n = n + 2;
        } else {
            let c = b64_value(c3);
            let d = b64_value(c4);
            if c < 0 || d < 0 {
                return 0 - 1;
            }
            out[n] = byte_of((a * 4 + b / 16) % 256);
            out[n + 1] = byte_of((b * 16 + c / 4) % 256);
            out[n + 2] = byte_of((c * 64 + d) % 256);
            n = n + 3;
        }
        i = i + 4;
    }
    return n;
}

// HMAC-SHA-256 (RFC 2104) of `message` under `key` (at most 64 bytes) into `out` (32 bytes): H(opad || H(ipad || message)). 0, or -1 for a longer key.
pub fn hmac[&k, &m, &o](key: &k [byte], message: &m [byte], out: &!o [byte]) -> [] int {
    if len(key) > 64 {
        return 0 - 1;
    }
    region a {
        let inner = alloc_slice[a](64 + len(message), byte_of(0));
        let outer = alloc_slice[a](96, byte_of(0));
        let mid = alloc_slice[a](32, byte_of(0));
        var i = 0;
        while i < 64 {
            var kb = 0;
            if i < len(key) {
                kb = int_of(key[i]);
            }
            inner[i] = byte_of(kb ^ 54);
            outer[i] = byte_of(kb ^ 92);
            i = i + 1;
        }
        i = 0;
        while i < len(message) {
            inner[64 + i] = message[i];
            i = i + 1;
        }
        crypto.sha256(inner, mid);
        i = 0;
        while i < 32 {
            outer[64 + i] = mid[i];
            i = i + 1;
        }
        crypto.sha256(outer, out);
    }
    return 0;
}

// Whether `proof_b64` is the proof of a client that knows the password whose keys are `stored` (SHA-256 of ClientKey) and `server_key`, for `auth_message`:
// ClientKey is the proof xor HMAC(StoredKey, AuthMessage), and must hash to StoredKey (compared without stopping at the first difference). If so, the server's
// signature, HMAC(ServerKey, AuthMessage), is written to `signature` (32 bytes).
pub fn verify[&s, &k, &a, &p, &o](stored: &s [byte], server_key: &k [byte], auth_message: &a [byte], proof_b64: &p [byte], signature: &!o [byte]) -> [] bool {
    var ok = false;
    region r {
        let proof = alloc_slice[r](len(proof_b64) + 4, byte_of(0));
        let n = b64_decode(proof_b64, proof);
        if n == 32 && len(stored) == 32 && len(server_key) == 32 {
            let client_sig = alloc_slice[r](32, byte_of(0));
            hmac(stored, auth_message, client_sig);
            let client_key = alloc_slice[r](32, byte_of(0));
            var i = 0;
            while i < 32 {
                client_key[i] = byte_of(int_of(proof[i]) ^ int_of(client_sig[i]));
                i = i + 1;
            }
            let hashed = alloc_slice[r](32, byte_of(0));
            crypto.sha256(client_key, hashed);
            var diff = 0;
            i = 0;
            while i < 32 {
                diff = diff | int_of(hashed[i]) ^ int_of(stored[i]);
                i = i + 1;
            }
            if diff == 0 {
                hmac(server_key, auth_message, signature);
                ok = true;
            }
        }
    }
    return ok;
}
