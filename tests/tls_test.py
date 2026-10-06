#!/usr/bin/env python3
"""TLS to the server (docs/tls.md section 10), against a real PostgreSQL with TLS on and against mock servers.

    eval "$(sh tests/postgres.sh)"; python3 tests/tls_test.py
    LEX_SYS=/path/to/lex-sys   (default: lex-sys on PATH; `lex-sys install` must have filled build/deps)

The server is the one tests/postgres.sh starts: TLS on with a certificate for `localhost`, `pg.test` and `127.0.0.1` from the
test CA in PG_TLS_CA (PG_TLS_OTHER_CA is a CA that issued nothing it has), the roles of PG_TLS_ONLY_* (hostssl) and
PG_PLAIN_ONLY_* (hostnossl), and a second server without TLS on PG_NOSSL_PORT. The blocking client is examples/psql_tls.ls; the
pool is tests/tls_drive.ls (tests/reconnect_drive.ls over TLS). PG_TLS_CONTAINER names the server's container, which one test
restarts (`docker restart`, or the Docker API on /var/run/docker.sock where there is no `docker` command); without it that test
is skipped. Every psql the test runs itself (the reference, and the administration) uses PGSSLMODE=disable, so that the only
TLS sessions on the server are the ones under test.
"""
import http.client
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from reconnect_test import Mock, ev, msg, read_message, read_startup, finish_login, serve_statements, hold, error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOST = os.environ.get("PGHOST", "127.0.0.1")
PORT = int(os.environ.get("PGPORT", "5432"))
USER = os.environ.get("PGUSER", "postgres")
DB = os.environ.get("PGDATABASE", "postgres")
LEX = os.environ.get("LEX_SYS", "lex-sys")
CA = os.environ.get("PG_TLS_CA", os.path.join(ROOT, "build", "tls", "ca.crt"))
OTHER_CA = os.environ.get("PG_TLS_OTHER_CA", os.path.join(ROOT, "build", "tls", "other.crt"))
NOSSL_PORT = int(os.environ.get("PG_NOSSL_PORT", "5433"))
CONTAINER = os.environ.get("PG_TLS_CONTAINER")
SCRAM = (os.environ.get("PG_SCRAM_USER"), os.environ.get("PG_SCRAM_DB"), os.environ.get("PG_SCRAM_PASSWORD"))
CLEARTEXT = (os.environ.get("PG_CLEARTEXT_USER"), os.environ.get("PG_CLEARTEXT_DB"), os.environ.get("PG_CLEARTEXT_PASSWORD"))
TLS_ONLY = (os.environ.get("PG_TLS_ONLY_USER"), os.environ.get("PG_TLS_ONLY_DB"))
PLAIN_ONLY = (os.environ.get("PG_PLAIN_ONLY_USER"), os.environ.get("PG_PLAIN_ONLY_DB"))

PSQL_TLS = None
DRIVE = None

# The most a turn of the pool's loop may take, as tests/reconnect_test.py has it (a gross bound: what it excludes is waiting for
# the network or the server).
BUSY_BOUND = 50


def deps():
    d = os.path.join(ROOT, "build", "deps")
    files = sorted(os.path.join(d, f) for f in os.listdir(d) if f.endswith(".ls")) if os.path.isdir(d) else []
    if not files:
        raise SystemExit("build/deps is empty: run `lex-sys install` first")
    return files


def build():
    global PSQL_TLS, DRIVE
    os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
    PSQL_TLS = os.path.join(ROOT, "build", "psql_tls")
    subprocess.run([LEX, "build", "--std", os.path.join(ROOT, "examples", "psql_tls.ls"), os.path.join(ROOT, "src", "ssl.ls"),
                    os.path.join(ROOT, "src", "pg.ls"), *deps(), "-o", PSQL_TLS], check=True)
    DRIVE = os.path.join(ROOT, "build", "tls_drive")
    subprocess.run([LEX, "build", "--std", os.path.join(ROOT, "tests", "tls_drive.ls"), os.path.join(ROOT, "src", "pool.ls"),
                    os.path.join(ROOT, "src", "pg.ls"), *deps(), "-o", DRIVE], check=True)


