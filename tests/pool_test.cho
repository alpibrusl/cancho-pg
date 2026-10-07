edition 5;

import std.buffer;
import std.test;
import pg;
import pg.pool;
import queries;

// What `pg.pool` decides, with no server: the arguments of `reconnect`, what is due when, and how the waits grow. The
// connections themselves (the login, the failures, the statements) are `tests/reconnect_test.py`'s.

fn test_lost_says_which_statuses_mean_the_connection_went() -> [] int {
    test.assert(!pool.lost(0));
    test.assert(pool.lost(1));
    test.assert(!pool.lost(2));
    test.assert(pool.lost(3));
    test.assert(!pool.lost(4));
    test.assert(!pool.lost(5));
    test.assert(pool.lost(6));
    test.assert(!pool.lost(7));
    test.assert(pool.lost(8));
    test.assert(!pool.lost(9));
    test.assert(pool.lost(10));
    test.assert(pool.lost(11));
    test.assert(pool.lost(12));
    test.assert(!pool.lost(13));
    return 0;
}

fn test_a_pool_that_was_not_asked_to_reconnect_makes_nothing[&h](heap: &!h Heap) -> [heap, conn_write, poll] int {
    var pl = pool.empty(heap, 2, 4, 4096, 4096);
    match poller_new() {
        Polling::Ok(po) => {
            var poller = po;
            borrow mut poller as &!pw in {
                borrow mut pl as &!qw in {
                    test.assert_eq(pool.start(qw, pw, 10), 0);
                    test.assert_eq(pool.tick(heap, qw, pw, 5000), 0);
                    test.assert_eq(pool.dial_failed(qw, 5000, 111), 0 - 1);
                }
            }
            borrow pl as &qr in {
                test.assert_eq(pool.next_wake(qr, 5000), 0 - 1);
                test.assert_eq(pool.live(qr), 0);
                test.assert_eq(pool.connecting(qr), 0);
                test.assert_eq(pool.attempts(qr), 0);
                test.assert_eq(pool.lane_state(qr, 0), 0);
                test.assert_eq(pool.lane_state(qr, 2), 0 - 1);
            }
            poller_close(poller);
        }
        Polling::Failed(e) => {
            test.assert(false);
        }
    }
    pool.close(heap, pl);
    return 0;
}

fn test_reconnect_refuses_what_cannot_be_used[&h](heap: &!h Heap) -> [heap] int {
    var pl = pool.empty(heap, 1, 4, 4096, 50);
    let seed = "0123456789abcdef";
    var rc = 0;
    // the waits: at least 1 ms, the longest not below the first
    let (p1, r1) = pool.reconnect(heap, pl, "u", "p", "d", seed, "", 0, 0, 100, 500, 0);
    pl = p1;
    rc = r1;
    test.assert_eq(rc, 0 - 1);
    let (p2, r2) = pool.reconnect(heap, pl, "u", "p", "d", seed, "", 0, 100, 99, 500, 0);
    pl = p2;
    rc = r2;
    test.assert_eq(rc, 0 - 1);
    let (p3, r3) = pool.reconnect(heap, pl, "u", "p", "d", seed, "", 0, 100, 200, 0, 0);
    pl = p3;
    rc = r3;
    test.assert_eq(rc, 0 - 1);
    let (p4, r4) = pool.reconnect(heap, pl, "u", "p", "d", seed, "", 0, 100, 200, 500, 0 - 1);
    pl = p4;
    rc = r4;
    test.assert_eq(rc, 0 - 1);
    let (p5, r5) = pool.reconnect(heap, pl, "u", "p", "d", seed, "", 0 - 1, 100, 200, 500, 0);
    pl = p5;
    rc = r5;
    test.assert_eq(rc, 0 - 1);
    // a seed too short to be unpredictable
    let (p6, r6) = pool.reconnect(heap, pl, "u", "p", "d", "0123456789abcde", "", 0, 100, 200, 500, 0);
    pl = p6;
    rc = r6;
    test.assert_eq(rc, 0 - 1);
    // a script larger than the output slab (50 bytes)
    var script = buffer.empty(heap, 8);
    script = pool.statement(heap, script, "a_statement", "select 1 where 'a long text to make the script longer than the slab' <> 'x'");
    borrow script as &sr in {
        let (p7, r7) = pool.reconnect(heap, pl, "u", "p", "d", seed, buffer.bytes(sr), 1, 100, 200, 500, 0);
        pl = p7;
        rc = r7;
    }
    buffer.drop(heap, script);
    test.assert_eq(rc, 0 - 1);
    // and what can: no seed (no SCRAM), no statements, equal waits
    let (p8, r8) = pool.reconnect(heap, pl, "u", "p", "d", "", "", 0, 100, 100, 500, 0);
    pl = p8;
    rc = r8;
    test.assert_eq(rc, 0);
    let (p9, r9) = pool.reconnect(heap, pl, "", "", "", seed, "", 0, 1, 1, 1, 0);
    pl = p9;
    rc = r9;
    test.assert_eq(rc, 0);
    pool.close(heap, pl);
    return 0;
}

