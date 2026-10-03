#!/usr/bin/env python3
"""P0 of docs/pooler.md: the transparent proxy against PgBouncer (session mode), through the same PostgreSQL.

    python3 pooler/bench/p0.py [path/to/proxy] [rounds]

Needs a PostgreSQL on 127.0.0.1:5432 with a database `bench` (`pgbench -i -s 10 bench`), trust authentication for `postgres`, pgbouncer and pgbench on PATH.
Pooler on core 0, PostgreSQL on cores 1-2 (the postmaster is pinned, so backends inherit it), the load generator on core 3.
For each cell, `rounds` rounds, each one run through the proxy then one through PgBouncer then one direct; medians. Reported per cell: throughput, and the
pooler's own CPU (utime + stime from /proc) per transaction or per megabyte, which is what shows its overhead when PostgreSQL is the bottleneck.
"""
import os, re, subprocess, sys, tempfile, time, statistics

PROXY = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "..", "build", "proxy")
ROUNDS = int(sys.argv[2]) if len(sys.argv) > 2 else 5
TICK = os.sysconf("SC_CLK_TCK")
PG = ("127.0.0.1", 5432)
PORTS = {"direct": 5432, "proxy": 6433, "pgbouncer": 6434}
PGB_DIR = tempfile.mkdtemp(prefix="pgb")
os.chmod(PGB_DIR, 0o777)


def cpu(pid):
    f = open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()
    return (int(f[11]) + int(f[12])) / TICK  # utime, stime


def core_busy():
    r = {}
    for l in open("/proc/stat"):
        if l.startswith("cpu") and l[3].isdigit():
            v = list(map(int, l.split()[1:]))
            r[int(l.split()[0][3:])] = (sum(v), v[3] + v[4])
    return r


def pg_busy(a, b):
    """Percent of the time cores 1 and 2 (PostgreSQL's) were busy between two core_busy() snapshots."""
    return sum(100 * (1 - (b[c][1] - a[c][1]) / (b[c][0] - a[c][0])) for c in (1, 2)) / 2


