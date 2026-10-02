edition 5;

module frame;

// `pooler.frame` -- the two small state machines of the pooler's transaction mode (`docs/pooler.md` section 3). Pure: bytes in, a
// decision out, no connection and no allocation, so they are tested from bytes (`tests/frame_test.ls`) at every split.
//
// After startup every message is a type byte, a big-endian int32 that counts itself and the body but not the type byte,
// and the body. The pooler needs the types and the lengths, and from two messages a little more:
//
//   * from the client, `Terminate` (it leaves, and needs no server), `Sync` and `Query` (each makes the server answer
//     with one `ReadyForQuery`, so each is one the pooler must wait for before a connection can go back), and a `Parse`
//     with a name (a prepared statement that would outlive the transaction on a connection the client will not see again);
//   * from the server, `ReadyForQuery` and the status byte in it: `I` idle, `T` in a transaction, `E` in a failed one.

// ---------------------------------------------------------------------
// Client to server
// ---------------------------------------------------------------------

// What `client_step` decided.
pub fn need_more() -> [] int {
    return 0;
}

// Pass `n` bytes on to the server.
pub fn forward() -> [] int {
    return 1;
}

// The client said `Terminate`: `n` bytes, to be dropped; the client is done.
pub fn terminate() -> [] int {
    return 2;
}

// A `Parse` with a name: `n` bytes are to be dropped and the client answered with an error; the rest of what it sends up to its next `Sync` is
// dropped too (that is what a server does after an error), and `Sync` is answered with `ReadyForQuery`.
pub fn refuse_named() -> [] int {
    return 3;
}

// Not the protocol (a length below 4 or above what is allowed): the client is cut off.
pub fn bad() -> [] int {
    return 4;
}

// Drop `n` bytes (a message after a refusal, up to a `Sync`).
pub fn drop_bytes() -> [] int {
    return 5;
}

// The `Sync` that ends a refusal: `n` bytes, to be dropped, and the client is answered with `ReadyForQuery`.
pub fn synced() -> [] int {
    return 6;
}

// The most a message may say its length is: past this the client is cut off rather than a 2 GB message tracked.
pub fn longest() -> [] int {
    return 1073741823;
}

fn be32[&b](m: &b [byte], at: int) -> [] int {
    return int_of(m[at]) * 16777216 + int_of(m[at + 1]) * 65536 + int_of(m[at + 2]) * 256 + int_of(m[at + 3]);
}

// Decide what to do with the start of `view`, which is what the client has sent that has not been dealt with.
//
// `left` is how much of the message being passed on is still to come (0 at a message boundary), and `skipping` is 1 while the
// client's messages are being dropped up to a `Sync`. Answers `(action, n, left, owed)`: what to do, with how many bytes of `view`, how much of the current
// message is still to come after them, and how many `ReadyForQuery`s the bytes passed on will make the server owe (`Query` and `Sync` one each, as `FunctionCall`).
//
// A message is decided on its header, whole: if fewer than five bytes (six for a `Parse`) have arrived the answer is `need_more`, and
// the caller reads more. Its body is passed on as it arrives, in as many pieces as it comes in.
pub fn client_step[&v](view: &v [byte], left: int, skipping: int) -> [] (int, int, int, int) {
    if len(view) == 0 {
        return (need_more(), 0, left, 0);
    }
    if left > 0 {
        var n = len(view);
        if n > left {
            n = left;
        }
        var act = forward();
        if skipping == 1 {
            act = drop_bytes();
        }
        return (act, n, left - n, 0);
    }
    if len(view) < 5 {
        return (need_more(), 0, 0, 0);
    }
    let kind = int_of(view[0]);
    let size = be32(view, 1);
    if size < 4 || size > longest() {
        return (bad(), 0, 0, 0);
    }
    let total = 1 + size;
    if kind == 88 {
        // `X`: Terminate.
        return (terminate(), 5, 0, 0);
    }
    var n = len(view);
    if n > total {
        n = total;
    }
    if skipping == 1 {
        if kind == 83 {
            return (synced(), 5, 0, 0);
        }
        return (drop_bytes(), n, total - n, 0);
    }
    if kind == 80 && size > 4 {
        // `P`: Parse. The statement's name comes first in the body, a C string: empty is the one byte 0.
        if len(view) < 6 {
            return (need_more(), 0, 0, 0);
        }
        if int_of(view[5]) != 0 {
            return (refuse_named(), n, total - n, 0);
        }
    }
    var owed = 0;
    if kind == 81 || kind == 83 || kind == 70 {
        // `Q`, `S`, `F`.
        owed = 1;
    }
    return (forward(), n, total - n, owed);
}

// ---------------------------------------------------------------------
// Server to client
// ---------------------------------------------------------------------

// The state of the scan of what the server sends: `fs[0..4]` is
//
//     0  bytes of the header of the message in hand that have been seen (0 to 5)
//     1  that message's type byte
//     2  how much of it is still to come, after the header
//     3  the status of the last `ReadyForQuery` that has been seen and not yet taken (0: none)
//     4  its length so far, while the header is being read
pub fn scan_size() -> [] int {
    return 5;
}

// Look through `view`, which is the next part of what the server sends, and keep the state in `fs`. Answers whether the stream is at a message
// boundary after it, and `fs[3]` is the status of the last `ReadyForQuery` seen. The caller takes that status when it
// is at a boundary and puts 0 back.
pub fn scan[&v, &f](view: &v [byte], fs: &!f [int]) -> [] bool {
    var i = 0;
    while i < len(view) {
        if fs[0] < 5 {
            let c = int_of(view[i]);
            if fs[0] == 0 {
                fs[1] = c;
                fs[4] = 0;
            } else {
                fs[4] = fs[4] * 256 + c;
            }
            fs[0] = fs[0] + 1;
            i = i + 1;
            if fs[0] == 5 {
                // A length below 4 is not a message; treat the stream as lost its place by reading it as an empty body.
                if fs[4] < 4 {
                    fs[2] = 0;
                } else {
                    fs[2] = fs[4] - 4;
                }
                if fs[2] == 0 {
                    fs[0] = 0;
                }
            }
        } else {
            var n = len(view) - i;
            if n > fs[2] {
                n = fs[2];
            }
            // The status of a ReadyForQuery is the one byte of its body.
            if fs[1] == 90 && fs[4] == 5 && n > 0 {
                fs[3] = int_of(view[i]);
            }
            fs[2] = fs[2] - n;
            i = i + n;
            if fs[2] == 0 {
                fs[0] = 0;
            }
        }
    }
    return fs[0] == 0;
}