fn test_a_statement_is_parse_and_sync_as_pg_makes_them[&h](heap: &!h Heap) -> [heap] int {
    var script = buffer.empty(heap, 8);
    script = pool.statement(heap, script, "dbl", "select ($1::int8 * 2)::text");
    script = pool.statement(heap, script, "len", "select 1");
    let a = pg.parse_named(heap, "dbl", "select ($1::int8 * 2)::text");
    let b = pg.parse_named(heap, "len", "select 1");
    borrow script as &sr in {
        borrow a as &ar in {
            borrow b as &br in {
                let want = len(buffer.bytes(ar)) + len(buffer.bytes(br));
                test.assert_eq(len(buffer.bytes(sr)), want);
                var i = 0;
                while i < len(buffer.bytes(ar)) {
                    test.assert_eq(int_of(buffer.bytes(sr)[i]), int_of(buffer.bytes(ar)[i]));
                    i = i + 1;
                }
                var j = 0;
                while j < len(buffer.bytes(br)) {
                    test.assert_eq(int_of(buffer.bytes(sr)[i + j]), int_of(buffer.bytes(br)[j]));
                    j = j + 1;
                }
            }
        }
    }
    buffer.drop(heap, script);
    buffer.drop(heap, a);
    buffer.drop(heap, b);
    return 0;
}

fn test_nothing_is_due_until_the_loop_has_started_the_pool[&h](heap: &!h Heap) -> [heap, conn_write, poll] int {
    var pl = pool.empty(heap, 1, 4, 4096, 4096);
    var rc = 0;
    let (p10, r10) = pool.reconnect(heap, pl, "u", "", "d", "", "", 0, 100, 800, 500, 0);
    pl = p10;
    rc = r10;
    test.assert_eq(rc, 0);
    match poller_new() {
        Polling::Ok(po) => {
            var poller = po;
            borrow mut poller as &!pw in {
                borrow mut pl as &!qw in {
                    test.assert_eq(pool.tick(heap, qw, pw, 0), 0);
                    test.assert_eq(pool.start(qw, pw, 3), 0);
                    test.assert_eq(pool.tick(heap, qw, pw, 0), 1);
                }
            }
            poller_close(poller);
        }
        Polling::Failed(e) => {
            test.assert(false);
        }
    }
    pool.close(heap, pl);
    return 0;
}

// 100, 200, 400, 800, 800: the wait after each failed attempt, doubling to the longest.
fn test_the_wait_doubles_to_the_longest_and_no_further[&h](heap: &!h Heap) -> [heap, conn_write, poll] int {
    var pl = pool.empty(heap, 1, 4, 4096, 4096);
    var rc = 0;
    let (p11, r11) = pool.reconnect(heap, pl, "u", "", "d", "", "", 0, 100, 800, 500, 0);
    pl = p11;
    rc = r11;
    test.assert_eq(rc, 0);
    match poller_new() {
        Polling::Ok(po) => {
            var poller = po;
            borrow mut poller as &!pw in {
                borrow mut pl as &!qw in {
                    pool.start(qw, pw, 3);
                    var now = 0;
                    var wait = 100;
                    var round = 0;
                    while round < 7 {
                        test.assert_eq(pool.tick(heap, qw, pw, now), 1);
                        test.assert_eq(pool.dial_failed(qw, now, 111), 0);
                        // not due again until the wait is over
                        test.assert_eq(pool.tick(heap, qw, pw, now), 0);
                        test.assert_eq(pool.tick(heap, qw, pw, now + wait - 1), 0);
                        now = now + wait;
                        test.assert_eq(pool.next_wake(qw, now - 1), 1);
                        wait = wait * 2;
                        if wait > 800 {
                            wait = 800;
                        }
                        round = round + 1;
                    }
                }
            }
            borrow pl as &qr in {
                test.assert_eq(pool.attempts(qr), 7);
                test.assert_eq(pool.failures(qr), 7);
                test.assert_eq(pool.last_failure(qr), 20);
                test.assert_eq(pool.last_errno(qr), 111);
                test.assert_eq(pool.made(qr), 0);
                test.assert_eq(pool.live(qr), 0);
                test.assert_eq(pool.changes(qr), 7);
            }
            poller_close(poller);
        }
        Polling::Failed(e) => {
            test.assert(false);
        }
    }
    pool.close(heap, pl);
    return 0;
}

