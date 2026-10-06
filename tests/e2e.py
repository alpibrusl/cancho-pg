#!/usr/bin/env python3
"""End-to-end tests of `pg` against a real PostgreSQL, through examples/psql.ls.

    PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGDATABASE=postgres python3 tests/e2e.py
    LEX_SYS=/path/to/lex-sys   (default: lex-sys on PATH)       BIN=build/psql  (skip the build)

The reference is the stock `psql` client: for every query in `QUERIES` both clients are
run and must print the same rows (`psql -At -F '|' -P null='\\N'` and psql.ls print the
same format). They are the same bytes only if `pg` decodes every message the server sends
for these types and sizes -- 20,000 rows and a 100,000-character value cross many reads --
which is what a hand-written wire-protocol decoder is most likely to get wrong.

Needs trust authentication for the user above. The cleartext-password test runs only when
PG_CLEARTEXT_USER / PG_CLEARTEXT_PASSWORD / PG_CLEARTEXT_DB name a role the server asks a
password of (pg_hba.conf method `password`). The SCRAM-SHA-256 tests run for each of
PG_SCRAM_* and PG_SCRAM_UNICODE_* (_USER, _PASSWORD, _DB) that is set: roles whose pg_hba.conf
method is `scram-sha-256`; the second has a non-ASCII password.
"""
import os
import subprocess
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOST = os.environ.get("PGHOST", "127.0.0.1")
PORT = os.environ.get("PGPORT", "5432")
USER = os.environ.get("PGUSER", "postgres")
DB = os.environ.get("PGDATABASE", "postgres")
BIN = os.environ.get("BIN")


DESCRIBE = None
PGEN = None
GEN_USE = None
POOL_DRIVE = None


def deps():
    """The sources `lex-sys install` wrote for lex-sys.toml's dependencies (the `tls` package and what it requires)."""
    d = os.path.join(ROOT, "build", "deps")
    files = sorted(os.path.join(d, f) for f in os.listdir(d) if f.endswith(".ls")) if os.path.isdir(d) else []
    if not files:
        raise SystemExit("build/deps is empty: run `lex-sys install` first")
    return files


def build():
    global BIN, DESCRIBE, PGEN, GEN_USE, POOL_DRIVE
    lex = os.environ.get("LEX_SYS", "lex-sys")
    os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
    def one(name):
        out = os.path.join(ROOT, "build", name)
        subprocess.run([lex, "build", "--std", os.path.join(ROOT, "examples", name + ".ls"),
                        os.path.join(ROOT, "src", "pg.ls"), "-o", out], check=True)
        return out
    BIN = BIN or one("psql")
    DESCRIBE = one("describe")
    lex_files = lambda out, main, *more: subprocess.run(
        [lex, "build", "--std", main, *more, os.path.join(ROOT, "src", "pg.ls"), "-o", out], check=True)
    PGEN = os.path.join(ROOT, "build", "pgen")
    lex_files(PGEN, os.path.join(ROOT, "tools", "pgen.ls"))
    # the program that uses the *checked-in* generated module, so a stale one is a failure
    GEN_USE = os.path.join(ROOT, "build", "gen_use")
    lex_files(GEN_USE, os.path.join(ROOT, "tests", "gen_use.ls"), os.path.join(ROOT, "tests", "generated", "queries.ls"))
    POOL_DRIVE = os.path.join(ROOT, "build", "pool_drive")
    # `pg.pool` takes lex-sys's `tls` package (docs/tls.md): `lex-sys install` puts its sources in build/deps
    lex_files(POOL_DRIVE, os.path.join(ROOT, "tests", "pool_drive.ls"), os.path.join(ROOT, "src", "pool.ls"), *deps())


def describe(sql, user=USER, db=DB):
    p = subprocess.run([DESCRIBE, HOST, PORT, user, db, "-", sql], capture_output=True, text=True, timeout=60)
    return p.stdout, p.returncode


def ours(sql, *params, user=USER, db=DB, password="-"):
    """(stdout, exit status) of psql.ls."""
    p = subprocess.run([BIN, HOST, PORT, user, db, password, sql, *params],
                       capture_output=True, text=True, timeout=60)
    return p.stdout, p.returncode


def rows_of(stdout):
    """Our output without the `# tag` lines (psql -At prints the tags to stderr-less stdout
    too, differently) and the error lines."""
    return "".join(l for l in stdout.splitlines(True) if not l.startswith("# ") and not l.startswith("ERROR "))


def psql(sql):
    env = dict(os.environ, PGPASSWORD="")
    p = subprocess.run(["psql", "-h", HOST, "-p", PORT, "-U", USER, "-d", DB, "-X", "-q", "-At", "-F", "|",
                        "-P", "null=\\N", "-c", sql], capture_output=True, text=True, env=env, timeout=60)
    return p.stdout


QUERIES = [
    "select 1",
    "select 1 as n, 'hello' as s",
    "select null",
    "select null::int, null::text, 'x'",
    "select ''::text, 'a', ''::text",
    "select 'h\u00e9llo w\u00f6rld \u2603 \U0001F600'",
    "select 2147483647::int, (-2147483648)::int, 9223372036854775807::bigint, (-9223372036854775808)::bigint",
    "select 1.5::float8, 1e100::float8, 'NaN'::float8, 'Infinity'::float8, 0.1::float4",
    "select 12345678901234567890.123456789::numeric, 0::numeric, -0.000001::numeric",
    "select true, false, null::bool",
    "select 'a\tb'::text, E'line1\\nline2'::text",
    "select date '2024-02-29', timestamp '2024-02-29 13:14:15.678', timestamptz '2024-02-29 13:14:15+00', interval '1 year 2 mons 3 days 04:05:06'",
    "select '\\xdeadbeef'::bytea, '\\x'::bytea",
    "select 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid",
    "select array[1,2,3], array['a',null,'c'], '{}'::int[], array[[1,2],[3,4]]",
    "select '{\"a\": [1, 2, {\"b\": null}], \"s\": \"x\"}'::json, '{\"a\":  [1,2]}'::jsonb",
    "select '[1,5)'::int4range, 'inet'::text, '10.0.0.1/24'::inet, '08:00:2b:01:02:03'::macaddr",
    "select repeat('x', 100000), length(repeat('y', 100000))",
    "select generate_series(1, 20000)",
    "select i, 'row ' || i, i * 1.5 from generate_series(1, 5000) i",
    "select * from generate_series(1, 0)",
    "select " + ", ".join("%d" % i for i in range(1, 301)),
    "select 1; select 'two'; select 3, 4",
    "select s.i, t.i from generate_series(1,3) s(i) cross join generate_series(10,12) t(i)",
    "select pg_typeof(1), pg_typeof('a'), pg_typeof(1.5), pg_typeof(now()), pg_typeof(array[1])",
    "select version() ~ 'PostgreSQL'",
    "select current_setting('server_encoding'), current_setting('standard_conforming_strings')",
    "show server_version_num",
    "select 'it''s', '\\', '\"quoted\"', '%s %d', '$1'",
]


