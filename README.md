# lexsys-pg

[![ci](https://github.com/alpibrusl/lexsys-pg/actions/workflows/ci.yml/badge.svg)](https://github.com/alpibrusl/lexsys-pg/actions/workflows/ci.yml)

A PostgreSQL client for [lex-sys](https://github.com/alpibrusl/lex-sys), written in lex-sys:
the v3 frontend/backend wire protocol over a TCP connection. **No C and no foreign call** --
`lex-sys authority` on a program using it reports the network (`net_out`, narrowable to one
`host:port`), `conn_read`, `conn_write`, `heap`, and nothing else: a service that talks to a
database says so in its own signature, and cannot talk to anything else.

It is a *driver*: it moves SQL and rows. What sits on top of it (typed queries generated from
`.sql` files, migrations, table-driven CRUD) and why that is the right shape for a language
without reflection is [`docs/design.md`](docs/design.md) §6.

## Status

**Slices 1 to 4 built:** startup, trust, cleartext-password and **SCRAM-SHA-256** login
(the default of every PostgreSQL since 14), simple queries, extended queries with parameters,
`describe`, prepared statements, and a generator of typed query functions (`tools/pgen.ls`, [below](#typed-queries-pgen)); checked against
PostgreSQL 16 and the stock `psql` client. **TLS** with lex-sys's own TLS client, no foreign code: `sslmode` `disable` and
`verify-full`, for the blocking connection (`pg.ssl`) and the pool (`pool.secure`) ([below](#tls), [`docs/tls.md`](docs/tls.md)). **Not yet:** MD5 login
(answered with status 5), binary result formats, `COPY`. The helpers of layer 3 wait for the
server; **`pg.pool`** ([below](#a-pool-that-does-not-wait)) is the connection that does not, and
[`docs/nonblocking.md`](docs/nonblocking.md) has what it measured. **The pool also reconnects without ever waiting**
(`pool.reconnect`, `tick`, `revive`: a lost connection is replaced, with its statements prepared again, by a login that is a state machine on the
poller's events; [below](#a-pool-that-comes-back) and [`docs/reconnect.md`](docs/reconnect.md)). [`docs/design.md`](docs/design.md)
§4-§5 says why the blocking ones are what they are.

## Requirements

- The **lex-sys** compiler at the revision this repository's CI builds with (below; `653bdd1`, which has `packages/tls` and the
  crypto it needs, and `tcp_connect_start`, the dial that does not wait). It is also `[package] lex-sys` in `lex-sys.toml`, and CI checks that
  the two agree. A package store records no hash of the `std` it was published against, so the compiler revision is part of the contract.
- For `pg.pool` and `pg.ssl`: lex-sys's TLS package, which `lex-sys install` fetches at the commit `lex-sys.toml` pins into `build/deps`
  (`pg` alone needs nothing from it).
- Rust, to build that compiler (its `rust-toolchain.toml` pins the toolchain).
- A **PostgreSQL** to talk to (any version; the tests use 16), and for the tests `docker`, `openssl` and the stock `psql` client.

## Quick start

Get the compiler at the revision CI builds and tests with (read from `ci.yml`, so this text cannot drift from it), and a PostgreSQL:

```
git clone https://github.com/alpibrusl/lex-sys
git clone https://github.com/alpibrusl/lexsys-pg && cd lexsys-pg
REV=$(sed -n 's/^ *LEX_SYS_REV: *//p' .github/workflows/ci.yml)
(cd ../lex-sys && git checkout "$REV" && cargo build --release -p lex-sys)
export PATH=$PWD/../lex-sys/target/release:$PATH

docker run --rm -d -p 5432:5432 -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16     # or any server; trust is simplest

lex-sys build --std examples/psql.ls src/pg.ls -o psql
```

`psql <host> <port> <user> <database> <password|-> <sql> [parameter ...]` prints one line per row
(`|` between values, `\N` for NULL), `# <tag>` for each completed command and
`ERROR <sqlstate>: <message>` for an error. These are real outputs:

```
$ ./psql 127.0.0.1 5432 postgres postgres - "select 1 as n, 'héllo' as s, null as missing, '' as empty"
1|héllo|\N|
# SELECT 1
```

A value is **data, never SQL**: parameters travel beside the statement (the extended protocol), so
nothing a user sends can become part of it. `\N` as a parameter is NULL; `''` is the empty string,
and the two stay different all the way through.

```
$ ./psql 127.0.0.1 5432 postgres postgres - 'select $1::int + $2::int as sum, $3::text as t' 40 2 "it's; drop table users; --"
42|it's; drop table users; --
# SELECT 1
```

The server's own account of a statement -- the type of every `$n` and of every result column, without
running it (`describe`; oid 23 is `int4`, 25 `text`) -- is what a code generator needs to give each
query a typed signature:

```
$ build/describe 127.0.0.1 5432 postgres postgres - 'select id, name from (values (1, $1::text)) v(id, name) where id = $2::int'
$1 25
$2 23
id 23
name 25
```

Errors are the server's, with its SQLSTATE, and the server parses a whole simple-query string before
running any of it, so a runtime error stops it where it happens:

```
$ ./psql 127.0.0.1 5432 postgres postgres - "select 1; select 1/0; select 3"
1
# SELECT 1
ERROR 22012: division by zero
```

Login: `<password>` answers whatever the server asks -- SCRAM-SHA-256 (the usual) or a cleartext password --
and is ignored by a server that trusts the connection; `-` sends none. A refused login is
`ERROR 28P01: password authentication failed ...` and exit status 4:

```
$ ./psql 127.0.0.1 5432 scramuser e2e_scram 's3cr3t pass' "select current_user"      # a scram-sha-256 role
scramuser
# SELECT 1
$ ./psql 127.0.0.1 5432 scramuser e2e_scram wrong "select 1"; echo $?
ERROR 28P01: password authentication failed for user "scramuser"
4
```

SCRAM is mutual: the client also checks the server's signature, which only a server that knows the
password can compute, so an impostor that answers every login with "ok" is refused (exit status 7), as is
a server that asks the client to compute a million-times-over key derivation.

## Typed queries: `pgen`

Writing `pg.extended(heap, conn, "select ... where id = $1", ps)` by hand and counting columns is what a
generator should do. `tools/pgen.ls` reads a file of SQL, asks the server what each statement's parameters and
columns are (`describe`: parsed and planned, not run), and writes a lex-sys module with a typed function per
query. The SQL stays SQL -- joins, CTEs, `RETURNING`, `ON CONFLICT` all work on day one, because nothing is
abstracted -- and a query that does not compile against the schema fails the *generation*, not production.

```
-- queries.sql
-- name: user_by_id id
select id, name, age from users where id = $1

-- name: add_user name age
insert into users (name, age) values ($1, $2) returning id
```

```
$ lex-sys build --std tools/pgen.ls src/pg.ls -o pgen
$ ./pgen 127.0.0.1 5432 postgres postgres - queries.sql > queries.ls          # module `queries`, from the file name
$ lex-sys build --std app.ls queries.ls src/pg.ls -o app
```

and the generated functions are what the program calls (`tests/gen_use.ls` is a complete one). The module also
has `prepare_all`: call it **once, after login**, and it parses every query on that connection under the
query's name; each query then runs by name, so PostgreSQL parses and plans it once instead of on every call
(about half the server's time on a one-row lookup, [`docs/design.md`](docs/design.md) section 4). It answers
the reply of the first refusal -- the schema no longer fits a query -- and a status, and nothing is to be run
unless both are clean. A query run without it is the server's own `26000`, not a hang.

```
let (refused, status) = queries.prepare_all(heap, conn);       // once, after pg.login
let (reply, status) = queries.user_by_id(heap, conn, 7);       // (id: int) -- the type came from the server
borrow reply as &rr in {
    let m = buffer.bytes(rr);
    var row = pg.first_row(m);
    while row >= 0 {
        let id = queries.user_by_id_id(m, row);                 // int
        let (from, to) = queries.user_by_id_name(m, row);       // text: a range of `m`, no copy
        if !queries.user_by_id_age_is_null(m, row) {            // age can be NULL, so it has an `_is_null`
            let age = queries.user_by_id_age(m, row);
        }
        row = pg.next_row(m, row);
    }
}
buffer.drop(heap, reply);
```

What the types are: a `$n` or a column of type `bool`, `int2`, `int4`, `int8` or `oid` is a `bool` or an `int`;
every other type (uuid, timestamp, numeric, json, bytea, ...) is `&[byte]` going in and the `(from, to)` range
of the **server's own text** coming out -- the generator does not guess a representation. A column gets an
`_is_null` accessor unless it is a plain reference to a table column the catalogue says is `NOT NULL`; a query
with a `join` in it has none, because an outer join makes a `NOT NULL` column NULL and the server does not say
so (a column *named* `joined` is not a join). Expressions -- `count(*)` -- are conservatively nullable.
`pg.failure(reply)` is the server's error, `pg.affected(reply)` the row count of an `INSERT`/`UPDATE`/`DELETE`.

Refused, with the query's name and a reason, and **nothing written** if any query is: a statement the server
rejects (its SQLSTATE), a name used twice, a result column that is not a plain identifier (alias it), two
functions that would share a name, parameter names that are the wrong number, repeated, or `heap`/`conn`, and a
statement with a control character in it. Not yet: dynamic filters, a result type per query (`:one`/`:many`), and `float`/`numeric` as lex
types.

A parameter that may be NULL is marked in the annotation: `-- name: add_user name age? nickname?` makes
`add_user(heap, conn, name, age, age_given, nickname, nickname_given)`, and a parameter whose `_given` is false is
sent as NULL (an empty string and `0` are values, not NULL). [`docs/design.md`](docs/design.md) §8 has the reasoning.

## A pool that does not wait

`src/pool.ls` (module `pg.pool`) holds a few logged-in, non-blocking connections and pipelines requests over
them, so that a loop with other work (an HTTP server) does not stop while PostgreSQL answers. The loop owns the
poller; the pool only asks to be told when its connections are ready:

```
var pl = pool.empty(heap, 4, 64, 131072, 131072);          // 4 connections, 64 requests deep each, slab sizes
(pl, slot) = pool.add(heap, pl, conn);                     // logged in and prepared with `pg.login`, `queries.prepare_all`
pool.start(pl, poller, first_token);                       // watch them, under tokens from first_token
...
pool.submit(pl, tag, queries.get_user_start(heap, id));    // queue; 0, or -1 full, -3 none live
pool.flush(pl, poller);                                    // once per turn: one write per connection
...                                                        // on a poller event for a token `pool.owns`:
pool.pump(pl, poller, token, readiness);
while (tag = pool.next_done(pl)) >= 0 { ... pool.reply(pl), pool.status(pl) ... }
```

The reply is what `pg.run_named` returns, so every accessor `pgen` wrote works on it. A connection the server
closes, or that sends something that is not the protocol, answers every request still on it with a `status` that is
not 0, in its place in the order. `examples/` has no program for it: `lexsys-web`'s `users_pg` is the user, with
`lex-sys`'s `http.server` (`hold`/`answer`). The package is a store of its own,
`.lex-sys-vcs-pool`, requiring the names it calls of `.lex-sys-vcs` and of lex-sys's `tls` (by origin: a consumer gets it fetched
with the pool). `pg.ssl` is a third store, `.lex-sys-vcs-ssl`; `tests/stores.sh` publishes all three.

### A pool that comes back

A connection that is lost (a restart, a cut network, an idle timeout, `pg_terminate_backend`) is **not** replaced by the pool above unless it is
asked to: give it the login and the statements once, and it makes the connections itself, never waiting for the server, the network or the key
derivation of a SCRAM login. The requests that were on the connection are answered with a status that says the connection was lost
(`pool.lost(status)`: the outcome is unknown), nothing is lost or answered twice, the next request after the new connection is up runs on a
connection that has the statements prepared, and a database that is down, silent, or refuses the password is retried after 100 ms, 200 ms, 400 ms ...
up to a longest wait you choose, never faster.

```
var pl = pool.empty(heap, 4, 64, 131072, 131072);
let (made, rc) = pool.reconnect(heap, pl, user, password, database, seed, setup, statements,
                                100, 5000, 5000, 0);     // waits 100 ms .. 5 s; an attempt may take 5 s; no request timeout
pl = made;                                               // seed: 16+ bytes from /dev/urandom; setup, statements: queries.prepare_script(heap)
pool.start(pl, poller, first_token);                     // no connection yet, and nothing waited for
...                                                      // each turn of the loop:
pl = pool.revive(heap, pl, net, "127.0.0.1", 5432, poller, clock_ms(clock));   // tick + a dial and adopt for each connection due
let wait = pool.next_wake(pl, now);                      // -1, or the ms until the pool needs a turn: poller_wait(..., min(wait, mine))
...                                                      // pump / submit / flush / next_done as before; pool.live(pl), pool.reconnects(pl) ...
```

`revive` is for a program that holds the whole network (`Net("")`). One that narrowed its network to the database calls `tick`, `tcp_connect_start`
and `adopt` (or `dial_failed`) itself, so that `lex-sys authority` still says `net_out("127.0.0.1:5432")` and not more (`tests/narrow_use.ls` is
that program, and the test reads its authority): the pool never dials. A host *name* is resolved by a call that waits (the compiler's, in
`tcp_connect_start`); give an address. [`docs/reconnect.md`](docs/reconnect.md) has the states, the status codes, every measurement and what is not done.

## Using it from your program

`pg` is a package: lock the names you call and fetch them, no copy of `pg.ls` in your tree
(`fetch` refuses a store that no longer matches the lock):

```
lex-sys vcs lock  --store ../lexsys-pg/.lex-sys-vcs -o pg.lock \
    login simple extended describing params param param_null drop_params size kind fields value tag error_field base64_encode
lex-sys vcs fetch --lock pg.lock --store ../lexsys-pg/.lex-sys-vcs -o deps/
lex-sys build --std app.ls deps/*.ls -o app
```

The shape of a program (`examples/psql.ls` is a complete one, including `fresh_nonce`: 18 bytes
from a `/dev/urandom` capability narrowed to that one file, as base64 -- the `nonce` below):

```
borrow net as &n in {                                    // the network capability
    match tcp_connect(n, "127.0.0.1", 5432) {
        Dialed::Ok(c) => {
            var conn = c;
            borrow mut conn as &!ch in {
                let (hello, status) = pg.login(heap, ch, "postgres", "-", "postgres", nonce);   // 0: ready for a query
                buffer.drop(heap, hello);
                let (reply, s) = pg.simple(heap, ch, "select 1, 'x'");                    // everything up to ReadyForQuery
                borrow reply as &rb in {
                    let m = buffer.bytes(rb);
                    var at = 0;
                    while pg.size(m, at) > 0 {                                            // walk the messages
                        if pg.kind(m, at) == 68 {                                         // 'D': a DataRow
                            let (from, to) = pg.value(m, at, 1);                          // column 1, as a range of `m`
                            ...                                                           // m[from..to]; from < 0 is NULL
                        }
                        at = at + pg.size(m, at);
                    }
                }
                buffer.drop(heap, reply);
            }
            conn_close(conn);
        }
        Dialed::Failed(e) => { ... }
    }
}
```

Nothing is copied out of the reply; a value is a `(from, to)` into the one buffer that holds it, and
a NULL is `(-1, -1)` while an empty string is a real, empty range.

### The API

| Encode (the bytes a client sends) | |
|---|---|
| `startup(heap, user, database)`, `password(heap, secret)`, `terminate(heap)` | connection setup and teardown |
| `query(heap, sql)` | a simple query: one message, results as text, several `;`-separated statements allowed |
| `params(heap)`, `param(heap, ps, value)`, `param_null(heap, ps)`, `drop_params(heap, ps)` | a parameter list |
| `execute(heap, sql, &ps)` | Parse, Bind, Describe, Execute, Sync: `$1`, `$2`, ... bound as data |
| `describe(heap, sql)` | the types of a statement's parameters and columns, without running it |
| `parse_named(heap, name, sql)`, `bind_named(heap, name, &ps)` | Parse a statement under a name, once; then Bind and Execute it by name (no Parse, no Describe) |

| Decode (a reply is every message up to `ReadyForQuery`, in one buffer) | |
|---|---|
| `size(m, at)` | the size of the message at `at`; `-1` not all there yet, `-2` impossible |
| `kind(m, at)` | its type byte (`R` 82 auth, `T` 84 columns, `D` 68 row, `C` 67 done, `E` 69 error, `Z` 90 ready, `t` 116 params) |
| `fields(m, at)`, `value(m, at, i)` | a `DataRow`'s count, and value `i` as `(from, to)`; NULL is `(-1, -1)` |
| `column_name(m, at, i)`, `column_oid(m, at, i)` | a `RowDescription`'s column `i` |
| `param_count(m, at)`, `param_oid(m, at, i)` | a `ParameterDescription`: the type of `$i` |
| `error_field(m, at, code)` | an `ErrorResponse` field by code byte: `C` 67 SQLSTATE, `M` 77 message, `S` 83 severity, `H` 72 hint |
| `tag(m, at)`, `status(m, at)`, `auth_code(m, at)`, `ready(m)` | the command tag; the transaction status; an authentication request; whether a reply is complete |

| Over a connection (blocking) | |
|---|---|
| `send(conn, bytes)`, `receive(heap, conn)` | write all of it; read up to `ReadyForQuery` |
| `login(heap, conn, user, secret, database, nonce)` | startup, whatever authentication the server asks (trust, cleartext, SCRAM-SHA-256), up to `ReadyForQuery`. `nonce`: at least 18 unpredictable bytes written as printable characters without a comma -- `examples/psql.ls` reads 18 bytes from `/dev/urandom` and base64-encodes them; an empty one makes a SCRAM server be refused |
| `simple(heap, conn, sql)`, `extended(heap, conn, sql, &ps)`, `describing(heap, conn, sql)` | send and receive |
| `prepare(heap, conn, name, sql)`, `run_named(heap, conn, name, &ps)` | prepare a statement on this connection; run it by name (see below) |
| `prepare_after(heap, conn, reply, status, name, sql)` | `prepare`, but only if the step before it went well: a chain of these prepares everything and stops at the first refusal |

| SCRAM-SHA-256 and the primitives it is made of (pure; each is also useful alone) | |
|---|---|
| `base64_encode(heap, data)`, `base64_decode(heap, text)` | RFC 4648; decode answers `(bytes, ok)` and refuses bad padding or alphabet |
| `hmac_sha256(heap, key, message)` | RFC 2104, 32 bytes; checked against RFC 4231 |
| `pbkdf2_sha256(heap, password, salt, iterations)` | RFC 8018, 32 bytes |
| `scram_client_first(heap, user, nonce)`, `scram_client_final(heap, password, user, nonce, server_first)` | the two client messages; the second answers `(client-final, expected server-final, status)` |

Status codes: `0` ok; `1` the server closed the connection; `2` a read or write would block; `3` a read
failed; `4` the server answered a login with an error (the reply holds the `ErrorResponse`); `5` the
server asked for authentication this cannot do (MD5); `6` a write failed; `7` the SCRAM exchange failed on
the client's side: no nonce, a challenge that is malformed, whose nonce does not extend the client's, whose
salt is not base64 or whose iteration count is not 1..1,000,000, or a final message that does not carry the
signature only the real server can compute. TLS adds `13` the server will not do TLS (`N`) and `verify-full` was asked for, `14` its
answer to SSLRequest was not one byte `S` or `N`, `15` the handshake or a record failed (the engine's code says why), `16` TLS could
not start. `status_tag(status)` names every one (`pg-closed`, `pg-ssl-not-offered`, ...); [`docs/tls.md`](docs/tls.md) §8 has the table.

**Not done, on purpose:** SASLprep (RFC 4013) of the password. PostgreSQL's own client applies it; a password
whose normalised form differs from what was typed (a non-breaking space, a compatibility ligature) is not
logged in with here. ASCII and already-normalised text are, and a password with accents and an emoji is one
of the end-to-end tests. Channel binding (`SCRAM-SHA-256-PLUS`) is not done: it needs the server certificate's hash from the TLS
engine ([`docs/tls.md`](docs/tls.md) §12).

## TLS

`pg.ssl` (`src/ssl.ls`) is a blocking connection that may be TLS, and `pool.secure` makes every connection a pool makes TLS; both
use lex-sys's own TLS client (`packages/tls`, TLS 1.3 and 1.2) and nothing foreign, so `lex-sys authority` of a program is what it
was, plus the CA file it reads. **Two modes**: `disable` (what every function did before, and still the default) and `verify-full`
(the server's chain to a root the program trusts, its name, its dates). `require`, `verify-ca`, `prefer` and `allow` are **not
offered**: the engine always verifies chain and name, and the weaker modes are either unauthenticated or downgradeable by whoever
answers `N` ([`docs/tls.md`](docs/tls.md) §4 has the reasons). The TLS engine is **not independently reviewed** (lex-sys #209).

```
let (link, status) = ssl.open(heap, conn, pg.sslmode(mode_text), "db.internal", entropy, pem, clock_unix_ms(clock));
let (hello, s) = ssl.login(heap, link, user, secret, database, nonce);     // and simple, extended, describing, prepare, run_named, request
conn_close(ssl.close(heap, link));                                         // close_notify, the engine's secrets overwritten

let (made, roots) = pool.secure(heap, pl, "db.internal", entropy, pem, clock_unix_ms(clock), clock_ms(clock));   // before reconnect/start
```

The program reads `entropy` (32 bytes of `/dev/urandom`) and `pem` (the trust store: an operator's CA, or the system bundle) itself, so
the library holds no file capability. The name checked is not the address dialled (libpq's `host` and `hostaddr`). A refusal has a tag:
`pg.status_tag(status)`, and for status 15 the engine's, `ssl.reason(link, status)` or `tls.refusal_tag(pool.tls_failure(pl))`:

```
$ build/psql_tls verify-full build/tls/ca.crt localhost 127.0.0.1 5432 postgres postgres - "select ssl, version from pg_stat_ssl where pid = pg_backend_pid()"
t|TLSv1.3
# SELECT 1
$ build/psql_tls verify-full build/tls/ca.crt wrong.test 127.0.0.1 5432 postgres postgres - "select 1"; echo $?
ERROR x509-name-mismatch
15
$ build/psql_tls verify-full build/tls/ca.crt localhost 127.0.0.1 5433 postgres postgres - "select 1"     # a server with ssl=off
ERROR pg-ssl-not-offered
```

(`lex-sys install; lex-sys build --std examples/psql_tls.ls src/ssl.ls src/pg.ls build/deps/*.ls -o build/psql_tls`.) What a TLS
connection costs to open, the memory a connection takes, and what is not done (direct TLS, client certificates, channel binding) are
[`docs/tls.md`](docs/tls.md) §9 and §11.

## A connection pooler

`pooler/pooler.ls` is a PostgreSQL connection pooler in the PgBouncer's `transaction` mode, written in lex-sys on the same loop as the cache: a few logged-in server connections
are lent to many clients one transaction at a time, clients are asked for a password with SCRAM-SHA-256 if one is given, and a named prepared statement is refused in the server's
words (it would outlive the transaction on a connection the client will not see again).

```
lex-sys build --std pooler/pooler.ls pooler/frame.ls pooler/scram.ls src/pg.ls -o pooler-bin
./pooler-bin <listen port> <server host> <server port> <user> <database> <server password | -> <pool size> [<client password>]
```

Against PgBouncer 1.22 it measures at parity (within about ten percent either way) on throughput and below it on CPU per transaction. What it does and does not do, and
every measurement with its caveats, is [`docs/pooler.md`](docs/pooler.md).

## Tests

```
lex-sys install                                                   # lex-sys's tls package into build/deps (pg.pool and pg.ssl need it)
lex-sys test tests/pg_test.ls src/pg.ls --std                     # 29 unit tests, no server
eval "$(sh tests/postgres.sh)"                                    # a throwaway postgres:16 with a role of each login kind, TLS on
python3 tests/e2e.py                                              # 46 tests against it (and a mock server)
lex-sys test tests/pool_test.ls src/pool.ls src/pg.ls tests/generated/queries.ls build/deps/*.ls --std   # 12 pool tests, no server
python3 tests/reconnect_test.py                                   # 34 tests of the reconnecting pool: PostgreSQL behind a proxy, and mocks
python3 tests/tls_test.py                                         # 38 TLS tests: the server with verify-full, refusals, mocks, a restart
sh tests/stores.sh                                                # the three published stores are the stores of the sources
```

The unit tests encode and decode with no server, from replies built here from the protocol's documented
layout, and check HMAC against RFC 4231, base64 against RFC 4648, PBKDF2 against Python's `hashlib`, and
the whole SCRAM exchange against the example in RFC 7677. The end-to-end tests need a PostgreSQL with trust
authentication and the stock `psql` client as the **reference** (`tests/postgres.sh` starts one, with
a role for each login kind): 29 queries are run through both clients and must print the same rows -- integers of
every width, `numeric`, `NaN`, `NULL` and `''`, newlines in text, dates and intervals, `bytea`, `uuid`,
arrays, `json`, ranges, a 100,000-character value, 20,000 rows, a 300-column row, and several statements
in one string. Errors, tags, parameters (hostile values come back byte for byte), login, and `describe`
(its oids compared with `pg_type`) are checked on the same server. Four deliberate bugs in the decoder
(NULL read as empty, a size one byte short, a column offset, a NULL that does not advance) each fail the
unit tests, and three of the four fail the end-to-end ones. The cleartext-password and SCRAM tests run when
`PG_CLEARTEXT_*` / `PG_SCRAM_*` / `PG_SCRAM_UNICODE_*` (`_USER`, `_PASSWORD`, `_DB`) name roles the server asks
those of. SCRAM is checked against a real server (the right password, near misses, an accented one, a
fresh nonce every handshake -- read off the wire through a tap) and against an **impostor** written in
the test: the same mock server that is an honest control also, in turn, signs wrongly, skips its signature,
answers with a nonce that is not an extension of the client's, and asks for zero or fifty million iterations;
the client must refuse each. Seven deliberate bugs in the SCRAM code (signature check off, nonce check off, an
iteration short, a long HMAC key not hashed, a wrong key label, the proof computed from the wrong key, the
iteration cap raised) each fail at least one of the two suites.

The generator is checked four ways: its output for `tests/queries.sql` must equal the checked-in
`tests/generated/queries.ls` (so that file cannot go stale); a program using that checked-in module
(`tests/gen_use.ls`) runs a scenario against the seeded database, its output is compared line by line and the
tables it leaves behind are read back with `psql` (a hostile string passed as a parameter is stored as data and
the table is still there); the types and the nullability it infers are asserted for each kind of parameter and
column, and every module it writes is run through `lex-sys check`; and fourteen kinds of bad input each fail with
a reason and write nothing. Thirteen deliberate bugs in the generator and the new decoders -- nullability
inverted, the join check off, `"` or `\` not escaped in the SQL literal, `int8` or `bool` read as text, a repeated
name allowed, a server error ignored, an integer read or written without its sign, the wrong word of a command tag, a
row visited twice, the column number off by one -- each fail at least one suite; the two sign bugs only the unit
tests catch, since the scenario has no negative numbers.

The reconnecting pool is checked on its own (`tests/reconnect_test.py`, [`docs/reconnect.md`](docs/reconnect.md) §6): a backend killed while the
pool is idle and with requests in flight, a server that goes away and comes back (a proxy, `tests/tcpproxy.py`, cuts and restores the network so the
server is left alone), a database that drops every packet, one that accepts and never answers, a wrong password, SCRAM and cleartext logins, one
connection of four killed, a connection that dies the moment it is made, and mock servers that answer the login in pieces, badly or hostilely; the
loop reports the longest it was kept from waiting. NN deliberate bugs in the pool and the SCRAM pieces (`tests/mutants.py`) each fail a test.

TLS is checked on its own (`tests/tls_test.py`, [`docs/tls.md`](docs/tls.md) §10 and §11): `tests/postgres.sh` runs the server with TLS on and
a certificate from a test CA that `tests/tls_certs.sh` makes on every run, a `hostssl` and a `hostnossl` role, and a second server with
`ssl=off`. The blocking client and the pool connect by name and by address with `verify-full` (trust, cleartext and SCRAM logins, the reference
client's rows over TLS); a wrong name, another CA, an empty trust store and the modes not offered are refused, each with its tag; mock servers
answer SSLRequest with bytes after the `S`, an ErrorResponse, a stray byte, a close, or something that is not TLS, and break a live session with a
record that does not authenticate or a close_notify; the pool remakes eight connections over one engine after every backend is ended, and after
a real `docker restart` of the server; the plaintext the engine holds when the pool's input is full is delivered to a loop that sleeps; and the
authority of two programs is checked (nothing foreign). The TLS mutants of `tests/mutants.py --tls` are in [`docs/tls.md`](docs/tls.md) §11.

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) builds the pinned compiler, installs the TLS package and runs all of it
against a `postgres:16` with TLS on, and checks that the three checked-in package stores are the stores of their sources.

## Documentation

- [`docs/design.md`](docs/design.md): the layers (driver, typed queries, helpers), why the blocking calls are what they are, and
  what each slice found.
- [`docs/nonblocking.md`](docs/nonblocking.md): the non-blocking connection and `pg.pool`, with what they measured.
- [`docs/reconnect.md`](docs/reconnect.md): the pool that makes its own connections: the login as a state machine, the backoff, what a caller sees, and every measurement.
- [`docs/pooler.md`](docs/pooler.md): the connection pooler, what it does and does not do, and every measurement with its caveats.
- [`docs/tls.md`](docs/tls.md): TLS to the server with lex-sys's own TLS client: why `disable` and `verify-full` only, the blocking link and the
  pool, the refusals and their tags, the costs, the tests and what they measured.

## Layout

```
src/pg.ls          the driver: login (trust, cleartext, SCRAM-SHA-256), simple and extended queries, describe, prepared statements
src/pool.ls        pg.pool: a few non-blocking connections, pipelined, for a loop that must not wait, and that makes its own (over TLS with `secure`)
src/ssl.ls         pg.ssl: a blocking connection that may be TLS (sslmode disable or verify-full)
tools/pgen.ls      the generator of typed query functions from .sql files
examples/          psql.ls, psql_tls.ls and describe.ls: small command-line clients
lex-sys.toml       the compiler and the one dependency (lex-sys's tls package)
pooler/            the connection pooler (PgBouncer's transaction mode)
tests/             unit tests (lex-sys), end-to-end tests against PostgreSQL 16 and a mock server (Python)
docs/              design, non-blocking, reconnect, pooler, tls
```

## Limitations

Not yet: MD5 login (answered with status 5), binary result formats, `COPY`. TLS is `disable` and `verify-full` only, with no direct TLS
(PostgreSQL 17's `sslnegotiation=direct`), no client certificate, no channel binding and no revocation check, on an engine not yet
independently reviewed ([`docs/tls.md`](docs/tls.md)); the pooler speaks no TLS. The password is not
SASLprep-normalised. The blocking helpers wait for the server; `pg.pool` is the connection that does not, and with `reconnect` it comes back
by itself (a host *name* is still resolved by a call that waits; a connection that goes silent without a close is found only by the request timeout).

## Contributing

Every change goes through what CI runs: the unit tests, `lex-sys fmt --check`, the end-to-end tests against a `postgres:16`
service (TLS on), the pooler tests, the TLS tests, and the check that the published package stores are the stores of `src/pg.ls`,
`src/pool.ls` and `src/ssl.ls` (`sh tests/stores.sh`; `sh tests/stores.sh write` after a change). Design
before code, in `docs/`, with claims measured; a claim that turns out false is corrected in place.

## Licence

[EUPL-1.2](LICENSE).
