# lexsys-pg: a PostgreSQL client in lex-sys

> **Status: slice 1 built** -- the v3 wire protocol (startup, trust and cleartext-password
> login, simple and extended queries with parameters, describe), checked against a real
> PostgreSQL 16 and the stock `psql` client. Not built: SCRAM-SHA-256 and MD5 login, TLS,
> a non-blocking connection, binary result formats, `COPY`. §5 says what comes after, in
> order, and §6 answers *what sits on top of a driver in a language without reflection*.

## 1. What it is

A client for PostgreSQL's frontend/backend protocol, written in lex-sys over the `Conn`
builtins. No C, no foreign call. `lex-sys authority` on a program using it names the network
(`net_out`, narrowable to one `host:port`), `conn_read`, `conn_write` and `heap`, and nothing
else -- which is the point of writing it in the language rather than linking `libpq`: a service
that talks to a database says so in its own signature, and cannot talk to anything else.

It is a *driver*. It does not know what a table is.

## 2. Three layers

1. **Encoders** build the bytes a client sends: `startup`, `password`, `query` (simple
   protocol), `execute` (Parse, Bind, Describe, Execute, Sync -- parameters travel beside the
   SQL, never inside it), `describe`, `terminate`.
2. **Decoders** read the bytes a server answers with. A reply is the accumulated bytes of every
   message up to `ReadyForQuery`, held in one buffer; `size` frames the message at an offset,
   and `kind`, `fields`, `value`, `column_name`, `column_oid`, `param_count`, `param_oid`,
   `error_field`, `tag`, `auth_code`, `status` read it. Nothing is copied out: a value is a
   `(from, to)` into the reply. A NULL is `(-1, -1)`, an empty string a real, empty range --
   they are different, and the first version of the spike conflated them (NULL's length is `-1`,
   which an unsigned read turns into four billion and a trap).
3. **Blocking helpers** over a `Conn`: `send`, `receive`, `login`, `simple`, `extended`,
   `describing`.

Layers 1 and 2 are pure: they are tested with no server, from canned bytes laid out per the
protocol documentation (`tests/pg_test.ls`, 7 tests). Layer 3 is the only place that waits.

## 3. How it was checked

* **Against the reference client.** `tests/e2e.py` runs 29 queries through both `examples/psql.ls`
  and the stock `psql -At -F '|'` and requires identical rows: integers of every width,
  `numeric`, `float8` including `NaN` and `Infinity`, booleans, `NULL` and the empty string,
  tabs and newlines in text, dates, timestamps, intervals, `bytea`, `uuid`, arrays, `json`,
  `jsonb`, ranges, `inet`, a 100,000-character value, 20,000 rows, 5,000 three-column rows, a
  300-column row and a three-statement string. The large ones cross many 4 KB reads, which is
  where a hand-written decoder tends to break.
* **Errors and commands.** SQLSTATE and message for syntax errors, a missing relation, division
  by zero, a bad integer; command tags for `CREATE`, `INSERT`, `UPDATE`, `DELETE`; the fact that
  the server parses a whole simple-query string before running any of it (a syntax error runs
  nothing) while a runtime error stops it where it happens.
* **Parameters are data.** Hostile values (`'; drop table ...; --`, `$1`, a backslash, a
  newline, a multi-byte character) come back byte for byte; NULL and `''` are distinguished;
  rows written through the driver are read back through `psql`.
* **Login.** Trust, cleartext password (the right one, the wrong one, none) against a role the
  server asks a password of; an unknown database is an `ErrorResponse`, not a hang.
* **Describe.** Parameter and column oids printed by `examples/describe.ls` are compared with
  `pg_type` on the same server.
* **Mutation checks.** Four deliberate bugs in the decoder -- NULL read as empty, a message size
  one byte short, the column-oid offset off by one, a NULL that does not advance the cursor --
  each fail the unit tests; the end-to-end suite catches three of them (it does not print oids,
  so the unit test is what guards that offset).