NO_ROWS = {"select * from generate_series(1, 0)"}


class Differential(unittest.TestCase):
    def test_same_rows_as_psql(self):
        for sql in QUERIES:
            want = psql(sql)
            got, status = ours(sql)
            self.assertEqual(status, 0, sql)
            # a query that fails on both sides prints nothing on both and would agree vacuously
            self.assertNotIn("ERROR ", got, sql[:80])
            if sql not in NO_ROWS:
                self.assertNotEqual(want, "", "the reference printed nothing: " + sql[:80])
            self.assertEqual(rows_of(got), want, sql[:80])


class Commands(unittest.TestCase):
    def test_tags_and_errors(self):
        out, st = ours("create temp table t(a int); insert into t values (1),(2),(3); update t set a = a + 1; "
                       "delete from t where a > 2; select count(*) from t")
        self.assertEqual(st, 0)
        self.assertEqual(out, "# CREATE TABLE\n# INSERT 0 3\n# UPDATE 3\n# DELETE 2\n1\n# SELECT 1\n")
        # the server parses the whole string before running any of it: a syntax error runs nothing
        out, st = ours("select 1; selec 2; select 3")
        self.assertEqual(out, "ERROR 42601: syntax error at or near \"selec\"\n")
        # a runtime error stops the string where it happens: the statement before it ran, the one after did not
        out, st = ours("select 1; select 1/0; select 3")
        self.assertEqual(out, "1\n# SELECT 1\nERROR 22012: division by zero\n")
        out, _ = ours("select * from no_such_table")
        self.assertEqual(out, 'ERROR 42P01: relation "no_such_table" does not exist\n')
        out, _ = ours("select 1/0")
        self.assertEqual(out, "ERROR 22012: division by zero\n")
        out, _ = ours("select 'a'::int")
        self.assertTrue(out.startswith("ERROR 22P02: invalid input syntax for type integer"), out)
        out, st = ours("")
        self.assertEqual((out, st), ("", 0))


class Parameters(unittest.TestCase):
    def test_typed_and_untyped(self):
        out, st = ours("select $1::int + $2::int, $3::text", "40", "2", "x")
        self.assertEqual((out, st), ("42|x\n# SELECT 1\n", 0))
        out, _ = ours("select $1, $2", "abc", "7")
        self.assertEqual(out, "abc|7\n# SELECT 1\n")

    def test_null_and_empty_are_different(self):
        out, _ = ours("select $1::text is null, $2::text is null, $2::text = ''", "\\N", "")
        self.assertEqual(out, "t|f|t\n# SELECT 1\n")
        out, _ = ours("select $1::text, $2::text", "\\N", "")
        self.assertEqual(out, "\\N|\n# SELECT 1\n")

    def test_a_value_is_never_sql(self):
        for hostile in ["'; drop table pg_e2e_victim; --", "x' or '1'='1", "\\", "$1", "%s", "a\nb", "h\u00e9llo \U0001F600"]:
            out, st = ours("select $1::text, length($1::text)", hostile)
            self.assertEqual(st, 0)
            self.assertEqual(out, "%s|%d\n# SELECT 1\n" % (hostile, len(hostile)), hostile)

    def test_write_then_read_back_through_the_reference_client(self):
        table = "pg_e2e_%d" % os.getpid()
        env = dict(os.environ, PGPASSWORD="")
        def run(sql):
            return subprocess.run(["psql", "-h", HOST, "-p", PORT, "-U", USER, "-d", DB, "-X", "-q", "-At", "-F", "|",
                                   "-P", "null=\\N", "-c", sql], capture_output=True, text=True, env=env).stdout
        run("create table %s (id serial primary key, name text, age int)" % table)
        try:
            for name, age in [("Ada", "36"), ("O'Brien; drop table x", "\\N"), ("", "0"), ("h\u00e9llo \U0001F600", "7")]:
                out, st = ours("insert into %s (name, age) values ($1, $2::int) returning id" % table, name, age)
                self.assertEqual(st, 0, out)
                self.assertTrue(out.startswith("1|") is False and out.endswith("# INSERT 0 1\n"), out)
            self.assertEqual(run("select name, age from %s order by id" % table),
                             "Ada|36\nO'Brien; drop table x|\\N\n|0\nh\u00e9llo \U0001F600|7\n")
        finally:
            run("drop table %s" % table)


