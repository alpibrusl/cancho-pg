import std.test;
import frame;

// The pooler's two framing state machines (`pooler/frame.ls`) from bytes, with no server: a client's stream decided message by
// message however it is cut into reads, and the server's stream scanned for `ReadyForQuery` however it is cut.

// Write a message of `kind` with `body` bytes (the first of them `first`, the rest `fill`) at `at`; answers where the next goes.
fn msg[&b](buf: &!b [byte], at: int, kind: int, body: int, first: int, fill: int) -> [] int {
    buf[at] = byte_of(kind);
    let size = body + 4;
    buf[at + 1] = byte_of(size / 16777216 % 256);
    buf[at + 2] = byte_of(size / 65536 % 256);
    buf[at + 3] = byte_of(size / 256 % 256);
    buf[at + 4] = byte_of(size % 256);
    var i = 0;
    while i < body {
        if i == 0 {
            buf[at + 5] = byte_of(first);
        } else {
            buf[at + 5 + i] = byte_of(fill);
        }
        i = i + 1;
    }
    return at + 5 + body;
}

// What the proxy's loop would do with `stream` if it arrived `chunk` bytes at a time. `out` gets: 0 bytes passed on, 1 `ReadyForQuery`s owed,
// 2 dropped bytes, 3 refusals, 4 syncs that ended a refusal, 5 1 if the client terminated, 6 1 if it was cut off, 7 bytes dealt with.
fn drive[&s, &o](stream: &s [byte], total: int, chunk: int, out: &!o [int]) -> [] int {
    var i = 0;
    while i < 8 {
        out[i] = 0;
        i = i + 1;
    }
    var seen = 0;
    var arrived = chunk;
    if arrived > total {
        arrived = total;
    }
    var left = 0;
    var skipping = 0;
    var going = true;
    var guard = 0;
    while going && guard < 100000 {
        guard = guard + 1;
        let (act, n, rest, owed) = frame.client_step(stream[seen..arrived], left, skipping);
        if act == frame.need_more() {
            if arrived >= total {
                going = false;
            } else {
                arrived = arrived + chunk;
                if arrived > total {
                    arrived = total;
                }
            }
        } else if act == frame.forward() {
            out[0] = out[0] + n;
            out[1] = out[1] + owed;
            seen = seen + n;
            left = rest;
        } else if act == frame.terminate() {
            out[5] = 1;
            seen = seen + n;
            going = false;
        } else if act == frame.refuse_named() {
            out[3] = out[3] + 1;
            out[2] = out[2] + n;
            skipping = 1;
            seen = seen + n;
            left = rest;
        } else if act == frame.drop_bytes() {
            out[2] = out[2] + n;
            seen = seen + n;
            left = rest;
        } else if act == frame.synced() {
            out[4] = out[4] + 1;
            out[2] = out[2] + n;
            skipping = 0;
            seen = seen + n;
        } else {
            out[6] = 1;
            going = false;
        }
    }
    out[7] = seen;
    return guard;
}

fn test_a_clean_stream_is_passed_on_whole_at_every_chunk_size() -> [] int {
    region a {
        let s = alloc_slice[a](400, byte_of(0));
        let out = alloc_slice[a](8, 0);
        // Q(10) P unnamed(12) B(20) E(9) S H d(100) Q(5) S X
        var at = msg(s, 0, 81, 10, 'q', 'q');
        at = msg(s, at, 80, 12, 0, 'p');
        at = msg(s, at, 66, 20, 'b', 'b');
        at = msg(s, at, 69, 9, 'e', 'e');
        at = msg(s, at, 83, 0, 0, 0);
        at = msg(s, at, 72, 0, 0, 0);
        at = msg(s, at, 100, 100, 'd', 'd');
        at = msg(s, at, 81, 5, 'q', 'q');
        at = msg(s, at, 83, 0, 0, 0);
        let before_x = at;
        at = msg(s, at, 88, 0, 0, 0);
        var chunk = 1;
        while chunk <= at + 1 {
            drive(s, at, chunk, out);
            test.assert_eq(out[0], before_x);
            test.assert_eq(out[1], 4);
            test.assert_eq(out[2], 0);
            test.assert_eq(out[3], 0);
            test.assert_eq(out[5], 1);
            test.assert_eq(out[6], 0);
            test.assert_eq(out[7], at);
            chunk = chunk + 1;
        }
    }
    return 0;
}

fn test_a_named_parse_is_refused_and_the_rest_dropped_up_to_the_sync() -> [] int {
    region a {
        let s = alloc_slice[a](400, byte_of(0));
        let out = alloc_slice[a](8, 0);
        // Q(10) P named(30) B(10) E(5) S Q(4) X : the P, B, E are dropped, that S answered, the second Q passed on
        var at = msg(s, 0, 81, 10, 'q', 'q');
        let q1 = at;
        at = msg(s, at, 80, 30, 'n', 'p');
        at = msg(s, at, 66, 10, 'b', 'b');
        at = msg(s, at, 69, 5, 'e', 'e');
        let dropped = at - q1;
        at = msg(s, at, 83, 0, 0, 0);
        at = msg(s, at, 81, 4, 'q', 'q');
        let q2 = 9;
        at = msg(s, at, 88, 0, 0, 0);
        var chunk = 1;
        while chunk <= at + 1 {
            drive(s, at, chunk, out);
            test.assert_eq(out[0], q1 + q2);
            test.assert_eq(out[1], 2);
            test.assert_eq(out[2], dropped + 5);
            test.assert_eq(out[3], 1);
            test.assert_eq(out[4], 1);
            test.assert_eq(out[5], 1);
            test.assert_eq(out[6], 0);
            chunk = chunk + 1;
        }
    }
    return 0;
}