def start_pooler(name):
    if name == "proxy":
        p = subprocess.Popen(["taskset", "-c", "0", PROXY, str(PORTS["proxy"]), PG[0], str(PG[1])], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        open(f"{PGB_DIR}/userlist.txt", "w").write('"postgres" ""\n')
        open(f"{PGB_DIR}/pgbouncer.ini", "w").write(f"""[databases]
* = host={PG[0]} port={PG[1]}
[pgbouncer]
listen_addr = 127.0.0.1
listen_port = {PORTS['pgbouncer']}
auth_type = trust
auth_file = {PGB_DIR}/userlist.txt
pool_mode = session
max_client_conn = 1000
default_pool_size = 200
server_tls_sslmode = disable
ignore_startup_parameters = extra_float_digits
logfile = {PGB_DIR}/log
""")
        for f in ("userlist.txt", "pgbouncer.ini"):
            os.chmod(f"{PGB_DIR}/{f}", 0o644)
        p = subprocess.Popen(["taskset", "-c", "0", "su", "postgres", "-c", f"pgbouncer {PGB_DIR}/pgbouncer.ini"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        r = subprocess.run(["psql", "-h", "127.0.0.1", "-p", str(PORTS[name]), "-U", "postgres", "-d", "bench", "-Atc", "select 1"], capture_output=True)
        if r.returncode == 0:
            break
        time.sleep(0.1)
    else:
        raise SystemExit(f"{name} did not come up")
    pid = int(subprocess.check_output(["pgrep", "-n", "-x", "proxy" if name == "proxy" else "pgbouncer"]).split()[0])
    return p, pid


def pgbench(port, clients, extra, secs=8):
    a = core_busy()
    out = subprocess.run(["taskset", "-c", "3", "pgbench", "-h", "127.0.0.1", "-p", str(port), "-U", "postgres", "-S", "-c", str(clients), "-j", "1", "-T", str(secs)] + extra + ["bench"], capture_output=True, text=True).stdout
    busy = pg_busy(a, core_busy())
    tps = float(re.search(r"tps = ([0-9.]+)", out).group(1))
    tx = int(re.search(r"transactions actually processed: (\d+)", out).group(1))
    lat = float(re.search(r"latency average = ([0-9.]+) ms", out).group(1))
    return tps, tx, busy, lat


def stream(port):
    t = time.time()
    subprocess.run(["taskset", "-c", "3", "psql", "-h", "127.0.0.1", "-p", str(port), "-U", "postgres", "-d", "bench", "-At", "-c", "select repeat('x',1000) from generate_series(1,200000)"], stdout=subprocess.DEVNULL, check=True)
    return time.time() - t, 200000 * 1001 / 1e6


# PostgreSQL's postmaster on cores 1-2: the backends it forks inherit it.
pm = int(subprocess.check_output(["pgrep", "-o", "-x", "postgres"]).split()[0])
subprocess.run(["taskset", "-a", "-p", "-c", "1,2", str(pm)], stdout=subprocess.DEVNULL, check=True)

servers = {n: start_pooler(n) for n in ("proxy", "pgbouncer")}
try:
    cells = [("-S c=1 simple", 1, ["-M", "simple"]), ("-S c=10 simple", 10, ["-M", "simple"]), ("-S c=50 simple", 50, ["-M", "simple"]), ("-S c=10 extended", 10, ["-M", "extended"]),
             ("-S c=10 R=10000", 10, ["-M", "simple", "-R", "10000"]), ("-S c=10 R=20000", 10, ["-M", "simple", "-R", "20000"])]
    for label, clients, extra in cells:
        res = {n: [] for n in PORTS}
        for _ in range(ROUNDS):
            for n in ("proxy", "pgbouncer", "direct"):
                before = cpu(servers[n][1]) if n in servers else 0
                tps, tx, busy, lat = pgbench(PORTS[n], clients, extra)
                used = (cpu(servers[n][1]) - before) if n in servers else 0
                res[n].append((tps, used / tx * 1e6 if tx else 0, busy, lat))
        med = {n: tuple(statistics.median(r[i] for r in v) for i in range(4)) for n, v in res.items()}
        bound = min(med[n][2] for n in med) >= 90  # PostgreSQL's two cores at 90% or more under every target
        ratio = "no ratio: PostgreSQL-bound" if bound else f"proxy/pgbouncer {med['proxy'][0] / med['pgbouncer'][0]:.2f}"
        print(f"{label:18} tps: direct {med['direct'][0]:8.0f}  proxy {med['proxy'][0]:8.0f}  pgbouncer {med['pgbouncer'][0]:8.0f}  {ratio} | PostgreSQL cores busy % {med['direct'][2]:.0f}/{med['proxy'][2]:.0f}/{med['pgbouncer'][2]:.0f}"
              f" | latency ms {med['direct'][3]:.3f}/{med['proxy'][3]:.3f}/{med['pgbouncer'][3]:.3f} | pooler CPU us/txn: proxy {med['proxy'][1]:5.1f}  pgbouncer {med['pgbouncer'][1]:5.1f}  ratio {med['proxy'][1] / med['pgbouncer'][1]:.2f}")
        print("   runs (tps): " + "  ".join(f"{n}: " + " ".join(f"{x[0]:.0f}" for x in v) for n, v in res.items()))
        print("   runs (latency ms): " + "  ".join(f"{n}: " + " ".join(f"{x[3]:.2f}" for x in v) for n, v in res.items()))
    res = {n: [] for n in PORTS}
    for _ in range(ROUNDS):
        for n in ("proxy", "pgbouncer", "direct"):
            before = cpu(servers[n][1]) if n in servers else 0
            secs, mb = stream(PORTS[n])
            res[n].append((secs, (cpu(servers[n][1]) - before) / mb * 1000 if n in servers else 0))
    print("   runs (seconds): " + "  ".join(f"{n}: " + " ".join(f"{x[0]:.2f}" for x in v) for n, v in res.items()))
    med = {n: (statistics.median(r[0] for r in v), statistics.median(r[1] for r in v)) for n, v in res.items()}
    print(f"{'200 MB result':18} seconds: direct {med['direct'][0]:.2f}  proxy {med['proxy'][0]:.2f}  pgbouncer {med['pgbouncer'][0]:.2f} | pooler CPU ms/MB: proxy {med['proxy'][1]:.2f}  pgbouncer {med['pgbouncer'][1]:.2f}  ratio {med['proxy'][1] / med['pgbouncer'][1]:.2f}")
finally:
    for n, (p, pid) in servers.items():
        subprocess.run(["kill", str(pid)])