class Describe(unittest.TestCase):
    """The server's own account of a statement's types, without running it."""

    def test_parameters_and_columns(self):
        out, st = describe("select $1::int as n, $2::text as s, now() as t, $3::bool, 1 + $1::int")
        self.assertEqual((out, st), ("$1 23\n$2 25\n$3 16\nn 23\ns 25\nt 1184\nbool 16\n?column? 23\n", 0))

    def test_oids_are_the_servers(self):
        # every oid printed is a real type of this server: ask psql what they are
        out, _ = describe("select 1::int2, 1::int8, 1.5::numeric, 'a'::varchar, now()::date, '{}'::jsonb, '\\x'::bytea")
        want = {}
        for line in psql("select oid, typname from pg_type where typname in ('int2','int8','numeric','varchar','date','jsonb','bytea')").splitlines():
            oid, name = line.split("|")
            want[name] = int(oid)
        got = [int(l.split()[-1]) for l in out.splitlines()]
        self.assertEqual(got, [want[n] for n in ("int2", "int8", "numeric", "varchar", "date", "jsonb", "bytea")])

    def test_a_statement_without_rows_and_a_bad_one(self):
        self.assertEqual(describe("create table pg_e2e_never_created (a int)"), ("", 0))
        out, _ = describe("select * from no_such_table")
        self.assertEqual(out, 'ERROR 42P01: relation "no_such_table" does not exist\n')
        out, _ = describe("select $1 + $2")   # two parameters whose types cannot be resolved
        self.assertTrue(out.startswith("ERROR 42725: "), out)
        out, _ = describe("select $1")        # a lone parameter is resolved as text
        self.assertEqual(out, "$1 25\n?column? 25\n")


class Connections(unittest.TestCase):
    def test_nothing_listening(self):
        p = subprocess.run([BIN, "127.0.0.1", "1", USER, DB, "-", "select 1"], capture_output=True, text=True)
        self.assertEqual(p.returncode, 103)

    def test_bad_arguments(self):
        p = subprocess.run([BIN, HOST, PORT], capture_output=True, text=True)
        self.assertEqual(p.returncode, 100)

    def test_unknown_database_is_an_error_not_a_hang(self):
        out, st = ours("select 1", db="no_such_database_here")
        self.assertEqual(st, 4)
        self.assertTrue(out.startswith("ERROR 3D000: "), out)

    @unittest.skipUnless(os.environ.get("PG_CLEARTEXT_USER"), "needs a role the server asks a cleartext password of")
    def test_cleartext_password(self):
        user, secret, db = os.environ["PG_CLEARTEXT_USER"], os.environ["PG_CLEARTEXT_PASSWORD"], os.environ["PG_CLEARTEXT_DB"]
        out, st = ours("select current_user", user=user, db=db, password=secret)
        self.assertEqual((out, st), (user + "\n# SELECT 1\n", 0))
        out, st = ours("select 1", user=user, db=db, password="not the password")
        self.assertEqual(st, 4)
        self.assertTrue(out.startswith("ERROR 28P01: "), out)
        out, st = ours("select 1", user=user, db=db, password="-")
        self.assertEqual(st, 4)

    def scram_roles(self):
        found = []
        for prefix in ("PG_SCRAM", "PG_SCRAM_UNICODE"):
            if os.environ.get(prefix + "_USER"):
                found.append((os.environ[prefix + "_USER"], os.environ[prefix + "_PASSWORD"], os.environ[prefix + "_DB"]))
        return found

    def test_scram_sha_256(self):
        roles = self.scram_roles()
        if not roles:
            self.skipTest("needs a role the server asks SCRAM-SHA-256 of (PG_SCRAM_USER, _PASSWORD, _DB)")
        for user, secret, db in roles:
            # the right password logs in, and the server says who it thinks we are
            out, st = ours("select current_user, 1 as n", user=user, db=db, password=secret)
            self.assertEqual((out, st), (user + "|1\n# SELECT 1\n", 0), user)
            # the same through the reference client, so a role that psql cannot log in to is not blamed on us
            ref = subprocess.run(["psql", "-At", "-F", "|", "-c", "select current_user"],
                                 env={**os.environ, "PGHOST": HOST, "PGPORT": PORT, "PGUSER": user, "PGDATABASE": db, "PGPASSWORD": secret},
                                 capture_output=True, text=True, timeout=60)
            self.assertEqual(ref.stdout, user + "\n", ref.stderr)
            # queries after the handshake work like any other (the SCRAM messages must not leave a byte behind)
            out, st = ours("select $1::int + $2::int", "40", "2", user=user, db=db, password=secret)
            self.assertEqual((out, st), ("42\n# SELECT 1\n", 0))
            # the wrong password, a near miss, and none at all are refused by the server
            for bad in (secret + "x", secret[:-1], secret.upper() if secret.upper() != secret else secret + " ", "-", "x"):
                out, st = ours("select 1", user=user, db=db, password=bad)
                self.assertEqual(st, 4, (user, bad, out))
                self.assertTrue(out.startswith("ERROR 28P01: "), out)

    def test_scram_logins_use_a_fresh_nonce(self):
        """Two handshakes must not be the same conversation: capture what the client sends."""
        roles = self.scram_roles()
        if not roles:
            self.skipTest("needs a SCRAM role")
        import socket, threading
        user, secret, db = roles[0]
        seen = []

        def tap(listener):
            conn, _ = listener.accept()
            up = socket.create_connection((HOST, int(PORT)))
            def pump(a, b, record):
                try:
                    while True:
                        d = a.recv(65536)
                        if not d:
                            break
                        if record:
                            seen.append(d)
                        b.sendall(d)
                except OSError:
                    pass
                finally:
                    for x in (a, b):
                        try:
                            x.shutdown(socket.SHUT_RDWR)
                        except OSError:
                            pass
            t = threading.Thread(target=pump, args=(up, conn, False), daemon=True)
            t.start()
            pump(conn, up, True)
            t.join(5)
            conn.close()
            up.close()

        nonces = []
        for _ in range(2):
            lis = socket.socket()
            lis.bind(("127.0.0.1", 0))
            lis.listen(1)
            th = threading.Thread(target=tap, args=(lis,), daemon=True)
            th.start()
            seen.clear()
            p = subprocess.run([BIN, "127.0.0.1", str(lis.getsockname()[1]), user, db, secret, "select 1"],
                               capture_output=True, text=True, timeout=60)
            th.join(10)
            lis.close()
            self.assertEqual(p.returncode, 0, p.stdout)
            blob = b"".join(seen)
            # SASLInitialResponse: 'p', int32 length, mechanism\0, int32 data length, data
            at = blob.index(b"SCRAM-SHA-256\0") + len(b"SCRAM-SHA-256\0")
            size = int.from_bytes(blob[at:at + 4], "big")
            first = blob[at + 4:at + 4 + size]
            self.assertTrue(first.startswith(b"n,,n=,r="), first)
            nonce = first[len(b"n,,n=,r="):]
            self.assertGreaterEqual(len(nonce), 24, nonce)
            nonces.append(nonce)
        self.assertNotEqual(nonces[0], nonces[1])


