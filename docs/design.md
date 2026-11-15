# cancho-pg: a PostgreSQL client in cancho

> **Status: slices 1-4 built; the non-blocking connection is built ([`nonblocking.md`](nonblocking.md)) and reconnects by itself ([`reconnect.md`](reconnect.md))** -- the v3 wire protocol (startup, trust, cleartext-password and
> SCRAM-SHA-256 login, simple and extended queries with parameters, describe), checked against
> a real PostgreSQL 16 and the stock `psql` client, the typed-query generator `tools/pgen.cho` (§8), and prepared statements (§4, §9), and TLS (`sslmode` `disable` and `verify-full`, [`tls.md`](tls.md)). Not built: MD5 login,
> binary result formats, `COPY`. §5 says what comes after, in
> order, and §6 answers *what sits on top of a driver in a language without reflection*.

## 1. What it is

A client for PostgreSQL's frontend/backend protocol, written in cancho over the `Conn`
builtins. No C, no foreign call. `cancho authority` on a program using it names the network
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
protocol documentation and the RFC vectors (`tests/pg_test.cho`, 20 tests). Layer 3 is the only place that waits.

## 3. How it was checked

* **Against the reference client.** `tests/e2e.py` runs 29 queries through both `examples/psql.cho`
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
* **Login.** Trust, cleartext password and SCRAM-SHA-256 (the right password, near misses, none, an
  accented one with an emoji) against roles the server asks those of; an unknown database is an
  `ErrorResponse`, not a hang. The reference client logs in to the same roles first, so a role `psql`
  cannot use is not blamed on this.
* **An impostor server.** SCRAM is mutual, and the half a client most easily forgets is the check of
  the *server's* signature. `tests/e2e.py` has a mock server holding the password: honest, it is the
  control (the client logs in and runs a query); signing wrongly, or not signing at all, it must be
  refused; answering a nonce that does not extend the client's, or asking for zero or fifty million
  PBKDF2 iterations, it must be refused without being answered. A hostile server would otherwise choose
  how long the client computes. The client's nonce is read off the wire through a tap on two logins and
  must differ and be at least 24 characters.
* **Describe.** Parameter and column oids printed by `examples/describe.cho` are compared with
  `pg_type` on the same server.
* **Mutation checks, SCRAM.** Seven deliberate bugs -- the server-signature check replaced by `true`, the
  nonce-extension check removed, PBKDF2 one iteration short, a long HMAC key not hashed first, the
  `Server Key` label wrong, the proof computed from the wrong key, the iteration cap raised -- each
  fail at least one suite. Two are caught by only one: the signature check by the end-to-end impostor
  (a connection is needed), the long HMAC key by the unit vector (no PostgreSQL password is 65 bytes).
  One was *not* caught at first: the cap raised to 2,000,000,000 survived the end-to-end suite because the
  digit-count limit in the parser refused the 10-digit value the mock asked for; the mock now asks for
  50,000,000, which only the cap stops.
* **Mutation checks.** Four deliberate bugs in the decoder -- NULL read as empty, a message size
  one byte short, the column-oid offset off by one, a NULL that does not advance the cursor --
  each fail the unit tests; the end-to-end suite catches three of them (it does not print oids,
  so the unit test is what guards that offset).

## 4. What it does not do, and why that is the order it is in

* **MD5 and channel binding.** MD5 password login (`R` code 5) is answered with status 5: it is
  deprecated in PostgreSQL 18, needs an MD5 `std` does not have, and a database that still uses
  it can use SCRAM. `SCRAM-SHA-256-PLUS` needs TLS. SASLprep (RFC 4013) of the password is not
  applied; see the README for what that excludes.
