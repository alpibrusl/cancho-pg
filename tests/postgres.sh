#!/bin/sh
# A throwaway PostgreSQL 16 for tests/e2e.py, on localhost:5432, with one role of each way a
# server can ask for a password:
#
#   postgres     (any database)  trust                           -- the default every test uses
#   pwuser       e2e_pw          password   (cleartext)          PG_CLEARTEXT_*
#   scramuser    e2e_scram       scram-sha-256                    PG_SCRAM_*
#   scramuni     e2e_scram_uni   scram-sha-256, non-ASCII secret  PG_SCRAM_UNICODE_*
#
# It runs with TLS on (docs/tls.md section 10), with a certificate from a test CA that tests/tls_certs.sh makes afresh in
# build/tls; a client that does not ask for TLS is served as before, so every suite but tests/tls_test.py is unchanged.
# Two roles are for TLS alone:
#
#   tlsonly      e2e_tls_only    trust over TLS (hostssl), refused without it    PG_TLS_ONLY_*
#   plainonly    e2e_plain_only  trust without TLS (hostnossl), refused with it  PG_PLAIN_ONLY_*
#
# and a second server, lexsys-pg-test-nossl on localhost:5433, runs with ssl=off (it answers SSLRequest with `N`).
#
# Needs docker, openssl and a psql client. Stop them with `docker rm -f lexsys-pg-test lexsys-pg-test-nossl`. The environment
# for the end-to-end tests is printed on stdout: `eval "$(sh tests/postgres.sh)"`.
set -eu
NAME=lexsys-pg-test
NOSSL=lexsys-pg-test-nossl
TLS_DIR=$(sh "$(dirname "$0")/tls_certs.sh" "$(pwd)/build/tls")
docker rm -f "$NAME" "$NOSSL" >/dev/null 2>&1 || true
# The key must belong to the server's user and be 0600: a copy made inside the container, from a read-only mount.
docker run -d --name "$NAME" -p 5432:5432 -e POSTGRES_HOST_AUTH_METHOD=trust -v "$TLS_DIR":/certs:ro postgres:16 sh -c '
    mkdir -p /tls && cp /certs/server.crt /certs/server.key /tls/ && chown -R postgres /tls && chmod 600 /tls/server.key &&
    exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/tls/server.crt -c ssl_key_file=/tls/server.key' >/dev/null
docker run -d --name "$NOSSL" -p 5433:5432 -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16 >/dev/null

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
create role tlsonly login;
create role plainonly login;
create database e2e_tls_only owner tlsonly;
create database e2e_plain_only owner plainonly;
SQL

# pwuser's password is stored as a SCRAM verifier, which the `password` method also accepts.
docker exec -u postgres "$NAME" sh -c '
    f=$(psql -Atc "show hba_file")
    { printf "%s\n" \
        "host e2e_pw pwuser all password" \
        "host e2e_scram scramuser all scram-sha-256" \
        "host e2e_scram_uni scramuni all scram-sha-256" \
        "hostssl e2e_tls_only tlsonly all trust" \
        "hostnossl e2e_tls_only tlsonly all reject" \
        "hostnossl e2e_plain_only plainonly all trust" \
        "hostssl e2e_plain_only plainonly all reject"
      cat "$f"; } > /tmp/hba.new
    cp /tmp/hba.new "$f"
    psql -Atc "select pg_reload_conf()" >/dev/null' >&2

tries=0
until PGPORT=5433 psql -Atc 'select 1' >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -lt 60 ] || { echo "the server without TLS did not come up" >&2; exit 1; }
    sleep 1
done

cat <<ENV
export PG_TLS_CA=$TLS_DIR/ca.crt PG_TLS_OTHER_CA=$TLS_DIR/other.crt PG_TLS_CONTAINER=$NAME PG_NOSSL_PORT=5433
ENV
cat <<'ENV'
export PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGDATABASE=postgres
export PG_CLEARTEXT_USER=pwuser PG_CLEARTEXT_PASSWORD=hunter2 PG_CLEARTEXT_DB=e2e_pw
export PG_SCRAM_USER=scramuser PG_SCRAM_PASSWORD='s3cr3t pass' PG_SCRAM_DB=e2e_scram
export PG_SCRAM_UNICODE_USER=scramuni PG_SCRAM_UNICODE_PASSWORD='pässwörd 🔑' PG_SCRAM_UNICODE_DB=e2e_scram_uni
export PG_TLS_ONLY_USER=tlsonly PG_TLS_ONLY_DB=e2e_tls_only PG_PLAIN_ONLY_USER=plainonly PG_PLAIN_ONLY_DB=e2e_plain_only
ENV
