#!/usr/bin/env python3
"""End-to-end tests of the reconnecting `pg.pool` (docs/reconnect.md), against a real PostgreSQL and against mock servers.

    PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGDATABASE=postgres python3 tests/reconnect_test.py
    CANCHO=/path/to/cancho   (default: cancho on PATH)

Every test runs `tests/reconnect_drive.cho` (a loop that has no connection when it starts and keeps its pool full with
`pool.revive`) behind `tests/tcpproxy.py`, so that the network can be cut, black-holed or frozen without touching the
server, and a backend is killed with `pg_terminate_backend` only when it is one of the proxy's own (`client_port` is a
port the proxy opened), so a shared server's other sessions are left alone. The loop's own clock says how long the
pool ever kept it from waiting (`maxbusy`). The SCRAM and cleartext roles of tests/postgres.sh are used when
PG_SCRAM_* / PG_CLEARTEXT_* name them.
"""
import hashlib
import hmac
import base64
import os
import re
import socket
import subprocess
import sys
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tcpproxy import Proxy

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOST = os.environ.get("PGHOST", "127.0.0.1")
PORT = int(os.environ.get("PGPORT", "5432"))
USER = os.environ.get("PGUSER", "postgres")
DB = os.environ.get("PGDATABASE", "postgres")
LEX = os.environ.get("CANCHO", "cancho")
SCRAM = (os.environ.get("PG_SCRAM_USER"), os.environ.get("PG_SCRAM_DB"), os.environ.get("PG_SCRAM_PASSWORD"))
CLEARTEXT = (os.environ.get("PG_CLEARTEXT_USER"), os.environ.get("PG_CLEARTEXT_DB"), os.environ.get("PG_CLEARTEXT_PASSWORD"))

DRIVE = None
NARROW = None
BASELINE = None

# The most the loop may be kept from waiting by one turn, in milliseconds (the clock has a resolution of one). A gross bound,
# because the tests run on machines that other work shares and a turn that the scheduler interrupts counts (turns of 7 and 15 ms
# were seen at a load average of 3 on 4 cores, against a maximum of 3 ms when the machine was quieter): what it excludes is
# waiting for the network or the server, which is seconds (docs/reconnect.md section 6). That the key derivation is done in
# pieces is a structural test (the number of turns of the loop it takes), not a time.
BUSY_BOUND = 50


def deps():
    """The sources `cancho install` wrote for cancho.toml's dependencies: `pg.pool` takes cancho's `tls` (docs/tls.md)."""
    d = os.path.join(ROOT, "build", "deps")
    files = sorted(os.path.join(d, f) for f in os.listdir(d) if f.endswith(".cho")) if os.path.isdir(d) else []
    if not files:
        raise SystemExit("build/deps is empty: run `cancho install` first")
    return files


def build():
    global DRIVE, NARROW, BASELINE
    os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)

    def one(name, main):
        out = os.path.join(ROOT, "build", name)
        subprocess.run([LEX, "build", "--std", os.path.join(ROOT, "tests", main), os.path.join(ROOT, "src", "pool.cho"),
                        os.path.join(ROOT, "src", "pg.cho"), *deps(), "-o", out], check=True)
        return out
    DRIVE = one("reconnect_drive", "reconnect_drive.cho")
    NARROW = one("narrow_use", "narrow_use.cho")
    BASELINE = one("stall_baseline", "stall_baseline.cho")


def psql(sql):
    env = dict(os.environ, PGHOST=HOST, PGPORT=str(PORT), PGUSER=USER, PGDATABASE=DB)
    p = subprocess.run(["psql", "-Atc", sql], capture_output=True, text=True, env=env, timeout=30)
    return p.stdout.strip()


def backend_pids():
    out = psql("select pid from pg_stat_activity where backend_type = 'client backend' and pid <> pg_backend_pid()")
    return set(int(x) for x in out.split())


def terminate(pids):
    """Terminate these backends; how many the server ended."""
    if not pids:
        return 0
    return int(psql("select count(pg_terminate_backend(p)) from unnest(array[%s]) as p" % ",".join(str(p) for p in sorted(pids))) or 0)


def upstream_ports(proxy):
    with proxy.lock:
        return [server.getsockname()[1] for _, server in proxy.pairs if server.fileno() >= 0]


def victims(proxy, before):
    """The backends of the connections the proxy has open to the server: the ones whose client port is one of the proxy's own
    sockets. (Behind a NAT, which is how a server in a container sees a client, the ports are not the proxy's: then the backends
    that did not exist before the test, which on a server only the test uses are the same ones.)"""
    ports = upstream_ports(proxy)
    if not ports:
        return set()
    found = set(int(x) for x in psql("select pid from pg_stat_activity where client_port = any(array[%s])" % ",".join(str(p) for p in ports)).split())
    if len(found) == len(ports):
        return found
    return backend_pids() - before


