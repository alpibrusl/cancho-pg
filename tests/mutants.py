#!/usr/bin/env python3
"""Single-edit mutants of src/pool.cho and src/pg.cho: each one must make a test fail.

    CANCHO=... PGHOST=... python3 tests/mutants.py [name ...]      (default: all; the server env of tests/e2e.py)

For each mutant: save the file, make the edit, run the unit tests (no server) and then tests/reconnect_test.py until the first
failure, restore the file from the saved copy and check with `cmp` that it is the same bytes. Prints one line per mutant
(`killed by <suite>` or `SURVIVED`) and a count.
"""
import filecmp
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LEX = os.environ.get("CANCHO", "cancho")

POOL = "src/pool.cho"
PG = "src/pg.cho"

# (name, file, old text, new text)
MUTANTS = [
    ("the backoff does not double", POOL, "    st[p + 13] = st[p + 13] * 2;\n    if st[p + 13] > ci[8] {", "    st[p + 13] = st[p + 13] * 1;\n    if st[p + 13] > ci[8] {"),
    ("the backoff has no cap", POOL, "    if st[p + 13] > ci[8] {\n        st[p + 13] = ci[8];\n    }\n    return 0;\n}\n\n// Connection `k`, logged in", "    if st[p + 13] > ci[8] * 1000 {\n        st[p + 13] = ci[8];\n    }\n    return 0;\n}\n\n// Connection `k`, logged in"),
    ("a connection that lived a moment is called stable", POOL, "now - st[p + 18] >= stable_ms()", "now - st[p + 18] >= 0"),
    ("the server's FATAL message is not noticed", POOL, "                ok = 0 - 2;", "                ok = 0;"),
    ("the requests on a lost connection are not answered", POOL, "    var lost = st[p + 5] - st[p + 2];", "    var lost = 0;"),
    ("a lost connection is not counted", POOL, "    ci[14] = ci[14] + 1;\n    ci[15] = ci[15] + 1;\n    ci[26] = code;", "    ci[15] = ci[15] + 1;\n    ci[26] = code;"),
    ("an attempt never runs out of time", POOL, "            if now >= st[p + 14] {", "            if now >= st[p + 14] + 100000000 {"),
    ("the first connections count as reconnects", POOL, "    if st[p + 20] == 1 {\n        ci[11] = ci[11] + 1;", "    if st[p + 20] <= 1 {\n        ci[11] = ci[11] + 1;"),
    ("the server's SCRAM signature is not checked", POOL, "        if !bytes.equal(m[at + 9..at + n], want) {", "        if false {"),
    ("AuthOk is taken before the server has proved itself", POOL, "        if ph == ph_scram_verify() {\n            // AuthOk before the server proved it knows the password\n            return 7;\n        }", "        if false {\n            return 7;\n        }"),
    ("every login has the same nonce", POOL, "    ci[16] = ci[16] + 1;\n    var data", "    var data"),
    ("one statement too many is waited for", POOL, "        if st[p + 16] >= ci[6] {", "        if st[p + 16] > ci[6] {"),
    ("a refused statement is called a refused login", POOL, "                    code = 9;", "                    code = 4;"),
    ("the SQLSTATE is read one byte late", POOL, "ci[20 + i] = int_of(m[cf + i]);", "ci[20 + i] = int_of(m[cf + i + 1]);"),
    ("a request that waits for ever is not given up", POOL, "                        kill(tab, core, k, 12);", "                        st[p + 23] = now;"),
    ("a connection is remade before its answers are taken", POOL, "st[p + 12] <= now && st[p + 5] == 0 && core.cur != k;", "st[p + 12] <= now && core.cur != k;"),
    ("a connected socket stays watched for writing", POOL, "        if conns.rewatch(tab, poller, st[p + 10], core.base + k, 1) != 0 {\n            ci[19] = 0;", "        if 0 != 0 {\n            ci[19] = 0;"),
    ("the key is derived in one turn", POOL, "    return 128;", "    return 100000000;"),
    ("the loop is not told that there is work to do", POOL, "            if ph_is_work(st[p + 11]) {\n                at = now;", "            if ph_is_work(st[p + 11]) {\n                at = st[p + 14];"),
    ("an attempt is not counted", POOL, "        ci[12] = ci[12] + 1;\n        var watched", "        var watched"),
    ("the cleartext password is never sent", POOL, "            st[p + 11] = ph_password();", "            st[p + 11] = ph_authok();"),
    ("a failed dial is retried at once", POOL, "    st[p + 12] = 0 - 1;\n    reschedule(core, lane, now);\n    return lane;", "    st[p + 12] = now;\n    return lane;"),
    ("a refused login is called a protocol error", POOL, "                code = 4;\n                if st[p + 11] == ph_setup() {", "                code = 10;\n                if st[p + 11] == ph_setup() {"),
    ("a pool is made before the loop has started it", POOL, "if contents(core.ci)[0] != 1 || core.base < 0 {", "if contents(core.ci)[0] != 1 {"),
    ("a longest wait below the first is accepted", POOL, "max_ms < min_ms ||", "max_ms < min_ms - 1 ||"),
    ("a connection lost for a request timeout is not a lost status", POOL, "|| status == 11 || status == 12;", "|| status == 11;"),
    ("a SCRAM challenge of any size is accepted", PG, "    if iterations < 1 || iterations > 1000000 {\n        return (0, 4);", "    if iterations < 1 || iterations > 100000000 {\n        return (0, 4);"),
    ("a SCRAM nonce that does not extend ours is accepted", PG, "    if len(full) <= len(nonce) || !bytes.starts_with(full, nonce) {\n        return (0, 2);", "    if len(full) <= len(nonce) {\n        return (0, 2);"),
    ("PBKDF2 in pieces xors with an or", PG, "state[32 + j] = byte_of(int_of(state[32 + j]) ^ int_of(nb[j]));", "state[32 + j] = byte_of(int_of(state[32 + j]) | int_of(nb[j]));"),
    ("PBKDF2 in pieces starts from nothing", PG, "            state[32 + j] = ub[j];\n", "            state[32 + j] = byte_of(0);\n"),
]