## 4. What it does not do, and why that is the order it is in

* **Authentication beyond cleartext.** A server asked for `scram-sha-256` -- the default
  `password_encryption` of every PostgreSQL since 14, and what managed offerings use -- is
  answered with status 5. SCRAM needs HMAC-SHA-256, PBKDF2, base64 and an unpredictable client
  nonce; `std` has `sha256` and nothing else of the four. Roughly 150 lines, and the RFC 7677
  test vectors check it. It is the next slice because without it the driver only talks to a
  database configured for it.
* **TLS.** There is none in pure lex-sys. The honest options are a sidecar (`stunnel`,
  `pgbouncer`) in front of the database, OpenSSL through the existing FFI (`lex-sys`'s
  `examples/tls_client` shows it works, and puts C back on the authority report), or a TLS 1.3
  implementation in lex-sys, which is a project of its own. Managed PostgreSQL requires it; a
  database on the same host or the same private network does not.
* **A non-blocking connection.** Every helper in layer 3 waits for the server. In an event loop
  that is one thread serving every client (`http.server`), a query inside a handler stops all of
  them for a round trip -- expected to be on the order of 100-300 microseconds to a local
  server (an estimate; not measured here), which would cap one core at a few thousand requests a
  second whatever the framework does. It is the right first version
  and the wrong last one. Layers 1 and 2 are already sans-io, so the fix is a state machine around
  them registered with the `Poller` and a request that can be suspended and resumed by an id
  (there is no `async`, no closure to resume with): the same inversion `http.server` needed.
  That is a design document and two slices of its own (§5).
* **Binary formats, `COPY`, `LISTEN`/`NOTIFY`, cancellation, pipelining.** Text results are
  what every consumer so far wants and what `psql` prints, so they are what could be checked
  against a reference. The rest are additions to layers 1 and 2, in that order of demand.

## 5. Order of work

1. **Slice 1 (this).** The protocol, tested against a real server.
2. **SCRAM-SHA-256**, with HMAC, PBKDF2 and base64 as small modules of their own (they are useful
   outside this repository, and belong in `lex-sys`'s `std` if they prove out), and the RFC 7677
   vectors as unit tests.
3. **Migrations and a typed-query generator** (§6): SQL files in, plain lex functions out.
4. **A users service on PostgreSQL** in `lexsys-web`, its end-to-end tests and Schemathesis
   unchanged, benchmarked against FastAPI with SQLAlchemy and asyncpg -- the comparison that says
   what the driver and the blocking model cost.
5. **The non-blocking connection and a pool**, with a design document first.
6. **TLS**, once the sidecar-or-FFI-or-implement question has an asker.

## 6. If we cannot have SQLAlchemy, what is the best thing to have?

SQLAlchemy and Django's ORM are built on three things this language does not have: reflection (a
class *is* the table), closures and operator overloading (`User.age > 30` builds a predicate),
and dynamic dispatch (lazy relationships that load on attribute access). No amount of effort in
a library supplies them; the language has captureless function values and no generics over
structs, and that is a deliberate property of what it can prove. So the question is which of the
*goals* of an ORM survive and what the best vehicle for each is.

The four candidates, judged against this language:

| Approach | What it is | Fit |
|---|---|---|
| **A. Query builder over data** (SQLAlchemy Core, Knex) | a tree of values, `select(table).where(col, ">", p)`, compiled to SQL | works, but rows come back as untyped columns by index, joins and CTEs are re-expressed in a DSL that will always be a subset of SQL, and every dynamic identifier is an injection risk |
| **B. SQL first, generated typed functions** (sqlc, sqlx's `query!`) | write `.sql` files; a generator asks the database to describe each statement and emits one typed function per query | fits almost exactly: no reflection needed, the SQL is the real language, the generated code is plain auditable lex with exact parameter and result types and exact effect rows |
| **C. Table declaration to runtime CRUD** (active-record-lite) | a table value built at start-up, `insert`/`get`/`update`/`delete` driven by it | cheap and useful for the boilerplate, limited exactly where queries get interesting |
| **D. Schema DSL to generated client** (Prisma, Ent) | a schema file generates a client and migrations | a large generator and a second language to maintain for what B gives from SQL we already write |

**Recommendation: B as the foundation, with C for the boilerplate, A only for dynamic filters.**

*Why B.* It is the one approach where the language's limits are the feature. A query is a `.sql`
file with a one-line annotation (`-- name: user_by_id :one`); the generator connects to a
development database, sends the statement through `describe` (`pg.describing`, already built and
tested here), and the server answers with the oid of every `$n` and of every result column --
nothing guessed, and a statement the server rejects fails the *generation*, so a query that does
not compile against the schema never reaches a build. The output is a lex function per query,
`user_by_id(heap, conn, id: int) -> ...`, with accessors typed to the column
(`user_by_id_name(row) -> &r [byte]`). It has no reflection because it needs none: the type
information is in the database, and the database is asked. It keeps every SQL feature on day one
-- joins, CTEs, window functions, `RETURNING`, `ON CONFLICT` -- because it never abstracts SQL.
Migrations are numbered `.sql` files and a small runner applying them in order, which needs only
the simple protocol.

*Why it suits this ecosystem in particular.* Authority and effects are the language's selling
point, and generated functions have exact signatures: a handler that calls `user_by_id` says in
its own row that it touches `conn_read`/`conn_write`, and a code reviewer reads the SQL it runs in
a file rather than inferring it from a builder expression. The generated code is content-addressed
like all lex-sys code, so "what queries does this service run" is a question with a stable answer.
And it connects to what exists: the generator can also emit `lexsys-schema` nodes for a result
row or an `INSERT`'s parameters, so the same declaration that validates a request body (`NewUser`)
types the query that stores it, and the OpenAPI document `lexsys-web` writes comes from the
same nodes. That recovers the "one declaration" property an ORM sells, from the direction this
language can support.

*Where it is weaker, honestly.* (1) Nullability is not in `describe`; the generator reads
`pg_attribute` for a result column that is a plain column reference and assumes *nullable* for
every expression, with an annotation to override. (2) Dynamic queries -- a search endpoint with
five optional filters -- are not statements known in advance; that is where a small builder (A) is
the right tool, restricted to assembling a `WHERE` from a fixed set of parameterised predicates,
never from identifiers or values. (3) The generator is another tool to run; it can be written in
lex-sys on this driver (it needs a file read and a connection), so it adds no second language.
(4) There are no relationships, no identity map, no unit of work, no lazy loading. That is the
real loss compared with SQLAlchemy and it is deliberate: those features are what make an ORM's
performance unpredictable and its SQL invisible, and a service that wants to know exactly what
it runs is not asking for them.

*C, the boilerplate.* `get`, `insert`, `update`, `delete` by primary key are the same four
statements for every table. A table is data (a name, columns with `lexsys-schema` nodes, a key),
and the four statements are generated from it at start-up or by the same generator -- the 80% of
a CRUD API that was identical, without pretending the other 20% is.

*Decision for slice 3.* Build the generator (B) and the table-driven CRUD (C) together, because
they share the type mapping (oid to column accessor to schema node); leave the dynamic-filter
builder (A) until an endpoint needs it.

## 7. Open questions

1. **Where the helpers' blocking boundary is drawn** once the non-blocking connection exists:
   whether `pg.simple` and `pg.extended` stay as the blocking convenience over the same state
   machine, or become the state machine's driver for tests only.
2. **`std` or here** for HMAC, PBKDF2 and base64: `lex-sys` has `sha256`; these three are generally
   useful and probably belong beside it. They would be built here first, where they have a
   test (SCRAM) and an asker.
3. **The package's name.** `pg` is short and accurate; the generator and CRUD layer will be a
   separate repository (`lexsys-orm` is the name used so far, though "ORM" overstates it).