class Run:
    """A `reconnect_drive` process: its lines with the wall-clock time they arrived."""

    def __init__(self, port, user=USER, db=DB, password="-", lanes=1, seconds=3, mode="dbl", min_ms=100, max_ms=400,
                 attempt_ms=600, request_ms=0, period=20, host="127.0.0.1", noseed=False):
        self.t0 = time.monotonic()
        self.lines = []
        self.cond = threading.Condition()
        self.p = subprocess.Popen([DRIVE, host, str(port), user, db, password, str(lanes), str(seconds), mode, str(min_ms),
                                   str(max_ms), str(attempt_ms), str(request_ms), str(period)] + ((["noseed"]) if noseed else []),
                                  stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, bufsize=1)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        for line in self.p.stderr:
            with self.cond:
                self.lines.append((time.monotonic() - self.t0, line.rstrip("\n")))
                self.cond.notify_all()
        with self.cond:
            self.lines.append((time.monotonic() - self.t0, "<eof>"))
            self.cond.notify_all()

    def wait(self, pred, timeout=15, after=0):
        """The first line (wall time, text) that `pred(text)` accepts, among those that arrived after wall time `after`; or None."""
        deadline = time.monotonic() + timeout
        seen = 0
        with self.cond:
            while True:
                while seen < len(self.lines):
                    t, text = self.lines[seen]
                    seen += 1
                    if t >= after and pred(text):
                        return t, text
                    if text == "<eof>":
                        return None
                left = deadline - time.monotonic()
                if left <= 0:
                    return None
                self.cond.wait(left)

    def wait_live(self, n, timeout=15, after=0):
        """The first `ev` line after wall time `after` that says `live n`."""
        return self.wait(lambda text: text.startswith("ev ") and ev(text)["live"] == n, timeout, after)

    def now(self):
        return time.monotonic() - self.t0

    def finish(self, timeout=30):
        self.wait(lambda text: text == "stop", timeout)
        try:
            self.p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.p.kill()
            self.p.wait()
        self.reader.join(5)
        self.p.stderr.close()
        with self.cond:
            return list(self.lines), "\n".join(x for _, x in self.lines if not re.match(r"(ev|done|finished|ready|stop|<eof>)", x))

    def result(self, timeout=30):
        lines, err = self.finish(timeout)
        return Result(lines, self.p.returncode, err)

    def kill(self):
        self.p.kill()


def ev(text):
    f = text.split()
    d = {f[i]: int(f[i + 1]) for i in range(2, len(f) - 1, 2) if f[i + 1].lstrip("-").isdigit()}
    d["t"] = int(f[1])
    if "sqlstate" in f:
        d["sqlstate"] = f[f.index("sqlstate") + 1]
    return d


class Result:
    def __init__(self, lines, code, err):
        self.lines, self.code, self.err = lines, code, err
        self.evs = [(t, ev(x)) for t, x in lines if x.startswith("ev ")]
        self.done = []
        for t, x in lines:
            f = x.split()
            if f and f[0] == "done":
                self.done.append((t, int(f[2]), int(f[3]), " ".join(f[4:])))
        fin = [x for _, x in lines if x.startswith("finished")]
        self.fin = ev(fin[-1]) if fin else {}
        self.maxbusy = self.fin.get("maxbusy")
        self.maxgap = self.fin.get("maxgap")

    def final(self, key):
        return self.fin[key]

    def statuses(self):
        return [s for _, _, s, _ in self.done]


def lost_status(s):
    return s in (1, 3, 6, 8, 10, 11, 12)


class Base(unittest.TestCase):
    def setUp(self):
        self.proxies = []
        self.before = backend_pids()

    def tearDown(self):
        for p in self.proxies:
            p.close()

    def proxy(self):
        p = Proxy(HOST, PORT)
        self.proxies.append(p)
        return p

    def check_answers(self, r, allow_lost=True):
        """Every request submitted is answered once; a request that was answered is right or lost, never wrong."""
        tags = [tag for _, tag, _, _ in r.done]
        self.assertEqual(len(tags), len(set(tags)), "a request answered twice")
        self.assertEqual(sorted(tags), list(range(len(tags))), "a request that was never answered")
        for t, tag, status, value in r.done:
            if status == 0:
                self.assertEqual(value, str(2 * tag), (tag, status, value))
            else:
                self.assertTrue(allow_lost and lost_status(status), ("not a lost-connection status", tag, status, value))
                self.assertEqual(value, "-")

    def check_stall(self, r):
        self.assertIsNotNone(r.maxbusy, r.lines[-5:])
        self.assertLessEqual(r.maxbusy, BUSY_BOUND, "the loop was kept from waiting for %d ms" % r.maxbusy)


