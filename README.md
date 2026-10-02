# lexsys-pg

A PostgreSQL client for [lex-sys](https://github.com/alpibrusl/lex-sys), written in lex-sys:
the v3 frontend/backend wire protocol over a TCP connection. **No C and no foreign call** --
`lex-sys authority` on a program using it reports the network (`net_out`, narrowable to one
`host:port`), `conn_read`, `conn_write`, `heap`, and nothing else: a service that talks to a
database says so in its own signature, and cannot talk to anything else.

It is a *driver*: it moves SQL and rows. What sits on top of it (typed queries generated from
`.sql` files, migrations, table-driven CRUD) and why that is the right shape for a language
without reflection is [`docs/design.md`](docs/design.md) §6.

> **Status: slices 1-2 built** -- startup, trust, cleartext-password and **SCRAM-SHA-256** login
> (the default of every PostgreSQL since 14), simple queries, extended queries with parameters,
> `describe`; checked against PostgreSQL 16 and the stock `psql` client. **Not yet:** MD5 login
> (answered with status 5), TLS, a non-blocking connection, binary result formats, `COPY`. Every
> helper here waits for the server. [`docs/design.md`](docs/design.md) §4-§5 says why, and in what
> order it is fixed.

## Quick start

You need the `lex-sys` compiler (Rust; the toolchain is pinned by its `rust-toolchain.toml`) and
a PostgreSQL to talk to. A package store records no hash of the `std` it was published against,
so the compiler revision is part of the contract; this is the one CI builds and tests with:

```
git clone https://github.com/alpibrusl/lex-sys
(cd lex-sys && git checkout bbeb75f6918105db6e49ec7c642f56009a911b8f && cargo build --release -p lex-sys)
export PATH=$PWD/lex-sys/target/release:$PATH

git clone https://github.com/alpibrusl/lexsys-pg && cd lexsys-pg
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
signature only the real server can compute.

**Not done, on purpose:** SASLprep (RFC 4013) of the password. PostgreSQL's own client applies it; a password
whose normalised form differs from what was typed (a non-breaking space, a compatibility ligature) is not
logged in with here. ASCII and already-normalised text are, and a password with accents and an emoji is one
of the end-to-end tests. Channel binding (`SCRAM-SHA-256-PLUS`) needs TLS, which does not exist yet.

## Tests

```
lex-sys test tests/pg_test.ls src/pg.ls --std                     # 13 unit tests, no server
eval "$(sh tests/postgres.sh)"                                    # a throwaway postgres:16 with a role of each login kind
python3 tests/e2e.py                                              # 19 tests against it (and a mock server)
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

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) builds the pinned compiler and runs all of it
against a `postgres:16` service, and checks that the checked-in package store is the store of `src/pg.ls`.

## Licence

[EUPL-1.2](LICENSE).
