edition 5;

import std.buffer;
import pg;
import pg.pool;

// A program that keeps a pool full while its network is narrowed to one host and port: `tests/reconnect_test.py` asks
// `lex-sys authority` about it and requires the network to be that one `host:port` and nothing wider (the pool does
// not dial, so it cannot ask for more). It does nothing useful when run.

fn dial_some[&h, &n, &p](heap: &!h Heap, pl: pool.Pool, net: &n Net("127.0.0.1:5432"), poller: &!p Poller, now: int) -> [heap, net_out("127.0.0.1:5432"), conn_write, poll] pool.Pool {
    var pool_now = pl;
    var want = 0;
    borrow mut pool_now as &!w in {
        want = pool.tick(heap, w, poller, now);
    }
    while want > 0 {
        match tcp_connect_start(net, "127.0.0.1", 5432) {
            Dialed::Ok(c) => {
                let (grown, lane) = pool.adopt(heap, pool_now, poller, now, c);
                pool_now = grown;
            }
            Dialed::Failed(e) => {
                borrow mut pool_now as &!w in {
                    pool.dial_failed(w, now, e);
                }
            }
        }
        want = want - 1;
    }
    return pool_now;
}

fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock } = split(world);
    release(ffi);
    release(fs);
    release(clock);
    let db = narrow(net, "127.0.0.1:5432");
    var status = 1;
    match poller_new() {
        Polling::Ok(po) => {
            var poller = po;
            borrow mut heap as &!h in {
                var pl = pool.empty(h, 1, 4, 4096, 4096);
                borrow db as &n in {
                    borrow mut poller as &!pw in {
                        pl = dial_some(h, pl, n, pw, 0);
                    }
                }
                status = 0;
                pool.close(h, pl);
            }
            poller_close(poller);
        }
        Polling::Failed(e) => {
            status = 2;
        }
    }
    release(db);
    release(args);
    release(io);
    release(heap);
    return status;
}
