#!/usr/bin/env python3
"""Mutants of tools/pgexport/core.cho (against tests/export_test.py) and of scripts/export_build.py (against tests/export_variant_test.py):
each must make its tests fail (a gate that cannot fail is not a gate).

    PGHOST=... PGPORT=... PGUSER=... PGDATABASE=... CANCHO=... python3 tests/export_mutants.py
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORE = os.path.join(ROOT, "tools", "pgexport", "core.cho")
BUILD = os.path.join(ROOT, "scripts", "export_build.py")
EXPORT_TESTS = os.path.join(ROOT, "tests", "export_test.py")
VARIANT_TESTS = os.path.join(ROOT, "tests", "export_variant_test.py")
CANCHO = os.environ.get("CANCHO", "cancho")

MUTANTS = [
    ("no READ ONLY", CORE, EXPORT_TESTS, 'command(heap, conn, io, "BEGIN READ ONLY")', 'command(heap, conn, io, "BEGIN")'),
    ("NaN written as a token", CORE, EXPORT_TESTS, "if !is_json_number(reply, vf, vt) {", "if false {"),
    ("UTF-8 not checked", CORE, EXPORT_TESTS, "    let c = int_of(m[i]);\n    if c < 128 {\n        return 1;\n    }", "    return 1;\n    let c = int_of(m[i]);\n    if c < 128 {\n        return 1;\n    }"),
    ("max_rows ignored", CORE, EXPORT_TESTS, "if count >= max_rows {", "if count > 2000000000 {"),
    ("max_bytes ignored", CORE, EXPORT_TESTS, "if size > max_bytes {", "if size < 0 {"),
    ("quote not escaped", CORE, EXPORT_TESTS, "if c == 34 || c == 92 || c < 32 {", "if c == 92 || c < 32 {"),
    ("NULL as empty string", CORE, EXPORT_TESTS, 'out = buffer.append(heap, out, "null");', 'out = buffer.append(heap, out, "\\"\\"");'),
    ("server message echoed", CORE, EXPORT_TESTS, 'io.error_all(io, "pg-export: pg-export.server-refused: SQLSTATE ");', 'io.error_all(io, "pg-export: pg-export.server-refused: SQLSTATE ");\n    let (mf, mt) = pg.error_field(reply, at, 77);\n    io.error_all(io, reply[mf..mt]);'),
    ("duplicate columns allowed", CORE, EXPORT_TESTS, "if repeated(reply, t, j) {", "if false {"),
    ("partial output on refusal", CORE, EXPORT_TESTS, "    if status == 0 {\n        borrow out as &or in {", "    if true {\n        borrow out as &or in {"),
    ("variant: network narrowed to the host only", BUILD, VARIANT_TESTS, 'let db = narrow(net, "%(bound)s");', 'let db = narrow(net, "%(host)s");'),
    ("variant: the newline is kept", BUILD, VARIANT_TESTS, "if int_of(raw[n - 1]) == 10 {", "if int_of(raw[n - 1]) == 1000 {"),
    ("variant: the carriage return is kept", BUILD, VARIANT_TESTS, "if n > 0 && int_of(raw[n - 1]) == 13 {", "if n > 0 && int_of(raw[n - 1]) == 1000 {"),
    ("variant: an empty password is accepted", BUILD, VARIANT_TESTS, "            if n < 1 {\n                status = 1;", "            if n < 0 {\n                status = 1;"),
    ("variant: a long password file is accepted", BUILD, VARIANT_TESTS, "if got < 1 || got > 1024 {", "if got < 1 || got > 1025 {"),
    ("variant: the path is echoed", BUILD, VARIANT_TESTS, '"the password file cannot be read, is empty, or is over 1024 bytes"', '"the password file%(pwnote)s cannot be read"'),
    ("variant: a wildcard host is accepted", BUILD, VARIANT_TESTS, 'HOST = re.compile(r"^[A-Za-z0-9]', 'HOST = re.compile(r"^[A-Za-z0-9*]'),
    ("variant: a manifest that differs is accepted", BUILD, VARIANT_TESTS, "open(a.manifest).read() != text", "False"),
]

survivors = []
for name, path, tests, old, new in MUTANTS:
    original = open(path).read()
    assert original.count(old) == 1, f"{name}: pattern not found exactly once"
    try:
        open(path, "w").write(original.replace(old, new))
        env = dict(os.environ)
        env.pop("BIN", None)
        p = subprocess.run([sys.executable, tests], capture_output=True, text=True, env=env)
        killed = p.returncode != 0
    finally:
        open(path, "w").write(original)
    print(("killed  " if killed else "SURVIVED"), name)
    if not killed:
        survivors.append(name)
sys.exit(1 if survivors else 0)
