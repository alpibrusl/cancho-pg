#!/usr/bin/env python3
"""End-to-end tests of the transaction pooler (docs/pooler.md section 4, the correctness list) against a real PostgreSQL.

    PGHOST=127.0.0.1 PGPORT=5432 python3 pooler/tests/pooler_e2e.py [path/to/pooler]

Needs trust authentication for `postgres` on the database `bench` (any database will do: PGDATABASE). Each test starts its own pooler on its own
port with the pool size it needs, speaks the wire protocol to it over raw sockets, and looks at what PostgreSQL itself says (backend pids, what is visible).
"""
import base64, hashlib, hmac, os, socket, struct, subprocess, sys, threading, time, unittest

BIN = sys.argv.pop(1) if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else os.path.join(os.path.dirname(__file__), "..", "..", "build", "pooler")
HOST = os.environ.get("PGHOST", "127.0.0.1")
PORT = int(os.environ.get("PGPORT", "5432"))
DB = os.environ.get("PGDATABASE", "bench")
USER = os.environ.get("PGUSER", "postgres")


class AuthError(Exception):
    pass


REPLAY = [None, None]


def msg(kind, body=b""):
    return kind + struct.pack("!i", len(body) + 4) + body


class Client:
    """A bare protocol client: startup, simple and extended messages, replies parsed to what the tests look at."""

    def __init__(self, port, user=USER, db=DB, timeout=10, password=None, mutate=None):
        self.s = socket.create_connection(("127.0.0.1", port), timeout)
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.buf = b""
        self.user = user
        body = struct.pack("!i", 196608) + b"user\0" + user.encode() + b"\0database\0" + db.encode() + b"\0\0"
        self.s.sendall(struct.pack("!i", len(body) + 4) + body)
        if password is not None:
            self.scram(password, mutate)
        self.startup = self.until_ready()

    def scram(self, password, mutate=None):
        """The client side of SCRAM-SHA-256 (RFC 7677), independent of the pooler's code. `mutate` names a way to get it wrong."""
        k, body = self.read_message()
        if k == b"E":
            raise AuthError(self.parse_error(body))
        assert k == b"R" and struct.unpack("!i", body[:4])[0] == 10, (k, body)
        mech = b"SCRAM-SHA-256"
        if mutate == "plus":
            mech = b"SCRAM-SHA-256-PLUS"
        cnonce = base64.b64encode(os.urandom(18)).decode()
        if mutate == "replay":
            cnonce = REPLAY[1]  # the same client nonce as the session the final message was captured in
        gs2 = "n,,"
        if mutate == "channel_binding":
            gs2 = "p=tls-server-end-point,,"
        bare = "n=,r=" + cnonce
        first = (gs2 + bare).encode()
        self.s.sendall(msg(b"p", mech + b"\0" + struct.pack("!i", len(first)) + first))
        k, body = self.read_message()
        if k == b"E":
            raise AuthError(self.parse_error(body))
        assert k == b"R" and struct.unpack("!i", body[:4])[0] == 11, (k, body)
        server_first = body[4:].decode()
        attrs = dict(a.split("=", 1) for a in server_first.split(","))
        assert attrs["r"].startswith(cnonce) and len(attrs["r"]) > len(cnonce)
        salt, iters = base64.b64decode(attrs["s"]), int(attrs["i"])
        salted = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iters)
        client_key = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
        stored = hashlib.sha256(client_key).digest()
        nonce = attrs["r"] if mutate != "wrong_nonce" else cnonce + "XXXXXXXXXXXXXXXXXXXXXXXX"
        without_proof = "c=biws,r=" + nonce
        if mutate == "bad_binding_flag":
            without_proof = "c=cD10bHMtc2VydmVyLWVuZC1wb2ludCws,r=" + nonce
        auth = bare + "," + server_first + "," + without_proof
        signature = hmac.new(stored, auth.encode(), hashlib.sha256).digest()
        proof = bytes(a ^ b for a, b in zip(client_key, signature))
        if mutate == "tampered_proof":
            proof = bytes([proof[0] ^ 1]) + proof[1:]
        final = without_proof + ",p=" + base64.b64encode(proof).decode()
        if mutate == "no_proof":
            final = without_proof
        self.captured = (cnonce, final)
        if mutate == "replay":
            final = REPLAY[0]
        self.s.sendall(msg(b"p", final.encode()))
        k, body = self.read_message()
        if k == b"E":
            raise AuthError(self.parse_error(body))
        assert k == b"R" and struct.unpack("!i", body[:4])[0] == 12, (k, body)
        server_key = hmac.new(salted, b"Server Key", hashlib.sha256).digest()
        expected = base64.b64encode(hmac.new(server_key, auth.encode(), hashlib.sha256).digest()).decode()
        assert body[4:].decode() == "v=" + expected, "the server's signature is not the one only a holder of the password can make"

    @staticmethod
    def parse_error(body):
        fields = {}
        for part in body.split(b"\0"):
            if part:
                fields[chr(part[0])] = part[1:].decode()
        return fields

    def raw(self, data):
        self.s.sendall(data)

    def read_message(self):
        while len(self.buf) < 5:
            self._more()
        size = struct.unpack("!i", self.buf[1:5])[0]
        while len(self.buf) < 1 + size:
            self._more()
        m, self.buf = self.buf[:1 + size], self.buf[1 + size:]
        return m[0:1], m[5:]

    def _more(self):
        d = self.s.recv(1 << 16)
        if not d:
            raise ConnectionError("closed")
        self.buf += d

    def until_ready(self, count=1):
        """Read to `count` ReadyForQuerys: (rows, errors, tags, statuses, other kinds seen)."""
        rows, errors, tags, statuses, kinds = [], [], [], [], []
        while len(statuses) < count:
            k, body = self.read_message()
            kinds.append(k)
            if k == b"D":
                n = struct.unpack("!h", body[:2])[0]
                at, row = 2, []
                for _ in range(n):
                    ln = struct.unpack("!i", body[at:at + 4])[0]
                    at += 4
                    if ln < 0:
                        row.append(None)
                    else:
                        row.append(body[at:at + ln].decode())
                        at += ln
                rows.append(row)
            elif k == b"E":
                fields = {}
                for part in body.split(b"\0"):
                    if part:
                        fields[chr(part[0])] = part[1:].decode()
                errors.append(fields)
            elif k == b"C":
                tags.append(body.rstrip(b"\0").decode())
            elif k == b"Z":
                statuses.append(chr(body[0]))
        return rows, errors, tags, statuses, kinds

    def query(self, sql):
        self.raw(msg(b"Q", sql.encode() + b"\0"))
        return self.until_ready()

    def one(self, sql):
        rows, errors, tags, statuses, _ = self.query(sql)
        assert not errors, errors
        return rows[0][0]

    def extended(self, sql, params=()):
        """Unnamed Parse, Bind, Describe, Execute, Sync, in one write."""
        parse = msg(b"P", b"\0" + sql.encode() + b"\0" + struct.pack("!h", 0))
        bind = b"\0\0" + struct.pack("!h", 0) + struct.pack("!h", len(params))
        for p in params:
            bind += struct.pack("!i", len(p)) + p.encode()
        bind += struct.pack("!h", 0)
        self.raw(parse + msg(b"B", bind) + msg(b"D", b"P\0") + msg(b"E", b"\0" + struct.pack("!i", 0)) + msg(b"S"))
        return self.until_ready()

    def close(self):
        try:
            self.s.sendall(msg(b"X"))
        except OSError:
            pass
        self.s.close()