fn test_two_connections_wait_each_on_its_own[&h](heap: &!h Heap) -> [heap, conn_write, poll] int {
    var pl = pool.empty(heap, 2, 4, 4096, 4096);
    var rc = 0;
    let (p12, r12) = pool.reconnect(heap, pl, "u", "", "d", "", "", 0, 100, 800, 500, 0);
    pl = p12;
    rc = r12;
    match poller_new() {
        Polling::Ok(po) => {
            var poller = po;
            borrow mut poller as &!pw in {
                borrow mut pl as &!qw in {
                    pool.start(qw, pw, 3);
                    test.assert_eq(pool.tick(heap, qw, pw, 0), 2);
                    test.assert_eq(pool.dial_failed(qw, 0, 111), 0);
                    // the other one is still due
                    test.assert_eq(pool.tick(heap, qw, pw, 0), 1);
                    test.assert_eq(pool.next_wake(qw, 0), 0);
                    test.assert_eq(pool.dial_failed(qw, 0, 111), 1);
                    test.assert_eq(pool.tick(heap, qw, pw, 0), 0);
                    test.assert_eq(pool.next_wake(qw, 0), 100);
                    test.assert_eq(pool.next_wake(qw, 60), 40);
                    // the first fails again at 100 and waits 200; the second was not tried in between
                    test.assert_eq(pool.tick(heap, qw, pw, 100), 2);
                    test.assert_eq(pool.dial_failed(qw, 100, 111), 0);
                    test.assert_eq(pool.tick(heap, qw, pw, 100), 1);
                    test.assert_eq(pool.next_wake(qw, 100), 0);
                    test.assert_eq(pool.dial_failed(qw, 100, 111), 1);
                    test.assert_eq(pool.next_wake(qw, 100), 200);
                    test.assert_eq(pool.tick(heap, qw, pw, 299), 0);
                    test.assert_eq(pool.tick(heap, qw, pw, 300), 2);
                }
            }
            poller_close(poller);
        }
        Polling::Failed(e) => {
            test.assert(false);
        }
    }
    pool.close(heap, pl);
    return 0;
}

// The script a `pgen` module writes is the statements of its `prepare_all`, as Parse and Sync pairs in order.
fn test_the_generated_script_is_one_parse_and_sync_for_each_statement[&h](heap: &!h Heap) -> [heap] int {
    let (script, count) = queries.prepare_script(heap);
    test.assert_eq(count, 11);
    var parses = 0;
    var syncs = 0;
    var first_name_ok = false;
    borrow script as &sr in {
        let m = buffer.bytes(sr);
        var at = 0;
        while pg.size(m, at) > 0 {
            if pg.kind(m, at) == 80 {
                parses = parses + 1;
                if parses == 1 {
                    first_name_ok = int_of(m[at + 5]) == 117 && int_of(m[at + 6]) == 115 && int_of(m[at + 14]) == 100 && int_of(m[at + 15]) == 0;
                }
            }
            if pg.kind(m, at) == 83 {
                syncs = syncs + 1;
            }
            at = at + pg.size(m, at);
        }
        test.assert_eq(at, len(m));
    }
    buffer.drop(heap, script);
    test.assert_eq(parses, 11);
    test.assert_eq(syncs, 11);
    test.assert(first_name_ok);
    return 0;
}

// ------------------------------------------------------------------ TLS (docs/tls.md section 7)

// A root certificate (ECDSA P-256, self-signed, ten years), only to be loaded: nothing it signed exists.
fn a_root() -> [] &static [byte] {
    return "-----BEGIN CERTIFICATE-----\nMIIBrDCCAVGgAwIBAgIUJLX7ifKpy03Pcn1QELLrc6slLZQwCgYIKoZIzj0EAwIw\nIzEhMB8GA1UEAwwYbGV4c3lzLXBnIHVuaXQgdGVzdCByb290MB4XDTI2MTAwNjIy\nMzAyM1oXDTM2MTAwMzIyMzAyM1owIzEhMB8GA1UEAwwYbGV4c3lzLXBnIHVuaXQg\ndGVzdCByb290MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEuXKaaSBDdlHRIMY6\nOaNhTiJ05H3a9p5e/xaMeqCW/hnErZ5CcxUU/5U7PpZ1Vz55QcIpySHdRyJP0CTy\n4ml9naNjMGEwHQYDVR0OBBYEFFzf3z+eZ4HUX1lVTS1ZU/jLFzALMB8GA1UdIwQY\nMBaAFFzf3z+eZ4HUX1lVTS1ZU/jLFzALMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0P\nAQH/BAQDAgIEMAoGCCqGSM49BAMCA0kAMEYCIQCAU/9Eu5y3DOU6KtvUyCMsD2GM\n49BcNbaWTa0z3GACjgIhAMlBYUSv9R5cjv8szlDoCLAYE/ONj/W4U06RHU2oCj/Q\n-----END CERTIFICATE-----\n";
}

