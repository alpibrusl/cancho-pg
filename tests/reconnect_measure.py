#!/usr/bin/env python3
"""The numbers of docs/reconnect.md: how long the loop is kept from waiting, how fast a pool is back, how the backoff behaves.

    python3 tests/reconnect_measure.py           (the server environment of tests/e2e.py; LEX_SYS; builds like reconnect_test.py)

Not a test: it prints what it measured, with the load of the machine, one table per question.
"""
import os
import statistics
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reconnect_test as T


def load():
    return open("/proc/loadavg").read().split()[0]


def run_stats(r):
    f = r.fin
    return "maxbusy %2d ms  busy>=1/2/5/10 ms: %d/%d/%d/%d turns of %d  maxgap %d ms" % (
        f["maxbusy"], f["busy1"], f["busy2"], f["busy5"], f["busy10"], f["turns"], f["maxgap"])


def latency_after_kill(user, db, password, kills, label):
    """Kill the one connection `kills` times, 1.2 s apart (a connection that lasted a second is retried at once)."""
    proxy = T.Proxy(T.HOST, T.PORT)
    before = T.backend_pids()
    run = T.Run(proxy.port, user=user, db=db, password=password, lanes=1, seconds=int(kills * 1.3 + 3), period=50, min_ms=100, max_ms=5000)
    run.wait_live(1)
    gaps = []
    for k in range(kills):
        time.sleep(1.2)
        v = T.victims(proxy, before)
        t_kill = run.now()
        T.terminate(v)
        run.wait(lambda x, k=k: x.startswith("ev ") and T.ev(x)["reconnects"] == k + 1 and T.ev(x)["live"] == 1, 10)
        gaps.append(run.now() - t_kill)
    r = run.result()
    proxy.close()
    ms = sorted(g * 1000 for g in gaps)
    print("| %s | %d | %.0f | %.0f | %.0f | %s |" % (label, kills, statistics.median(ms), ms[-1], ms[0], run_stats(r)))
    return r


def outage(seconds, phase, label):
    """The proxy down for `seconds`; a pool of 2 with waits 100 ms to 5 s; how long after the restore until both are back."""
    proxy = T.Proxy(T.HOST, T.PORT)
    run = T.Run(proxy.port, lanes=2, seconds=int(seconds + 8), period=50, min_ms=100, max_ms=5000, attempt_ms=5000)
    run.wait_live(2)
    time.sleep(0.5 + phase)
    proxy.cut()
    time.sleep(seconds)
    proxy.restore()
    t_back = run.now()
    up = run.wait_live(2, 20, after=t_back)
    took = up[0] - t_back if up else float("nan")
    r = run.result()
    proxy.close()
    print("| %s | %.1f | %.2f | %d | %d | %d | %s |" % (label, seconds, took, r.fin["attempts"], r.fin["failures"], r.fin["reconnects"], run_stats(r)))
    return took


def blackhole(seconds, label, lanes=2):
    proxy = T.Proxy(T.HOST, T.PORT)
    proxy.blackhole()
    run = T.Run(proxy.port, lanes=lanes, seconds=seconds + 2, period=50, min_ms=100, max_ms=5000, attempt_ms=1000)
    first = run.wait(lambda x: x.startswith("ev "), 5)
    time.sleep(seconds)
    proxy.restore()
    t_back = run.now()
    up = run.wait_live(lanes, 20, after=t_back)
    r = run.result()
    proxy.close()
    print("| %s | %.0f ms | %d | %d | %.2f | %s |" % (label, first[0] * 1000, r.fin["attempts"], r.fin["failures"], (up[0] - t_back) if up else float("nan"), run_stats(r)))


def main():
    T.build()
    print("load average at the start: %s\n" % load())
    print("### Back after a killed connection (loss to live again, ms)\n")
    print("| login | kills | median | max | min | the loop |\n|---|---:|---:|---:|---:|---|")
    latency_after_kill(T.USER, T.DB, "-", 10, "trust")
    if T.SCRAM[0]:
        latency_after_kill(*T.SCRAM, 10, "SCRAM-SHA-256")
    print("\n### Back after the server was away (waits 100 ms doubling to 5 s; pool of 2)\n")
    print("| run | away (s) | restore to both live (s) | attempts | failed | reconnects | the loop |\n|---|---:|---:|---:|---:|---:|---|")
    for i, (secs, phase) in enumerate([(1, 0.0), (1, 0.3), (3, 0.0), (3, 0.4), (6, 0.0), (6, 0.7), (12, 0.0)]):
        outage(secs, phase, "cut %d" % (i + 1))
    print("\n### Starting against a database that drops every packet (waits 100 ms to 5 s, attempts of 1 s; pool of 2)\n")
    print("| run | first line after | attempts | failed | restore to live (s) | the loop |\n|---|---:|---:|---:|---:|---|")
    blackhole(4, "black hole 4 s")
    blackhole(8, "black hole 8 s")
    print("\nload average at the end: %s" % load())


if __name__ == "__main__":
    main()