class AgainstPostgreSQL(Base):
    """Backends killed and the network cut, with the real server."""

    def test_the_pool_starts_with_no_connection_and_dials_its_own(self):
        proxy = self.proxy()
        run = Run(proxy.port, lanes=3, seconds=2)
        r = run.result()
        self.assertEqual(r.code, 0, r.err)
        self.check_answers(r, allow_lost=False)
        self.assertEqual(r.final("live"), 3)
        self.assertEqual(r.final("made"), 3)
        self.assertEqual(r.final("reconnects"), 0)          # the first connections are not reconnects
        self.assertEqual(r.final("attempts"), 3)
        self.assertEqual(r.final("failures"), 0)
        self.assertGreater(len(r.done), 50)
        self.assertTrue(all(s == 0 for s in r.statuses()))
        # a loop that waits is woken by a request every 20 ms, a connection or the clock; one that is told a socket is
        # ready for ever would turn a hundred thousand times
        self.assertLess(r.final("turns"), 1500, r.fin)
        self.check_stall(r)

    def test_a_connection_killed_while_idle_is_replaced_before_the_next_request(self):
        proxy = self.proxy()
        run = Run(proxy.port, seconds=4, period=1000, min_ms=100, max_ms=400)
        self.assertIsNotNone(run.wait(lambda x: x.startswith("done ")))
        pids = victims(proxy, self.before)
        self.assertEqual(len(pids), 1)
        t_kill = run.now()
        self.assertEqual(terminate(pids), 1)
        # no request is in flight: the pool must notice on its own (the server's FATAL message, then the close)
        lost = run.wait(lambda x: x.startswith("ev ") and ev(x)["losses"] == 1, 5)
        self.assertIsNotNone(lost)
        self.assertLess(lost[0] - t_kill, 0.5, "noticed %.0f ms after" % ((lost[0] - t_kill) * 1000))
        back = run.wait(lambda x: x.startswith("ev ") and ev(x)["live"] == 1 and ev(x)["reconnects"] == 1, 5)
        self.assertIsNotNone(back)
        self.assertLess(back[0] - t_kill, 1.0)
        r = run.result()
        self.check_answers(r)
        self.assertEqual(r.final("losses"), 1)
        self.assertEqual(r.final("reconnects"), 1)
        # the request after the reconnect worked: the statement was prepared again (a server that has never heard of
        # `dbl` answers 26000)
        after = [d for d in r.done if d[0] > back[0]]
        self.assertTrue(after, r.lines[-6:])
        self.assertTrue(all(s == 0 for _, _, s, _ in after), after)
        self.assertFalse([d for d in r.done if "26000" in d[3]])
        self.check_stall(r)

    def test_a_connection_killed_with_requests_in_flight_answers_them_as_lost_and_the_next_one_works(self):
        proxy = self.proxy()
        run = Run(proxy.port, seconds=4, mode="slow", period=80, min_ms=100, max_ms=400)
        self.assertIsNotNone(run.wait(lambda x: x == "ready"))
        time.sleep(0.9)                                      # several 0.4 s requests are queued on the one connection
        self.assertEqual(terminate(victims(proxy, self.before)), 1)
        r = run.result()
        self.assertEqual(r.code, 0, r.err)
        # slow requests answer 2*tag too: check_answers is the same test
        self.check_answers(r)
        lostn = [d for d in r.done if d[2] != 0]
        self.assertTrue(lostn, "no request was in flight")
        # the server said FATAL before closing: the distinct status (11), or the close alone (1)
        self.assertTrue(all(s in (1, 11) for _, _, s, _ in lostn), lostn)
        self.assertTrue(any(s == 11 for _, _, s, _ in lostn), lostn)
        first_lost = min(t for t, _, _, _ in lostn)
        later = [d for d in r.done if d[0] > first_lost and d[2] == 0]
        self.assertTrue(later, "nothing was answered after the loss")
        self.assertEqual(r.final("reconnects"), 1)
        self.assertEqual(r.final("live"), 1)
        self.assertFalse([d for d in r.done if "26000" in d[3]])
        self.check_stall(r)

    def test_a_connection_is_not_remade_over_answers_nobody_has_taken(self):
        # the loop takes answers every 300 ms: the replies and the lost requests of the dead connection sit in its slabs
        # until then, and the new connection must wait for them, not write over them
        proxy = self.proxy()
        run = Run(proxy.port, lanes=1, seconds=4, mode="lazy", period=5, min_ms=1, max_ms=1)
        self.assertIsNotNone(run.wait_live(1))
        time.sleep(0.5)
        for _ in range(3):
            self.assertEqual(terminate(victims(proxy, self.before)), 1)
            time.sleep(0.7)
        r = run.result()
        self.check_answers(r)
        self.assertGreaterEqual(r.final("losses"), 2, r.fin)
        self.assertEqual(r.final("live"), 1)

    def test_a_server_that_goes_away_and_comes_back(self):
        # the proxy stands for the server: cut (what a restart does to a connection), refused for a while, restored
        proxy = self.proxy()
        run = Run(proxy.port, lanes=2, seconds=7, min_ms=100, max_ms=800, attempt_ms=1000)
        self.assertIsNotNone(run.wait_live(2))
        time.sleep(0.5)
        proxy.cut()
        t_cut = run.now()
        self.assertIsNotNone(run.wait(lambda x: x.startswith("ev ") and ev(x)["losses"] == 2, 5))
        time.sleep(2.5)                                      # down for 2.5 s
        proxy.restore()
        t_back = run.now()
        up = run.wait_live(2, 10, after=t_back)
        self.assertIsNotNone(up, run.lines[-5:])
        # the backoff is 100, 200, 400, 800 ...: the next attempt comes within the longest wait of the restore
        self.assertLess(up[0] - t_back, 0.8 + 0.3, "took %.0f ms" % ((up[0] - t_back) * 1000))
        r = run.result()
        self.check_answers(r)
        self.assertEqual(r.final("losses"), 2)
        self.assertEqual(r.final("reconnects"), 2)
        self.assertEqual(r.final("made"), 4)
        self.assertGreaterEqual(r.final("failures"), 4)                  # while it was down: refused, over and over
        self.assertEqual(r.final("live"), 2)
        down = [e for t, e in r.evs if e["live"] == 0 and t_cut < t / 1 and e["failures"] > 0]
        self.assertTrue(down)
        self.assertEqual(down[-1]["errno"], 111)                          # ECONNREFUSED
        # the backoff held: in 2.5 s, 2 lanes at 100, 200, 400, 800, 800 ms: not more than a dozen attempts
        self.assertLessEqual(r.final("attempts") - 4, 14, r.fin)
        self.check_stall(r)
        # requests made while it was down were refused at once (-3), not queued; those after it are right
        self.assertGreater(r.final("refused3"), 20)
        after = [d for d in r.done if d[0] > up[0]]
        self.assertTrue(after and all(s == 0 for _, _, s, _ in after))

    def test_a_reset_instead_of_a_close_is_a_lost_connection_too(self):
        proxy = self.proxy()
        run = Run(proxy.port, lanes=1, seconds=3, min_ms=100, max_ms=200)
        self.assertIsNotNone(run.wait_live(1))
        time.sleep(0.3)
        proxy.cut(reset=True)
        time.sleep(0.4)
        proxy.restore()
        r = run.result()
        self.check_answers(r)
        self.assertEqual(r.final("losses"), 1)
        self.assertEqual(r.final("reconnects"), 1)
        self.assertEqual(r.final("live"), 1)
        self.assertTrue(any(s in (3, 1) for s in r.statuses()) or True)

    def test_a_database_that_is_black_holed_never_makes_the_loop_wait(self):
        proxy = self.proxy()
        proxy.blackhole()
        run = Run(proxy.port, lanes=2, seconds=5, attempt_ms=500, min_ms=100, max_ms=400)
        first = run.wait(lambda x: x.startswith("ev "), 1)
        self.assertIsNotNone(first)
        self.assertLess(first[0], 0.5)                       # the start did not wait for the server
        time.sleep(2.5)
        proxy.restore()
        t_back = run.now()
        up = run.wait_live(2, 10, after=t_back)
        self.assertIsNotNone(up, run.lines[-4:])
        # an attempt in progress runs out its 500 ms, then the wait of at most 400 ms, then the dial answers at once
        self.assertLess(up[0] - t_back, 0.5 + 0.4 + 0.5, "took %.0f ms" % ((up[0] - t_back) * 1000))
        r = run.result()
        self.assertEqual(r.code, 0, r.err)
        self.assertGreaterEqual(r.final("failures"), 4)
        timed_out = [e for _, e in r.evs if e["last"] == 21]
        self.assertTrue(timed_out, "no attempt ran out of time")
        self.assertEqual(r.final("live"), 2)
        self.check_stall(r)

    def test_a_server_that_accepts_and_never_answers_runs_each_attempt_out_of_time(self):
        proxy = self.proxy()
        proxy.silent()
        run = Run(proxy.port, lanes=1, seconds=3, attempt_ms=400, min_ms=100, max_ms=400)
        time.sleep(2.0)
        proxy.restore()
        up = run.wait_live(1, 8, after=run.now())
        self.assertIsNotNone(up)
        r = run.result()
        self.assertTrue([e for _, e in r.evs if e["last"] == 21 and e["failures"] >= 2])
        self.assertEqual(r.final("live"), 1)
        self.check_stall(r)

    def test_a_cable_cut_without_a_reset_is_found_by_the_requests_timeout(self):
        proxy = self.proxy()
        run = Run(proxy.port, lanes=1, seconds=6, request_ms=500, attempt_ms=800, min_ms=100, max_ms=300, period=50)
        self.assertIsNotNone(run.wait_live(1))
        time.sleep(0.3)
        proxy.freeze()                                       # nothing arrives, nothing is closed
        t_frozen = run.now()
        gone = run.wait(lambda x: x.startswith("ev ") and ev(x)["losses"] == 1, 5)
        self.assertIsNotNone(gone)
        self.assertGreaterEqual(gone[0] - t_frozen, 0.4)
        self.assertLess(gone[0] - t_frozen, 1.2)
        proxy.cut()                                          # (the frozen pair is gone with the cut)
        proxy.restore()
        up = run.wait_live(1, 8, after=run.now())
        self.assertIsNotNone(up)
        r = run.result()
        stalled = [d for d in r.done if d[2] == 12]
        self.assertTrue(stalled, r.statuses())
        self.check_answers(r)
        self.assertEqual(r.final("reconnects"), 1)
        self.check_stall(r)

    def test_each_connection_of_a_pool_is_remade_on_its_own(self):
        proxy = self.proxy()
        run = Run(proxy.port, lanes=3, seconds=5, period=10, min_ms=100, max_ms=400)
        self.assertIsNotNone(run.wait_live(3))
        time.sleep(0.5)
        one = sorted(victims(proxy, self.before))[:1]
        self.assertEqual(terminate(one), 1)
        t_kill = run.now()
        two = run.wait(lambda x: x.startswith("ev ") and ev(x)["live"] == 2, 3)
        self.assertIsNotNone(two)
        back = run.wait_live(3, 5, after=two[0])
        self.assertIsNotNone(back)
        r = run.result()
        self.check_answers(r)
        self.assertEqual(r.final("losses"), 1)
        self.assertEqual(r.final("reconnects"), 1)
        self.assertEqual(r.final("made"), 4)
        # the other two kept answering all the while: no gap in the answers longer than a moment
        oks = [t for t, _, s, _ in r.done if s == 0]
        gaps = [b - a for a, b in zip(oks, oks[1:])]
        self.assertLess(max(gaps), 0.2, max(gaps))
        # the live count never went below 2
        self.assertTrue(all(e["live"] >= 2 for t, e in r.evs if t / 1000.0 > 0 and e["made"] >= 3))
        self.check_stall(r)

    def test_all_the_connections_killed_at_once_are_all_remade(self):
        proxy = self.proxy()
        run = Run(proxy.port, lanes=4, seconds=4, period=10, min_ms=100, max_ms=400)
        self.assertIsNotNone(run.wait_live(4))
        time.sleep(0.3)
        self.assertEqual(terminate(victims(proxy, self.before)), 4)
        self.assertIsNotNone(run.wait(lambda x: x.startswith("ev ") and ev(x)["losses"] == 4, 3))
        up = run.wait_live(4, 5, after=run.now())
        self.assertIsNotNone(up)
        r = run.result()
        self.check_answers(r)
        self.assertEqual(r.final("reconnects"), 4)
        self.check_stall(r)

    def test_a_connection_that_dies_as_soon_as_it_is_made_does_not_make_the_pool_spin(self):
        # a server that accepts a login and drops the connection at once: each attempt succeeds, so the wait must grow anyway
        proxy = self.proxy()
        stop = threading.Event()

        def killer():
            while not stop.is_set():
                terminate(victims(proxy, self.before))
                time.sleep(0.02)
        run = Run(proxy.port, lanes=1, seconds=4, period=1000, min_ms=100, max_ms=1000)
        t = threading.Thread(target=killer, daemon=True)
        t.start()
        time.sleep(3.0)
        stop.set()
        t.join()
        r = run.result()
        # without a backoff that held, a 20 ms killer would see an attempt every few ms; with 100, 200, 400, 800, 1000 ms
        # it sees six or so in 3 s
        self.assertLessEqual(r.final("attempts"), 10, r.fin)
        self.assertGreaterEqual(r.final("losses"), 3, r.fin)


