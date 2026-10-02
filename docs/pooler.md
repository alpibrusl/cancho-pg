# A PostgreSQL connection pooler in lex-sys

> **Status: P0 built and measured (section 7); P1-P3 designed, not built.** Sections 1-6 were written before the code
> and say what is built, in what order, what each step must show to be kept, and what would make the whole project not
> worth continuing, so that the gate could not move to fit the result. Section 7 is what P0 showed.

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

## 7. P0, built and measured

`pooler/proxy.ls` (about 330 lines) is the transparent proxy: one loop on `std.conns` and `Poller` (the cache's), a client paired with a server connection
opened when it is accepted, bytes forwarded in 32 KiB chunks, a 256 KiB queue per connection for what the kernel will not take, a connection read from only while
its peer's queue has room, and a peer closed once what is queued for it has gone. It understands nothing of the protocol. `lex-sys build` of it needs nothing outside
`std` (`Net("")`, `conn_*`, the poller, the heap).

**Correctness (section 4's list, the part P0 can show).** `tests/e2e.py`, 46 tests (29 queries compared with stock `psql`, hostile parameters, trust, cleartext and SCRAM-SHA-256 logins including a non-ASCII
password and an impostor server, the pool tests against the real server) passes unchanged **through the proxy**, and CI runs it that way. `pgbench` (simple, extended, prepared; select-only and TPC-B)
through the proxy completes with no failed transactions. **Not yet done** from the list: the hostile-bytes test and mutation testing of the framing (the proxy has no framing yet: it is bytes in, bytes out),
the differential against PgBouncer's behaviour on refusals (P1 and later), and the other real clients.

**Performance** (`pooler/bench/p0.py`, 5 rounds, runs interleaved proxy / PgBouncer / direct; pooler on core 0, PostgreSQL 16.15 on cores 1-2, `pgbench` on core 3; PgBouncer 1.22.0 in
session mode with server TLS disabled, so that neither side spends CPU on encryption; this is a noisy 4-vCPU VM). Medians, with every run in the script's output:

| cell | tps direct / proxy / PgBouncer | PostgreSQL cores busy % (direct / proxy / PgBouncer) | proxy over PgBouncer, throughput | pooler CPU per transaction, proxy / PgBouncer |
|---|---|---|---|---|
| `-S` 1 client | 12,481 / 8,261 / 9,121 | 35 / 26 / 25 | **0.91** | 32.3 / 34.8 us (0.93) |
| `-S` 10 clients | 34,328 / 37,812 / 47,144 | 98 / 94 / 96 | no ratio: PostgreSQL-bound (0.80) | 16.1 / 18.0 (0.90) |
| `-S` 50 clients | 29,982 / 31,520 / 40,076 | 97 / 81 / 99 | **0.79** | 16.8 / 17.7 (0.95) |
| `-S` 10 clients, extended | 29,828 / 34,607 / 41,629 | 98 / 93 / 97 | no ratio: PostgreSQL-bound (0.83) | 16.7 / 19.2 (0.87) |
| 10,000 tps offered, 10 clients | 9,994 / 10,026 / 10,001 | 43 / 42 / 38 | 1.00 (latency 0.30 / 0.44 ms) | 26.5 / 29.6 (0.90) |
| 20,000 tps offered, 10 clients | 19,986 / 20,000 / 20,011 | 67 / 64 / 59 | 1.00 (latency 0.32 / 0.29 ms) | 21.5 / 24.6 (0.87) |
| a 200 MB result, one client | 0.59 s / 0.69 s / 0.57 s | | 0.83 (time) | **0.75 / 1.45 ms per MB (0.52)** |

**Against the gate.** The CPU the pooler spends is at or below PgBouncer's in every cell (0.87 to 0.95 per transaction, 0.52 per megabyte forwarded), where the gate allowed 1.5x and the stop condition was
2x: **that part passes, and the forwarding-path stop condition does not fire.** Throughput does not clear the gate in the cells where it can be judged: **0.91 at one client (passes, narrowly) and 0.79 at
fifty (fails 0.9)**, and the two ten-client cells, flagged PostgreSQL-bound by the rule (PostgreSQL's cores at 90% or more under every target), show the same direction (0.80, 0.83) and are not quoted as ratios. At a fixed offered load both keep up, and the latencies are in the same range and noisy
(rounds of 2 to 4 ms appear under every target, direct included).

**What was ruled out, and what is not explained.** The pooler's own cost is not the difference: its CPU per transaction is lower, and its core is 53% busy at fifty clients. `strace -c` shows the same syscalls per
transaction (2.0 `sendto`, 2.0 `recvfrom`, 0.22 `epoll_wait`) for both. PgBouncer sets `TCP_NODELAY` and `SO_KEEPALIVE` on its sockets and the proxy sets neither (lex-sys has no way to set a socket option on a
`Conn`); a throwaway `LD_PRELOAD` shim that set `TCP_NODELAY` on both of the proxy's sockets made **no difference** (36-38k plain, 36-37k with it, at ten clients), so it is not that. What does differ is PostgreSQL's own cost per transaction: measured on the
backends' CPU times, about 44 us of user time per transaction behind the proxy and 46 direct, against 33-35 behind PgBouncer (system time 19 / 20 / 14-15), with one context switch per transaction in each case (two runs of each; a second proxy run read 21 us and 0.47 switches per transaction, which a handful of backends' counters not being sampled would explain and which is left out of these figures, so the proxy's 44 rests on one run). PgBouncer's traffic makes PostgreSQL ~25% cheaper per transaction, and
PgBouncer is faster than a direct connection at ten clients, which a proxy cannot be by doing less. Two guesses, neither tested: bursts of requests arriving back to back help the backends' caches, or something in how it writes to the server socket changes the kernel work done on PostgreSQL's side.
This needs a profiler (`perf` is not installed here) and a quieter machine, and it is the first thing to look at before P1 is judged.

**The 200 MB cell** was bimodal (rounds of 0.45-0.7 s and of 1.1-1.5 s, under every target, direct too), and the median of five is the ordinary mode; the run-to-run noise of this VM is larger than the difference between the three. The CPU per megabyte is not noisy and is the figure to read.

**Decision.** P0 is not a stop: the forwarding path is cheap, the protocol is untouched, the existing end-to-end suite passes through it. But P0 does **not** meet its own throughput gate at fifty clients, and that is recorded here
instead of being averaged away. Slice P1 (transaction pooling, which is the point of a pooler and changes the traffic shape PostgreSQL sees) is the next step; the throughput gate is to be re-run on P1, and
if the difference in PostgreSQL's cost per transaction persists there it is a finding about PgBouncer's behaviour to reproduce, not about our CPU.

**Not built in P0, as designed:** the connection to the server is opened with a blocking `tcp_connect` when a client is accepted; there is no limit on connection attempts, no timeout, and a client that connects and
says nothing holds a server connection (P1 and P3).