def psql(sql, port=PORT, user=USER, db=DB, mode="disable"):
    env = dict(os.environ, PGHOST=HOST, PGPORT=str(port), PGUSER=user, PGDATABASE=db, PGSSLMODE=mode, PGSSLROOTCERT=CA)
    p = subprocess.run(["psql", "-X", "-At", "-F", "|", "-c", sql], capture_output=True, text=True, env=env, timeout=60)
    return p.stdout, p.returncode


def ours(mode, sql, *params, name="localhost", ca=CA, host="127.0.0.1", port=PORT, user=USER, db=DB, password="-"):
    """(stdout, exit status) of psql_tls."""
    p = subprocess.run([PSQL_TLS, mode, ca, name, host, str(port), user, db, password, sql, *params],
                       capture_output=True, text=True, timeout=60)
    return p.stdout, p.returncode


def tls_pids():
    out, _ = psql("select pid from pg_stat_ssl where ssl and pid <> pg_backend_pid()")
    return set(int(x) for x in out.split())


def terminate(pids):
    if not pids:
        return 0
    out, _ = psql("select count(pg_terminate_backend(p)) from unnest(array[%s]) as p" % ",".join(str(p) for p in sorted(pids)))
    return int(out.strip() or 0)


def restart_server():
    """Restart the server's container (a real restart: the postmaster stops, every backend is ended, the port refuses, then
    it comes back) and wait until it answers."""
    if shutil.which("docker"):
        subprocess.run(["docker", "restart", "-t", "5", CONTAINER], check=True, capture_output=True, timeout=120)
    else:
        class Unix(http.client.HTTPConnection):
            def connect(self):
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect("/var/run/docker.sock")
        c = Unix("docker", timeout=120)
        c.request("POST", "/containers/%s/restart?t=5" % CONTAINER)
        r = c.getresponse()
        assert r.status == 204, (r.status, r.read())
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        out, code = psql("select 1")
        if code == 0 and out.strip() == "1":
            return
        time.sleep(0.2)
    raise AssertionError("the server did not come back")