def sql(text, db=DB, user=USER):
    """Run SQL through the reference client; (stdout, exit status)."""
    p = subprocess.run(["psql", "-At", "-v", "ON_ERROR_STOP=1", "-F", "|", "-c", text],
                       env={**os.environ, "PGHOST": HOST, "PGPORT": PORT, "PGUSER": user, "PGDATABASE": db},
                       capture_output=True, text=True, timeout=60)
    return p.stdout, p.returncode


def pgen(queries_path, db=DB):
    """(stdout, stderr, exit status) of the generator."""
    p = subprocess.run([PGEN, HOST, PORT, USER, db, "-", queries_path], capture_output=True, text=True, timeout=60)
    return p.stdout, p.stderr, p.returncode


class Generator(unittest.TestCase):
    """`tools/pgen.ls`: typed queries from SQL, by asking the server to describe each statement."""

    QUERIES = os.path.join(ROOT, "tests", "queries.sql")
    GENERATED = os.path.join(ROOT, "tests", "generated", "queries.ls")

    @classmethod
    def setUpClass(cls):
        p = subprocess.run(["psql", "-q", "-v", "ON_ERROR_STOP=1", "-f", os.path.join(ROOT, "tests", "schema.sql")],
                           env={**os.environ, "PGHOST": HOST, "PGPORT": PORT, "PGUSER": USER, "PGDATABASE": DB},
                           capture_output=True, text=True)
        assert p.returncode == 0, p.stderr
        out, st = sql("insert into gen_users (name, age, active, balance, nickname) values "
                      "('ann', 30, true, 1234, 'zed'), ('cy', null, false, 0, null) returning id")
        assert st == 0, out

    def test_the_checked_in_module_is_what_the_generator_writes(self):
        out, err, st = pgen(os.path.join("tests", "queries.sql"))
        self.assertEqual(st, 0, err)
        with open(self.GENERATED) as f:
            self.assertEqual(out, f.read(), "tests/generated/queries.ls is stale: regenerate it with pgen")

    def test_generated_functions_run_and_read_back(self):
        # a fresh seed each time: the scenario inserts and renames
        self.setUpClass()
        p = subprocess.run([GEN_USE, HOST, PORT, USER, DB, "-", "2"], capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(p.stdout, "\n".join([
            "count 2",
            "user 1: ann age=30 active nickname=zed",
            "user 2: cy age=NULL inactive nickname=NULL",
            "user 99999: no row",
            "added 3 affected 1",
            "user 3: dee'; drop table gen_users; -- age=41 active nickname=NULL",
            "renamed affected 1",
            "user 3: renamed age=41 active nickname=NULL",
            "older 1 ann",
            "older 3 renamed",
            "nickname zed: 1",
            "nickname nobody: none",
            "details balance=1234 joined=2024-05-06 07:08:09+00 next_age=31",
            "details next_age=NULL",
            "add_post ERROR 23503",
            "add_post affected 1",
            "post first post by ann",
            "user 4: eve age=NULL active nickname=nick",
            "user 5: fay age=0 active nickname=",
            "user 6: gus age=NULL active nickname=NULL",
            'tricky [say "hi" \\ back] [two',
            "lines]",
            ""]))
        # what the generated functions wrote, as the reference client reads it: the table is still
        # there, the hostile name was data, and the rename took
        out, st = sql("select id, name, age, active, coalesce(nickname, '<null>') from gen_users order by id")
        self.assertEqual(out, "1|ann|30|t|zed\n2|cy||f|<null>\n3|renamed|41|t|<null>\n4|eve||t|nick\n5|fay|0|t|\n6|gus||t|<null>\n")
        out, st = sql("select user_id, title from gen_posts")
        self.assertEqual(out, "1|first post\n")

    def test_a_query_that_was_not_prepared_is_the_servers_26000_not_a_hang(self):
        self.setUpClass()
        p = subprocess.run([GEN_USE, HOST, PORT, USER, DB, "-", "2", "unprepared"], capture_output=True, text=True, timeout=60)
        self.assertEqual((p.stdout, p.returncode), ("count_users ERROR 26000\n", 0), p.stderr)

    def test_prepare_all_refuses_when_the_schema_no_longer_fits_the_queries(self):
        # The module was generated against a schema where `active` exists, and only the *first* query uses
        # it. Prepared on a database where it does not, the server refuses that one, `prepare_all` reports
        # it -- and must not let the successful prepares after it hide the refusal -- and nothing is run.
        self.setUpClass()
        out, st = sql("alter table gen_users rename column active to alive")
        self.assertEqual(st, 0, out)
        try:
            p = subprocess.run([GEN_USE, HOST, PORT, USER, DB, "-", "2"], capture_output=True, text=True, timeout=60)
            self.assertEqual((p.stdout, p.returncode), ("", 7), p.stderr)
        finally:
            sql("alter table gen_users rename column alive to active")

    def test_each_connection_prepares_its_own_statements(self):
        # statement names are per connection: two programs at once, each preparing every name, do not collide
        self.setUpClass()
        procs = [subprocess.Popen([GEN_USE, HOST, PORT, USER, DB, "-", "2"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                 for _ in range(3)]
        outs = [pr.communicate(timeout=60) for pr in procs]
        for pr, (out, err) in zip(procs, outs):
            self.assertEqual(pr.returncode, 0, out + err)
            self.assertTrue(out.startswith("count "), out)

    def generated(self, queries, check=True):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            q = os.path.join(d, "t.sql")
            with open(q, "w") as f:
                f.write(queries)
            out, err, st = pgen(q)
            if st == 0 and check:
                m = os.path.join(d, "t.ls")
                with open(m, "w") as f:
                    f.write(out)
                lex = os.environ.get("LEX_SYS", "lex-sys")
                c = subprocess.run([lex, "check", "--std", m, os.path.join(ROOT, "src", "pg.ls")],
                                   capture_output=True, text=True)
                # a module with no `main` is complete: that is the one thing a check may say
                self.assertEqual(c.stdout + c.stderr.replace(m, "t.ls").replace(os.path.join(ROOT, "src", "pg.ls"), "pg.ls"),
                                 "t.ls: error: no `main` function\n", "the generated module does not compile:\n" + out)
            return out, err, st

    def test_types_come_from_the_server(self):
        out, err, st = self.generated(
            "-- name: kinds a b c d e f g\n"
            "select $1::bool as flag, $2::int2 as small, $3::int8 as big, $4::oid as o, $5::uuid as u, "
            "$6::timestamptz as t, $7::numeric as n")
        self.assertEqual(st, 0, err)
        self.assertIn("a: bool, b: int, c: int, d: int, e: &a5 [byte], f: &a6 [byte], g: &a7 [byte])", out.replace("conn: &!c Conn, ", ""))
        self.assertIn("pub fn kinds_flag[&m](m: &m [byte], row: int) -> [] bool", out)
        for name in ("small", "big", "o"):
            self.assertIn(f"pub fn kinds_{name}[&m](m: &m [byte], row: int) -> [] int", out)
        for name in ("u", "t", "n"):
            self.assertIn(f"pub fn kinds_{name}[&m](m: &m [byte], row: int) -> [] (int, int)", out)
        # no parameter names given: p1, p2, ...
        out, err, st = self.generated("-- name: pair\nselect $1::int + $2::int as s")
        self.assertIn("p1: int, p2: int", out)
        # `?`: an optional parameter is followed by its flag, and is NULL when the flag is false
        out, err, st = self.generated("-- name: maybe a? b c?\nselect $1::int + $2::int + $3::int as s")
        self.assertEqual(st, 0, err)
        self.assertIn(", a: int, a_given: bool, b: int, c: int, c_given: bool)", out)
        self.assertIn("    if a_given {\n        ps = pg.param_int(heap, ps, a);\n    } else {\n        ps = pg.param_null(heap, ps);\n    }\n", out)
        self.assertIn("    ps = pg.param_int(heap, ps, b);\n", out)

    def test_nullability_is_the_catalogue_and_a_join_forgets_it(self):
        out, err, st = self.generated(
            "-- name: plain\nselect id, name, age from gen_users\n"
            "-- name: joined\nselect u.id, p.title from gen_users u left join gen_posts p on p.user_id = u.id\n"
            "-- name: a_column_named_joined\nselect id as joined_at, balance as joined from gen_users\n")
        self.assertEqual(st, 0, err)
        # NOT NULL columns: no `_is_null`; a nullable one has it
        self.assertNotIn("plain_id_is_null", out)
        self.assertNotIn("plain_name_is_null", out)
        self.assertIn("plain_age_is_null", out)
        # an outer join can make a NOT NULL column NULL, and the server does not say: all nullable
        self.assertIn("joined_id_is_null", out)
        self.assertIn("joined_title_is_null", out)
        # ... but `joined` as a name is not a join
        self.assertNotIn("a_column_named_joined_joined_is_null", out)

    def test_what_is_refused_is_refused_with_a_reason_and_nothing_is_written(self):
        cases = [
            ("syntax error from the server", "-- name: q\nselect from from", "42601"),
            ("a table that does not exist", "-- name: q\nselect * from no_such_table_here", "42P01"),
            ("a name used twice", "-- name: q\nselect 1 as a\n-- name: q\nselect 2 as b", "used twice"),
            ("a column that is not an identifier", "-- name: q\nselect 1", "plain identifier"),
            ("a column that needs quotes", '-- name: q\nselect 1 as "Bad Name"', "plain identifier"),
            ("two columns with one name", "-- name: q\nselect 1 as a, 2 as a", "same function name"),
            ("a name that is not an identifier", "-- name: Bad-Name\nselect 1 as a", "lower-case letters"),
            ("too few parameter names", "-- name: q a\nselect $1::int + $2::int as s", "different number"),
            ("a parameter named like the connection", "-- name: q conn\nselect $1::int as s", "`conn`"),
            ("a parameter name twice", "-- name: q x x\nselect $1::int + $2::int as s", "not repeated"),
            ("no statement", "-- name: q\n", "no statement"),
            ("no queries at all", "select 1", "no queries"),
            ("two statements", "-- name: q\nselect 1 as a; select 2 as b", "42601"),
            ("an optional parameter's flag taken by an earlier parameter", "-- name: q a_given a?\nselect $1::int + $2::int as s", "_given"),
            ("an optional parameter's flag taken by a later parameter", "-- name: q a? a_given\nselect $1::int + $2::int as s", "_given"),
            ("a column and a query with one name", "-- name: q_a\nselect 1 as x\n-- name: q\nselect 1 as a", "same function name"),
        ]
        for what, queries, reason in cases:
            out, err, st = self.generated(queries, check=False)
            self.assertNotEqual(st, 0, what)
            self.assertEqual(out, "", what + ": a refused file must write nothing")
            self.assertIn(reason, err, what)
        # one bad query among good ones: still nothing
        out, err, st = self.generated("-- name: ok\nselect 1 as a\n-- name: bad\nselect * from no_such_table_here", check=False)
        self.assertNotEqual(st, 0)
        self.assertEqual(out, "")

    def test_a_file_that_cannot_be_read_or_a_database_that_is_not_there(self):
        out, err, st = pgen("/no/such/queries.sql")
        self.assertEqual((out, st), ("", 1))
        self.assertIn("cannot read", err)
        out, err, st = pgen(os.path.join(ROOT, "tests", "..", "tests", "queries.sql"))
        self.assertEqual((out, st), ("", 1), "a `..` path is refused, not a trap")
        self.assertIn("`..`", err)
        out, err, st = pgen(self.QUERIES, db="no_such_database_here")
        self.assertEqual((out, st), ("", 1))
        self.assertIn("3D000", err)


class ImpostorServer(unittest.TestCase):
    """A server that speaks SCRAM without the password -- or with a hostile challenge -- must be refused.

    The client checks the server's signature (that is the *server* proving it knows the password) and
    bounds the iteration count a server may ask it to compute. A mock server written here holds the
    password, so the honest run is the positive control for every dishonest one."""

    PASSWORD = "pencil"

    def exchange(self, tamper):
        import base64, hashlib, hmac, socket, threading
        lis = socket.socket()
        lis.bind(("127.0.0.1", 0))
        lis.listen(1)
        result = {}

        def read_exact(c, n):
            data = b""
            while len(data) < n:
                chunk = c.recv(n - len(data))
                if not chunk:
                    raise EOFError
                data += chunk
            return data

        def msg(kind, body):
            return kind + (len(body) + 4).to_bytes(4, "big") + body

        def serve():
            c, _ = lis.accept()
            try:
                n = int.from_bytes(read_exact(c, 4), "big")
                read_exact(c, n - 4)                                    # startup
                c.sendall(msg(b"R", (10).to_bytes(4, "big") + b"SCRAM-SHA-256\0\0"))
                assert read_exact(c, 1) == b"p"
                n = int.from_bytes(read_exact(c, 4), "big")
                body = read_exact(c, n - 4)
                mech, rest = body.split(b"\0", 1)
                first = rest[4:].decode()
                bare = first[3:]                                        # strip the "n,," gs2 header
                client_nonce = bare.split(",r=")[1]
                nonce = client_nonce + "srvnonce" if tamper != "nonce" else "unrelated" + client_nonce[3:]
                salt = base64.b64encode(b"0123456789abcdef").decode()
                iterations = {"huge": 50000000, "zero": 0}.get(tamper, 4096)
                server_first = f"r={nonce},s={salt},i={iterations}"
                c.sendall(msg(b"R", (11).to_bytes(4, "big") + server_first.encode()))
                if tamper in ("huge", "zero", "nonce"):
                    result["stopped"] = c.recv(1) == b""                 # the client must close, not answer
                    return
                assert read_exact(c, 1) == b"p"
                n = int.from_bytes(read_exact(c, 4), "big")
                final = read_exact(c, n - 4).decode()
                without_proof, proof_b64 = final.rsplit(",p=", 1)
                salted = hashlib.pbkdf2_hmac("sha256", self.PASSWORD.encode(), b"0123456789abcdef", iterations)
                client_key = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
                stored = hashlib.sha256(client_key).digest()
                auth = ",".join([bare, server_first, without_proof]).encode()
                signature = hmac.new(stored, auth, hashlib.sha256).digest()
                recovered = bytes(a ^ b for a, b in zip(base64.b64decode(proof_b64), signature))
                result["proof_ok"] = hashlib.sha256(recovered).digest() == stored
                server_key = hmac.new(salted, b"Server Key", hashlib.sha256).digest()
                v = base64.b64encode(hmac.new(server_key, auth, hashlib.sha256).digest()).decode()
                if tamper == "signature":
                    v = base64.b64encode(b"\0" * 32).decode()
                if tamper != "skip_final":
                    c.sendall(msg(b"R", (12).to_bytes(4, "big") + f"v={v}".encode()))
                c.sendall(msg(b"R", (0).to_bytes(4, "big")) + msg(b"Z", b"I"))
                assert read_exact(c, 1) == b"Q"
                n = int.from_bytes(read_exact(c, 4), "big")
                read_exact(c, n - 4)
                c.sendall(msg(b"C", b"SELECT 0\0") + msg(b"Z", b"I"))
                c.recv(1)
            except (EOFError, OSError, AssertionError) as e:
                result["error"] = repr(e)
            finally:
                c.close()

        t = threading.Thread(target=serve, daemon=True)
        t.start()
        p = subprocess.run([BIN, "127.0.0.1", str(lis.getsockname()[1]), "user", "db", self.PASSWORD, "select 1"],
                           capture_output=True, text=True, timeout=60)
        t.join(10)
        lis.close()
        return p, result

    def test_the_honest_server_is_the_control(self):
        p, result = self.exchange(None)
        self.assertEqual((p.stdout, p.returncode), ("# SELECT 0\n", 0), result)
        self.assertTrue(result.get("proof_ok"), result)

    def test_a_server_that_cannot_sign_is_refused(self):
        p, result = self.exchange("signature")
        self.assertTrue(result.get("proof_ok"), result)             # it did get a valid proof ...
        self.assertEqual(p.returncode, 7, p.stdout)                 # ... and still is not trusted

    def test_a_server_that_skips_the_signature_is_refused(self):
        p, result = self.exchange("skip_final")
        self.assertEqual(p.returncode, 7, p.stdout)

    def test_a_hostile_challenge_is_not_answered(self):
        for tamper in ("huge", "zero", "nonce"):
            p, result = self.exchange(tamper)
            self.assertEqual(p.returncode, 7, (tamper, p.stdout))
            self.assertTrue(result.get("stopped"), (tamper, result))


def pool_run(port, lanes, count, mode="plain", depth=64, budget=6000, host=HOST, user=USER, db=DB, out_cap=65536, nbytes=0):
    """Run tests/pool_drive.ls: (the `done` lines as (tag, status, value), the `finished` line, the exit code)."""
    p = subprocess.run([POOL_DRIVE, host, str(port), user, db, str(lanes), str(count), mode, str(depth), str(budget), str(out_cap), str(nbytes)],
                       capture_output=True, text=True, timeout=120)
    done, finished = [], None
    for line in p.stdout.splitlines():
        f = line.split()
        if f and f[0] == "done":
            done.append((int(f[1]), int(f[2]), " ".join(f[3:])))
        elif f and f[0] == "finished":
            finished = (int(f[1]), int(f[2]))
    return done, finished, p.returncode


class PoolAgainstPostgreSQL(unittest.TestCase):
    """`pg.pool` over real connections: the answers are the ones `pg.run_named` would get, every request
    is answered once, and nothing waits for the server."""

    def test_one_connection_pipelines_and_keeps_the_order(self):
        done, finished, rc = pool_run(PORT, 1, 300)
        self.assertEqual(rc, 0)
        self.assertEqual(done, [(i, 0, str(2 * i)) for i in range(300)])
        self.assertEqual(finished[0], 300)

    def test_more_connections_each_request_once(self):
        done, finished, rc = pool_run(PORT, 4, 2000)
        self.assertEqual(rc, 0)
        self.assertEqual(sorted(done), [(i, 0, str(2 * i)) for i in range(2000)])

    def test_back_pressure_a_full_pool_refuses_and_nothing_is_lost(self):
        # depth 2 on one connection: submit answers -1 most of the time, and the driver submits again
        done, finished, rc = pool_run(PORT, 1, 500, depth=2)
        self.assertEqual(rc, 0)
        self.assertEqual(done, [(i, 0, str(2 * i)) for i in range(500)])

    def test_a_slow_request_holds_up_its_own_connection_and_no_other(self):
        done, finished, rc = pool_run(PORT, 2, 6, "slow0")
        self.assertEqual(rc, 0)
        order = [t for t, _, _ in done]
        self.assertEqual(sorted(order), list(range(6)))
        # request 0 sleeps 0.4 s on one connection: what was queued behind it waits (so 2 and 4 are
        # after it), what went to the other connection does not (1, 3, 5 come first)
        self.assertEqual(order, [1, 3, 5, 0, 2, 4])

    def test_the_servers_error_is_the_answer_and_the_rest_go_on(self):
        done, finished, rc = pool_run(PORT, 1, 4, "err")
        self.assertEqual(done[0], (0, 0, "0"))
        self.assertEqual(done[1], (1, 0, "- 26000"))
        self.assertEqual(done[2:], [(2, 0, "4"), (3, 0, "6")])

    def test_a_request_the_kernel_will_not_take_at_once_goes_out_as_it_is_taken(self):
        # 6 requests of 3 MB through one connection with room for 4 MB of them: the socket's buffers
        # fill, writes answer Again, and the rest goes when the poller says the socket is writable
        done, finished, rc = pool_run(PORT, 1, 6, "big", out_cap=4 << 20, nbytes=3 << 20, budget=20000)
        self.assertEqual(rc, 0)
        self.assertEqual(done, [(i, 0, str(3 << 20)) for i in range(6)])

    def test_an_idle_loop_sleeps(self):
        # one 0.4 s request: the loop must not wake up every few microseconds meanwhile
        done, finished, rc = pool_run(PORT, 1, 1, "slowall")
        self.assertEqual(done, [(0, 0, "0")])
        self.assertLess(finished[1], 10, finished)

    def test_killing_the_backends_answers_every_request_once_with_a_status(self):
        import threading, time
        def kill():
            time.sleep(0.25)
            subprocess.run(["psql", "-Atc", "select count(pg_terminate_backend(pid)) from pg_stat_activity "
                            "where pid <> pg_backend_pid() and backend_type = 'client backend' and application_name = ''"],
                           capture_output=True, text=True)
        t = threading.Thread(target=kill)
        t.start()
        done, finished, rc = pool_run(PORT, 2, 6, "slowall")
        t.join()
        self.assertEqual(rc, 0)
        self.assertEqual(sorted(t for t, _, _ in done), list(range(6)))        # none lost, none twice
        self.assertTrue(all(s != 0 for _, s, _ in done), done)


class PoolAgainstAMock(unittest.TestCase):
    """The same, against a server that answers as a bad network would: in pieces, late, never, and not at
    all in the protocol."""

    def serve(self, plan, lanes=1, pause=0.0):
        """A fake backend on a port. `plan(conn_index, request_index, value)` says what it does for a Bind:
        a list of (bytes, delay_before_seconds), None for never answering it, or "close". `pause`: seconds
        the server does not read for after the client has prepared its statements."""
        import socket, threading
        lis = socket.socket()
        lis.bind(("127.0.0.1", 0))
        lis.listen(8)
        self.addCleanup(lis.close)

        def msg(kind, body):
            return kind + (len(body) + 4).to_bytes(4, "big") + body

        def good(value):
            text = str(value * 2).encode()
            return (msg(b"2", b"") + msg(b"D", (1).to_bytes(2, "big") + len(text).to_bytes(4, "big") + text)
                    + msg(b"C", b"SELECT 1\0") + msg(b"Z", b"I"))
        self.good = good
        self.msg = msg

        def read_exact(c, n):
            data = b""
            while len(data) < n:
                chunk = c.recv(n - len(data))
                if not chunk:
                    raise EOFError
                data += chunk
            return data

        def handle(c, index):
            import time
            try:
                n = int.from_bytes(read_exact(c, 4), "big")
                read_exact(c, n - 4)                                            # startup
                c.sendall(msg(b"R", (0).to_bytes(4, "big")) + msg(b"Z", b"I"))
                requested = 0
                parsed = 0
                value = None
                hung = False
                while True:
                    kind = read_exact(c, 1)
                    body = read_exact(c, int.from_bytes(read_exact(c, 4), "big") - 4)
                    if kind == b"P":                                            # Parse: ParseComplete, then Sync's Z
                        read_exact(c, 5)
                        c.sendall(msg(b"1", b"") + msg(b"Z", b"I"))
                        parsed += 1
                        if parsed == 3 and pause:                               # the driver prepares three statements
                            time.sleep(pause)
                    elif kind == b"B":
                        # portal \0 statement \0 formats(2+..) nparams(2) [len(4) value]...
                        rest = body.split(b"\0", 2)[2]
                        nfmt = int.from_bytes(rest[:2], "big")
                        rest = rest[2 + 2 * nfmt + 2:]
                        length = int.from_bytes(rest[:4], "big")
                        text = rest[4:4 + length]
                        value = int(text) if text.isdigit() else len(text)
                    elif kind == b"S":
                        action = plan(index, requested, value)
                        requested += 1
                        if action == "close":
                            # a FIN, not a reset: a close with unread requests in the receive buffer
                            # sends RST, which may discard replies the client has not read yet
                            c.shutdown(socket.SHUT_WR)
                            while c.recv(4096):
                                pass
                            return
                        if action is None:
                            hung = True
                        if hung:
                            continue
                        for chunk, delay in action:
                            if delay:
                                time.sleep(delay)
                            c.sendall(chunk)
            except (EOFError, OSError):
                pass

        def accept():
            index = 0
            while True:
                try:
                    c, _ = lis.accept()
                except OSError:
                    return
                threading.Thread(target=handle, args=(c, index), daemon=True).start()
                index += 1
        threading.Thread(target=accept, daemon=True).start()
        return lis.getsockname()[1]

    def test_replies_in_pieces_of_one_byte(self):
        def plan(conn, i, v):
            return [(bytes([b]), 0.0005) for b in self.good(v)]
        port = self.serve(plan)
        done, finished, rc = pool_run(port, 1, 12)
        self.assertEqual(done, [(i, 0, str(2 * i)) for i in range(12)])

    def test_replies_that_arrive_late_and_all_at_once(self):
        def plan(conn, i, v):
            return [(self.good(v), 0.3 if i == 0 else 0)]
        port = self.serve(plan)
        done, finished, rc = pool_run(port, 1, 8)
        self.assertEqual(done, [(i, 0, str(2 * i)) for i in range(8)])
        self.assertLess(finished[1], 12, finished)                           # it slept; it did not spin

    def test_two_replies_in_one_write(self):
        pending = {}
        def plan(conn, i, v):
            if i % 2 == 0:
                pending["held"] = self.good(v)
                return []
            return [(pending.pop("held") + self.good(v), 0)]
        port = self.serve(plan)
        done, finished, rc = pool_run(port, 1, 6)
        self.assertEqual(done, [(i, 0, str(2 * i)) for i in range(6)])

    def test_a_request_that_is_never_answered_is_not_answered_and_the_loop_gives_up_quietly(self):
        def plan(conn, i, v):
            return None if i == 2 else [(self.good(v), 0)]
        port = self.serve(plan)
        done, finished, rc = pool_run(port, 1, 5, budget=800)
        self.assertEqual(rc, 0)
        self.assertEqual(done, [(0, 0, "0"), (1, 0, "2")])                   # the rest wait behind the one that never came
        # (the mock stops answering after it: a real server cannot answer the ones behind it either)
        self.assertEqual(finished[0], 2)

    def test_a_server_that_hangs_up_part_way_fails_the_rest_in_place(self):
        def plan(conn, i, v):
            return "close" if i == 3 else [(self.good(v), 0)]
        port = self.serve(plan)
        done, finished, rc = pool_run(port, 1, 8)
        self.assertEqual([t for t, _, _ in done], list(range(8)))            # each once, in order
        self.assertEqual([s for _, s, _ in done[:3]], [0, 0, 0])
        self.assertTrue(all(s == 1 for _, s, _ in done[3:]), done)           # 1: the server closed the connection
        self.assertEqual(done[2][2], "4")

    def test_a_reply_that_is_not_the_protocol_fails_the_connection(self):
        def plan(conn, i, v):
            if i == 1:
                return [(b"Z\x00\x00\x00\x01", 0)]                          # a length no message can have
            return [(self.good(v), 0)]
        port = self.serve(plan)
        done, finished, rc = pool_run(port, 1, 4)
        self.assertEqual([t for t, _, _ in done], [0, 1, 2, 3])
        self.assertEqual(done[0], (0, 0, "0"))
        self.assertTrue(all(s == 10 for _, s, _ in done[1:]), done)

    def test_a_reply_larger_than_the_input_slab_fails_the_connection(self):
        def plan(conn, i, v):
            if i == 1:
                big = b"x" * 100000
                return [(self.msg(b"D", (1).to_bytes(2, "big") + len(big).to_bytes(4, "big") + big), 0)]
            return [(self.good(v), 0)]
        port = self.serve(plan)
        done, finished, rc = pool_run(port, 1, 3)
        self.assertEqual(done[0], (0, 0, "0"))
        self.assertEqual([s for _, s, _ in done[1:]], [8, 8])

    def test_a_request_larger_than_the_kernels_buffers_goes_out_as_the_socket_takes_it(self):
        # The server does not read for a second: 3 MB requests fill the socket's buffers, writes answer
        # Again, the rest of what is queued waits for the poller to say writable. Eight of them through
        # an output slab of 8 MB, so that some are queued while others are half sent (the queue is
        # moved down to make room), and the answers come late enough that a connection still watched
        # for writing -- always ready -- would spin the loop.
        def plan(conn, i, v):
            return [(self.good(v), 0.4 if i == 0 else 0)]
        port = self.serve(plan, pause=1.0)
        done, finished, rc = pool_run(port, 1, 8, "big", out_cap=8 << 20, nbytes=3 << 20, budget=20000)
        self.assertEqual(rc, 0)
        self.assertEqual(done, [(i, 0, str(2 * (3 << 20))) for i in range(8)])
        self.assertLess(finished[1], 60, finished)

    def test_a_connection_that_fails_with_answers_nobody_has_taken_loses_none_of_them(self):
        # "lazy": the driver takes answers only when the poller has been quiet, so the first three replies
        # and the server's hang-up are both in before it looks
        def plan(conn, i, v):
            return "close" if i == 3 else [(self.good(v), 0)]
        port = self.serve(plan)
        done, finished, rc = pool_run(port, 1, 8, "lazy")
        self.assertEqual([t for t, _, _ in done], list(range(8)))
        self.assertEqual([s for _, s, _ in done], [0, 0, 0, 1, 1, 1, 1, 1])

    def test_one_connection_dying_leaves_the_other_serving(self):
        def plan(conn, i, v):
            return "close" if conn == 0 and i == 1 else [(self.good(v), 0)]
        port = self.serve(plan, lanes=2)
        done, finished, rc = pool_run(port, 2, 8)
        self.assertEqual(sorted(t for t, _, _ in done), list(range(8)))
        failed = [t for t, s, _ in done if s != 0]
        self.assertTrue(failed, done)                                        # what was on the dead one
        self.assertTrue(any(s == 0 for _, s, _ in done), done)               # and the other one answered


if __name__ == "__main__":
    build()
    unittest.main(argv=[sys.argv[0]] + sys.argv[1:], verbosity=2)