* **TLS.** There is none in pure cancho. The honest options are a sidecar (`stunnel`,
  `pgbouncer`) in front of the database, OpenSSL through the existing FFI (`cancho`'s
  `examples/tls_client` shows it works, and puts C back on the authority report), or a TLS 1.3
  implementation in cancho, which is a project of its own. Managed PostgreSQL requires it; a
  database on the same host or the same private network does not. *Corrected:* the third option exists now (cancho's
  `packages/tls`, cancho epic #197), and TLS is built on it, `disable` and `verify-full`, with no foreign code:
  [`tls.md`](tls.md).
* **A non-blocking connection.** Every helper in layer 3 waits for the server. In an event loop
  that is one thread serving every client (`http.server`), a query inside a handler stops all of
  them for a round trip. **Measured** (`cancho-web`, docs/benchmarks.md "On PostgreSQL"): about
  **90 microseconds** for a one-row lookup to a PostgreSQL on its own core, which caps a service
  that makes one such query per request at about **10,000 a second** -- 81% of what PostgreSQL itself
  answers over the same protocol -- and about **370 microseconds** for a durable `INSERT` (the
  commit's `fsync`), which caps writes at about **2,700 a second** with the loop blocked the whole
  time, because one connection cannot have its commits grouped. (The first version of this paragraph
  estimated 100-300 microseconds and "a few thousand requests a second"; the read figure was
  pessimistic, the write figure about right.) It is the right first version
  and the wrong last one for a service that writes. Layers 1 and 2 are already sans-io, so the fix is a state machine around
  them registered with the `Poller` and a request that can be suspended and resumed by an id
  (there is no `async`, no closure to resume with): the same inversion `http.server` needed.
  That is a design document and two slices of its own (§5).
* **Prepared statements: built (§9).** `execute` still sends Parse every time (the unnamed statement), and stays
  for ad-hoc SQL. PostgreSQL does 2.1x as many one-row lookups a second when the statement is parsed once
  (`pgbench`: 26,787 against 12,577 on the same machine), and asyncpg, which the FastAPI services it is
  compared with use, already did.
* **Binary formats, `COPY`, `LISTEN`/`NOTIFY`, cancellation, pipelining.** Text results are
  what every consumer so far wants and what `psql` prints, so they are what could be checked
  against a reference. The rest are additions to layers 1 and 2, in that order of demand.

## 5. Order of work

1. **Slice 1 (built).** The protocol, tested against a real server.
2. **SCRAM-SHA-256 (built).** HMAC, PBKDF2 and base64 are here, as public functions beside the
   rest of `pg` (they belong in `cancho`'s `std` if they prove out; see §7), with the RFC 4231,
   RFC 4648 and RFC 7677 vectors as unit tests, a real server, and an impostor.
3. **A typed-query generator (built, §8)**: SQL files in, plain lex functions out. **Migrations and table-driven CRUD** (§6 C) are next.
4. **A users service on PostgreSQL (built)** in `cancho-web`, its end-to-end tests and Schemathesis
   unchanged, benchmarked against FastAPI with SQLAlchemy and with asyncpg and against `pgbench`: a
   read is 3.5x lean FastAPI and at 81% of what PostgreSQL itself does over this protocol; a write is
   `fsync`-bound at about 2,700 a second. What it found is in §4 and §8.
4b. **Prepared statements (built, §9)**: the slice, because the read path is PostgreSQL-bound and about
   half of PostgreSQL's time on a lookup is parsing and planning (37 against 80 microseconds).
5. **The non-blocking connection and a pool**: designed in [`nonblocking.md`](nonblocking.md), not built. The
   measurements say the case is not throughput (three copies of the blocking service already reach PostgreSQL's
   ceiling on reads) but shared state, slow queries and group commit for writes; the document states, before it
   is built, what the benchmark must show for it to be worth keeping.
6. **A connection pooler** (PgBouncer's job, in cancho): designed in [`pooler.md`](pooler.md), not built, with its slices, its gate against PgBouncer 1.22 and the conditions under which it is stopped written down first.
7. **TLS**, once the sidecar-or-FFI-or-implement question has an asker. *Built* on cancho's own TLS client: [`tls.md`](tls.md).

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
like all cancho code, so "what queries does this service run" is a question with a stable answer.
And it connects to what exists: the generator can also emit `cancho-schema` nodes for a result
row or an `INSERT`'s parameters, so the same declaration that validates a request body (`NewUser`)
types the query that stores it, and the OpenAPI document `cancho-web` writes comes from the
same nodes. That recovers the "one declaration" property an ORM sells, from the direction this
language can support.

*Where it is weaker, honestly.* (1) Nullability is not in `describe`; the generator reads
`pg_attribute` for a result column that is a plain column reference and assumes *nullable* for
every expression, with an annotation to override. (2) Dynamic queries -- a search endpoint with
five optional filters -- are not statements known in advance; that is where a small builder (A) is
the right tool, restricted to assembling a `WHERE` from a fixed set of parameterised predicates,
never from identifiers or values. (3) The generator is another tool to run; it can be written in
cancho on this driver (it needs a file read and a connection), so it adds no second language.
(4) There are no relationships, no identity map, no unit of work, no lazy loading. That is the
real loss compared with SQLAlchemy and it is deliberate: those features are what make an ORM's
performance unpredictable and its SQL invisible, and a service that wants to know exactly what
it runs is not asking for them.

*C, the boilerplate.* `get`, `insert`, `update`, `delete` by primary key are the same four
statements for every table. A table is data (a name, columns with `cancho-schema` nodes, a key),
and the four statements are generated from it at start-up or by the same generator -- the 80% of
a CRUD API that was identical, without pretending the other 20% is.

*Decision for slice 3.* Build the generator (B) and the table-driven CRUD (C) together, because
they share the type mapping (oid to column accessor to schema node); leave the dynamic-filter
builder (A) until an endpoint needs it.

## 7. Open questions

1. **Where the helpers' blocking boundary is drawn** once the non-blocking connection exists:
   whether `pg.simple` and `pg.extended` stay as the blocking convenience over the same state
   machine, or become the state machine's driver for tests only.
2. **`std` or here** for HMAC, PBKDF2 and base64: `cancho` has `sha256`; these three are generally
   useful and probably belong beside it. They would be built here first, where they have a
   test (SCRAM) and an asker.
3. **The package's name.** `pg` is short and accurate; the generator and CRUD layer will be a
   separate repository (`lexsys-orm` is the name used so far, though "ORM" overstates it).

## 8. The generator, as built

`tools/pgen.cho` is §6's option B: `pgen <conn> queries.sql > queries.cho`. It is a cancho program on this
driver (a file read, a connection, `describe`), so there is no second language.

**What a query becomes.** A `-- name: user_by_id id` line, then one statement. The server describes the
statement (`pg.describing`: parsed and planned, never run), and the generator writes a function that takes the
`$n` as typed parameters and answers `(reply, status)`, and one accessor per result column that reads a row of
that reply. The reply is the server's whole answer in one buffer, rows are visited with `pg.first_row` /
`pg.next_row`, and a text value is a range of the reply -- nothing is copied, nothing is allocated per row.

**Decisions, and what they cost.**

* **No result type per query.** sqlc has `:one`, `:many` and `:exec`, and a row struct per query. cancho has no
  generics and a struct per query is a second kind of generated code; a reply with accessors does the same job
  for all three shapes, and `pg.first_row` is `:one`. It costs a few lines at each call site.
* **Only `bool` and the integers are mapped.** Every other type is text in and text out. That is the honest
  thing available -- the server's own text form of a `numeric` or a `timestamptz` is exact and a lex `float` is
  not -- and it means a `uuid` parameter is checked by the server, not the type system.
* **Nullability is the catalogue where the catalogue knows.** `describe` carries, for a column that is a plain
  reference to a table column, the table and column number; one more query (`pg_attribute.attnotnull`) answers.
  An expression is nullable, and so is *everything* in a statement with a `join`, because an outer join turns
  a NOT NULL column into a NULL one and nothing in the protocol says which side was outer. That is
  conservative in the right direction -- an extra `_is_null` is harmless, a missing one is a wrong answer --
  and it is matched as a word: the first version looked for `join` anywhere and found it in a column named
  `joined` (the test now has that column).
* **NULL parameters are marked, and cost a flag.** `age?` in the annotation adds an `age_given: bool` after the
  parameter, and the generated function sends `param_null` when it is false. A `$n` that is not marked cannot be
  NULL, so a caller cannot forget; the flag rather than an `Option` because cancho has no generics. The
  first service on the generator (`cancho-web`'s users on PostgreSQL) asked for it: four of the five columns of
  an `INSERT` are optional.
* **Refuse, write nothing.** Output is accumulated and written only if every query passed, so a half-generated
  module never exists, and a refusal names the query and the reason (the server's SQLSTATE for SQL it rejects).
  Names are checked for collisions across *all* generated functions: a column `a` of query `q` and a query
  `q_a` would both be `q_a`.
* **The module is checked in.** `tests/generated/queries.cho` is what the generator wrote, and a test fails if the
  generator would write anything else, which makes "the SQL changed, the generated code did not" a red build.
  A consumer does the same with its own queries.

**What testing found.** (1) `join` matched inside `joined` (above). (2) A path with `..` in it makes the file
capability *trap* -- a SIGILL, by design (`filesystem.md` §4.1) -- and the first end-to-end test passed a path
built as `tests/../tests/queries.sql`; the generator now refuses such a path with a message, and the test keeps
the case. (3) A syntax error was reported as "the server did not answer", because the check for a missing
parameter description ran before the check for an `ErrorResponse`; the order is now the other way, and the
test asserts the SQLSTATE. (4) A mutation run caught a unit test that looped forever rather than failing (a row
visited twice); that is a pass for the mutation and a reminder that the runner has no timeout.

**What the first consumer found.** `cancho-web`'s users service on PostgreSQL asked for optional parameters
(four of five columns of its `INSERT` are optional; added, above) and, through Schemathesis, found that
PostgreSQL `text` cannot hold U+0000 although a JSON string, and so the OpenAPI document, allows it. The fix is
not in the database layer: a constraint the store imposes belongs in the schema the document is generated from
(`cancho-schema` design.md §13), so the generated queries stay free of validation.

**Not built.** Table-driven CRUD from `cancho-schema` nodes (§6 C), migrations, dynamic filters (§6 A), array parameters, prepared statements (every call parses again; a `Parse` once and `Bind` many is the first thing a
benchmark will ask for), and generating `cancho-schema` nodes from result rows.

## 9. Prepared statements, as built

`pg.parse_named` / `pg.bind_named` are the two messages, `pg.prepare` / `pg.run_named` the blocking helpers, and
`pgen` writes `prepare_all` (a chain of `pg.prepare_after`) and has each query run by name. A named statement is
per connection and lives as long as it, so the call goes once after login.

* **No Describe on the named path.** `execute` asks the server to describe the portal every time, which costs it
  work and the client bytes it then ignores: a generated function knows its columns. `bind_named` sends Bind,
  Execute and Sync only. (A reply therefore has no RowDescription; the accessors never read one.)
* **Refuse, and say which.** `prepare_all` stops at the first statement the server refuses and answers that reply,
  so a schema that has moved under the queries is one message at start-up -- `42703`, column does not exist --
  instead of a failure on the first request that uses it. The first version of the test renamed a column that
  *every* query used, and a `prepare_after` that ignored failures still passed it, because the last prepare failed
  too; the test now renames one that only the first query uses.
* **A statement that was not prepared** is the server's `26000` (`prepared statement "x" does not exist`) in the
  reply, which `pg.failure` finds; it does not hang and does not run the SQL.
* **What it does not do.** No automatic re-prepare: a connection that is replaced has to run `prepare_all` again,
  which is the pool's job once there is one. No server-side statement for dynamic SQL: `execute` is still the way.
  A statement prepared with the types the server inferred is re-planned by PostgreSQL itself when the table changes
  under it, and fails with `0A000` ("cached plan must not change result type") if a column's *type* changed; a
  fresh connection, running `prepare_all` again, picks up the new types, and the generated accessors are regenerated
  from the changed schema like any other.

## 10. `pg-export`: rows out as JSON lines, for `table` and for a recorded step

> **Status: built** (`tools/pgexport/`, `tests/export_test.py`, `tests/export_mutants.py`, `scripts/bench_export.py`); §10.7 says what the build changed from the design below and what
> was measured. Every claim is marked as a **read** (with the file it was read from), a **choice**, **open**, or **measured** (in §10.7, with the command). Where the build differs
> from §10.2 to §10.4, the text there is corrected in place and §10.7 lists each change.

**The question.** Can `cancho-table` take a PostgreSQL query as its data? **Choice: not inside `table`.** `table`'s authority row has no `net_out`, `conn_read` or
`conn_write`, `tools.toml` there forbids `net_out` for every tool, and CI fails if the binary differs from `manifests/table.authority.json`
(**read**: `cancho-table/docs/architecture.md`, "Not in the row"; `README.md`, "No implicit network access"). A live database also breaks `table`'s other promise,
the same bytes for the same input. So the database is a *separate program* that writes a file or a pipe, and `table` reads that (`table ... -` or a file).

### 10.1 Where it lives, and why

| place | verdict | reason |
|---|---|---|
| inside `cancho-table` | **no** | above |
| inside `cancho-flow` | **no** | `flow` "knows nothing of the programs it starts" and its row has no network (**read**: `cancho-flow/README.md`, `CLAUDE.md`, `docs/design.md` §0 and the row of `flow`) |
| **`cancho-pg/tools/pgexport/`**, beside `tools/pgen.cho` | **yes** | the only place whose row is *meant* to hold `net_out` (narrowable to one `host:port`), `conn_read`, `conn_write`, `heap`; `pgen` is the precedent for a tool that is a program on this driver |
| a new repository for all sources | **open** (§10.5) | only if a second source with a different transport arrives |

### 10.2 The command

```
pg-export <host> <port> <user> <database> <password|-> <sql> [max_rows [max_bytes]]
```

* **One statement, read only.** It runs inside `BEGIN READ ONLY` (**choice**: the server refuses a write whatever the SQL says, `25006`), with `statement_timeout` set
  (as built: `SET LOCAL statement_timeout = 60000`, fixed; no flag). It sends exactly one statement; the extended protocol is used so that a `;`-separated second statement is refused by the server rather than run
  (**read**: §2 layer 1, `execute`; **open**: the exact behaviour is a test, G-E2).
* **Output is JSON lines**, in the shape `table --input-format jsonl` reads (**read**: `cancho-table/docs/readers.md` §5): one object per row, the keys the column
  names in the order the server sent them, so `--fields` is the column list and `--discover` works on it.
  * integer, `numeric` and the float types are JSON **number tokens carrying the server's own text**, never through a double (the server's text for a `numeric`
    is exact; **read**: §8 "Only `bool` and the integers are mapped"; `table` keeps a number's token text, `readers.md` §5.3);
  * `bool` is `true`/`false`; every other type, the timestamps and dates included, is a **string with the server's text form**; the types a caller declares in
    `table` (`:dec(S)`, `:timestamp`, `:date`) are the caller's, as for any CSV;
  * a SQL `NULL` is JSON `null`, which `table` treats as absent and **refuses by default** (`parse.jsonl-missing-field`, `--absent empty` to accept)
    (**read**: `readers.md` §5.3). That default is the right one and is the reason to prefer JSON lines to CSV, where `NULL`, `""` and a missing cell collapse;
  * a value that is not valid UTF-8 (a `bytea` in text form is ASCII, but a database in another encoding is not) is refused, not repaired: `pg-export.not-utf8`.
* **Bounded.** `max_rows` (default 1,000,000, ceiling 100,000,000) and `max_bytes` (default 256 MiB, ceiling 1 GiB) are the last two arguments; past one the export stops, **writes nothing** (like `pgen`: output is
  accumulated and written once to standard output only if every row passed; **corrected:** there is no `--out` file and rename in the first build) and says which bound, with a rule tag. Every refusal has a `pg-export.<name>` tag and no
  input reaches a panic (**the rule of every repository here**).
* **No payload is ever logged.** **Corrected:** an error from the server carries its SQLSTATE and nothing else (the server's own message can quote a value); the other refusals are fixed sentences.
* **The password is an argument** in the generic program, as in `pgen`, and `-` is the empty one. **Corrected:** this design first said "a file or `-`, not a flag value that a process list shows"; the first build did
  not read a file (a file read of a caller's path widens the authority row from `fs_read("/dev/urandom")` to `fs_read("")`), so a password was visible in the process list. **Done in §11:** the one-host build reads it from a file narrowed to that one path, as `cancho-fetch`'s credentials are (`cancho-fetch/docs/design.md` §8.6).

### 10.3 Composing it

```sh
pg-export db.internal 5432 reader orders - "select id, amount, status from orders where day = '2026-11-13' order by id" > orders.jsonl
table --input-format jsonl --fields id,amount,status --where "status = 'paid'" --agg "sum:amount:dec(2)" orders.jsonl
```

`order by` is the caller's; without it the order is the server's, and `pg-export` does not add one (**choice**: adding a sort would change the query).

**Recorded, with `cancho-flow`.** `flow step` records what a program was given, which program ran, and the hashes of what it wrote
(**read**: `cancho-flow/README.md`). A deployment bakes `pg-export` into the programs directory of its `flow`, and the export becomes a step:

```sh
flow step --root . --record records --out orders.jsonl -- sh -c 'pg-export db.internal 5432 reader orders - "..." > orders.jsonl'
table ... orders.jsonl      # replayable offline: the file's hash is in the record
# NOT RUN: G-E7. This line was written, not executed; it needs `sh` and `pg-export` in the baked directory of a `flow` build.
```

What this does and does not give (**choices, stated so they are not read as more**):

* The record says *this file is what the database returned, at that time*; it does **not** say the database would return it again. The step is **not** `--deterministic`
  and must not be declared so (a record is "a pure function of its inputs", and a live table is not an input `flow` can see; **read**: `cancho-flow/CLAUDE.md`, and §9 of its design on undeclared inputs).
* What *is* replayable is everything after: `table` over `orders.jsonl` from the recorded hash, with no database.
* The child has its user's whole authority; `flow`'s row says what `flow` may start, not what the child does (**read**: `cancho-flow/docs/design.md`, row of `flow`). `pg-export`'s own row, derived by
  `cancho authority`, is what a reviewer reads for the child, and **open**: whether `flow`'s build step should check that a baked program's row is inside a ceiling a deployment names. That is a
  `cancho-flow` change and is not made here.

### 10.4 Gates, written before the code, each able to fail

| gate | what it checks | a version it must refuse |
|---|---|---|
| G-E1 authority | `cancho authority` on the binary lists the network, `conn_read`, `conn_write`, `heap`, the console and one file, `fs_read("/dev/urandom")`, and nothing else (no `ffi`, no `net_in`, no `clock`, no file written). **Not met as first written:** the design said `net_out` for one `host:port`; the generic build is `net_out("")`, `bounded: false`, and a one-host build is **open** (§10.7) | a build that adds any other label |
| G-E2 read only | a statement `insert`, `create table`, `drop`, and a second statement after a `;` are each refused and the table is unchanged | a version that sends `Query` with the caller's text outside `BEGIN READ ONLY` |
| G-E3 exactness | a `numeric(40,10)`, `int8` at both limits, a `float8` `NaN` and `-0`, and a hostile string (`"`, `\`, U+2028, U+0000, 4-byte UTF-8) round-trip through `table --input-format jsonl` to the same text; `NaN` is a refusal, not a number token (JSON has none) | a version that goes through a double, or writes `NaN` as a bare token |
| G-E4 NULL | a `NULL`, `''` and a string `'null'` are three different things to `table` | a version that writes `NULL` as `""` |
| G-E5 bounds | each of `--max-rows` and `--max-bytes` stops the export with its tag and leaves no file | a version that leaves a half file |
| G-E6 no leak | no row, parameter or SQL text in any error or log line, over the hostile corpus | a version that echoes the SQL in `error.message` |
| G-E7 flow | the `flow step` line above records the file's hash; changing the file makes `flow-records check` fail | not applicable until `flow` is built with `pg-export` in its directory |
| mutants | a runner like `tests/mutants.py`: all killed, or each survivor explained | |

### 10.5 BigQuery and Athena

Same output, different transport. **Where: not here.** `cancho-pg` is a PostgreSQL wire client; both are HTTPS APIs. The model to follow is `cancho-fetch`: one binary per
allow-list, the hosts as `narrow` literals so the row shows one `net_out("host:443")` each, and credentials from a file named at build time, never a flag
(**read**: `cancho-fetch/README.md`, `docs/design.md` §8.6).

| | BigQuery | Athena |
|---|---|---|
| API (**recalled, not read from the services' documentation: to be checked before this design is final**) | `jobs.query` / `jobs.getQueryResults`, JSON, paged by token | `StartQueryExecution`, poll `GetQueryExecution`, `GetQueryResults` (JSON, paged) or the CSV Athena wrote to S3 |
| auth | a bearer token; a service account's own JWT needs **RSA signing** | AWS SigV4 on every request: **HMAC-SHA256**, which this repository already has (`pg.hmac_sha256`) |
| what cancho has (**read**: `cancho/packages`) | `tls`, `x509`, `http-client`; **no RSA signing found** (`x509` verifies) | the same, plus the HMAC |
| consequence | **choice**: take a short-lived access token from a file the operator refreshes (e.g. `gcloud auth print-access-token` in a sidecar), as `cancho-fetch`'s credential is a file; do not sign JWTs until cancho has RSA signing | SigV4 in cancho is writable; **open**: whether the signing key is a file (one per binary) and how a session token is refreshed |
| shape | an asynchronous job: start, poll with a bound and a deadline, page, write whole or nothing | the same, and the results may sit in S3, which is a second host and a second row entry |

**Recommendation (choice):** one new repository, `cancho-export`, holding `bq-export` and `athena-export` (each a binary with its own row), and the **output contract**
of §10.2 written once there; `pg-export` stays here and follows the same contract. **Open:** whether the contract belongs in `cancho-table`'s `docs/readers.md` instead, since `table` is
the consumer and the contract is its input format. Neither warehouse tool is started until `pg-export` has passed G-E1 to G-E6, so the contract is one that was exercised.

### 10.6 Open questions

1. How a `numeric` `NaN`, `Infinity` and a `float8` `NaN` are written (JSON has no token for them): refuse (the first choice, G-E3) or a string.
2. Whether `--sql FILE` takes more than one statement with a name, as `pgen`'s `-- name:` file does, to export several in one run (several files; each one whole).
3. `COPY ... TO STDOUT` as the transport, which is what `psql \copy` uses (whether it would be faster here is **not measured**), and not built here (§4, "Not yet: `COPY`"); the extended-protocol path in §10.2 is what exists.
4. Whether `table` should learn to read a `flow` record's output file by record id. That is a `table` and `flow` question and is not decided here.

### 10.7 As built, and what was measured

`tools/pgexport.cho` (496 lines; since §11 it is `tools/pgexport/core.cho` and `generic.cho`), built with `cancho build --std tools/pgexport/generic.cho tools/pgexport/core.cho src/pg.cho -o build/pg-export`, compiler `f4ead824` (`cancho.toml`). Everything below was run in one
session on one machine: Linux 6.18 (a 4-CPU virtual machine), PostgreSQL 16.15 from the Ubuntu package on the same machine, trust authentication, loopback TCP.

**What differs from §10.2 to §10.4** (each corrected in place above):

| design said | as built |
|---|---|
| flags `--sql FILE`, `--query`, `--out FILE`, `--max-rows`, `--max-bytes` | positional: `<sql> [max_rows [max_bytes]]`; output on standard output; no `--out` and no rename |
| `statement_timeout` from a flag | fixed, 60 s |
| password from a file | an argument (`-` is empty); a file is **open** |
| the server's message class in an error | the SQLSTATE only |
| G-E1: `net_out` for one `host:port` | `net_out("")`, `bounded: false`; narrowing is a deployment's build and is **not built** |
| G-E7: the `flow step` composition | **not run**; the line in §10.3 is written, not executed |

**Gates** (`python3 tests/export_test.py`; 20 tests, all passed; the last of them runs the export through `table`, with `TABLE` set to cancho-table's `build/table`, built with that repository's pinned compiler):

| gate | test | result |
|---|---|---|
| G-E1 | `test_authority_row`: the label set is exactly `args, conn_read, conn_write, err_write, fs_read("/dev/urandom"), heap, io_write, net_out("")`, no foreign symbol | met for the generic build; **not** the one-host row of the design |
| G-E2 | `insert`, `delete`, `update`, `create`, `drop`, `truncate` are each refused with SQLSTATE `25006` and change nothing; `select 1; drop table` is `42601` | met |
| G-E3 | `numeric(40,10)`, `int8` at both limits, `1.50` keep the server's text; `NaN`, `Infinity`, `-Infinity` and numeric `NaN` are `pg-export.non-finite` and write nothing; a string with `"`, `\`, U+2028, U+2029, a tab, a newline, U+0001, U+001F, an accent and a 4-byte character round-trips | met |
| G-E4 | `NULL`, `''` and the string `null` come out as `null`, `""` and `"null"` | met |
| G-E5 | `max_rows`, `max_bytes` and the bad limits refuse with their tags and write nothing | met |
| G-E6 | `select 'SECRETVALUE'::int`, an unknown column and an unknown table: the error line is `pg-export: pg-export.server-refused: SQLSTATE XXXXX` and holds none of the names | met |
| mutants | `python3 tests/export_mutants.py`: 10 mutants (no `READ ONLY`, `NaN` as a token, no UTF-8 check, no `max_rows`, no `max_bytes`, an unescaped quote, `NULL` as `""`, the server message echoed, duplicate columns allowed, partial output on a refusal) | **10 of 10 killed** |

Two things the tests found while they were being written: the first draft wrote a tab as `\u0009`, where the server's `row_to_json` writes `\t` (both are valid JSON; the short escapes are now used, so the bytes are the server's),
and a test that split the output with Python's `str.splitlines` broke on a U+2028 inside a string (the test was wrong, not the tool).

**Same bytes as the server's own JSON writer** (**measured**): `test_same_bytes_as_row_to_json` compares the output with `psql -At -c "select row_to_json(t) from (q) t"` over 500 rows with a `NULL`, a `numeric`, a boolean,
a date, and a string with a quote, a backslash, a tab and a 4-byte character; and for the benchmark table below at 100,000 rows the two outputs have the same SHA-256 (`f1765898...`). That is one query shape,
not every type. Arrays and `jsonb` are strings in this tool; `row_to_json` is expected to write them as JSON arrays and objects, so the two would differ for those (**not tested**).

**Time and memory against the stock `psql`** (**measured**: `PGHOST=127.0.0.1 PGPORT=54329 PGUSER=postgres PGDATABASE=shop RUNS=7 python3 scripts/bench_export.py 100000 1000000`; the table, the three commands, the warm-up run
and how memory is read are in the script's header). One run of that command; the median of 7 timed runs after one warm-up; each writes to a file; peak memory is `ru_maxrss` of the client process.

| rows | | median s | min s | peak MB | output MB |
|---|---|---|---|---|---|
| 100,000 | `psql --csv` | 0.119 | 0.100 | 32.2 | 9.0 |
| | `psql` + `row_to_json` | 0.196 | 0.167 | 26.7 | 14.6 |
| | `pg-export` | 0.190 | 0.166 | 36.3 | 14.6 |
| 1,000,000 | `psql --csv` | 0.920 | 0.823 | 247.4 | 92.2 |
| | `psql` + `row_to_json` | 1.677 | 1.601 | 188.1 | 148.4 |
| | `pg-export` | 1.943 | 1.761 | 365.9 | 148.4 |

What this says and does not say:

* **`pg-export` is not faster than `psql`.** For the same JSON lines it is level at 100,000 rows and about 16 percent slower at 1,000,000 (1.94 s against 1.68 s, medians), and it holds about twice the memory (366 MB against 188 MB).
  Against `psql --csv`, which does less work (no JSON, about 38 percent fewer bytes), it takes about twice as long at 1,000,000 rows.
* **What the time contains** is not separated: it is the server running the query, the transfer, and the client; the server's share is the same for the three commands except that `row_to_json` makes the server write the JSON.
* **Why it is slower and larger** is **not measured**. The reply is held whole in one buffer (§2, layer 2) and the output is built whole beside it, which is the memory; the time is a loop that copies each value once into a
  buffer that grows by doubling. No profile was taken and no optimisation was tried; streaming (write a row, drop it) is the obvious next step for the memory, but it gives up "writes nothing on a refusal" unless the output is spooled first.
* **One machine, one table shape** (six columns of five types, short values), a loopback connection, a cold-ish page cache not controlled for. These numbers do not carry to a remote server, wide rows, or a loaded machine.
* **Open:** `--out` with a rename; the streaming build; the `flow` composition (G-E7). **Done since, in §11:** the one-host build that meets G-E1 as written, and the password file.


## 11. A one-host `pg-export`, and a password that is not in the process list

> **Status: built** (§11.3 says what was measured). §11.1 and §11.2 were written before the code; where the build differs, §11.3 says so and the text above it is corrected in place. Marked as in §10: **read**, **choice**, **open**, **measured**.

**The problem** (§10.7, **measured**): the generic `pg-export` reports `net_out("")` and `bounded: false`, and takes its password as an argument. The authority row therefore says "any host", and `ps` shows the password.

**Why not a flag** (**read**: `cancho/docs/capability-budget.md`, "Where a bound comes from"; `cancho/docs/agent-toolbox.md` D14): a capability's bound is a *literal*, "checked where it is written". `narrow(net, arg(g, 1))` is refused (`capability-not-narrowable`), so the host cannot come from the command line and still be in the row. The way cancho's own tools do it, and `cancho-fetch` (**read**: `cancho-fetch/scripts/fetch_build.py`), is a **build-time variant**: a script writes a small source with the literals, and the ordinary build derives the row from it.

### 11.1 The build

```
python3 scripts/export_build.py --host db.internal --port 5432 [--password-file /run/secrets/pg] [--out build/pg-export-db] [--manifest FILE [--check]]
pg-export-db <user> <database> <sql> [max_rows [max_bytes]]
```

* **Split of the source** (**choice**): everything that is not the choice of host and secret moves to a module, `tools/pgexport/core.cho` (`module pgexport;`), so there is one copy of the JSON writer and the refusals. `tools/pgexport/generic.cho` is the existing program (host, port and password as arguments, `net_out("")`), unchanged in behaviour. The script writes the third file, the variant's `main`, into `build/gen/`, and builds the three with `src/pg.cho`.
* **What is baked**: `narrow(net, "HOST:PORT")` (the network is that one name and port), and `narrow(fs, "/dev/urandom", "PASSWORD_FILE")` (**read**: `cancho/docs/narrowing-into-several.md`: the unrelated paths of one `Fs`, two labels, no `fs_read("")`). Without `--password-file` the file is not narrowed to, and the password is the empty one (trust authentication).
* **What the variant refuses to take**: no host, port or password argument exists. The password cannot be passed on the command line at all, so it cannot be in the process list (**choice**; the generic build still takes it that way and its `--help`-equivalent usage line says so).
* **The password file** is read once, at most 1,024 bytes, one trailing `\n` or `\r\n` removed. A file that is missing, unreadable, over the limit or empty is `pg-export.password-file` (fixed sentence; the content and the path are never printed). The file's permissions are **not** checked: the language has no `stat` in this row, and the deployment owns them (**open**).
* **What the script validates before it writes a literal** (so that a bad input is an error of the script, not a source that fails to compile or, worse, a wider row): the host is letters, digits, dots and hyphens (no wildcard, no IPv6 bracket form: **open**), the port is 1 to 65535, the password file is an absolute path of plain characters with no `..` and is not `/dev/urandom` and not under it.
* **A host name is a name** (**read**: `cancho/docs/net-bounds.md`, `capability-budget.md`): the row says `net_out("db.internal:5432")`; what the name resolves to is the resolver's answer at run time and is not in the row. An IP literal gives the tighter claim. Say so in the build's output.

### 11.2 Gates, written first

| gate | what it checks | a version it must refuse |
|---|---|---|
| G-E1b | the variant's row is `bounded: true` and is exactly `args, conn_read, conn_write, err_write, fs_read("/dev/urandom"), fs_read(<password file>), heap, io_write, net_out("<host>:<port>")` (the file label only with `--password-file`), no foreign symbol; the script itself fails the build if the derived row differs | a build that narrows to the host only (no port), to a wider path, or leaves `Net("")` |
| G-E1c | the committed reference row (`manifests/pg-export.authority.json`) equals the row derived for the reference variant (`--check`), in CI | a change that adds a label and does not update the file, and the other way round |
| G-P1 | the variant logs in with a password that is read from a file, against a role that is `scram-sha-256` and one that is cleartext (CI has them: `tests/postgres.sh`), and the same role with a wrong password is `pg-export.login` | a variant that sends the file's trailing newline |
| G-P2 | a missing file, an empty file, a 1,025-byte file are each `pg-export.password-file` and the output holds neither the path nor the content | a variant that echoes either |
| G-P3 | the password is in no argument of the variant's process (`/proc/<pid>/cmdline` while a slow query runs) | the generic build, which fails this by design (shown, as the contrast) |
| G-S | the variant refuses an input the script must refuse (a wildcard, a port 0, a relative or `..` path, `/dev/urandom/x`) before it writes any file | a script that writes the source first and validates after |
| mutants | extend `tests/export_mutants.py` to the new source: the narrow literal widened, the password's newline kept, an empty password file accepted, the path echoed | |

**Not in this slice:** `--out` with a rename, the `cancho-flow` step, streaming (§10.7 "Open").

### 11.3 As built, and what was measured

`scripts/export_build.py` (about 250 lines) writes the variant's `main` from literals and builds it with `tools/pgexport/core.cho` and `src/pg.cho`; `tools/pgexport/generic.cho` is the old program, unchanged in what it does. Same session, machine and compiler (`f4ead824`) as §10.7, PostgreSQL 16.15 on the same machine; the SCRAM and cleartext roles are made locally with the same names as `tests/postgres.sh` (`scramuser`, `pwuser`), not by that script (it needs docker, which was not available), so **CI's run of these tests on the real `postgres.sh` server is the first run there**.

| gate | result |
|---|---|
| G-E1b | **met.** The variant's row is `bounded: true` with exactly `args, conn_read, conn_write, err_write, fs_read("/dev/urandom"), fs_read(<password file>), heap, io_write, net_out("<host>:<port>")`, no foreign symbol. The script fails the build, and writes no binary, when the derived row differs; the generic build is `bounded: false` (a test says so) |
| G-E1c | **met.** `manifests/pg-export.authority.json` is the row of the reference variant (`127.0.0.1:5432`, `/run/secrets/pg`); `--check` re-derives it and refuses a different file |
| G-P1 | **met** against a `scram-sha-256` role and a cleartext one: the password comes from the file, a trailing `\n` or `\r\n` or none is accepted, and a wrong password is `pg-export.login` with neither the password nor the file in the output |
| G-P2 | **met.** A missing, empty, newline-only and 1,025-byte file are each `pg-export.password-file` and print neither the path nor the content; a 1,024-byte file is taken |
| G-P3 | **met.** `/proc/<pid>/cmdline` of the running variant does not hold the password; the same check on the generic build **does** (a test asserts the contrast, so the claim cannot go stale) |
| G-S | **met.** Eight bad hosts (wildcard, space, `;`, brackets, empty, leading hyphen, `..`, a quote), three bad ports, nine bad password paths (relative, `..`, trailing or doubled slash, `/dev/urandom` and under it, a quote, a space, `/`) are each refused by the script before it writes any file |
| mutants | **18 of 18 killed**: the earlier 10 and, for the variant, the network narrowed to the host only, the newline kept, the carriage return kept, an empty password accepted, a 1,025-byte file accepted, the path echoed, a wildcard host accepted, and a manifest that differs accepted |

Tests: `tests/export_test.py` (20, on the generic build) and `tests/export_variant_test.py` (17), all passing locally.

**What differs from §11.1:**

* **The variant's `main` takes `<user> <database> <sql> [max_rows [max_bytes]]`**, as written. The generic program's file moved from `tools/pgexport.cho` to `tools/pgexport/generic.cho`, so the build line of §10.7 and the README changed with it.
* **A host name** is accepted and the row names it: a build for `db.internal:5432` is `bounded: true` with `net_out("db.internal:5432")` (**measured**, one build), and prints a note that what the name resolves to is not in the row; an IP literal is the tighter claim. **Not tested:** a connection to a real host name (the tests use `127.0.0.1`), so how the resolver behaves under the bound is a **read** of `net-bounds.md`, not a measurement.
* **The file's permissions** are not checked (no `stat` in the row): **open**, the deployment's.
* **IPv6** hosts are refused by the script: **open**.
* **A timing of the variant** against the generic build was not taken; it runs the same core, and nothing is claimed about its speed beyond §10.7's numbers for the generic one.

