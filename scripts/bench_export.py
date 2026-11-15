#!/usr/bin/env python3
"""pg-export (cancho-pg) against the stock psql, on the same rows from the same server: wall time and peak memory.

    PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGDATABASE=bench python3 scripts/bench_export.py [rows ...]
    BIN=build/pg-export   RUNS=5   (the default)

The table is made here (`bench`, rows 1..N, six columns of five types) and dropped at the end. Three ways to get the
rows out, each written to a file (not /dev/null, so every writer pays for the write):
  psql --csv          the stock client, CSV
  psql row_to_json    the stock client, `select row_to_json(t) from (query) t` with -At: JSON lines made by the server
  pg-export           this repository's tool, JSON lines made by the client
Both psql runs and pg-export hold the whole result before writing (psql without FETCH_COUNT does too).
For each: the median and the minimum of RUNS wall times, the peak resident memory of the process (wait4's ru_maxrss),
and the size of the output. The server and the client are on one machine, over TCP on the loopback.
"""
import os
import platform
import statistics
import subprocess
import sys
import time

HOST = os.environ.get("PGHOST", "127.0.0.1")
PORT = os.environ.get("PGPORT", "5432")
USER = os.environ.get("PGUSER", "postgres")
DB = os.environ.get("PGDATABASE", "postgres")
BIN = os.environ.get("BIN", os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "build", "pg-export"))
RUNS = int(os.environ.get("RUNS", "5"))
OUT = os.environ.get("OUT", "/var/tmp/bench_export.out")
QUERY = "select id, customer, status, amount, placed, note from bench order by id"


def psql(args):
    return ["psql", "-h", HOST, "-p", PORT, "-U", USER, "-d", DB, "-X", "-q"] + args


def run(argv):
    with open(OUT, "wb") as f:
        t0 = time.perf_counter()
        p = subprocess.Popen(argv, stdout=f, stderr=subprocess.PIPE)
        _, status, ru = os.wait4(p.pid, 0)
        wall = time.perf_counter() - t0
    err = p.stderr.read()
    p.stderr.close()
    assert status == 0, (argv[:1], err)
    return wall, ru.ru_maxrss / 1024.0, os.path.getsize(OUT)


COMMANDS = {
    "psql --csv": lambda: psql(["--csv", "-c", QUERY]),
    "psql row_to_json": lambda: psql(["-At", "-c", f"select row_to_json(t) from ({QUERY}) t"]),
    "pg-export": lambda: [BIN, HOST, PORT, USER, DB, "-", QUERY, "100000000", "1073741824"],
}


def main():
    sizes = [int(a) for a in sys.argv[1:]] or [100000, 1000000]
    print(f"{platform.platform()}, {os.cpu_count()} cpus; server and client on one machine, loopback TCP; {RUNS} runs each, output to a file")
    for n in sizes:
        subprocess.run(psql(["-c", "drop table if exists bench"]), check=True)
        subprocess.run(psql(["-c", "create table bench (id int primary key, customer text not null, status int not null, amount numeric(12,2), "
                                   "placed date not null, note text)"]), check=True)
        subprocess.run(psql(["-c", f"insert into bench select g, 'customer ' || (g % 1000), 200 + (g % 5) * 100, "
                                   f"case when g % 17 = 0 then null else (g % 100000) / 100.0 end, date '2026-01-01' + (g % 300), "
                                   f"'note number ' || g || ' with, a comma and a \"quote\"' from generate_series(1, {n}) g"]), check=True)
        subprocess.run(psql(["-c", "analyze bench"]), check=True)
        print(f"\n{n:,} rows")
        print(f"{'':20}{'median s':>10}{'min s':>9}{'peak MB':>9}{'output MB':>11}")
        for name, argv in COMMANDS.items():
            run(argv())  # a warm-up run, not counted
            walls, rss, size = [], [], 0
            for _ in range(RUNS):
                w, r, size = run(argv())
                walls.append(w)
                rss.append(r)
            print(f"{name:20}{statistics.median(walls):10.3f}{min(walls):9.3f}{max(rss):9.1f}{size / 1e6:11.1f}")
    subprocess.run(psql(["-c", "drop table if exists bench"]), check=True)
    os.path.exists(OUT) and os.remove(OUT)


main()