fn entropy() -> [] &static [byte] {
    return "0123456789abcdef0123456789abcdef";
}

fn test_a_tls_failure_of_a_live_connection_is_lost() -> [] int {
    test.assert(pool.lost(15));
    // an attempt's TLS failures are not a request's status
    test.assert(!pool.lost(14));
    test.assert(!pool.lost(16));
    return 0;
}

fn test_secure_refuses_what_cannot_be_used[&h](heap: &!h Heap) -> [heap] int {
    var pl = pool.empty(heap, 2, 4, 4096, 4096);
    var rc = 0;
    let (p1, r1) = pool.secure(heap, pl, "", entropy(), a_root(), 1000000, 0);
    pl = p1;
    test.assert_eq(r1, 0 - 1);
    let (p2, r2) = pool.secure(heap, pl, "db", entropy()[0..31], a_root(), 1000000, 0);
    pl = p2;
    test.assert_eq(r2, 0 - 1);
    // a name of 256 bytes (the most is 255)
    let (p3, r3) = pool.secure(heap, pl, "nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn", entropy(), a_root(), 1000000, 0);
    pl = p3;
    test.assert_eq(r3, 0 - 1);
    // nothing in the bundle to trust: not made secure
    let (p4, r4) = pool.secure(heap, pl, "db", entropy(), "not a certificate", 1000000, 0);
    pl = p4;
    test.assert_eq(r4, 0);
    borrow pl as &qr in {
        test.assert(!pool.secured(qr));
    }
    let (p5, r5) = pool.secure(heap, pl, "db", entropy(), a_root(), 1000000, 0);
    pl = p5;
    test.assert_eq(r5, 1);
    borrow pl as &qr in {
        test.assert(pool.secured(qr));
        test.assert_eq(pool.tls_failure(qr), 0);
    }
    // once
    let (p6, r6) = pool.secure(heap, pl, "db", entropy(), a_root(), 1000000, 0);
    pl = p6;
    test.assert_eq(r6, 0 - 1);
    borrow mut pl as &!qw in {
        test.assert_eq(pool.wall(qw, 2000000, 10), 0);
    }
    pool.close(heap, pl);
    return 0;
}

fn test_secure_comes_before_start[&h](heap: &!h Heap) -> [heap, poll] int {
    var pl = pool.empty(heap, 1, 4, 4096, 4096);
    match poller_new() {
        Polling::Ok(po) => {
            var poller = po;
            borrow mut poller as &!pw in {
                borrow mut pl as &!qw in {
                    pool.start(qw, pw, 10);
                }
            }
            let (made, rc) = pool.secure(heap, pl, "db", entropy(), a_root(), 1000000, 0);
            pl = made;
            test.assert_eq(rc, 0 - 1);
            poller_close(poller);
        }
        Polling::Failed(e) => {
            test.assert(false);
        }
    }
    pool.close(heap, pl);
    return 0;
}

// A secure pool and `reconnect`, in either order, and nothing is due until `start`.
fn test_a_secure_pool_reconnects_like_any_other[&h](heap: &!h Heap) -> [heap, conn_write, poll] int {
    var pl = pool.empty(heap, 2, 4, 4096, 4096);
    let (p1, r1) = pool.reconnect(heap, pl, "u", "p", "d", "0123456789abcdef", "", 0, 100, 400, 1000, 0);
    pl = p1;
    test.assert_eq(r1, 0);
    let (p2, r2) = pool.secure(heap, pl, "db", entropy(), a_root(), 1000000, 0);
    pl = p2;
    test.assert_eq(r2, 1);
    match poller_new() {
        Polling::Ok(po) => {
            var poller = po;
            borrow mut poller as &!pw in {
                borrow mut pl as &!qw in {
                    test.assert_eq(pool.tick(heap, qw, pw, 0), 0);
                    pool.start(qw, pw, 10);
                    test.assert_eq(pool.tick(heap, qw, pw, 0), 2);
                }
            }
            poller_close(poller);
        }
        Polling::Failed(e) => {
            test.assert(false);
        }
    }
    pool.close(heap, pl);
    return 0;
}
