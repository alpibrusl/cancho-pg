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
password of (pg_hba.conf method `password`).
"""
import os
import subprocess
import sys
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
HOST = os.environ.get("PGHOST", "127.0.0.1")
PORT = os.environ.get("PGPORT", "5432")
USER = os.environ.get("PGUSER", "postgres")
DB = os.environ.get("PGDATABASE", "postgres")
BIN = os.environ.get("BIN")


DESCRIBE = None


def build():
    global BIN, DESCRIBE
    lex = os.environ.get("LEX_SYS", "lex-sys")
    os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
    def one(name):
        out = os.path.join(ROOT, "build", name)
        subprocess.run([lex, "build", "--std", os.path.join(ROOT, "examples", name + ".ls"),
                        os.path.join(ROOT, "src", "pg.ls"), "-o", out], check=True)
        return out
    BIN = BIN or one("psql")
    DESCRIBE = one("describe")


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


if __name__ == "__main__":
    build()
    unittest.main(argv=[sys.argv[0]] + sys.argv[1:], verbosity=2)