def admin(sql):
    """Run SQL directly on the server (not through any pooler)."""
    r = subprocess.run(["psql", "-h", HOST, "-p", str(PORT), "-U", USER, "-d", DB, "-Atc", sql], capture_output=True, text=True)
    return r.stdout.strip()


_next_port = [6500]


class Pooler:
    def __init__(self, size, db=DB, client_password=None):
        _next_port[0] += 1
        self.port = _next_port[0]
        self.client_password = client_password
        self.p = subprocess.Popen([BIN, str(self.port), HOST, str(PORT), USER, db, "-", str(size)] + ([client_password] if client_password else []), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", self.port), 0.2).close()
                break
            except OSError:
                time.sleep(0.05)
        # wait until the pool is logged in: a client is answered only when it is
        for _ in range(100):
            try:
                c = Client(self.port, password=client_password)
                c.close()
                break
            except Exception:
                time.sleep(0.05)

    def stop(self):
        self.p.kill()
        self.p.wait()


class PoolerCase(unittest.TestCase):
    size = 1

    def setUp(self):
        self.pooler = Pooler(self.size)
        self.addCleanup(self.pooler.stop)
        self.clients = []
        admin("drop table if exists pooler_t; create table pooler_t (v int)")
        self.addCleanup(lambda: admin("drop table if exists pooler_t"))

    def client(self):
        c = Client(self.pooler.port)
        self.clients.append(c)
        self.addCleanup(c.close)
        return c


class TransactionBoundaries(PoolerCase):
    size = 1

    def test_the_startup_is_the_poolers_own_and_looks_like_a_servers(self):
        c = self.client()
        rows, errors, tags, statuses, kinds = c.startup
        self.assertEqual(statuses, ["I"])
        self.assertEqual(kinds[0], b"R")
        self.assertIn(b"S", kinds)
        self.assertIn(b"K", kinds)
        self.assertEqual(kinds[-1], b"Z")

    def test_clients_take_turns_on_one_server_connection(self):
        pids = set()
        for _ in range(5):
            c = self.client()
            pids.add(c.one("select pg_backend_pid()"))
        self.assertEqual(len(pids), 1)

    def test_an_open_transaction_keeps_its_connection_and_others_wait_for_it(self):
        a, b = self.client(), self.client()
        a.query("begin")
        a.query("insert into pooler_t values (1)")
        order = []

        def other():
            order.append(("b asks", time.time()))
            r = b.one("select count(*) from pooler_t")
            order.append(("b answered " + r, time.time()))

        t = threading.Thread(target=other)
        t.start()
        time.sleep(0.5)
        self.assertEqual(len(order), 1, "b must not be answered while a's transaction is open")
        self.assertEqual(a.one("select count(*) from pooler_t"), "1")
        a.query("commit")
        t.join(5)
        self.assertEqual(order[1][0], "b answered 1")

    def test_a_rolled_back_transaction_is_not_seen_by_the_next_client(self):
        a, b = self.client(), self.client()
        a.query("begin")
        a.query("insert into pooler_t values (1)")
        a.query("rollback")
        self.assertEqual(b.one("select count(*) from pooler_t"), "0")

    def test_a_client_that_leaves_in_a_transaction_does_not_leave_it_open(self):
        a = self.client()
        pid_a = a.one("select pg_backend_pid()")
        a.query("begin")
        a.query("insert into pooler_t values (1)")
        a.s.close()  # no Terminate, no commit
        b = self.client()
        self.assertEqual(b.one("select count(*) from pooler_t"), "0")
        self.assertNotEqual(b.one("select pg_backend_pid()"), pid_a, "the connection that was in a transaction is not reused")
        self.assertEqual(admin("select count(*) from pg_stat_activity where datname = '%s' and state = 'idle in transaction'" % DB), "0")

    def test_a_failed_transaction_holds_its_connection_until_rollback(self):
        a, b = self.client(), self.client()
        a.query("begin")
        rows, errors, tags, statuses, _ = a.query("select 1/0")
        self.assertEqual(statuses, ["E"])
        self.assertEqual(errors[0]["C"], "22012")
        done = []
        t = threading.Thread(target=lambda: done.append(b.one("select 1")))
        t.start()
        time.sleep(0.4)
        self.assertEqual(done, [], "still held by the failed transaction")
        a.query("rollback")
        t.join(5)
        self.assertEqual(done, ["1"])

    def test_waiting_clients_are_served_in_the_order_they_came(self):
        a = self.client()
        a.query("begin")
        a.query("select pg_sleep(0)")
        order, threads = [], []
        cs = [self.client() for _ in range(4)]
        for i, c in enumerate(cs):
            def go(i=i, c=c):
                c.one("select 1")
                order.append(i)
            t = threading.Thread(target=go)
            t.start()
            threads.append(t)
            time.sleep(0.15)
        a.query("commit")
        for t in threads:
            t.join(5)
        self.assertEqual(order, [0, 1, 2, 3])


class Pipelining(PoolerCase):
    size = 1

    def test_pipelined_queries_are_all_answered_and_the_connection_is_held_to_the_last(self):
        a, b = self.client(), self.client()
        a.raw(msg(b"Q", b"select pg_backend_pid()\0") + msg(b"Q", b"select pg_backend_pid()\0") + msg(b"Q", b"select 3\0"))
        rows, errors, tags, statuses, _ = a.until_ready(3)
        self.assertEqual(statuses, ["I", "I", "I"])
        self.assertEqual(rows[0], rows[1])
        self.assertEqual(rows[2], ["3"])
        self.assertEqual(b.one("select 1"), "1")

    def test_extended_protocol_with_the_unnamed_statement_works(self):
        a = self.client()
        rows, errors, tags, statuses, _ = a.extended("select $1::int + 1", ["41"])
        self.assertEqual((rows, errors, statuses), ([["42"]], [], ["I"]))
        rows, errors, tags, statuses, _ = a.extended("select $1::text || 'x'", ["a'; drop table pooler_t; --"])
        self.assertEqual(rows, [["a'; drop table pooler_t; --x"]])
        self.assertEqual(admin("select count(*) from pooler_t"), "0")

    def test_two_syncs_in_one_write_release_only_after_the_second(self):
        a, b = self.client(), self.client()
        one = msg(b"P", b"\0select 1\0" + struct.pack("!h", 0)) + msg(b"B", b"\0\0" + struct.pack("!hhh", 0, 0, 0)) + msg(b"E", b"\0" + struct.pack("!i", 0)) + msg(b"S")
        a.raw(one + one)
        rows, errors, tags, statuses, _ = a.until_ready(2)
        self.assertEqual((rows, errors, statuses), ([["1"], ["1"]], [], ["I", "I"]))
        self.assertEqual(b.one("select 2"), "2")


class Refusals(PoolerCase):
    size = 1

    def test_a_named_statement_is_refused_in_the_servers_words_and_the_connection_goes_on(self):
        a = self.client()
        raw = msg(b"P", b"stmt1\0select 1\0" + struct.pack("!h", 0)) + msg(b"B", b"\0stmt1\0" + struct.pack("!hhh", 0, 0, 0)) + msg(b"E", b"\0" + struct.pack("!i", 0)) + msg(b"S")
        a.raw(raw)
        rows, errors, tags, statuses, _ = a.until_ready()
        self.assertEqual(rows, [])
        self.assertEqual(errors[0]["C"], "0A000")
        self.assertEqual(statuses, ["I"])
        self.assertEqual(a.one("select 7"), "7")

    def test_a_named_statement_inside_a_transaction_fails_it(self):
        a = self.client()
        a.query("begin")
        a.raw(msg(b"P", b"s\0select 1\0" + struct.pack("!h", 0)) + msg(b"S"))
        rows, errors, tags, statuses, _ = a.until_ready()
        self.assertEqual((errors[0]["C"], statuses), ("0A000", ["E"]))
        rows, errors, tags, statuses, _ = a.query("rollback")
        self.assertEqual((errors, statuses), ([], ["I"]))
        self.assertEqual(a.one("select 8"), "8")

    def test_the_wrong_user_or_database_is_refused(self):
        with self.assertRaises(Exception):
            Client(self.pooler.port, user="nobody")
        with self.assertRaises(Exception):
            Client(self.pooler.port, db="no_such_database")
        self.assertEqual(self.client().one("select 1"), "1")

    def test_ssl_request_is_answered_no_and_the_startup_follows(self):
        s = socket.create_connection(("127.0.0.1", self.pooler.port), 5)
        s.sendall(struct.pack("!ii", 8, 80877103))
        self.assertEqual(s.recv(1), b"N")
        body = struct.pack("!i", 196608) + b"user\0" + USER.encode() + b"\0database\0" + DB.encode() + b"\0\0"
        s.sendall(struct.pack("!i", len(body) + 4) + body)
        data = b""
        while not data.endswith(b"Z\0\0\0\x05I"):
            data += s.recv(4096)
        s.close()


class Failures(PoolerCase):
    size = 2

    def test_a_server_connection_that_dies_idle_is_replaced(self):
        c = self.client()
        pid = c.one("select pg_backend_pid()")
        c.close()
        time.sleep(0.2)
        admin("select pg_terminate_backend(pid) from pg_stat_activity where datname = '%s' and pid <> pg_backend_pid() and application_name = ''" % DB)
        time.sleep(1.0)
        d = self.client()
        self.assertEqual(d.one("select 1"), "1")
        self.assertEqual(d.one("select 2"), "2")

    def test_a_server_connection_that_dies_mid_transaction_cuts_its_client_and_no_one_else(self):
        a, b = self.client(), self.client()
        pid_a = a.one("select pg_backend_pid()")
        a.query("begin")
        admin("select pg_terminate_backend(%s)" % pid_a)
        a.s.settimeout(3)
        with self.assertRaises(ConnectionError):  # closed by the pooler, not a read that timed out
            a.query("select 1")
            a.query("select 1")
        time.sleep(0.5)
        self.assertEqual(b.one("select 1"), "1")
        c = self.client()
        self.assertEqual(c.one("select 3"), "3")

    def test_a_client_that_never_reads_does_not_stop_the_others(self):
        slow = self.client()
        slow.raw(msg(b"Q", b"select repeat('x', 1000000) from generate_series(1, 30)\0"))  # 30 MB it will not read
        time.sleep(0.5)
        fast = self.client()
        self.assertEqual(fast.one("select 5"), "5")


class Volume(PoolerCase):
    size = 4

    def test_a_large_result_arrives_whole(self):
        a = self.client()
        rows, errors, tags, statuses, _ = a.query("select i, repeat('y', 200) from generate_series(1, 50000) i")
        self.assertEqual(len(rows), 50000)
        self.assertEqual(rows[49999][0], "50000")
        self.assertEqual(statuses, ["I"])

    def test_a_slow_server_pushes_back_on_a_client_that_keeps_sending_and_nothing_is_lost(self):
        a = self.client()
        # The server is busy for two seconds and does not read; the client has already sent 6 MB behind it, more than every buffer between them holds.
        a.raw(msg(b"Q", b"select pg_sleep(2)\0") + msg(b"Q", ("select length('%s')" % ("z" * 6000000)).encode() + b"\0") + msg(b"Q", b"select 99\0"))
        a.s.settimeout(20)
        rows, errors, tags, statuses, _ = a.until_ready(3)
        self.assertEqual((errors, statuses), ([], ["I", "I", "I"]))
        self.assertEqual([r for r in rows if r != [""]], [["6000000"], ["99"]])

    def test_a_large_query_arrives_whole(self):
        a = self.client()
        self.assertEqual(a.one("select length('%s')" % ("x" * 5000000)), "5000000")
        rows, errors, tags, statuses, _ = a.extended("select length($1::text)", ["y" * 3000000])
        self.assertEqual((rows, errors), ([["3000000"]], []))

    def test_many_clients_on_few_connections_all_get_their_own_answers(self):
        results, errors = {}, []

        def work(i):
            try:
                c = Client(self.pooler.port)
                for j in range(20):
                    r = c.one("select %d * 1000 + %d" % (i, j))
                    assert r == str(i * 1000 + j), (i, j, r)
                results[i] = True
                c.close()
            except Exception as e:  # noqa
                errors.append(repr(e))
        ts = [threading.Thread(target=work, args=(i,)) for i in range(60)]
        [t.start() for t in ts]
        [t.join(30) for t in ts]
        self.assertEqual(errors, [])
        self.assertEqual(len(results), 60)
        self.assertLessEqual(int(admin("select count(*) from pg_stat_activity where datname = '%s' and pid <> pg_backend_pid()" % DB)), 5)


class Hostile(PoolerCase):
    size = 2

    def alive(self):
        c = Client(self.pooler.port)
        self.assertEqual(c.one("select 1"), "1")
        c.close()

    def test_garbage_before_during_and_after_the_startup(self):
        cases = [b"", b"\0", b"\0\0\0\0", struct.pack("!ii", 0, 0), struct.pack("!ii", 3, 196608), struct.pack("!ii", 2**31 - 1, 196608), struct.pack("!ii", 100000, 196608), b"GET / HTTP/1.1\r\n\r\n",
                 struct.pack("!ii", 8, 12345), struct.pack("!ii", 8, 80877102), struct.pack("!ii", 12, 196608) + b"user", os.urandom(300)]
        for data in cases:
            s = socket.create_connection(("127.0.0.1", self.pooler.port), 5)
            s.sendall(data)
            s.settimeout(0.3)
            try:
                s.recv(4096)
            except OSError:
                pass
            s.close()
        self.alive()

    def test_garbage_after_a_good_startup(self):
        for data in [b"Q", b"Q\0\0\0\3", b"Q\xff\xff\xff\xff", b"Z" * 100, b"\0" * 100, b"P\0\0\0\4", os.urandom(500), b"Q\0\0\0\x08ab\0\0\0\0"]:
            c = Client(self.pooler.port)
            c.raw(data)
            c.s.settimeout(0.3)
            try:
                c.s.recv(4096)
            except OSError:
                pass
            c.s.close()
        self.alive()

    def test_connections_that_open_and_close_and_say_nothing(self):
        for _ in range(500):
            s = socket.create_connection(("127.0.0.1", self.pooler.port), 5)
            s.close()
        quiet = [socket.create_connection(("127.0.0.1", self.pooler.port), 5) for _ in range(50)]
        self.alive()
        for s in quiet:
            s.close()
        self.alive()

    def test_more_clients_than_the_limit_are_turned_away_and_the_pooler_survives(self):
        socks = []
        try:
            for _ in range(260):
                try:
                    socks.append(socket.create_connection(("127.0.0.1", self.pooler.port), 2))
                except OSError:
                    break
        finally:
            for s in socks:
                s.close()
        time.sleep(0.3)
        self.alive()


class Authentication(unittest.TestCase):
    PASSWORD = "correct horse battery staple"

    def setUp(self):
        self.pooler = Pooler(2, client_password=self.PASSWORD)
        self.addCleanup(self.pooler.stop)

    def login(self, password=None, mutate=None):
        c = Client(self.pooler.port, password=self.PASSWORD if password is None else password, mutate=mutate)
        self.addCleanup(c.close)
        return c

    def refused(self, code, **kw):
        with self.assertRaises(AuthError) as ctx:
            self.login(**kw)
        self.assertEqual(ctx.exception.args[0]["C"], code)
        self.alive()

    def alive(self):
        self.assertEqual(self.login().one("select 41 + 1"), "42")

    def test_the_right_password_logs_in_and_the_server_signature_is_the_one_only_the_pooler_can_make(self):
        c = self.login()
        self.assertEqual(c.startup[3], ["I"])
        self.assertEqual(c.one("select current_user"), USER)

    def test_libpq_logs_in_with_the_right_password_and_not_with_a_wrong_or_no_one(self):
        env = dict(os.environ, PGPASSWORD=self.PASSWORD)
        r = subprocess.run(["psql", "-h", "127.0.0.1", "-p", str(self.pooler.port), "-U", USER, "-d", DB, "-Atc", "select 'libpq', 1 + 1"], capture_output=True, text=True, env=env)
        self.assertEqual(r.stdout.strip(), "libpq|2", r.stderr)
        bad = subprocess.run(["psql", "-h", "127.0.0.1", "-p", str(self.pooler.port), "-U", USER, "-d", DB, "-Atc", "select 1"], capture_output=True, text=True, env=dict(os.environ, PGPASSWORD="wrong"))
        self.assertNotEqual(bad.returncode, 0)
        self.assertIn("password authentication failed", bad.stderr)
        none = subprocess.run(["psql", "-w", "-h", "127.0.0.1", "-p", str(self.pooler.port), "-U", USER, "-d", DB, "-Atc", "select 1"], capture_output=True, text=True, env={k: v for k, v in os.environ.items() if k != "PGPASSWORD"})
        self.assertNotEqual(none.returncode, 0)
        self.alive()

    def test_pgbench_logs_in_through_it(self):
        r = subprocess.run(["pgbench", "-h", "127.0.0.1", "-p", str(self.pooler.port), "-U", USER, "-S", "-c", "4", "-j", "1", "-T", "1", DB], capture_output=True, text=True, env=dict(os.environ, PGPASSWORD=self.PASSWORD))
        self.assertIn("number of failed transactions: 0", r.stdout, r.stderr)

    def test_a_wrong_password_is_refused_in_the_servers_words(self):
        self.refused("28P01", password="wrong")
        self.refused("28P01", password=self.PASSWORD + " ")
        self.refused("28P01", password="")

    def test_a_proof_with_one_bit_changed_is_refused(self):
        self.refused("28P01", mutate="tampered_proof")

    def test_a_final_message_with_another_nonce_or_no_proof_is_refused(self):
        self.refused("28P01", mutate="wrong_nonce")
        self.refused("08P01", mutate="no_proof")

    def test_a_proof_replayed_from_another_session_is_refused(self):
        first = self.login()
        REPLAY[0] = first.captured[1]
        REPLAY[1] = first.captured[0]
        self.refused("28P01", mutate="replay")

    def test_channel_binding_and_the_plus_mechanism_are_not_offered(self):
        self.refused("28000", mutate="channel_binding")
        self.refused("28000", mutate="plus")
        self.refused("28P01", mutate="bad_binding_flag")

    def test_a_client_that_does_not_answer_the_password_request_with_a_password_is_refused(self):
        for first in [msg(b"Q", b"select 1\0"), msg(b"X"), b"\0\0\0\0\0", msg(b"p", b""), b"p\xff\xff\xff\xff", msg(b"p", b"SCRAM-SHA-256\0\0\0\0\x05n,,n"), msg(b"p", b"SCRAM-SHA-256\0" + struct.pack("!i", 1000) + b"n,,n=,r=abc"), os.urandom(200)]:
            s = socket.create_connection(("127.0.0.1", self.pooler.port), 5)
            body = struct.pack("!i", 196608) + b"user\0" + USER.encode() + b"\0database\0" + DB.encode() + b"\0\0"
            s.sendall(struct.pack("!i", len(body) + 4) + body)
            s.recv(4096)
            s.sendall(first)
            s.settimeout(1)
            try:
                s.recv(4096)
            except OSError:
                pass
            s.close()
        self.alive()

    def test_a_password_exchange_cut_off_at_any_byte_leaves_the_pooler_answering(self):
        cnonce = base64.b64encode(os.urandom(18)).decode()
        first = ("n,,n=,r=" + cnonce).encode()
        whole = struct.pack("!i", 196608) + b"user\0" + USER.encode() + b"\0database\0" + DB.encode() + b"\0\0"
        stream = struct.pack("!i", len(whole) + 4) + whole + msg(b"p", b"SCRAM-SHA-256\0" + struct.pack("!i", len(first)) + first)
        for cut in range(1, len(stream), 3):
            s = socket.create_connection(("127.0.0.1", self.pooler.port), 5)
            s.sendall(stream[:cut])
            time.sleep(0.002)
            s.close()
        self.alive()

    def test_clients_that_start_the_exchange_and_stop_do_not_stop_others(self):
        socks = []
        for _ in range(50):
            s = socket.create_connection(("127.0.0.1", self.pooler.port), 5)
            body = struct.pack("!i", 196608) + b"user\0" + USER.encode() + b"\0database\0" + DB.encode() + b"\0\0"
            s.sendall(struct.pack("!i", len(body) + 4) + body)
            socks.append(s)
        self.alive()
        for s in socks:
            s.close()
        self.alive()

    def test_without_a_client_password_clients_are_not_asked_for_one(self):
        p = Pooler(1)
        self.addCleanup(p.stop)
        c = Client(p.port)
        self.assertEqual(c.one("select 5"), "5")
        c.close()


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]] + sys.argv[1:], verbosity=2)
