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

## 10. `pg-export`: rows out as JSON lines, for `table` and for a recorded step (design; nothing built)

> **Status: design.** Every claim below is marked as a **read** (with the file it was read from), a **choice**, or **open**. Nothing here is measured: no code
> exists, and the first measurement is a gate (G-E1 below).

**The question.** Can `cancho-table` take a PostgreSQL query as its data? **Choice: not inside `table`.** `table`'s authority row has no `net_out`, `conn_read` or
`conn_write`, `tools.toml` there forbids `net_out` for every tool, and CI fails if the binary differs from `manifests/table.authority.json`
(**read**: `cancho-table/docs/architecture.md`, "Not in the row"; `README.md`, "No implicit network access"). A live database also breaks `table`'s other promise,
the same bytes for the same input. So the database is a *separate program* that writes a file or a pipe, and `table` reads that (`table ... -` or a file).

### 10.1 Where it lives, and why

| place | verdict | reason |
|---|---|---|
| inside `cancho-table` | **no** | above |
| inside `cancho-flow` | **no** | `flow` "knows nothing of the programs it starts" and its row has no network (**read**: `cancho-flow/README.md`, `CLAUDE.md`, `docs/design.md` §0 and the row of `flow`) |
| **`cancho-pg/tools/pg-export.cho`**, beside `tools/pgen.cho` | **yes** | the only place whose row is *meant* to hold `net_out` (narrowable to one `host:port`), `conn_read`, `conn_write`, `heap`; `pgen` is the precedent for a tool that is a program on this driver |
| a new repository for all sources | **open** (§10.5) | only if a second source with a different transport arrives |

### 10.2 The command

```
pg-export <host> <port> <user> <database> <password|-> [--sql FILE | --query "select ..."] [--out FILE] [--max-rows N] [--max-bytes N]
```

* **One statement, read only.** It runs inside `BEGIN READ ONLY` (**choice**: the server refuses a write whatever the SQL says, `25006`), with `statement_timeout` set
  from a flag. It sends exactly one statement; the extended protocol is used so that a `;`-separated second statement is refused by the server rather than run
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
* **Bounded.** `--max-rows` and `--max-bytes` have defaults and ceilings; past one the export stops, **writes nothing** (like `pgen`: output is accumulated or
  written whole to a file named by `--out` through a rename, never half) and says which bound, with a rule tag. Every refusal has a `pg-export.<name>` tag and no
  input reaches a panic (**the rule of every repository here**).
* **No payload is ever logged.** An error carries the SQLSTATE and the server's message *class*, not a row, a parameter or the SQL text beyond its first token.
* **The password is a file or `-`**, as in `pgen`; it is not a flag value that a process list shows (**choice**).

### 10.3 Composing it

```sh
pg-export db.internal 5432 reader orders - --query "select id, amount, status from orders where day = '2026-11-13' order by id" --out orders.jsonl
table --input-format jsonl --fields id,amount,status --where "status = 'paid'" --agg "sum(amount:dec(2))" orders.jsonl
```

`order by` is the caller's; without it the order is the server's, and `pg-export` does not add one (**choice**: adding a sort would change the query).

**Recorded, with `cancho-flow`.** `flow step` records what a program was given, which program ran, and the hashes of what it wrote
(**read**: `cancho-flow/README.md`). A deployment bakes `pg-export` into the programs directory of its `flow`, and the export becomes a step:

```sh
flow step --root . --record records --out orders.jsonl -- pg-export db.internal 5432 reader orders /run/secrets/pg --query "..." --out orders.jsonl
table ... orders.jsonl      # replayable offline: the file's hash is in the record
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
| G-E1 authority | `cancho authority` on the binary lists `net_out` for one `host:port`, `conn_read`, `conn_write`, `heap`, `fs_read`/`file_write` for the named paths, and nothing else (no `ffi`, no `net_in`, no `clock`); the row is committed and CI re-derives it | a build that adds any other label |
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
| API (**read from my memory of the services, not from their documentation; to be checked before the design is final**) | `jobs.query` / `jobs.getQueryResults`, JSON, paged by token | `StartQueryExecution`, poll `GetQueryExecution`, `GetQueryResults` (JSON, paged) or the CSV Athena wrote to S3 |
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
3. `COPY ... TO STDOUT` as the transport, which is what `psql \copy` uses: faster, and not built here (§4, "Not yet: `COPY`"); the extended-protocol path in §10.2 is what exists.
4. Whether `table` should learn to read a `flow` record's output file by record id. That is a `table` and `flow` question and is not decided here.
