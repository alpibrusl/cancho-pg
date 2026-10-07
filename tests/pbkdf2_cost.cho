edition 5;

import std.io;
import std.buffer;
import pg;

// What one turn's share of a SCRAM login costs: `pbkdf2_more` of 128 iterations, 2,000 times, timed with the clock; and the whole
// 4,096-iteration derivation `pg.pbkdf2_sha256` does in one go, 200 times. Prints microseconds per piece and per whole
// derivation (for `docs/reconnect.md`; not a test).

fn timed[&h, &k](heap: &!h Heap, clock: &k Clock) -> [heap, clock] int {
    let state = box_slice(heap, 64, byte_of(0));
    let started = clock_ms(clock);
    var i = 0;
    borrow mut state as &!sw in {
        pg.pbkdf2_begin(heap, "pencil", "saltsaltsalt", contents(sw));
        while i < 2000 {
            pg.pbkdf2_more(heap, "pencil", contents(sw), 128);
            i = i + 1;
        }
    }
    unbox_slice(heap, state);
    return clock_ms(clock) - started;
}

fn whole[&h, &k](heap: &!h Heap, clock: &k Clock) -> [heap, clock] int {
    let started = clock_ms(clock);
    var i = 0;
    while i < 200 {
        let key = pg.pbkdf2_sha256(heap, "pencil", "saltsaltsalt", 4096);
        buffer.drop(heap, key);
        i = i + 1;
    }
    return clock_ms(clock) - started;
}

fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock } = split(world);
    release(ffi);
    release(fs);
    release(net);
    release(args);
    borrow mut heap as &!h in {
        borrow clock as &k in {
            borrow mut io as &!i in {
                let pieces = timed(h, k);
                io.write_all(i, "2000 pieces of 128 iterations: ");
                io.print_nat(i, pieces);
                io.write_all(i, " ms, ");
                io.print_nat(i, pieces * 1000 / 2000);
                io.write_all(i, " us a piece\n");
                let all = whole(h, k);
                io.write_all(i, "200 derivations of 4096 iterations in one go: ");
                io.print_nat(i, all);
                io.write_all(i, " ms, ");
                io.print_nat(i, all * 1000 / 200);
                io.write_all(i, " us each\n");
            }
        }
    }
    release(clock);
    release(io);
    release(heap);
    return 0;
}