class Run:
    """A `tls_drive` process: its lines with the wall-clock time they arrived (as reconnect_test.Run)."""

    def __init__(self, port=PORT, user=USER, db=DB, password="-", lanes=1, seconds=3, mode="dbl", min_ms=100, max_ms=400,
                 attempt_ms=2000, request_ms=0, period=20, name="localhost", ca=CA, in_cap=65536, host="127.0.0.1"):
        self.t0 = time.monotonic()
        self.lines = []
        self.cond = threading.Condition()
        self.p = subprocess.Popen([DRIVE, host, str(port), user, db, password, str(lanes), str(seconds), mode, str(min_ms),
                                   str(max_ms), str(attempt_ms), str(request_ms), str(period), name, ca, str(in_cap)],
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

    def wait(self, pred, timeout=15):
        deadline = time.monotonic() + timeout
        seen = 0
        with self.cond:
            while True:
                while seen < len(self.lines):
                    t, text = self.lines[seen]
                    seen += 1
                    if pred(text):
                        return t, text
                    if text == "<eof>":
                        return None
                left = deadline - time.monotonic()
                if left <= 0:
                    return None
                self.cond.wait(left)

    def result(self, timeout=60):
        self.wait(lambda text: text == "stop", timeout)
        try:
            self.p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.p.kill()
            self.p.wait()
        self.reader.join(5)
        self.p.stderr.close()
        with self.cond:
            return Result(list(self.lines), self.p.returncode)


class Result:
    def __init__(self, lines, code):
        self.lines, self.code = lines, code
        self.err = "\n".join(x for _, x in lines if not re.match(r"(ev|done|finished|ready|stop|<eof>|add)", x))
        self.evs = [(t, ev(x)) for t, x in lines if x.startswith("ev ")]
        self.done = []
        for t, x in lines:
            f = x.split()
            if f and f[0] == "done":
                self.done.append((t, int(f[2]), int(f[3]), " ".join(f[4:])))
        fin = [x for _, x in lines if x.startswith("finished")]
        self.fin = ev(fin[-1]) if fin else {}
        self.tag = None
        if fin:
            f = fin[-1].split()
            self.tag = f[f.index("tag") + 1]

    def final(self, key):
        return self.fin[key]


class Blocking(unittest.TestCase):
    """`pg.ssl`, through examples/psql_tls.ls."""

    def test_verify_full_by_name_and_by_address(self):
        for name in ("localhost", "pg.test", "127.0.0.1"):
            out, code = ours("verify-full", "select ssl, version from pg_stat_ssl where pid = pg_backend_pid()", name=name)
            self.assertEqual(code, 0, (name, out))
            self.assertRegex(out, r"^t\|TLSv1\.[23]\n# SELECT 1\n$", name)

    def test_the_same_rows_as_the_reference_over_tls(self):
        # what crosses many records and many reads: a long value, many rows, a wide row, parameters as data
        for sql in ("select repeat('é', 100000)", "select g, md5(g::text) from generate_series(1, 20000) g",
                    "select " + ", ".join("%d as c%d" % (i, i) for i in range(300)),
                    "select 1; select 1/0; select 3"):
            want, _ = psql(sql, mode="verify-full")
            got, code = ours("verify-full", sql)
            lines = [x for x in got.splitlines() if not x.startswith("# ") and not x.startswith("ERROR")]
            self.assertEqual("\n".join(lines), want.strip(), sql[:40])
        out, code = ours("verify-full", "select $1::text, $2::int + 1", "it's; drop table x; --", "41")
        self.assertEqual(out, "it's; drop table x; --|42\n# SELECT 1\n")

    def test_every_login_over_tls(self):
        for user, db, password in (CLEARTEXT, SCRAM):
            if not user:
                continue
            out, code = ours("verify-full", "select current_user, ssl from pg_stat_ssl where pid = pg_backend_pid()",
                             user=user, db=db, password=password)
            self.assertEqual((out, code), ("%s|t\n# SELECT 1\n" % user, 0))
            out, code = ours("verify-full", "select 1", user=user, db=db, password=password + "x")
            self.assertEqual(code, 4)
            self.assertIn("ERROR 28P01", out)

    def test_a_name_the_certificate_does_not_carry_is_refused(self):
        for name in ("wrong.test", "127.0.0.2", "pg.test.evil", "test"):
            out, code = ours("verify-full", "select 1", name=name)
            self.assertEqual((out, code), ("ERROR x509-name-mismatch\n", 15), name)

    def test_a_trust_store_without_the_servers_authority_is_refused(self):
        out, code = ours("verify-full", "select 1", ca=OTHER_CA)
        self.assertEqual((out, code), ("ERROR x509-unknown-issuer\n", 15))

    def test_a_trust_store_with_nothing_in_it_is_refused_before_anything_is_sent(self):
        out, code = ours("verify-full", "select 1", ca="-")
        self.assertEqual((out, code), ("ERROR pg-ssl-setup\n", 16))
        # a file that holds no certificate (the key of the server, say)
        out, code = ours("verify-full", "select 1", ca=os.path.join(os.path.dirname(CA), "ca.cnf"))
        self.assertEqual((out, code), ("ERROR pg-ssl-setup\n", 16))

    def test_the_modes_that_are_not_offered_are_refused_before_dialling(self):
        # the port is one nothing listens on: a refusal that dialled would be status 103
        free = socket.socket()
        free.bind(("127.0.0.1", 0))
        port = free.getsockname()[1]
        free.close()
        for mode in ("require", "verify-ca", "prefer", "allow", "verify_full", ""):
            out, code = ours(mode, "select 1", port=port)
            self.assertEqual(code, 16, mode)
            self.assertIn("pg-ssl-setup", out)

    def test_a_server_without_tls_is_refused_by_verify_full_and_used_by_disable(self):
        out, code = ours("verify-full", "select 1", port=NOSSL_PORT)
        self.assertEqual((out, code), ("ERROR pg-ssl-not-offered\n", 13))
        out, code = ours("disable", "select ssl from pg_stat_ssl where pid = pg_backend_pid()", port=NOSSL_PORT)
        self.assertEqual((out, code), ("f\n# SELECT 1\n", 0))

    def test_disable_is_the_connection_it_always_was(self):
        out, code = ours("disable", "select ssl from pg_stat_ssl where pid = pg_backend_pid()", ca="-")
        self.assertEqual((out, code), ("f\n# SELECT 1\n", 0))

    @unittest.skipUnless(TLS_ONLY[0] and PLAIN_ONLY[0], "PG_TLS_ONLY_* and PG_PLAIN_ONLY_* name no roles")
    def test_the_servers_hostssl_and_hostnossl_both_ways(self):
        user, db = TLS_ONLY
        out, code = ours("verify-full", "select current_user", user=user, db=db)
        self.assertEqual((out, code), ("%s\n# SELECT 1\n" % user, 0))
        out, code = ours("disable", "select 1", user=user, db=db)
        self.assertEqual(code, 4)
        self.assertIn("ERROR 28000", out)
        user, db = PLAIN_ONLY
        out, code = ours("disable", "select current_user", user=user, db=db)
        self.assertEqual((out, code), ("%s\n# SELECT 1\n" % user, 0))
        out, code = ours("verify-full", "select 1", user=user, db=db)
        self.assertEqual(code, 4)
        self.assertIn("ERROR 28000", out)


# ---------------------------------------------------------------------------------------------------------------------
# Mock servers: what a server, or a man in the middle, answers to SSLRequest
# ---------------------------------------------------------------------------------------------------------------------

def read_ssl_request(c):
    data = b""
    while len(data) < 8:
        chunk = c.recv(8 - len(data))
        if not chunk:
            raise EOFError
        data += chunk
    assert data == b"\0\0\0\x08\x04\xd2\x16\x2f", data
    return data


def answers(payload, then=None):
    def handler(c, i):
        read_ssl_request(c)
        c.sendall(payload)
        if then:
            then(c)
        else:
            hold(c)
    return handler


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

    def blocking(self, handler):
        m = self.mock(handler)
        return ours("verify-full", "select 1", port=m.port)

    def test_bytes_after_the_s_are_refused(self):
        # CVE-2021-23222: what a man in the middle puts after the server's `S`, before the handshake
        self.assertEqual(self.blocking(answers(b"S" + msg(b"Z", b"I"))), ("ERROR pg-ssl-bad-answer\n", 14))

    def test_an_error_or_another_byte_instead_of_s_or_n_is_refused(self):
        self.assertEqual(self.blocking(answers(error(b"08P01", b"unsupported frontend protocol"))), ("ERROR pg-ssl-bad-answer\n", 14))
        self.assertEqual(self.blocking(answers(b"X")), ("ERROR pg-ssl-bad-answer\n", 14))

    def test_a_server_that_closes_after_s(self):
        self.assertEqual(self.blocking(answers(b"S", then=lambda c: None)), ("ERROR tls-peer-closed\n", 15))

    def test_a_server_that_answers_the_client_hello_with_something_that_is_not_tls(self):
        def then(c):
            c.recv(4096)
            c.sendall(b"HTTP/1.1 400 Bad Request\r\n\r\n")
            hold(c)
        out, code = self.blocking(answers(b"S", then=then))
        self.assertEqual(code, 15)
        self.assertRegex(out, r"^ERROR tls-")

    def test_a_server_that_says_n_to_a_pool(self):
        m = self.mock(answers(b"N"))
        r = Run(port=m.port, lanes=2, seconds=1).result()
        self.assertEqual(r.code, 0, r.err)
        self.assertEqual(r.final("live"), 0)
        self.assertEqual(r.final("last"), 13)

    def test_bytes_after_the_s_are_refused_by_the_pool(self):
        m = self.mock(answers(b"S" + msg(b"Z", b"I")))
        r = Run(port=m.port, lanes=1, seconds=1).result()
        self.assertEqual(r.final("live"), 0)
        self.assertEqual(r.final("last"), 14)

    def test_a_server_that_closes_after_s_fails_the_pools_attempt(self):
        m = self.mock(answers(b"S", then=lambda c: None))
        r = Run(port=m.port, lanes=1, seconds=1).result()
        self.assertEqual(r.final("live"), 0)
        self.assertEqual(r.final("last"), 15)
        self.assertEqual(r.tag, "tls-peer-closed")

    def tls_server(self, then, statements=4):
        """A mock that answers `S`, makes the TLS handshake as the real server's certificate would (Python's `ssl`), logs the
        client in and answers its statements over TLS, then calls `then(raw, tls)` with the raw socket under the session."""
        import ssl
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        d = os.path.dirname(CA)
        ctx.load_cert_chain(os.path.join(d, "server.crt"), os.path.join(d, "server.key"))

        def handler(c, i):
            read_ssl_request(c)
            c.sendall(b"S")
            t = ctx.wrap_socket(c, server_side=True)
            read_startup(t)
            t.sendall(finish_login())
            serve_statements(t, count=statements)
            # `wrap_socket` detached `c`: the raw socket under the session is a second descriptor of it
            raw = socket.socket(fileno=os.dup(t.fileno()))
            try:
                then(raw, t)
            finally:
                raw.close()
                try:
                    t.close()
                except OSError:
                    pass
        return self.mock(handler)

    def test_a_record_that_does_not_authenticate_ends_a_live_connection(self):
        def then(raw, t):
            time.sleep(0.5)
            # an application-data record of 64 bytes the session's key did not seal
            raw.sendall(b"\x17\x03\x03\x00\x40" + os.urandom(64))
            hold(raw)
        m = self.tls_server(then)
        r = Run(port=m.port, lanes=1, seconds=2, mode="idle", min_ms=5000, max_ms=5000).result()
        self.assertEqual(r.code, 0, r.err)
        self.assertEqual((r.final("made"), r.final("losses"), r.final("loss")), (1, 1, 15))
        self.assertEqual(r.tag, "tls-bad-record-mac")

    def test_a_close_notify_ends_a_live_connection_as_a_close(self):
        def then(raw, t):
            time.sleep(0.5)
            t.unwrap()
            hold(raw)
        m = self.tls_server(then)
        r = Run(port=m.port, lanes=1, seconds=2, mode="idle", min_ms=5000, max_ms=5000).result()
        self.assertEqual((r.final("made"), r.final("losses"), r.final("loss")), (1, 1, 1))

    def test_the_blocking_client_refuses_a_reply_that_does_not_authenticate(self):
        def then(raw, t):
            read_message(t)
            raw.sendall(b"\x17\x03\x03\x00\x40" + os.urandom(64))
            hold(raw)
        m = self.tls_server(then, statements=0)
        out, code = ours("verify-full", "select 1", port=m.port)
        self.assertEqual((out, code), ("ERROR tls-bad-record-mac\n", 15))

    def test_the_mock_tls_server_is_a_good_control(self):
        m = self.tls_server(lambda raw, t: hold(t))
        r = Run(port=m.port, lanes=1, seconds=1, mode="idle").result()
        self.assertEqual((r.final("live"), r.final("made"), r.final("losses")), (1, 1, 0))

    def test_a_plain_pool_never_sends_ssl_request(self):
        def handler(c, i):
            body = read_startup(c)
            assert b"user" in body, body
            c.sendall(finish_login())
            serve_statements(c, count=4)
            hold(c)
        m = self.mock(handler)
        r = Run(port=m.port, lanes=1, seconds=1, mode="idle", name="-", ca="-").result()
        self.assertEqual(r.final("live"), 1)
        self.assertEqual(r.final("secured"), 0)


# ---------------------------------------------------------------------------------------------------------------------
# The pool over TLS, against the real server
# ---------------------------------------------------------------------------------------------------------------------

class Pool(unittest.TestCase):
    def check_answers(self, r, allow_lost=False):
        tags = [tag for _, tag, _, _ in r.done]
        self.assertEqual(len(tags), len(set(tags)), "a request answered twice")
        self.assertEqual(sorted(tags), list(range(len(tags))), "a request that was never answered")
        for t, tag, status, value in r.done:
            if status == 0:
                self.assertEqual(value, str(2 * tag), (tag, status, value))
            else:
                self.assertTrue(allow_lost and status in (1, 3, 6, 8, 10, 11, 12, 15), (tag, status, value))

    def check_stall(self, r):
        self.assertLessEqual(r.final("maxbusy"), BUSY_BOUND, "the loop was kept from waiting for %d ms" % r.final("maxbusy"))

    def test_many_connections_over_one_engine(self):
        r = Run(lanes=8, seconds=3, period=1).result()
        self.assertEqual(r.code, 0, r.err)
        self.check_answers(r)
        self.assertGreater(len(r.done), 1500)
        self.assertEqual((r.final("live"), r.final("made"), r.final("failures"), r.final("secured")), (8, 8, 0, 1))
        self.check_stall(r)

    def test_the_server_sees_tls_sessions(self):
        run = Run(lanes=3, seconds=4, mode="idle")
        self.assertIsNotNone(run.wait(lambda text: text == "ready"))
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and len(tls_pids()) < 3:
            time.sleep(0.1)
        out, _ = psql("select count(*) from pg_stat_ssl s join pg_stat_activity a using (pid) where s.ssl and a.usename = '%s' "
                      "and s.version like 'TLSv1.%%'" % USER)
        self.assertGreaterEqual(int(out), 3)
        r = run.result()
        self.assertEqual(r.final("live"), 3)

    def test_every_backend_ended_and_every_connection_remade_over_tls(self):
        run = Run(lanes=4, seconds=6, period=10)
        self.assertIsNotNone(run.wait(lambda text: text.startswith("ev ") and ev(text)["live"] == 4))
        time.sleep(1.5)
        victims = tls_pids()
        self.assertGreaterEqual(len(victims), 4)
        self.assertEqual(terminate(victims), len(victims))
        r = run.result()
        self.assertEqual(r.code, 0, r.err)
        self.check_answers(r, allow_lost=True)
        self.assertEqual(r.final("live"), 4)
        self.assertGreaterEqual(r.final("losses"), 4)
        self.assertGreaterEqual(r.final("reconnects"), 4)
        # the last requests, after the new connections were made, are answered
        self.assertTrue(all(s == 0 for t, _, s, _ in r.done if t > r.done[-1][0] - 1.0))
        self.check_stall(r)

    @unittest.skipUnless(CONTAINER, "PG_TLS_CONTAINER names no container to restart")
    def test_the_server_restarted_and_the_pool_back_over_tls(self):
        run = Run(lanes=2, seconds=20, period=20, min_ms=100, max_ms=1000)
        self.assertIsNotNone(run.wait(lambda text: text.startswith("ev ") and ev(text)["live"] == 2))
        time.sleep(1.0)
        restarted = time.monotonic() - run.t0
        restart_server()
        back = time.monotonic() - run.t0
        r = run.result(timeout=90)
        self.assertEqual(r.code, 0, r.err)
        self.check_answers(r, allow_lost=True)
        self.assertEqual(r.final("live"), 2)
        self.assertGreaterEqual(r.final("losses"), 2)
        self.assertGreaterEqual(r.final("reconnects"), 2)
        # the losses are seen once the restart begins; both lanes are live again by the time the server answers psql, or
        # within the longest wait (1 s) and an attempt after it
        lost_at = [t for t, e in r.evs if t > restarted and e["live"] < 2]
        self.assertTrue(lost_at, "the restart was not seen")
        live_again = [t for t, e in r.evs if t > lost_at[0] and e["live"] == 2]
        self.assertTrue(live_again, "never live again after the restart")
        self.assertLess(live_again[0] - back, 2.5, "slower back than the longest wait allows")
        late = [s for t, _, s, _ in r.done if t > live_again[0] + 0.5]
        self.assertGreater(len(late), 50)
        self.assertTrue(all(s == 0 for s in late))
        self.check_stall(r)
        print("\n    restart: down at %.2f s, accepting at %.2f s, both live at %.2f s; losses %d, attempts %d, failures %d"
              % (restarted, back, live_again[0], r.final("losses"), r.final("attempts"), r.final("failures")), file=sys.stderr)

    def test_a_wrong_name_is_never_live_and_waits_its_backoff(self):
        r = Run(lanes=2, seconds=2, name="wrong.test", min_ms=100, max_ms=400).result()
        self.assertEqual(r.code, 0, r.err)
        self.assertEqual((r.final("live"), r.final("last"), r.tag), (0, 15, "x509-name-mismatch"))
        # a lane fails at about 0, 0.1, 0.3, 0.7, 1.1, 1.5, 1.9 s: seven, at the backoff, never faster
        self.assertGreaterEqual(r.final("attempts"), 8)
        self.assertLessEqual(r.final("attempts"), 18)
        self.assertEqual(r.final("attempts"), r.final("failures"))
        self.check_stall(r)

    def test_an_unknown_authority_is_never_live(self):
        r = Run(lanes=1, seconds=1, ca=OTHER_CA).result()
        self.assertEqual((r.final("live"), r.final("last"), r.tag), (0, 15, "x509-unknown-issuer"))

    def test_a_server_without_tls_is_refused_by_the_pool(self):
        r = Run(port=NOSSL_PORT, lanes=1, seconds=1).result()
        self.assertEqual((r.final("live"), r.final("last")), (0, 13))

    def test_logins_of_every_kind_over_tls(self):
        for user, db, password in (CLEARTEXT, SCRAM):
            if not user:
                continue
            r = Run(user=user, db=db, password=password, lanes=2, seconds=1).result()
            self.assertEqual(r.code, 0, r.err)
            self.check_answers(r)
            self.assertEqual(r.final("live"), 2, user)
            r = Run(user=user, db=db, password=password + "x", lanes=1, seconds=1).result()
            self.assertEqual((r.final("live"), r.final("last")), (0, 4))

    @unittest.skipUnless(TLS_ONLY[0], "PG_TLS_ONLY_* names no role")
    def test_a_hostssl_role_through_the_pool(self):
        user, db = TLS_ONLY
        r = Run(user=user, db=db, lanes=1, seconds=1).result()
        self.assertEqual(r.final("live"), 1)
        r = Run(user=user, db=db, lanes=1, seconds=1, name="-", ca="-").result()
        self.assertEqual((r.final("live"), r.final("last")), (0, 4))

    def test_what_the_engine_holds_when_the_input_is_full_is_delivered(self):
        # answers of 1,000 to 7,000 bytes taken every 300 ms into an input of 16 KiB: reading stops for room while a record's
        # plaintext is still in the engine, and no poller event will say so
        r = Run(lanes=2, seconds=3, mode="wide", period=5, in_cap=16384).result()
        self.assertEqual(r.code, 0, r.err)
        tags = sorted(tag for _, tag, _, _ in r.done)
        self.assertEqual(tags, list(range(len(tags))))
        self.assertGreater(len(tags), 50)
        for _, tag, status, value in r.done:
            self.assertEqual((status, value), (0, "w%d" % ((tag % 7 + 1) * 1000)), tag)

    def test_a_secure_pool_takes_no_connection_from_add(self):
        r = Run(lanes=1, seconds=1, mode="add").result()
        line = [x for _, x in r.lines if x.startswith("add")][0]
        self.assertEqual(line, "add 0 lane 9")
        r = Run(lanes=1, seconds=1, mode="add", name="-", ca="-").result()
        line = [x for _, x in r.lines if x.startswith("add")][0]
        self.assertEqual(line, "add 0 lane 10")

    def test_a_plain_pool_against_the_tls_server_is_unchanged(self):
        r = Run(lanes=2, seconds=1, name="-", ca="-").result()
        self.check_answers(r)
        self.assertEqual((r.final("live"), r.final("secured")), (2, 0))


class Authority(unittest.TestCase):
    def report(self, *files):
        out = subprocess.run([LEX, "authority", *files, *deps(), "--std", "--output", "json"], capture_output=True, text=True)
        import json
        return json.loads(out.stdout)

    def test_a_program_with_a_secure_pool_holds_nothing_foreign(self):
        d = self.report(os.path.join(ROOT, "tests", "narrow_tls.ls"), os.path.join(ROOT, "src", "pool.ls"), os.path.join(ROOT, "src", "pg.ls"))
        self.assertTrue(d["bounded"])
        self.assertEqual(d["foreign_symbols"], [])
        labels = {(x["name"], x["argument"]) for x in d["labels"]}
        self.assertIn(("net_out", "127.0.0.1:5432"), labels)
        self.assertIn(("fs_read", "/dev/urandom"), labels)
        self.assertNotIn(("net_out", ""), labels)
        self.assertFalse(any(name.startswith("ffi") for name, _ in labels))

    def test_the_blocking_client_holds_nothing_foreign(self):
        d = self.report(os.path.join(ROOT, "examples", "psql_tls.ls"), os.path.join(ROOT, "src", "ssl.ls"), os.path.join(ROOT, "src", "pg.ls"))
        self.assertTrue(d["bounded"])
        self.assertEqual(d["foreign_symbols"], [])
        self.assertFalse(any(x["name"].startswith("ffi") for x in d["labels"]))


def main():
    build()
    unittest.main(argv=[sys.argv[0]] + sys.argv[1:], verbosity=2)


if __name__ == "__main__":
    main()
