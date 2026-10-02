# lexsys-pg

A PostgreSQL client for [lex-sys](https://github.com/alpibrusl/lex-sys), written in lex-sys:
the v3 frontend/backend wire protocol over a TCP connection. **No C and no foreign call** --
`lex-sys authority` on a program using it reports the network (`net_out`, narrowable to one
`host:port`), `conn_read`, `conn_write`, `heap`, and nothing else: a service that talks to a
database says so in its own signature, and cannot talk to anything else.

It is a *driver*: it moves SQL and rows. What sits on top of it (typed queries generated from
`.sql` files, migrations, table-driven CRUD) and why that is the right shape for a language
without reflection is [`docs/design.md`](docs/design.md) §6.

> **Status: slice 1 built** -- startup, trust and cleartext-password login, simple queries,
> extended queries with parameters, `describe`; checked against PostgreSQL 16 and the stock
> `psql` client. **Not yet:** SCRAM-SHA-256 and MD5 login (a server that asks for one is
> answered with status 5, so today it needs a database configured for `trust` or `password`),
> TLS, a non-blocking connection, binary result formats, `COPY`. Every helper here waits for
> the server. [`docs/design.md`](docs/design.md) §4-§5 says why, and in what order it is fixed.

## Quick start

You need the `lex-sys` compiler (Rust; the toolchain is pinned by its `rust-toolchain.toml`) and
a PostgreSQL to talk to. A package store records no hash of the `std` it was published against,
so the compiler revision is part of the contract; this is the one CI builds and tests with:

```
git clone https://github.com/alpibrusl/lex-sys
(cd lex-sys && git checkout bbeb75f6918105db6e49ec7c642f56009a911b8f && cargo build --release -p lex-sys)
export PATH=$PWD/lex-sys/target/release:$PATH

git clone https://github.com/alpibrusl/lexsys-pg && cd lexsys-pg
docker run --rm -d -p 5432:5432 -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16     # or any server with trust auth

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

Login: `<password>` is answered when the server asks for a cleartext password; `-` sends none. A refused
login is `ERROR 28P01: password authentication failed ...` and exit status 4.

## Using it from your program

`pg` is a package: lock the names you call and fetch them, no copy of `pg.ls` in your tree
(`fetch` refuses a store that no longer matches the lock):

```
lex-sys vcs lock  --store ../lexsys-pg/.lex-sys-vcs -o pg.lock \
    login simple extended describing params param param_null drop_params size kind fields value tag error_field
lex-sys vcs fetch --lock pg.lock --store ../lexsys-pg/.lex-sys-vcs -o deps/
lex-sys build --std app.ls deps/*.ls -o app
```

The shape of a program (`examples/psql.ls` is a complete one):

```
borrow net as &n in {                                    // the network capability
    match tcp_connect(n, "127.0.0.1", 5432) {
        Dialed::Ok(c) => {
            var conn = c;
            borrow mut conn as &!ch in {
                let (hello, status) = pg.login(heap, ch, "postgres", "-", "postgres");   // 0: ready for a query
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
| `login(heap, conn, user, secret, database)` | startup, a cleartext-password answer if asked, up to `ReadyForQuery` |
| `simple(heap, conn, sql)`, `extended(heap, conn, sql, &ps)`, `describing(heap, conn, sql)` | send and receive |

Status codes: `0` ok; `1` the server closed the connection; `2` a read or write would block; `3` a read
failed; `4` the server answered a login with an error (the reply holds the `ErrorResponse`); `5` the
server asked for authentication this cannot do; `6` a write failed.

## Tests

```
lex-sys test tests/pg_test.ls src/pg.ls --std                     # 7 unit tests, no server
PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres python3 tests/e2e.py # 13 tests against a real PostgreSQL
```

The unit tests encode and decode with no server, from replies built here from the protocol's documented
layout. The end-to-end tests need a PostgreSQL with trust authentication and the stock `psql` client as
the **reference**: 29 queries are run through both clients and must print the same rows -- integers of
every width, `numeric`, `NaN`, `NULL` and `''`, newlines in text, dates and intervals, `bytea`, `uuid`,
arrays, `json`, ranges, a 100,000-character value, 20,000 rows, a 300-column row, and several statements
in one string. Errors, tags, parameters (hostile values come back byte for byte), login, and `describe`
(its oids compared with `pg_type`) are checked on the same server. Four deliberate bugs in the decoder
(NULL read as empty, a size one byte short, a column offset, a NULL that does not advance) each fail the
unit tests, and three of the four fail the end-to-end ones. The cleartext-password test runs when
`PG_CLEARTEXT_USER`, `PG_CLEARTEXT_PASSWORD` and `PG_CLEARTEXT_DB` name a role the server asks a password of.

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) builds the pinned compiler and runs all of it
against a `postgres:16` service, and checks that the checked-in package store is the store of `src/pg.ls`.

## Licence

[EUPL-1.2](LICENSE).
