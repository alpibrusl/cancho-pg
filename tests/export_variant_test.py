#!/usr/bin/env python3
"""Gates G-E1b, G-E1c, G-P1, G-P2, G-P3 and G-S of docs/design.md section 11: the one-host `pg-export` and its password file.

    PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGDATABASE=postgres python3 tests/export_variant_test.py
    CANCHO=/path/to/cancho   (default: cancho on PATH)
    PG_SCRAM_USER / PG_SCRAM_PASSWORD / PG_SCRAM_DB and PG_CLEARTEXT_USER / PG_CLEARTEXT_PASSWORD / PG_CLEARTEXT_DB
        name roles whose pg_hba.conf method is scram-sha-256 and password (tests/postgres.sh makes them); the tests that need them skip without.

Each variant is built here by scripts/export_build.py with literals for the test server. Every test asserts a refusal where the
gate has one, not only a success.
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOST = os.environ.get("PGHOST", "127.0.0.1")
PORT = int(os.environ.get("PGPORT", "5432"))
USER = os.environ.get("PGUSER", "postgres")
DB = os.environ.get("PGDATABASE", "postgres")
SCRIPT = os.path.join(ROOT, "scripts", "export_build.py")
CANCHO = os.environ.get("CANCHO", "cancho")
SCRAM = [os.environ.get(k) for k in ("PG_SCRAM_USER", "PG_SCRAM_PASSWORD", "PG_SCRAM_DB")]
CLEAR = [os.environ.get(k) for k in ("PG_CLEARTEXT_USER", "PG_CLEARTEXT_PASSWORD", "PG_CLEARTEXT_DB")]
GENERIC = [os.path.join(ROOT, "tools", "pgexport", "generic.cho"), os.path.join(ROOT, "tools", "pgexport", "core.cho"), os.path.join(ROOT, "src", "pg.cho")]

TMP = tempfile.mkdtemp(prefix="pgxv")  # plain characters: the script only takes such a path
_built = {}


def build(host=HOST, port=PORT, password_file=None, extra=()):
    key = (host, port, password_file, tuple(extra))
    if key in _built:
        return _built[key]
    out = os.path.join(TMP, "bin%d" % len(_built))
    argv = [sys.executable, SCRIPT, "--host", host, "--port", str(port), "--out", out, "--gen", os.path.join(TMP, "gen%d" % len(_built)),
            "--cancho", CANCHO, *extra]
    if password_file:
        argv += ["--password-file", password_file]
    p = subprocess.run(argv, capture_output=True, text=True, cwd=ROOT)
    assert p.returncode == 0, p.stdout + p.stderr
    _built[key] = out
    return out


def pwfile(content, name=None):
    path = os.path.join(TMP, name or "pw%d" % len(os.listdir(TMP)))
    with open(path, "wb") as f:
        f.write(content)
    return path


def run(binary, user, database, sql, *limits):
    p = subprocess.run([binary, user, database, sql, *limits], capture_output=True)
    return p.returncode, p.stdout, p.stderr.decode("utf-8", "replace")


def authority(files):
    p = subprocess.run([CANCHO, "authority", *files, "--std", "--output", "json"], capture_output=True, text=True, cwd=ROOT)
    assert p.returncode == 0, p.stderr
    return json.loads(p.stdout)


class Variant(unittest.TestCase):
    # G-E1b: the row of the variant is the bound one
    def test_the_row_is_one_host_and_one_file(self):
        pw = pwfile(b"x\n", "pw_row")
        build(HOST, PORT, pw)
        row = authority([os.path.join(TMP, "gen%d" % (len(_built) - 1), "pgexport_main_%s_%d.cho" % (HOST.replace(".", "_"), PORT)),
                         os.path.join(ROOT, "tools", "pgexport", "core.cho"), os.path.join(ROOT, "src", "pg.cho")])
        self.assertTrue(row["bounded"], row.get("unbounded_by"))
        got = sorted((l["name"], l["argument"]) for l in row["labels"])
        self.assertEqual(got, [("args", None), ("conn_read", None), ("conn_write", None), ("err_write", None), ("fs_read", "/dev/urandom"),
                               ("fs_read", pw), ("heap", None), ("io_write", None), ("net_out", "%s:%d" % (HOST, PORT))])
        self.assertEqual(row["foreign_symbols"], [])

    def test_without_a_password_file_there_is_no_file_label(self):
        build(HOST, PORT)
        row = authority([os.path.join(TMP, "gen%d" % (len(_built) - 1), "pgexport_main_%s_%d.cho" % (HOST.replace(".", "_"), PORT)),
                         os.path.join(ROOT, "tools", "pgexport", "core.cho"), os.path.join(ROOT, "src", "pg.cho")])
        self.assertTrue(row["bounded"])
        self.assertEqual([l["argument"] for l in row["labels"] if l["name"] == "fs_read"], ["/dev/urandom"])

    def test_the_generic_build_is_not_bounded(self):
        row = authority(GENERIC)
        self.assertFalse(row["bounded"])

    # G-E1c: the committed row is the derived one
    def test_the_committed_reference_row(self):
        p = subprocess.run([sys.executable, SCRIPT, "--host", "127.0.0.1", "--port", "5432", "--password-file", "/run/secrets/pg",
                            "--out", os.path.join(TMP, "ref"), "--gen", os.path.join(TMP, "genref"), "--manifest",
                            os.path.join(ROOT, "manifests", "pg-export.authority.json"), "--check", "--cancho", CANCHO],
                           capture_output=True, text=True, cwd=ROOT)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

    def test_a_manifest_that_differs_is_refused(self):
        bad = pwfile(json.dumps({"bounded": True, "labels": [], "foreign_symbols": []}).encode(), "bad_manifest.json")
        p = subprocess.run([sys.executable, SCRIPT, "--host", "127.0.0.1", "--port", "5432", "--out", os.path.join(TMP, "ref2"),
                            "--gen", os.path.join(TMP, "genref2"), "--manifest", bad, "--check", "--cancho", CANCHO],
                           capture_output=True, text=True, cwd=ROOT)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("is not the row derived", p.stderr)

    # G-P1: the password comes from the file, newline removed, and the wrong one is refused
    @unittest.skipUnless(all(SCRAM), "PG_SCRAM_* not set")
    def test_scram_login_from_a_file(self):
        user, password, db = SCRAM
        good = pwfile(password.encode() + b"\n", "pw_scram_good")
        code, out, err = run(build(HOST, PORT, good), user, db, "select 7 as n")
        self.assertEqual((code, out), (0, b'{"n":7}\n'), err)
        crlf = pwfile(password.encode() + b"\r\n", "pw_scram_crlf")
        self.assertEqual(run(build(HOST, PORT, crlf), user, db, "select 7 as n")[:2], (0, b'{"n":7}\n'))
        nonl = pwfile(password.encode(), "pw_scram_nonl")
        self.assertEqual(run(build(HOST, PORT, nonl), user, db, "select 7 as n")[:2], (0, b'{"n":7}\n'))

    @unittest.skipUnless(all(SCRAM), "PG_SCRAM_* not set")
    def test_a_wrong_password_is_refused_and_not_echoed(self):
        user, password, db = SCRAM
        bad = pwfile(b"not the password hunter9\n", "pw_scram_bad")
        code, out, err = run(build(HOST, PORT, bad), user, db, "select 7 as n")
        self.assertEqual((code, out), (1, b""))
        self.assertIn("pg-export.login", err)
        self.assertNotIn("hunter9", err)
        self.assertNotIn(password, err)

    @unittest.skipUnless(all(CLEAR), "PG_CLEARTEXT_* not set")
    def test_cleartext_login_from_a_file(self):
        user, password, db = CLEAR
        good = pwfile(password.encode() + b"\n", "pw_clear_good")
        code, out, err = run(build(HOST, PORT, good), user, db, "select 8 as n")
        self.assertEqual((code, out), (0, b'{"n":8}\n'), err)

    # G-P2: an unusable file is one tag and prints neither the path nor the content
    def test_a_missing_empty_or_long_file(self):
        missing = os.path.join(TMP, "pw_missing")
        empty = pwfile(b"", "pw_empty")
        newline = pwfile(b"\n", "pw_newline_only")
        long = pwfile(b"A" * 1025, "pw_long")
        for path in (missing, empty, newline, long):
            code, out, err = run(build(HOST, PORT, path), USER, DB, "select 1 as a")
            self.assertEqual((code, out), (1, b""), path)
            self.assertIn("pg-export.password-file", err, path)
            self.assertNotIn(path, err)
            self.assertNotIn("AAAA", err)
            self.assertNotIn(TMP, err)

    def test_a_file_of_exactly_1024_bytes_is_taken(self):
        ok = pwfile(b"A" * 1024, "pw_1024")
        code, out, err = run(build(HOST, PORT, ok), USER, DB, "select 1 as a")  # trust: the password is not asked
        self.assertEqual((code, out), (0, b'{"a":1}\n'), err)

    # G-P3: the password is in no argument
    @unittest.skipUnless(all(SCRAM), "PG_SCRAM_* not set")
    def test_the_password_is_not_in_the_process_list(self):
        user, password, db = SCRAM
        good = pwfile(password.encode() + b"\n", "pw_scram_ps")
        p = subprocess.Popen([build(HOST, PORT, good), user, db, "select pg_sleep(1.5) as s"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(0.5)
        with open("/proc/%d/cmdline" % p.pid, "rb") as f:
            cmdline = f.read()
        p.communicate()
        self.assertNotIn(password.encode(), cmdline)

    @unittest.skipUnless(all(SCRAM), "PG_SCRAM_* not set")
    def test_the_generic_build_shows_the_password_in_the_process_list(self):
        # The contrast the design states: the generic program takes the password as an argument.
        user, password, db = SCRAM
        generic = os.path.join(TMP, "generic")
        subprocess.run([CANCHO, "build", "--std", *GENERIC, "-o", generic], check=True, cwd=ROOT, capture_output=True)
        p = subprocess.Popen([generic, HOST, str(PORT), user, db, password, "select pg_sleep(1.5) as s"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(0.5)
        with open("/proc/%d/cmdline" % p.pid, "rb") as f:
            cmdline = f.read()
        p.communicate()
        self.assertIn(password.encode(), cmdline)

    # The variant does the work of the generic program
    def test_the_variant_exports_and_refuses_like_the_generic(self):
        binary = build(HOST, PORT)
        self.assertEqual(run(binary, USER, DB, "select 1 as a, null as b, 'x' as c")[:2], (0, b'{"a":1,"b":null,"c":"x"}\n'))
        code, out, err = run(binary, USER, DB, "insert into nowhere values (1)")
        self.assertEqual((code, out), (1, b""))
        code, out, err = run(binary, USER, DB, "select g as n from generate_series(1, 100) g", "10")
        self.assertEqual((code, out), (1, b""))
        self.assertIn("pg-export.too-many-rows", err)
        code, out, err = run(binary, USER, DB, "select 1 as a", "0")
        self.assertIn("pg-export.bad-limit", err)
        p = subprocess.run([binary, USER], capture_output=True)
        self.assertEqual(p.returncode, 2)
        self.assertIn(b"pg-export.usage", p.stderr)

    def test_the_variant_dials_only_its_host(self):
        # The other port is not reachable: the variant has no argument that names a host or a port.
        binary = build("127.0.0.1", 1)
        code, out, err = run(binary, USER, DB, "select 1 as a")
        self.assertEqual((code, out), (1, b""))
        self.assertIn("pg-export.connect", err)


class Script(unittest.TestCase):
    # G-S: refuse before writing anything
    def refused(self, *argv):
        gen = os.path.join(TMP, "genrefuse%d" % len(os.listdir(TMP)))
        p = subprocess.run([sys.executable, SCRIPT, "--gen", gen, "--out", os.path.join(TMP, "never"), "--cancho", CANCHO, *argv],
                           capture_output=True, text=True, cwd=ROOT)
        self.assertNotEqual(p.returncode, 0, argv)
        self.assertIn("export_build:", p.stderr, argv)
        self.assertFalse(os.path.exists(gen), "wrote a file before refusing: %s" % (argv,))
        self.assertFalse(os.path.exists(os.path.join(TMP, "never")))

    def test_bad_hosts(self):
        for host in ["*.example.com", "a b", "host;rm", "[::1]", "", "-x", "a..b", 'q"uote']:
            self.refused("--host=" + host, "--port", "5432")

    def test_bad_ports(self):
        for port in ["0", "65536", "-1"]:
            self.refused("--host", "db.internal", "--port=" + port)

    def test_bad_password_files(self):
        for path in ["relative/pw", "/run/../etc/passwd", "/run/secrets/", "/run//secrets", "/dev/urandom", "/dev/urandom/x", '/run/"q', "/run/a b", "/"]:
            self.refused("--host", "db.internal", "--port", "5432", "--password-file=" + path)


if __name__ == "__main__":
    unittest.main(verbosity=2)