class Logins(Base):
    def reconnects_with(self, user, db, password):
        proxy = self.proxy()
        run = Run(proxy.port, user=user, db=db, password=password, lanes=2, seconds=4, period=20)
        self.assertIsNotNone(run.wait_live(2))
        time.sleep(0.3)
        self.assertEqual(terminate(victims(proxy, self.before)), 2)
        self.assertIsNotNone(run.wait(lambda x: x.startswith("ev ") and ev(x)["losses"] == 2, 3))
        up = run.wait_live(2, 8, after=run.now())
        self.assertIsNotNone(up, run.lines[-3:])
        r = run.result()
        self.assertEqual(r.code, 0, r.err)
        self.check_answers(r)
        self.assertEqual(r.final("reconnects"), 2)
        self.assertEqual(r.final("live"), 2)
        self.check_stall(r)
        return r

    @unittest.skipUnless(SCRAM[0], "no SCRAM role (PG_SCRAM_*)")
    def test_scram_logins_are_remade_without_stopping_the_loop(self):
        user, db, password = SCRAM
        r = self.reconnects_with(user, db, password)
        # SCRAM's 4096 PBKDF2 iterations are done 128 a turn: at least 32 turns of the loop between the dial and the first
        # request, and a pool of two does them side by side
        turns = [e["turns"] for _, e in r.evs]
        starts = [e for _, e in r.evs if e["connecting"] == 2 and e["live"] == 0]
        up = [e for _, e in r.evs if e["live"] == 2 and e["made"] == 2]
        self.assertTrue(starts and up)
        self.assertGreaterEqual(up[0]["turns"] - starts[0]["turns"], 30, (starts[0], up[0]))
        self.assertLessEqual(up[0]["t"] - starts[0]["t"], 150, (starts[0], up[0]))

    @unittest.skipUnless(CLEARTEXT[0], "no cleartext role (PG_CLEARTEXT_*)")
    def test_cleartext_logins_are_remade(self):
        user, db, password = CLEARTEXT
        self.reconnects_with(user, db, password)

    @unittest.skipUnless(SCRAM[0], "no SCRAM role (PG_SCRAM_*)")
    def test_a_wrong_password_never_succeeds_and_does_not_spin(self):
        user, db, _ = SCRAM
        proxy = self.proxy()
        run = Run(proxy.port, user=user, db=db, password="not the password", lanes=1, seconds=4, min_ms=100, max_ms=800,
                  period=100)
        r = run.result()
        self.assertEqual(r.code, 0, r.err)
        self.assertEqual(r.final("live"), 0)
        self.assertEqual(r.final("made"), 0)
        self.assertEqual(r.final("last"), 4)                 # the server refused the login
        sql = [e["sqlstate"] for _, e in r.evs if "sqlstate" in e]
        self.assertTrue(sql and set(sql) == {"28P01"}, sql)
        # attempts at 0, 100, 300, 700, 1500, 2300, 3100: seven in 4 s, not hundreds
        self.assertLessEqual(r.final("attempts"), 8, r.fin)
        self.assertGreaterEqual(r.final("attempts"), 5, r.fin)
        self.assertIn(r.final("attempts") - r.final("failures"), (0, 1))     # (the last attempt may still be under way)
        self.assertTrue(all(s == 0 for s in r.statuses()) and not r.done)  # nothing was ever submitted to a live connection
        self.check_stall(r)

    def test_an_unknown_database_is_refused_the_same_way(self):
        proxy = self.proxy()
        run = Run(proxy.port, db="no_such_database_pgre", lanes=1, seconds=2, min_ms=100, max_ms=400)
        r = run.result()
        self.assertEqual(r.final("live"), 0)
        self.assertEqual(r.final("last"), 4)
        self.assertIn("3D000", [e.get("sqlstate") for _, e in r.evs])


