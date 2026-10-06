#!/usr/bin/env python3
"""What TLS costs (docs/tls.md section 11): the tables of that section, printed.

    eval "$(sh tests/postgres.sh)"; python3 tests/tls_measure.py [connections] [runs]      (default 200 and 7)
    LEX_SYS=/path/to/lex-sys   (build/deps filled by `lex-sys install`)

1. Opening a connection: tests/tls_cost.ls opens `connections` connections one after the other (dial, `ssl.open`, `ssl.login`
   with trust, `select 1`, Terminate, close) with `disable` and with `verify-full`, `runs` times each, alternating. Per
   connection: the wall time (the program's own clock over the whole batch) and the client's CPU (user + system, from the
   kernel's account of the child, `getrusage`). Medians, with the least and the most.
2. Memory: tests/tls_drive.ls holding `lanes` idle connections, plain and secure, its resident set (VmRSS) once they are live
   (Linux only: /proc).
3. The loop: the longest turn of tests/tls_drive.ls while 8 TLS connections are made at once and then carry requests.

The server's own CPU is not here (it is in another process, often another machine); section 11 says how it was read.
"""
import os
import resource
import statistics
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOST = os.environ.get("PGHOST", "127.0.0.1")
PORT = os.environ.get("PGPORT", "5432")
USER = os.environ.get("PGUSER", "postgres")
DB = os.environ.get("PGDATABASE", "postgres")
LEX = os.environ.get("LEX_SYS", "lex-sys")
CA = os.environ.get("PG_TLS_CA", os.path.join(ROOT, "build", "tls", "ca.crt"))


def deps():
    d = os.path.join(ROOT, "build", "deps")
    return sorted(os.path.join(d, f) for f in os.listdir(d) if f.endswith(".ls"))


def build(main, *srcs, out):
    subprocess.run([LEX, "build", "--std", os.path.join(ROOT, main), *[os.path.join(ROOT, s) for s in srcs], *deps(), "-o", out],
                   check=True)
    return out


def batch(cost, mode, n):
    """(wall ms per connection, CPU ms per connection) of one batch of `n` connections."""
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    p = subprocess.run([cost, mode, CA if mode != "disable" else "-", "localhost", HOST, PORT, USER, DB, "-", str(n)],
                       capture_output=True, text=True, timeout=600)
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    line = p.stderr.strip().splitlines()[-1].split()
    f = {line[i]: int(line[i + 1]) for i in range(1, len(line) - 1, 2)}
    assert p.returncode == 0 and f["failed"] == 0, p.stderr
    cpu = (after.ru_utime - before.ru_utime + after.ru_stime - before.ru_stime) * 1000
    return f["total_ms"] / n, cpu / n, f["open_ms"] / n


def spread(xs):
    return "%.2f (%.2f to %.2f)" % (statistics.median(xs), min(xs), max(xs))


def rss_kib(pid):
    try:
        for line in open("/proc/%d/status" % pid):
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    except OSError:
        return None


def hold(drive, lanes, secure):
    """VmRSS (KiB) of a driver holding `lanes` live idle connections, and with none (a pool that is never started)."""
    p = subprocess.Popen([drive, HOST, PORT, USER, DB, "-", str(lanes), "4", "idle", "100", "400", "5000", "0", "20",
                          "localhost" if secure else "-", CA if secure else "-", "65536"], stderr=subprocess.PIPE, text=True)
    rss = None
    for line in p.stderr:
        if line.startswith("ev ") and (" live %d " % lanes) in line:
            time.sleep(0.5)
            rss = rss_kib(p.pid)
            break
    p.kill()
    p.wait()
    return rss


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 200
    runs = int(sys.argv[2]) if len(sys.argv) > 2 else 7
    os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
    cost = build("tests/tls_cost.ls", "src/ssl.ls", "src/pg.ls", out=os.path.join(ROOT, "build", "tls_cost"))
    drive = build("tests/tls_drive.ls", "src/pool.ls", "src/pg.ls", out=os.path.join(ROOT, "build", "tls_drive"))
    batch(cost, "disable", 20)
    batch(cost, "verify-full", 20)
    res = {"disable": [], "verify-full": []}
    for _ in range(runs):
        for mode in ("disable", "verify-full"):
            res[mode].append(batch(cost, mode, n))
    print("1. Opening a connection (%d connections a batch, %d batches each; dial, open, login, select 1, close), per connection:" % (n, runs))
    print("| mode | wall ms | client CPU ms | of which ssl.open, ms |")
    print("|---|---:|---:|---:|")
    for mode in ("disable", "verify-full"):
        w = [x[0] for x in res[mode]]
        c = [x[1] for x in res[mode]]
        o = [x[2] for x in res[mode]]
        print("| %s | %s | %s | %s |" % (mode, spread(w), spread(c), spread(o)))
    dw = statistics.median(x[0] for x in res["verify-full"]) - statistics.median(x[0] for x in res["disable"])
    dc = statistics.median(x[1] for x in res["verify-full"]) - statistics.median(x[1] for x in res["disable"])
    print("TLS adds %.2f ms of wall time and %.2f ms of client CPU to opening a connection (medians)." % (dw, dc))
    if os.path.isdir("/proc/self"):
        print()
        print("2. Resident memory of the pool driver, idle connections live:")
        print("| lanes | plain KiB | TLS KiB | TLS - plain, per lane |")
        print("|---:|---:|---:|---:|")
        for lanes in (1, 8, 32):
            a = statistics.median(hold(drive, lanes, False) for _ in range(3))
            b = statistics.median(hold(drive, lanes, True) for _ in range(3))
            print("| %d | %d | %d | %.0f |" % (lanes, a, b, (b - a) / lanes))
    print()
    print("3. The loop while 8 TLS connections are made at once and carry a request a millisecond for 3 s:")
    busy = []
    for _ in range(5):
        p = subprocess.run([drive, HOST, PORT, USER, DB, "-", "8", "3", "dbl", "100", "400", "5000", "0", "1", "localhost", CA,
                            "65536"], capture_output=True, text=True, timeout=60)
        fin = [l for l in p.stderr.splitlines() if l.startswith("finished")][-1].split()
        f = {fin[i]: fin[i + 1] for i in range(2, len(fin) - 1, 2)}
        ready = [l for l in p.stderr.splitlines() if l.startswith("ev ") and " live 8 " in l][0].split()[1]
        busy.append((int(f["maxbusy"]), int(f["busy1"]), int(f["busy2"]), int(f["busy5"]), int(f["turns"]), int(f["ok"]), int(ready)))
    print("| run | all 8 live at (ms) | maxbusy ms | turns of 1, 2, 5 ms or more | turns | answers |")
    print("|---:|---:|---:|---|---:|---:|")
    for i, b in enumerate(busy):
        print("| %d | %d | %d | %d, %d, %d | %d | %d |" % (i + 1, b[6], b[0], b[1], b[2], b[3], b[4], b[5]))


if __name__ == "__main__":
    main()
