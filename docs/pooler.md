# A PostgreSQL connection pooler in lex-sys

> **Status: designed, not built.** This document says what would be built, in what order, what each step must
> show to be kept, and what would make the whole project not worth continuing. It is written before the code so
> that the gate cannot move to fit the result.

## 1. What it is, and why it is a candidate at all

PostgreSQL forks a process per connection. A service with hundreds of clients (many app instances, each with its
own pool) wants far fewer server connections than client connections, and a *pooler* sits between them:
clients connect to it as if it were the server; it keeps a few real connections and lends one to a client for the
length of one **transaction**, then takes it back (PgBouncer's `pool_mode = transaction`). The mature tools are
PgBouncer (C, 2007), PgCat (Rust) and Odyssey (C).

A pooler is a good fit for lex-sys for reasons that are about the language, not about speed:

* it is a **protocol proxy**: it frames messages and forwards bytes. It never needs to understand SQL, so it needs
  the part of the wire protocol this repository already has (framing, the startup exchange, `ReadyForQuery`'s
  status byte) and none of the part that is hard (types, formats);
* it is a **network service that should be small and provably limited**. `lex-sys authority` on it names the
  network and the heap and nothing else: no filesystem, no foreign code. For a component that holds every
  database credential in the deployment, that sentence is the product;
* it reuses what `lexsys-cache` already proved on this runtime: a loop on `std.conns` and `Poller`, sans-io parsers
  tested from bytes, a differential harness against the reference implementation, and pinned-core benchmarks.

What it is **not** is a faster PgBouncer. PgBouncer is one thread and tuned for fifteen years; at the
throughputs a database can sustain the pooler is not the bottleneck, and the gate below is "no worse", not "better".

## 2. Scope of the first version

Built, in this order (each its own slice with its own gate, §4):

| slice | adds | what the client sees |
|---|---|---|
| **P0** | a transparent proxy: one client connection to one server connection, bytes forwarded both ways, startup and `SSLRequest` handled, `Terminate` and disconnects propagated | the same server, one hop away |
| **P1** | **transaction pooling**: a server connection is assigned when a client's first message of a transaction arrives and released when the server answers `ReadyForQuery` with status `I`; clients queue when none is free; a pool of *N* server connections per (database, user) | many clients, few server connections |
| **P2** | **authentication of clients**: `trust` (localhost only), cleartext and SCRAM-SHA-256 against a user list, with the server-side logins done with the configured credentials | clients need a password |
| **P3** | **operations**: `CancelRequest` mapped to the right backend, timeouts (idle in transaction, query, queue wait), a connection limit, `PAUSE`/`RESUME`-style shutdown, counters | the things a deployment needs |

**Not in the first version, said now so that it is not discovered later:**

* **Session state in transaction mode.** `SET`, `LISTEN`, temporary tables, advisory locks held across
  transactions, and `WITH HOLD` cursors do not survive a change of server connection, in PgBouncer and here. The
  pooler does not parse SQL to detect them (PgBouncer does not either); a `pool_mode = session` is the answer and
  is part of P1 because it is what P0 already is.
* **Protocol-level prepared statements in transaction mode** (named `Parse`; PgBouncer added tracking in 1.21). The
  first version refuses a named `Parse` in transaction mode with an `ErrorResponse` rather than forwarding it to a
  connection that may not have the statement, and says so in the error. The unnamed statement (`Parse`, `Bind`,
  `Execute`, `Sync` in one go, which is what most drivers do for parameterised queries) works because it never
  outlives the transaction. Tracking and replaying statements per server connection is a later slice if it has an asker.
* **TLS** on either side (as in the client: the sidecar-or-FFI-or-implement question has no asker yet),
  `COPY` in either direction beyond forwarding bytes, replication connections, `GSSENCRequest` (answered `N`).
* **More than one thread.** A pooler is one event loop, as the cache is; scaling out is more processes.

## 3. How it works

**Framing.** After startup every message is a type byte, an int32 length that includes itself, and the body. The
proxy needs the type of each message and its length and nothing else. It never copies a body: it moves bytes between
two buffers and counts how many of the current message are left to forward, so a 100 MB `DataRow` stream costs
a buffer's worth of memory.

**What the pooler has to read, and nothing more:**

* from the client: the `StartupMessage` (`user`, `database`, and the other parameters, which become the key of the pool
  and the values it must reproduce), `SSLRequest`/`GSSENCRequest`/`CancelRequest` (the first two answered `N` / handled,
  the last mapped), and the type byte of each later message (`Q`, `P`, `B`, `E`, `S`, `H`, `X`, `d`/`c`/`f`);
* from the server: the type byte, and for `ReadyForQuery` (`Z`) the status byte: `I` idle, `T` in a transaction, `E` in
  a failed one. A connection goes back to the pool only on `I`. `ErrorResponse` in a failed transaction is forwarded
  and the connection stays assigned until the client's `ROLLBACK` brings `I`.

**What it must invent.** In transaction mode the client is not attached to a server when it connects, so the
pooler itself answers the startup: `AuthenticationOk`, the `ParameterStatus` messages (copied from the first server
connection it opened for that pool: `server_version`, `client_encoding`, `DateStyle`, ...), a `BackendKeyData` of its
own (the key a later `CancelRequest` quotes, mapped to the real backend's only while a transaction is running), and
`ReadyForQuery` `I`.

**The loop** is the cache's: one `Poller`, a `std.conns` table of client connections and server connections, input
buffers per connection, a bounded queue of clients waiting for a server connection, backpressure by not reading from a
connection whose peer's output is full.

**Why a named `Parse` is refused rather than pinned.** Pinning the client to one server connection for the rest
of its session turns transaction mode into session mode silently, and the deployment that sized the pool for
transaction mode starves. A refusal is loud and says what to change.

## 4. What each slice must show

The reference is **PgBouncer 1.22** (the Ubuntu package), the same PostgreSQL 16, the same session, interleaved runs,
pinned cores (pooler on one core, PostgreSQL on two, the load generator on the last), medians of five, and a cell
reported as bound by the load generator or by PostgreSQL itself carries no ratio, exactly as for the cache.

**Correctness first (no performance number is quoted before these pass).**

1. *Differential against the server.* `tests/e2e.py`'s 29 queries and the hostile-parameter cases, through the
   pooler and directly, rows identical; the same with the bytes split at every offset of the first few messages
   (the cache's framing test).
2. *Differential against PgBouncer.* The same sessions through both: where the two differ, the difference is
   written down as known and asserted to still differ, not allowed to drift.
3. *Transaction boundaries.* A transaction that is interleaved with other clients' keeps its server connection; one
   that ends releases it (the pool's idle count is observable); an aborted transaction (`E`) holds until `ROLLBACK`;
   a client that disconnects mid-transaction has its server connection rolled back (a `ROLLBACK` is sent) or closed
   before the next client sees it. A test that leaves a row uncommitted and checks that no other client reads it.
4. *Refusals in their words.* A named `Parse` in transaction mode, a client over the limit, a wrong password, a
   database that does not exist: `ErrorResponse` with a SQLSTATE a client library understands, never a hang or a reset.
5. *Real clients.* `psql`, `pgbench` (simple and extended protocol), `psycopg`, and `lexsys-pg`'s own driver and
   pool, each through the pooler.
6. *Hostile bytes.* A client sending a message length of 0, 3, 2^31-1, a truncated message, garbage startup, a million
   connections that open and close, a client that never reads: the pooler stays up and answers the next client. Mutation
   testing of the framing and release logic, as for the cache.
7. *`lex-sys authority`* names the network and the heap, and the CI check that it names no filesystem and no foreign
   code is kept.

**Performance gate (P1; the one that decides whether this is worth keeping).** `pgbench -S` (select-only) at 1, 10 and 100
clients through the pooler (pool size 10) and through PgBouncer, with `-M simple` (what both support) and `-M extended`
(unnamed statements), 10 seconds a run:

* **throughput at least 0.9x PgBouncer** in every cell not bound by PostgreSQL or by `pgbench`;
* **latency added at one client**: the median round trip through the pooler against direct, reported next to PgBouncer's,
  not gated (a single hop costs what it costs);
* **the pooler's CPU per transaction** (utime + stime over the run, divided by transactions), at most 1.5x PgBouncer's. This is
  the number that shows overhead when PostgreSQL is the bottleneck and throughput cannot;
* **memory** at 1,000 idle clients, reported.

## 5. What would make this not worth continuing

Stopped, and written up as a negative result, if any of these holds after the slice that could show it:

* **P0:** the framing and forwarding layer cannot reach 0.9x of PgBouncer's CPU per forwarded byte on a large result (the
  forwarding path is where a runtime without a zero-copy `splice` loses first). It would then be the language, not the
  design, and the finding would go to lex-sys.
* **P1:** correctness test 3 cannot be made to pass without parsing SQL.
* **P1:** CPU per transaction above 2x PgBouncer's after the obvious fixes: a pooler that costs twice the tool it replaces
  has only the authority story left, and that is not enough for a component on the hot path.
* **At any point:** a defect in the framing that the hostile-bytes test finds after the mutants are killed. A pooler that
  can be made to crash by a client is worse than none.

## 6. Why in this repository

`lexsys-pg` already has the message encoders and decoders, SCRAM (client side, with HMAC and PBKDF2 that P2 reuses for the
server side), and the test rig (a real PostgreSQL, `psql`, a mock server). The pooler is a second *program* here, not a
second layer of the driver: `examples/` or a `pooler/` directory with its own entry point, sharing `src/pg.ls` for
what it needs and adding nothing to the driver's public surface.