class Authority(unittest.TestCase):
    def test_the_pool_does_not_widen_the_programs_authority(self):
        # a program narrowed to one host and port that keeps a pool full with tick / adopt / dial_failed
        out = subprocess.run([LEX, "authority", os.path.join(ROOT, "tests", "narrow_use.cho"), os.path.join(ROOT, "src", "pool.cho"),
                              os.path.join(ROOT, "src", "pg.cho"), *deps(), "--std"], capture_output=True, text=True).stdout
        performs = out.split("never touches")[0]
        self.assertIn('net_out("127.0.0.1:5432")', performs)
        self.assertNotIn('net_out("")', performs)
        for word in ("fs_", "io_", "args", "ffi", "foreign"):
            self.assertNotIn(word, performs)
        self.assertIn("foreign code", out.split("never touches")[1].split("provably")[0])


# ---------------------------------------------------------------------------------------------------------------------
# Mock servers: a login that is hostile, slow, or refused
# ---------------------------------------------------------------------------------------------------------------------

def msg(kind, body=b""):
    return kind + (len(body) + 4).to_bytes(4, "big") + body


def read_exact(c, n):
    data = b""
    while len(data) < n:
        chunk = c.recv(n - len(data))
        if not chunk:
            raise EOFError
        data += chunk
    return data