fn test_a_parse_without_a_body_or_with_an_empty_name_is_not_refused() -> [] int {
    region a {
        let s = alloc_slice[a](100, byte_of(0));
        let out = alloc_slice[a](8, 0);
        var at = msg(s, 0, 80, 0, 0, 0);
        at = msg(s, at, 80, 1, 0, 0);
        at = msg(s, at, 80, 6, 0, 'x');
        var chunk = 1;
        while chunk <= at + 1 {
            drive(s, at, chunk, out);
            test.assert_eq(out[0], at);
            test.assert_eq(out[3], 0);
            chunk = chunk + 1;
        }
    }
    return 0;
}

fn test_a_message_that_cannot_be_the_protocol_cuts_the_client_off() -> [] int {
    region a {
        let s = alloc_slice[a](100, byte_of(0));
        let out = alloc_slice[a](8, 0);
        // A length of 3 (below the 4 it counts itself and the length)
        s[0] = byte_of('Q');
        s[4] = byte_of(3);
        drive(s, 5, 5, out);
        test.assert_eq(out[6], 1);
        test.assert_eq(out[0], 0);
        // A length above the limit
        s[1] = byte_of(255);
        s[2] = byte_of(255);
        s[3] = byte_of(255);
        s[4] = byte_of(255);
        drive(s, 5, 2, out);
        test.assert_eq(out[6], 1);
        // Just under the limit is a message that is passed on as it arrives, without a buffer for it.
        s[1] = byte_of(63);
        drive(s, 5, 5, out);
        test.assert_eq(out[6], 0);
        test.assert_eq(out[0], 5);
    }
    return 0;
}

// Every message the server may send, in a stream with `ReadyForQuery`s of three statuses; cut at every chunk size.
fn test_the_scan_finds_every_ready_for_query_at_any_cut() -> [] int {
    region a {
        let s = alloc_slice[a](500, byte_of(0));
        let fs = alloc_slice[a](frame.scan_size(), 0);
        // 1 ParseComplete(0) 2 BindComplete(0) T(30) D(10) D(1) C(13) Z 'I'
        var at = msg(s, 0, 49, 0, 0, 0);
        at = msg(s, at, 50, 0, 0, 0);
        at = msg(s, at, 84, 30, 1, 2);
        at = msg(s, at, 68, 10, 3, 4);
        at = msg(s, at, 68, 1, 5, 5);
        at = msg(s, at, 67, 13, 'S', 'E');
        let before_z = at;
        at = msg(s, at, 90, 1, 'I', 0);
        let first_end = at;
        // then a transaction: C, Z 'T', then an error and Z 'E'
        at = msg(s, at, 67, 9, 'B', 'E');
        at = msg(s, at, 90, 1, 'T', 0);
        at = msg(s, at, 69, 20, 'S', 'x');
        at = msg(s, at, 90, 1, 'E', 0);
        var chunk = 1;
        while chunk <= at + 1 {
            var i = 0;
            while i < frame.scan_size() {
                fs[i] = 0;
                i = i + 1;
            }
            var pos = 0;
            var statuses = 0;
            while pos < at {
                var to = pos + chunk;
                if to > at {
                    to = at;
                }
                let boundary = frame.scan(s[pos..to], fs);
                // The status of a ReadyForQuery is not known before its last byte has arrived.
                if to < first_end {
                    test.assert_eq(fs[3], 0);
                }
                if boundary && fs[3] != 0 {
                    statuses = statuses * 256 + fs[3];
                    fs[3] = 0;
                }
                pos = to;
            }
            // Whatever the cut, the last ReadyForQuery (an 'E') is the last status taken; and cut a byte at a time the three are taken one by one.
            test.assert_eq(statuses % 256, 69);
            if chunk == 1 {
                test.assert_eq(statuses, 73 * 65536 + 84 * 256 + 69);
            }
            test.assert_eq(fs[0], 0);
            test.assert_eq(fs[2], 0);
            chunk = chunk + 1;
        }
        // One cut where every Z is taken on its own: after each of the three ends.
        var i = 0;
        while i < frame.scan_size() {
            fs[i] = 0;
            i = i + 1;
        }
        test.assert(frame.scan(s[0..before_z], fs));
        test.assert_eq(fs[3], 0);
        test.assert(!frame.scan(s[before_z..first_end - 1], fs));
        test.assert_eq(fs[3], 0);
        test.assert(frame.scan(s[first_end - 1..first_end], fs));
        test.assert_eq(fs[3], 73);
    }
    return 0;
}

fn test_messages_with_no_body_back_to_back_do_not_stall_the_scan() -> [] int {
    region a {
        let s = alloc_slice[a](100, byte_of(0));
        let fs = alloc_slice[a](frame.scan_size(), 0);
        var at = 0;
        var k = 0;
        while k < 20 {
            at = msg(s, at, 49, 0, 0, 0);
            k = k + 1;
        }
        var chunk = 1;
        while chunk <= at {
            var i = 0;
            while i < frame.scan_size() {
                fs[i] = 0;
                i = i + 1;
            }
            var pos = 0;
            while pos < at {
                var to = pos + chunk;
                if to > at {
                    to = at;
                }
                frame.scan(s[pos..to], fs);
                pos = to;
            }
            test.assert_eq(fs[0], 0);
            test.assert_eq(fs[3], 0);
            chunk = chunk + 1;
        }
    }
    return 0;
}
