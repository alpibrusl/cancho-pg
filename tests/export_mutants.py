#!/usr/bin/env python3
"""Mutants of tools/pgexport.cho: each must make tests/export_test.py fail (a gate that cannot fail is not a gate).

    PGHOST=... PGPORT=... PGUSER=... PGDATABASE=... CANCHO=... python3 tests/export_mutants.py
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "tools", "pgexport.cho")
CANCHO = os.environ.get("CANCHO", "cancho")

MUTANTS = [
    ("no READ ONLY", 'command(heap, conn, io, "BEGIN READ ONLY")', 'command(heap, conn, io, "BEGIN")'),
    ("NaN written as a token", "if !is_json_number(reply, vf, vt) {", "if false {"),
    ("UTF-8 not checked", "    let c = int_of(m[i]);\n    if c < 128 {\n        return 1;\n    }", "    return 1;\n    let c = int_of(m[i]);\n    if c < 128 {\n        return 1;\n    }"),
    ("max_rows ignored", "if count >= max_rows {", "if count > 2000000000 {"),
    ("max_bytes ignored", "if size > max_bytes {", "if size < 0 {"),
    ("quote not escaped", "if c == 34 || c == 92 || c < 32 {", "if c == 92 || c < 32 {"),
    ("NULL as empty string", 'out = buffer.append(heap, out, "null");', 'out = buffer.append(heap, out, "\\"\\"");'),
    ("server message echoed", 'io.error_all(io, "pg-export: pg-export.server-refused: SQLSTATE ");', 'io.error_all(io, "pg-export: pg-export.server-refused: SQLSTATE ");\n    let (mf, mt) = pg.error_field(reply, at, 77);\n    io.error_all(io, reply[mf..mt]);'),
    ("duplicate columns allowed", "if repeated(reply, t, j) {", "if false {"),
    ("partial output on refusal", "    if status == 0 {\n        borrow out as &or in {", "    if true {\n        borrow out as &or in {"),
]

original = open(SRC).read()
survivors = []
try:
    for name, old, new in MUTANTS:
        assert original.count(old) == 1, f"{name}: pattern not found exactly once"
        open(SRC, "w").write(original.replace(old, new))
        env = dict(os.environ)
        env.pop("BIN", None)
        p = subprocess.run([sys.executable, os.path.join(ROOT, "tests", "export_test.py")], capture_output=True, text=True, env=env)
        killed = p.returncode != 0
        print(("killed  " if killed else "SURVIVED"), name)
        if not killed:
            survivors.append(name)
finally:
    open(SRC, "w").write(original)
sys.exit(1 if survivors else 0)
