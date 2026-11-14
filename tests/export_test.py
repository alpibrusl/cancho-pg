#!/usr/bin/env python3
"""Gates G-E2 to G-E6 of docs/design.md section 10, on a real PostgreSQL, for `pg-export` (tools/pgexport.cho).

    PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGDATABASE=postgres python3 tests/export_test.py
    CANCHO=/path/to/cancho   (default: cancho on PATH)    BIN=build/pg-export  (skip the build)
    TABLE=/path/to/table     (optional: also run the export through `table --input-format jsonl`)

Every gate has a refusal it must give; each test asserts the refusal, not only the success.
Needs trust authentication for the user above, and the right to create a table and a database.
"""
import json
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
TABLE = os.environ.get("TABLE")


def psql(sql, db=DB):
    p = subprocess.run(["psql", "-h", HOST, "-p", PORT, "-U", USER, "-d", db, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-c", sql],
                       capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    return p.stdout


def psql_text(sql, db=DB):
    p = subprocess.run(["psql", "-h", HOST, "-p", PORT, "-U", USER, "-d", db, "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-c", sql],
                       capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    return p.stdout


def build():
    global BIN
    if BIN:
        return
    out = os.path.join(ROOT, "build", "pg-export")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    cancho = os.environ.get("CANCHO", "cancho")
    subprocess.run([cancho, "build", "--std", os.path.join(ROOT, "tools", "pgexport.cho"), os.path.join(ROOT, "src", "pg.cho"), "-o", out],
                   check=True, cwd=ROOT)
    BIN = out


def export(sql, *limits, db=DB):
    p = subprocess.run([BIN, HOST, PORT, USER, db, "-", sql, *map(str, limits)], capture_output=True)
    return p.returncode, p.stdout, p.stderr.decode("utf-8", "replace")


def rows(sql, *limits, db=DB):
    code, out, err = export(sql, *limits, db=db)
    assert code == 0, err
    return [json.loads(line) for line in out.decode("utf-8").split("\n") if line]


class Gates(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        build()
        psql("drop table if exists pgx_t")
        psql("create table pgx_t (id int primary key, note text)")
        psql("insert into pgx_t values (1, 'one'), (2, null), (3, ''), (4, 'null')")

    @classmethod
    def tearDownClass(cls):
        psql("drop table if exists pgx_t")

    # G-E2: read only
    def test_writes_are_refused_and_change_nothing(self):
        for sql in ["insert into pgx_t values (9, 'x')", "delete from pgx_t", "update pgx_t set note = 'z'",
                    "create table pgx_u (a int)", "drop table pgx_t", "truncate pgx_t"]:
            code, out, err = export(sql)
            self.assertEqual(code, 1, sql)
            self.assertEqual(out, b"", sql)
            self.assertIn("pg-export.server-refused: SQLSTATE", err, sql)
        self.assertEqual(len(rows("select id from pgx_t")), 4)

    def test_a_second_statement_is_refused(self):
        code, out, err = export("select 1 as a; drop table pgx_t")
        self.assertEqual((code, out), (1, b""))
        self.assertIn("SQLSTATE 42601", err)
        self.assertEqual(len(rows("select id from pgx_t")), 4)

    def test_a_query_that_writes_through_a_function_is_refused(self):
        code, out, err = export("select nextval('pgx_seq') as n")
        self.assertEqual(code, 1)  # no such sequence is also a refusal; the transaction is read only either way
        self.assertEqual(out, b"")

    # G-E3: exactness
    def test_numbers_are_the_servers_text(self):
        r = rows("select 12345678901234567890.0123456789::numeric(40,10) as n, 9223372036854775807::int8 as hi, "
                 "(-9223372036854775808)::int8 as lo, 1.50::numeric as d, '-0'::float8 as z, 1e300::float8 as big")
        self.assertEqual(len(r), 1)
        _, out, _ = export("select 12345678901234567890.0123456789::numeric(40,10) as n, 1.50::numeric as d, "
                           "9223372036854775807::int8 as hi, (-9223372036854775808)::int8 as lo")
        self.assertEqual(out.decode(), '{"n":12345678901234567890.0123456789,"d":1.50,"hi":9223372036854775807,"lo":-9223372036854775808}\n')

    def test_nan_and_infinity_are_refused_not_written_as_tokens(self):
        for sql in ["select 'NaN'::float8 as x", "select 'Infinity'::float8 as x", "select '-Infinity'::float4 as x",
                    "select 'NaN'::numeric as x"]:
            code, out, err = export(sql)
            self.assertEqual((code, out), (1, b""), sql)
            self.assertIn("pg-export.non-finite", err, sql)

    def test_hostile_strings_round_trip(self):
        want = "\"\\/  \U0001F600é\t\n\r\x01\x1f end"
        sql = ("select chr(34)||chr(92)||'/'||chr(8232)||chr(8233)||chr(128512)||chr(233)||chr(9)||chr(10)||chr(13)||chr(1)||chr(31)||' end' as s")
        self.assertEqual(rows(sql), [{"s": want}])

    def test_booleans_and_types_that_are_strings(self):
        self.assertEqual(rows("select true as t, false as f, '2026-11-13'::date as d, 'a'::bytea as b, '{1,2}'::int[] as arr"),
                         [{"t": True, "f": False, "d": "2026-11-13", "b": "\\x61", "arr": "{1,2}"}])

    # G-E4: NULL, empty and the string 'null' are three things
    def test_null_empty_and_the_word_null(self):
        self.assertEqual(rows("select id, note from pgx_t order by id"),
                         [{"id": 1, "note": "one"}, {"id": 2, "note": None}, {"id": 3, "note": ""}, {"id": 4, "note": "null"}])

    def test_a_repeated_column_name_is_refused(self):
        code, out, err = export("select 1 as a, 2 as a")
        self.assertEqual((code, out), (1, b""))
        self.assertIn("pg-export.duplicate-column", err)

    def test_a_command_is_not_a_query(self):
        code, out, err = export("set work_mem = '64MB'")
        self.assertEqual((code, out), (1, b""))
        self.assertIn("pg-export.no-columns", err)

    # G-E5: bounds leave nothing
    def test_max_rows(self):
        code, out, err = export("select g as n from generate_series(1, 100) g", 10)
        self.assertEqual((code, out), (1, b""))
        self.assertIn("pg-export.too-many-rows", err)
        self.assertEqual(len(rows("select g as n from generate_series(1, 100) g", 100)), 100)

    def test_max_bytes(self):
        code, out, err = export("select g as n from generate_series(1, 100000) g", 1000000, 1000)
        self.assertEqual((code, out), (1, b""))
        self.assertIn("pg-export.too-large", err)

    def test_bad_limits_and_usage(self):
        for limits in [(0,), (100000001,), (10, 0), (10, 1073741825)]:
            code, out, err = export("select 1 as a", *limits)
            self.assertEqual((code, out), (1, b""), limits)
            self.assertIn("pg-export.bad-limit", err, limits)
        p = subprocess.run([BIN], capture_output=True)
        self.assertEqual(p.returncode, 2)
        self.assertIn(b"pg-export.usage", p.stderr)

    # G-E6: no payload in an error line
    def test_an_error_never_echoes_the_sql_or_a_value(self):
        for sql in ["select 'SECRETVALUE'::int as x", "select SECRETCOLUMN from pgx_t", "select * from SECRETTABLE"]:
            code, out, err = export(sql)
            self.assertEqual((code, out), (1, b""), sql)
            self.assertNotIn("SECRET", err, sql)
            self.assertRegex(err, r"^pg-export: pg-export\.server-refused: SQLSTATE [0-9A-Z]{5}\n$")

    def test_a_bad_login_never_echoes(self):
        p = subprocess.run([BIN, HOST, PORT, "no_such_user_xyz", DB, "hunter2", "select 1 as a"], capture_output=True)
        # trust authentication accepts any name; a server that asks for a password refuses and the line carries the SQLSTATE only
        self.assertNotIn(b"hunter2", p.stderr)

    def test_a_connect_failure_is_a_tagged_refusal(self):
        p = subprocess.run([BIN, "127.0.0.1", "1", USER, DB, "-", "select 1 as a"], capture_output=True)
        self.assertEqual((p.returncode, p.stdout), (1, b""))
        self.assertIn(b"pg-export.connect", p.stderr)

    # UTF-8: a database in another encoding can hold bytes that are not UTF-8
    def test_bytes_that_are_not_utf8_are_refused(self):
        psql("drop database if exists pgx_ascii")
        psql("create database pgx_ascii template template0 encoding 'SQL_ASCII'")
        try:
            psql("create table t (s text)", db="pgx_ascii")
            psql("insert into t values (convert_from('\\xe9ff41'::bytea, 'SQL_ASCII'))", db="pgx_ascii")
            code, out, err = export("select s from t", db="pgx_ascii")
            self.assertEqual((code, out), (1, b""))
            self.assertIn("pg-export.not-utf8", err)
        finally:
            psql("drop database if exists pgx_ascii")

    # G-E1: the authority row is a fact, and it is checked
    def test_authority_row(self):
        cancho = os.environ.get("CANCHO", "cancho")
        p = subprocess.run([cancho, "authority", os.path.join(ROOT, "tools", "pgexport.cho"), os.path.join(ROOT, "src", "pg.cho"), "--std", "--output", "json"],
                           capture_output=True, text=True, cwd=ROOT)
        self.assertEqual(p.returncode, 0, p.stderr)
        row = json.loads(p.stdout)
        got = sorted((l["name"], l["argument"]) for l in row["labels"])
        # What the generic build reaches: the network (any host: a deployment's build would narrow it), the connection, the console,
        # the heap, and one file, the kernel's random bytes for the login's nonce. No foreign code, no clock, no writing a file.
        self.assertEqual(got, [("args", None), ("conn_read", None), ("conn_write", None), ("err_write", None), ("fs_read", "/dev/urandom"),
                               ("heap", None), ("io_write", None), ("net_out", "")])
        self.assertEqual(row["foreign_symbols"], [])

    # The server's own JSON writer is the reference: the same bytes for the same rows
    def test_same_bytes_as_row_to_json(self):
        q = ("select g as id, 'name ' || g as s, case when g % 3 = 0 then null else g / 4.0 end as n, g % 2 = 0 as b, "
             "date '2026-01-01' + g as d, chr(34) || chr(92) || chr(9) || chr(233) || chr(128512) as txt from generate_series(1, 500) g")
        code, out, err = export(q)
        self.assertEqual(code, 0, err)
        want = psql_text(f"select row_to_json(t) from ({q}) t")
        self.assertEqual(out.decode("utf-8"), want)

    # The consumer: what table reads is what was exported
    @unittest.skipUnless(TABLE, "TABLE not set")
    def test_table_reads_it(self):
        code, out, err = export("select id, note, (id * 1.25)::numeric(8,2) as price from pgx_t order by id")
        self.assertEqual(code, 0, err)
        p = subprocess.run([TABLE, "--input-format", "jsonl", "--fields", "id,price", "--agg", "count,sum:price:dec(2)", "--format", "csv", "-"],
                           input=out, capture_output=True)
        self.assertEqual(p.stdout.decode(), "count,sum:price\n4,12.50\n", p.stderr)
        # NULL is refused by default (a missing value), and --absent empty accepts it
        p = subprocess.run([TABLE, "--input-format", "jsonl", "--fields", "id,note", "--select", "id,note", "--format", "csv", "-"], input=out, capture_output=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn(b"parse.jsonl-missing-field", p.stdout + p.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