def run(cmd, **kw):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, **kw)


def suites():
    """The suites, in the order a mutant is most likely to fail them. Yields (name, command)."""
    yield "pg_test", [LEX, "test", "tests/pg_test.cho", "src/pg.cho", "--std"]
    yield "pool_test", [LEX, "test", "tests/pool_test.cho", "src/pool.cho", "src/pg.cho", "tests/generated/queries.cho", "--std"]
    yield "scram_test", [LEX, "test", "tests/scram_test.cho", "pooler/scram.cho", "src/pg.cho", "--std"]
    yield "reconnect_test", [sys.executable, "tests/reconnect_test.py", "-f"]


def main():
    wanted = sys.argv[1:]
    killed, survived = 0, []
    scratch = tempfile.mkdtemp()
    for name, rel, old, new in MUTANTS:
        if wanted and not any(w in name for w in wanted):
            continue
        path = os.path.join(ROOT, rel)
        saved = os.path.join(scratch, os.path.basename(rel))
        shutil.copy2(path, saved)
        text = open(path).read()
        if text.count(old) != 1:
            print("BAD MUTANT (%d matches): %s" % (text.count(old), name))
            sys.exit(2)
        try:
            with open(path, "w") as f:
                f.write(text.replace(old, new))
            verdict = "SURVIVED"
            for suite, cmd in suites():
                p = run(cmd, timeout=900)
                if p.returncode != 0:
                    out = p.stdout + p.stderr
                    first = [l.strip() for l in out.splitlines() if l.startswith(("FAIL:", "ERROR:")) or " ... FAILED" in l or l.startswith("error")]
                    verdict = "killed by %s: %s" % (suite, (first[0] if first else out.strip().splitlines()[-1] if out.strip() else "?")[:110])
                    break
        finally:
            shutil.copy2(saved, path)
            assert filecmp.cmp(saved, path, shallow=False), "restore failed for " + rel
        print("%-70s %s" % (name, verdict), flush=True)
        if verdict == "SURVIVED":
            survived.append(name)
        else:
            killed += 1
    print("%d killed, %d survived" % (killed, len(survived)))
    for s in survived:
        print("  survived:", s)
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
