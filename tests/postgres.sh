#!/bin/sh
# A throwaway PostgreSQL 16 for tests/e2e.py, on localhost:5432, with one role of each way a
# server can ask for a password:
#
#   postgres     (any database)  trust                           -- the default every test uses
#   pwuser       e2e_pw          password   (cleartext)          PG_CLEARTEXT_*
#   scramuser    e2e_scram       scram-sha-256                    PG_SCRAM_*
#   scramuni     e2e_scram_uni   scram-sha-256, non-ASCII secret  PG_SCRAM_UNICODE_*
#
# Needs docker and a psql client. Stop it with `docker rm -f lexsys-pg-test`. The environment
# for the end-to-end tests is printed on stdout: `eval "$(sh tests/postgres.sh)"`.
set -eu
NAME=lexsys-pg-test
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p 5432:5432 -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16 >/dev/null

export PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGDATABASE=postgres
tries=0
until psql -Atc 'select 1' >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -lt 60 ] || { echo "postgres did not come up" >&2; exit 1; }
    sleep 1
done

psql -q -v ON_ERROR_STOP=1 >&2 <<'SQL'
set password_encryption = 'scram-sha-256';
create role pwuser login password 'hunter2';
create role scramuser login password 's3cr3t pass';
create role scramuni login password 'pässwörd 🔑';
create database e2e_pw owner pwuser;
create database e2e_scram owner scramuser;
create database e2e_scram_uni owner scramuni;
SQL

# pwuser's password is stored as a SCRAM verifier, which the `password` method also accepts.
docker exec -u postgres "$NAME" sh -c '
    f=$(psql -Atc "show hba_file")
    { printf "%s\n" \
        "host e2e_pw pwuser all password" \
        "host e2e_scram scramuser all scram-sha-256" \
        "host e2e_scram_uni scramuni all scram-sha-256"
      cat "$f"; } > /tmp/hba.new
    cp /tmp/hba.new "$f"
    psql -Atc "select pg_reload_conf()" >/dev/null' >&2

cat <<'ENV'
export PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGDATABASE=postgres
export PG_CLEARTEXT_USER=pwuser PG_CLEARTEXT_PASSWORD=hunter2 PG_CLEARTEXT_DB=e2e_pw
export PG_SCRAM_USER=scramuser PG_SCRAM_PASSWORD='s3cr3t pass' PG_SCRAM_DB=e2e_scram
export PG_SCRAM_UNICODE_USER=scramuni PG_SCRAM_UNICODE_PASSWORD='pässwörd 🔑' PG_SCRAM_UNICODE_DB=e2e_scram_uni
ENV
