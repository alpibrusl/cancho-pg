#!/bin/sh
# The three package stores of this repository, published afresh from the sources (docs/tls.md section 9):
#
#   .lex-sys-vcs       pg       src/pg.ls, requiring nothing
#   .lex-sys-vcs-pool  pg.pool  src/pool.ls, requiring the names it calls of pg's store and of lex-sys's tls and tls_record
#   .lex-sys-vcs-ssl   pg.ssl   src/ssl.ls, the same
#
#   sh tests/stores.sh          publish into a fresh directory and compare each store with the committed one (CI runs this)
#   sh tests/stores.sh write    publish, and make the committed stores those (after a change to a source, or of the compiler)
#
# A store records the stores it requires: pg's by its path relative to itself (so all three are published side by side, as
# they are committed), lex-sys's by origin (the repository and the commit lex-sys.toml pins). LEX_SYS names the compiler.
set -eu
cd "$(dirname "$0")/.."
LEX=${LEX_SYS:-lex-sys}
REV=$(sed -n 's/^lex-sys = "\([0-9a-f]*\)"$/\1/p' lex-sys.toml)
[ -n "$REV" ] || { echo "no lex-sys revision in lex-sys.toml" >&2; exit 1; }
LEXSYS=https://github.com/alpibrusl/lex-sys
OUT=$(mktemp -d)
# keep the published stores for a look when a check fails
echo "publishing into $OUT" >&2

# what pg.pool and pg.ssl call of pg (a store's requirement is a lock of names)
POOL_PG="auth_code base64_encode error_field hmac_sha256 kind parse_append password pbkdf2_begin pbkdf2_more sasl_initial
  sasl_response scram_client_final_with scram_client_first scram_iterations scram_salt size ssl_answer ssl_request_code startup"
SSL_PG="auth_code bind_named describe execute failure kind login_asks parse_named password query sasl_initial sasl_response
  scram_challenge scram_client_final scram_client_first scram_verdict size ssl_answer ssl_request_code sslmode_disable
  sslmode_verify_full startup status_tag"
# and of lex-sys's engine
POOL_TLS="close drop eof event event_closed event_established event_failed failure feed open open_with_tickets recv seed
  send start take trust would_block"
SSL_TLS="close eof event event_closed event_established event_failed failure feed finish open recv refusal_tag seed send
  start take trust would_block"
RECORD="peer_closed too_many_messages"

$LEX vcs publish --std --store "$OUT/.lex-sys-vcs" src/pg.ls >/dev/null
$LEX vcs lock --git "$LEXSYS" --rev "$REV" --path packages/tls/.lex-sys-vcs/tls -o "$OUT/pool-tls.lock" $POOL_TLS >/dev/null
$LEX vcs lock --git "$LEXSYS" --rev "$REV" --path packages/tls/.lex-sys-vcs/tls -o "$OUT/ssl-tls.lock" $SSL_TLS >/dev/null
$LEX vcs lock --git "$LEXSYS" --rev "$REV" --path packages/tls/.lex-sys-vcs/tls_record -o "$OUT/record.lock" $RECORD >/dev/null
$LEX vcs lock --store "$OUT/.lex-sys-vcs" -o "$OUT/pool-pg.lock" $POOL_PG >/dev/null
$LEX vcs lock --store "$OUT/.lex-sys-vcs" -o "$OUT/ssl-pg.lock" $SSL_PG >/dev/null
$LEX vcs publish --std --store "$OUT/.lex-sys-vcs-pool" --requires "$OUT/pool-pg.lock:$OUT/.lex-sys-vcs" \
    --requires "$OUT/pool-tls.lock" --requires "$OUT/record.lock" src/pool.ls >/dev/null
$LEX vcs publish --std --store "$OUT/.lex-sys-vcs-ssl" --requires "$OUT/ssl-pg.lock:$OUT/.lex-sys-vcs" \
    --requires "$OUT/ssl-tls.lock" --requires "$OUT/record.lock" src/ssl.ls >/dev/null

if [ "${1:-check}" = write ]; then
    for s in .lex-sys-vcs .lex-sys-vcs-pool .lex-sys-vcs-ssl; do
        mkdir -p "$s"
        rsync -a --delete "$OUT/$s/" "$s/"
    done
    echo "written" >&2
    exit 0
fi
status=0
for s in .lex-sys-vcs .lex-sys-vcs-pool .lex-sys-vcs-ssl; do
    if diff -r "$OUT/$s" "$s"; then
        echo "$s: the store of the source" >&2
    else
        echo "$s: NOT the store of the source (sh tests/stores.sh write)" >&2
        status=1
    fi
done
exit $status