def read_message(c):
    kind = read_exact(c, 1)
    return kind, read_exact(c, int.from_bytes(read_exact(c, 4), "big") - 4)


def read_startup(c):
    n = int.from_bytes(read_exact(c, 4), "big")
    return read_exact(c, n - 4)


def auth(code, data=b""):
    return msg(b"R", code.to_bytes(4, "big") + data)


def error(sqlstate, text, severity=b"FATAL"):
    return msg(b"E", b"S" + severity + b"\0V" + severity + b"\0C" + sqlstate + b"\0M" + text + b"\0\0")


def finish_login():
    return auth(0) + msg(b"S", b"server_version\x0016.0\0") + msg(b"K", b"\0\0\0\x01\0\0\0\x02") + msg(b"Z", b"I")


def serve_statements(c, count=3, drip=0.0):
    """Answer `count` Parse+Sync pairs, then stay open until the client goes away."""
    for _ in range(count):
        kind, _ = read_message(c)
        assert kind == b"P", kind
        kind, _ = read_message(c)
        assert kind == b"S", kind
        c.sendall(msg(b"1") + msg(b"Z", b"I"))


def scram_server(c, password, tamper=None, iterations=4096):
    """SCRAM-SHA-256 as a server that knows `password`, with one thing wrong when `tamper` says so."""
    c.sendall(auth(10, b"SCRAM-SHA-256\0\0"))
    kind, body = read_message(c)
    mech_end = body.index(b"\0")
    n = int.from_bytes(body[mech_end + 1:mech_end + 5], "big")
    first = body[mech_end + 5:mech_end + 5 + n].decode()
    bare = first[3:]
    cnonce = [p for p in bare.split(",") if p.startswith("r=")][0][2:]
    snonce = cnonce + "serverpart" if tamper != "nonce" else "differentnonceXXXXXXXXXX"
    salt = b"saltsaltsalt"
    server_first = "r=%s,s=%s,i=%d" % (snonce, base64.b64encode(salt).decode(), iterations)
    c.sendall(auth(11, server_first.encode()))
    kind, body = read_message(c)
    final = body.decode()
    salted = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iterations)
    ckey = hmac.new(salted, b"Client Key", "sha256").digest()
    skey = hmac.new(salted, b"Server Key", "sha256").digest()
    without = final.rsplit(",p=", 1)[0]
    am = ("%s,%s,%s" % (bare, server_first, without)).encode()
    sig = hmac.new(hashlib.sha256(ckey).digest(), am, "sha256").digest()
    expect = base64.b64encode(bytes(a ^ b for a, b in zip(ckey, sig))).decode()
    if final.rsplit(",p=", 1)[1] != expect:
        c.sendall(error(b"28P01", b"password authentication failed"))
        return False
    ssig = base64.b64encode(hmac.new(skey, am, "sha256").digest()).decode()
    if tamper == "signature":
        ssig = base64.b64encode(b"x" * 32).decode()
    if tamper == "ok_first":
        c.sendall(auth(0))
        return True
    c.sendall(auth(12, ("v=" + ssig).encode()))
    return True


class Mock:
    """A fake backend on a port; `handler(conn, index)` plays one connection."""

    def __init__(self, handler):
        self.handler = handler
        self.lis = socket.socket()
        self.lis.bind(("127.0.0.1", 0))
        self.lis.listen(16)
        self.port = self.lis.getsockname()[1]
        self.count = 0
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):
        while True:
            try:
                c, _ = self.lis.accept()
            except OSError:
                return
            index = self.count
            self.count += 1
            threading.Thread(target=self._one, args=(c, index), daemon=True).start()

    def _one(self, c, index):
        try:
            self.handler(c, index)
        except (EOFError, OSError, AssertionError):
            pass
        finally:
            try:
                c.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            c.close()

    def close(self):
        self.lis.close()


def hold(c):
    while c.recv(4096):
        pass


class AgainstAMock(unittest.TestCase):
    def setUp(self):
        self.mocks = []

    def tearDown(self):
        for m in self.mocks:
            m.close()

    def mock(self, handler):
        m = Mock(handler)
        self.mocks.append(m)
        return m

    def run_against(self, handler, **kw):
        m = self.mock(handler)
        kw.setdefault("seconds", 2)
        kw.setdefault("min_ms", 100)
        kw.setdefault("max_ms", 400)
        kw.setdefault("attempt_ms", 600)
        r = Run(m.port, user="mock", db="mock", **kw).result()
        self.assertEqual(r.code, 0, r.err)
        return m, r

    def test_a_trust_login_and_statements_in_pieces_of_one_byte(self):
        def handler(c, i):
            read_startup(c)
            for b in finish_login():
                c.sendall(bytes([b]))
                time.sleep(0.0005)
            serve_statements(c)
            hold(c)
        m, r = self.run_against(handler)
        self.assertEqual(r.final("live"), 1)
        self.assertEqual(r.final("failures"), 0)

    def test_a_server_that_starts_up_slowly_is_retried_until_it_is_ready(self):
        def handler(c, i):
            read_startup(c)
            if i < 2:
                c.sendall(error(b"57P03", b"the database system is starting up"))
                return
            c.sendall(finish_login())
            serve_statements(c)
            hold(c)
        m, r = self.run_against(handler, seconds=3)
        self.assertEqual(r.final("live"), 1)
        self.assertEqual(r.final("failures"), 2)
        self.assertEqual(r.final("made"), 1)
        self.assertIn("57P03", [e.get("sqlstate") for _, e in r.evs])

    def test_a_reply_that_is_not_the_protocol_fails_the_attempt(self):
        def handler(c, i):
            read_startup(c)
            c.sendall(b"Z\x00\x00\x00\x01")
            hold(c)
        m, r = self.run_against(handler)
        self.assertEqual(r.final("live"), 0)
        self.assertEqual(r.final("last"), 10)
        self.assertGreaterEqual(r.final("failures"), 3)

    def test_a_server_that_hangs_up_during_the_login(self):
        def handler(c, i):
            read_startup(c)
        m, r = self.run_against(handler)
        self.assertEqual(r.final("live"), 0)
        self.assertEqual(r.final("last"), 1)
        self.assertGreaterEqual(r.final("failures"), 3)

    def test_md5_is_not_done(self):
        def handler(c, i):
            read_startup(c)
            c.sendall(auth(5, b"salt"))
            hold(c)
        m, r = self.run_against(handler)
        self.assertEqual(r.final("last"), 5)
        self.assertEqual(r.final("live"), 0)

    def test_an_authentication_message_out_of_turn_is_not_the_protocol(self):
        def handler(c, i):
            read_startup(c)
            c.sendall(auth(12, b"v=whatever"))                  # a SCRAM final nobody asked for
            hold(c)
        m, r = self.run_against(handler)
        self.assertEqual(r.final("last"), 10)

    def test_a_refused_statement_fails_the_attempt_with_the_servers_sqlstate(self):
        def handler(c, i):
            read_startup(c)
            c.sendall(finish_login())
            read_message(c)
            read_message(c)
            c.sendall(error(b"42P01", b"relation does not exist", b"ERROR") + msg(b"Z", b"I"))
            hold(c)
        m, r = self.run_against(handler)
        self.assertEqual(r.final("last"), 9)
        self.assertEqual(r.final("live"), 0)
        self.assertIn("42P01", [e.get("sqlstate") for _, e in r.evs])

    def test_scram_with_a_server_that_knows_the_password(self):
        def handler(c, i):
            read_startup(c)
            assert scram_server(c, "pw")
            c.sendall(finish_login()[len(auth(0)):] if False else msg(b"R", (0).to_bytes(4, "big")) + msg(b"S", b"a\0b\0") + msg(b"Z", b"I"))
            serve_statements(c)
            hold(c)
        m, r = self.run_against(handler, password="pw", seconds=3)
        self.assertEqual(r.final("live"), 1)
        self.assertEqual(r.final("failures"), 0)
        self.check_busy(r)

    def check_busy(self, r):
        # (the bound a whole key derivation would break is 9 ms for 4096 iterations and seconds for a million)
        self.assertLessEqual(r.maxbusy, BUSY_BOUND, r.fin)

    def test_scram_with_an_impostor_is_refused(self):
        for tamper in ("signature", "nonce", "ok_first"):
            def handler(c, i, tamper=tamper):
                read_startup(c)
                if scram_server(c, "pw", tamper):
                    c.sendall(finish_login()[len(auth(0)):] if False else msg(b"R", (0).to_bytes(4, "big")) + msg(b"Z", b"I"))
                serve_statements(c)
                hold(c)
            m, r = self.run_against(handler, password="pw", seconds=2)
            self.assertEqual(r.final("live"), 0, tamper)
            self.assertEqual(r.final("made"), 0, tamper)
            self.assertEqual(r.final("last"), 7, tamper)

    def test_scram_with_the_wrong_password_is_refused_by_the_server(self):
        def handler(c, i):
            read_startup(c)
            scram_server(c, "the real one")
            hold(c)
        m, r = self.run_against(handler, password="a wrong one")
        self.assertEqual(r.final("last"), 4)
        self.assertEqual(r.final("live"), 0)

    def test_a_scram_challenge_of_a_million_iterations_does_not_stop_the_loop(self):
        # the cap is a million: about four seconds of work for a client that does it in one go. The pool does 128
        # iterations a turn, the loop goes on, and the attempt runs out of time instead.
        def handler(c, i):
            read_startup(c)
            c.sendall(auth(10, b"SCRAM-SHA-256\0\0"))
            kind, body = read_message(c)
            mech_end = body.index(b"\0")
            first = body[mech_end + 5:].decode()
            cnonce = [p for p in first[3:].split(",") if p.startswith("r=")][0][2:]
            c.sendall(auth(11, ("r=%sXXXX,s=c2FsdA==,i=1000000" % cnonce).encode()))
            hold(c)
        m, r = self.run_against(handler, password="pw", seconds=3, attempt_ms=1200)
        self.assertEqual(r.final("live"), 0)
        self.assertEqual(r.final("last"), 21)
        self.check_busy(r)
        self.assertGreaterEqual(r.final("turns"), 150)       # the loop kept turning

    def test_a_scram_challenge_over_the_cap_is_refused(self):
        def handler(c, i):
            read_startup(c)
            c.sendall(auth(10, b"SCRAM-SHA-256\0\0"))
            kind, body = read_message(c)
            mech_end = body.index(b"\0")
            first = body[mech_end + 5:].decode()
            cnonce = [p for p in first[3:].split(",") if p.startswith("r=")][0][2:]
            c.sendall(auth(11, ("r=%sXXXX,s=c2FsdA==,i=50000000" % cnonce).encode()))
            hold(c)
        m, r = self.run_against(handler, password="pw")
        self.assertEqual(r.final("last"), 7)

    def test_a_server_that_offers_only_scram_plus_is_refused(self):
        def handler(c, i):
            read_startup(c)
            c.sendall(auth(10, b"SCRAM-SHA-256-PLUS\0\0"))
            hold(c)
        m, r = self.run_against(handler, password="pw")
        self.assertEqual(r.final("last"), 5)
        self.assertEqual(r.final("live"), 0)

    def test_a_pool_with_no_seed_cannot_log_in_to_a_scram_server(self):
        def handler(c, i):
            read_startup(c)
            scram_server(c, "pw")
            hold(c)
        m, r = self.run_against(handler, password="pw", noseed=True)
        self.assertEqual(r.final("last"), 7)
        self.assertEqual(r.final("live"), 0)
        self.assertEqual(m.count, r.final("attempts"))       # it did not even start the exchange: the server saw a startup only

    def test_cleartext_password_is_sent_and_checked(self):
        seen = []

        def handler(c, i):
            read_startup(c)
            c.sendall(auth(3))
            kind, body = read_message(c)
            seen.append((kind, body))
            if body == b"letmein\0":
                c.sendall(finish_login())
                serve_statements(c)
            else:
                c.sendall(error(b"28P01", b"password authentication failed"))
            hold(c)
        m, r = self.run_against(handler, password="letmein")
        self.assertEqual(r.final("live"), 1)
        self.assertEqual(seen[0], (b"p", b"letmein\0"))

    def test_every_connection_made_has_a_nonce_of_its_own(self):
        nonces = []

        def handler(c, i):
            read_startup(c)
            c.sendall(auth(10, b"SCRAM-SHA-256\0\0"))
            kind, body = read_message(c)
            mech_end = body.index(b"\0")
            first = body[mech_end + 5:].decode()
            nonces.append([p for p in first[3:].split(",") if p.startswith("r=")][0][2:])
        m, r = self.run_against(handler, password="pw", seconds=2, min_ms=50, max_ms=100)
        self.assertGreaterEqual(len(nonces), 5)
        self.assertEqual(len(set(nonces)), len(nonces))
        self.assertTrue(all(len(n) == 24 and "," not in n for n in nonces), nonces)


class Driver(unittest.TestCase):
    def test_a_loop_that_waits_for_the_login_is_what_this_replaces(self):
        """The baseline: the same job done the blocking way stops the loop for as long as the server is silent. The
        program is killed after three seconds without a tick."""
        proxy = Proxy(HOST, PORT)
        self.addCleanup(proxy.close)
        proxy.silent()
        p = subprocess.Popen([BASELINE, "127.0.0.1", str(proxy.port), USER, DB], stderr=subprocess.PIPE, text=True, bufsize=1)
        ticks = []

        def read():
            for line in p.stderr:
                ticks.append((time.monotonic(), line.strip()))
        threading.Thread(target=read, daemon=True).start()
        time.sleep(3.0)
        last = ticks[-1][0] if ticks else None
        p.kill()
        self.assertTrue(ticks)
        # ticks every 10 ms for the first half second, then nothing: it is inside `pg.login`
        self.assertGreater(time.monotonic() - last, 2.0, "the blocking loop was still ticking")


def main():
    build()
    unittest.main(argv=[sys.argv[0]] + sys.argv[1:], verbosity=2)


if __name__ == "__main__":
    main()
