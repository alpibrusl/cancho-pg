# A PostgreSQL connection pooler in lex-sys

> **Status: P0 to P3 built (sections 7 to 10); what is still not here is in section 10.** Sections 1-6 were written before the code
> and say what is built, in what order, what each step must show to be kept, and what would make the whole project not
> worth continuing, so that the gate could not move to fit the result. Sections 7 to 10 are what P0 to P3 showed.

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

**A correction found while building P1 (section 8): P0 stalls for 44 ms on any result of more than one TCP segment.** P0's benchmark used one-row lookups and a 200 MB stream, and
neither shows it: a stream is not latency-bound and a lookup is one segment. Measured with one request outstanding, a 70,000-byte result takes 0.48 ms directly and **44.0 ms through the P0 proxy** (Nagle's algorithm
holds a small write while an earlier one is unacknowledged, and the peer's delayed acknowledgement answers 40 ms later). The cause is that lex-sys had no way to set `TCP_NODELAY`; `conn_nodelay` (lex-sys #187) is the fix, and with it P0 takes 0.55 ms. The
"throughput" numbers above are the proxy before this fix, for results that fit one segment, and are not wrong, but "the proxy is transparent" was true only for those.

## 8. P1, built and measured

`pooler/pooler.ls` is transaction pooling: a pool of logged-in server connections (`pg.login`, so trust, cleartext and SCRAM), clients answered by the pooler itself at startup (the parameters come from the first server connection;
`BackendKeyData` is the pooler's own), a server connection lent for one transaction and taken back when `ReadyForQuery` arrives with status idle and the client is owed no more, and clients that find none free queued in order with what
they sent held back. `pooler/frame.ls` is the two state machines it rests on: what to do with a client's next message (`client_step`: forward, drop, terminate, refuse a named `Parse`, count the `Query` and `Sync` that each owe a
`ReadyForQuery`) and a scan of the server's stream for `ReadyForQuery` and its status (`scan`). Neither copies a message body.

**Not in P1** (as designed in section 2, and what that costs): clients are not authenticated (P2: it is for a trusted network); a client's user and database must be the pool's (one pool); `CancelRequest` is not mapped and the
`BackendKeyData` a client gets is a number and a zero (P3); there are no timeouts (P3); a server connection that is replaced is logged in with a blocking connect while the loop waits (a millisecond on localhost; P3); a named `Parse` is refused
with `0A000`, which is correct and also means `pgbench -M prepared` and any driver that names its statements does not work through it; a refusal inside a pipeline answers before the replies to what came before it (a client that starts a batch with the named statement, as drivers do, is not affected); asynchronous messages
(`NOTIFY`, a changed parameter) that the server sends to an idle connection are discarded.

**Correctness.**

* `tests/frame_test.ls`: 6 tests that feed generated streams to both machines cut at every chunk size from one byte up (a clean stream, a stream with a refused statement and the `Sync` that ends it, bodies of every length, messages that cannot be the protocol,
  runs of empty messages, three `ReadyForQuery`s in one look). 13 mutants of `frame.ls` (a refusal inverted, `Sync` not owed, the length limit gone, the status read from the wrong byte, ...) are each killed.
* `pooler/tests/pooler_e2e.py`: 25 tests against a real PostgreSQL over the raw protocol, each starting its own pooler: the startup looks like a server's; clients take turns on one connection; an open transaction keeps its connection and the others wait; a rolled-back one is not seen; **a client that leaves in a transaction leaves nothing open** (the connection
  is dropped, not reused, and `pg_stat_activity` shows no idle-in-transaction); a failed transaction holds until `ROLLBACK`; waiting clients are served in arrival order; pipelined queries and two `Sync`s in one write release only after the last; the unnamed extended protocol works with hostile parameters; a named statement is refused in the server's
  words (`0A000`), also inside a transaction (where the answer is `E`), and the connection goes on; wrong user, wrong database, `SSLRequest`; a server connection that dies idle is replaced, and one that dies mid-transaction closes its client and no one else's; a client that never reads does not stop the others; a 50,000-row result and a 5 MB query arrive whole; **a busy server that does
  not read while the client keeps sending 6 MB (backpressure through every buffer) loses nothing**; 60 clients on 4 connections each get their own answers; and hostile bytes (garbage startups and messages, lengths of 0, 3 and 2^31-1, 500 connections that open and close, 50 that say nothing, more clients than the limit) leave it answering.
* Mutation testing of `pooler.ls`: 16 mutants (release on any `ReadyForQuery`, the owed count ignored, a dirty server kept when its client leaves, no skip to `Sync` after a refusal, the wrong status after it, the user or database unchecked, waiting clients not served on release, last-in-first-out, reads not resumed after a drain, held-back input not sent after a drain,
  no capacity check towards the server, a dead server not uncounted, no parameters in the startup, `Terminate` keeping the server, a server's end of stream leaving its client hanging). **The first version of the tests let four survive** (the two backpressure mutants, the end-of-stream one, and a dirty-server mutant that did not compile and had to be written another way); the slow-server test was added for the first two, the death test was
  changed to require the connection to be *closed* (it had passed on a read that timed out), and all 16 are now killed.
* `pgbench` select-only and TPC-B, simple and extended, run through it with no failed transactions; `psql` is the same server on every connection.

**What building it found.** Writing a message per write is what Nagle's algorithm punishes: forwarding the extended protocol message by message (Parse, Bind, Execute, Sync as four writes) gave **90 transactions a second at fifty clients, against 25,700 with `TCP_NODELAY` and
33,300 when the messages that arrived together are sent in one write** (the pooler now does both: one write per run of consecutive messages, and `TCP_NODELAY` on every socket). And the result larger than a segment (above) needs the option whatever the pooler does.

**Performance** (`pooler/bench/p1.py`, 5 rounds interleaved pooler / PgBouncer 1.22 in transaction mode / direct; a pool of 8 on each; same cores, same PostgreSQL 16.15 as section 7; PgBouncer with server TLS off). Medians; every run is in the script's output.

| cell | tps direct / pooler / PgBouncer | PostgreSQL cores busy % | pooler over PgBouncer | pooler CPU per transaction, pooler / PgBouncer |
|---|---|---|---|---|
| `-S` 1 client | 13,172 / 9,655 / 9,392 | 34 / 24 / 24 | **1.03** | 33.1 / 35.2 us (0.94) |
| `-S` 10 clients | 38,785 / 50,028 / 46,444 | 98 / 93 / 90 | PostgreSQL-bound (raw 1.08) | 17.9 / 20.4 (0.88) |
| `-S` 50 clients | 27,869 / 51,454 / 43,213 | 97 / 96 / 87 | **1.19** | 16.3 / 22.1 (0.74) |
| `-S` 100 clients | 26,915 / 51,216 / 48,995 | 94 / 97 / 93 | PostgreSQL-bound (raw 1.05) | 15.7 / 19.0 (0.83) |
| `-S` 10 clients, extended | 30,758 / 43,510 / 42,050 | 98 / 96 / 94 | PostgreSQL-bound (raw 1.03) | 19.2 / 22.0 (0.87) |
| `-S` 100 clients, extended | 23,425 / 43,716 / 42,105 | 95 / 98 / 95 | PostgreSQL-bound (raw 1.04) | 16.7 / 20.5 (0.81) |
| 10,000 tps offered, 10 clients | 10,012 / 10,013 / 10,000 | 49 / 40 / 40 | 1.00 (latency 0.28 / 0.27 ms) | 29.5 / 32.0 (0.92) |
| 20,000 tps offered, 100 clients | 19,813 / 20,063 / 20,000 | 82 / 60 / 59 | 1.00 (latency 0.38 / 0.29 ms) | 24.7 / 26.8 (0.92) |
| a 200 MB result | 0.53 s / 0.45 s / 0.54 s | | | **0.60 / 1.45 ms per MB (0.41)** |

**Against the gate.** Throughput at least 0.9x PgBouncer's in every cell where it can be judged (1.03, 1.19, 1.00, 1.00), and the pooler's CPU per transaction below PgBouncer's in every cell (0.74 to 0.94; the gate allowed 1.5x and the stop
condition was 2x). **The gate is met.** Both poolers beat a direct connection to PostgreSQL at 50 and 100 clients (51,000 against 27,000 transactions a second) because PostgreSQL has eight busy backends instead of a hundred, which is what a pooler is for.

**How firmly.** Not as "faster than PgBouncer". An earlier run of the same script, four cells of which finished before the machine was restarted, read **0.93, 0.95 and 0.94** at 10, 50 and 100 clients (47,400 against 51,200, 47,000 against 49,600, 45,300 against 48,200) where this one reads 1.08,
1.19 and 1.05: the sign of the difference at saturation changed between two sessions on this noisy VM, and the cells are PostgreSQL-bound, so what the data supports is **parity within about ten percent in either direction**, the CPU advantage (which did not change sign), and the 200 MB result's
2.4x lower CPU per megabyte. The one latency that is not parity is the 100-client cell at an offered 20,000 a second (median 0.38 against 0.29 ms, rounds from 0.27 to 0.57): it is what the CPU ratio does not show, and it is not explained.

**Section 7's open question** (PostgreSQL spending a quarter less CPU per transaction behind PgBouncer than behind the P0 proxy, with one connection per client on each) is partly answered by measuring the same thing with a pool of eight, fifty clients, select-only (the backends'
CPU times from `/proc`, three runs each): PostgreSQL's user time per transaction was **27.0, 25.4 and 25.5 us behind the pooler and 28.2, 26.8 and 30.7 behind PgBouncer** (system time 14.4, 14.2, 13.6 against 14.6, 14.5, 15.3), and **53.6 us user and 21.3 system on a direct connection** (one run; the
other two direct runs read 0.1 and 7.5 us and are discarded as a failure of the sampling, which reads the counters of whichever backends exist when it looks). So the two poolers cost PostgreSQL the same as each other, about half what a direct connection does, and the difference follows the number of busy backends (eight against fifty): what a pooler is for. That does
not explain P0's gap, where both had a backend per client and PostgreSQL still spent 33-35 us behind PgBouncer against 44 behind the proxy; that stays unexplained.

**Decision.** P1 is kept. The stop conditions of section 5 did not fire: transaction boundaries needed no SQL parsing, the CPU per transaction is below PgBouncer's, and no client-reachable crash survived the mutants and the hostile-bytes tests. What is between this and something to run in front of a database is P2 (clients that are
authenticated) and P3 (cancel, timeouts, limits, a connection that is replaced without waiting).

## 9. P2, built: clients are asked for a password

`pooler/scram.ls` and the startup state machine in `pooler/pooler.ls`. Given a client password as the last argument (`pooler <listen> <host> <port> <user> <database> <server password | -> <pool size> <client password>`), the pooler answers a startup with
`AuthenticationSASL` and runs SCRAM-SHA-256 (RFC 5802, 7677) against the client before the client is told it is in; without one (or `-`) clients are trusted, as in P1. The pooler never holds the password after start: it derives the salt, `StoredKey` and `ServerKey` once (16 random bytes of salt,
4096 iterations, as PostgreSQL does) and a login is two HMACs, a SHA-256 and a constant-time comparison. The client's proof is checked, the exchange's nonces are checked (the final message's must be the one the pooler made, so a captured final message is useless in another session even with the same client nonce),
the channel-binding flag is checked, and the server signature the client is sent is the one only a holder of the password can make.

It works over plain slices, with no heap, because the request loop has none; the random bytes for nonces come from a pool the main loop (the one holding `/dev/urandom`) keeps topped up.

**Checked.**

* `tests/scram_test.ls`: the RFC 7677 exchange (the proof is accepted, the server signature is the RFC's); the heap-free HMAC and base64 against the driver's own at every key length from 0 to 64 and every message length in steps of 13 up to 200, and base64 at every length to 40; each of the 44 characters of the proof changed in turn, another message,
  another password and another iteration count refused, and no signature written for a refusal. 9 mutants killed (one, a comparison that stops at the first difference, cannot be told apart by a test and is left to review).
* `pooler/tests/pooler_e2e.py`, class `Authentication` (14 tests): **`libpq` (`psql`, `pgbench`) logs in** with the right password (it checks the server signature too, so this is the independent oracle) and not with a wrong or no password; an independent Python SCRAM client does the same and verifies the signature; a wrong password, a proof with one bit changed, another nonce, no proof,
  an empty proof, a proof replayed from another session with the same client nonce, channel binding requested, the `-PLUS` mechanism, a bad channel-binding flag, a first message with a wrong declared length, and messages that are not password messages (each refused with the SQLSTATE PostgreSQL would use: `28P01`, `28000`, `08P01`); an exchange cut off at every third byte, 50 half-finished exchanges, and
  garbage in the place of the password leave the pooler answering; without a client password nobody is asked for one. 13 mutants of the authentication code were run and **the first version of the tests let three survive** (the message type not checked as a password message, the proof search stopping one byte early so an empty proof was a "malformed message"
  instead of a wrong password, and the declared length not checked): each now has a test, the error codes are asserted where the mutant changed only the code, and all 13 are killed. A fourth, a pattern that did not match after formatting, was rewritten and killed.
* A test that was wrong, found by running the whole suite instead of one class: "waiting clients are served in the order they came" recorded the order in which Python threads woke up, which two answers a fraction of a millisecond apart can swap (it failed two runs in eight when the database was `postgres`). It now orders the answers by the server's own `clock_timestamp()`, and three full runs of 39 tests pass.

**What it costs and what it does not do.** The login is one extra round trip pair and two HMACs; the pooler's request path is untouched after it. **The password is a command-line argument**, which any user on the machine can read from the process list: it is for tests and for a network of one. Reading it from a file needs
a file capability the pooler does not hold (`lex-sys authority` shows exactly what it holds, which is the point), and that is the next thing to design, not done. One user, one secret: the client password is separate from the password the pooler logs in to the server with, and there is no per-user list (a second pool is a second process). The password is used as the bytes given, not run through SASLprep (so an ASCII
password is correct and a non-ASCII one that needs normalising is not). Cleartext and MD5 authentication are not offered, only SCRAM; and an unauthenticated client holds one of the 200 client slots until it is cut off, because there are no timeouts yet (P3): fifty half-open exchanges are survived, 200 would fill the slots.

## 10. P3, built: timeouts and cancel

`pooler <listen> <host> <port> <user> <database> <server password | -> <pool size> [<client password | -> [<login ms> [<idle in transaction ms> [<queue wait ms>]]]]`.

**Timeouts** (milliseconds, 0 for none), each ending in the PostgreSQL error for it and the client cut off: a client that has not finished its startup and login in `login` ms (default 60,000; this is what closes the half-open-login hole of section 9: a client that connects and
says nothing, or stops half way through the password exchange, is cut and its slot freed), one that holds a server connection in a transaction and says nothing for `idle in transaction` ms (default none; `25P03`), one that waits for a server connection for `queue wait` ms (default 120,000; `53000`). A client that
was idle in a transaction takes its server connection with it, which is dropped and replaced, because what state it left it in is not known. The loop reads the clock once per turn and wakes every 100 ms when any timeout is set.

**Cancel.** A client's `BackendKeyData` is the pooler's own: a number for the client and 31 random bits as its secret, never the server's. A `CancelRequest` that quotes them is answered with nothing and the connection closed, as PostgreSQL does; if the client holds a server connection at that moment, the pooler opens a connection to the server
and sends a cancel with *that connection's* own process id and secret (kept from its login), which the loop does once per turn. A cancel with the wrong secret or process id, for a client that holds no server connection, or a malformed one does nothing. What a cancel can hit is whatever the client's server connection is running when the cancel arrives, which is
what PgBouncer does too; a cancel that arrives just after the client's transaction ended and another client began on the same connection can cancel the other client's statement, and nothing here narrows that window.

**Checked** (`Timeouts`, 8 tests, and `Cancel`, 5, in `pooler/tests/pooler_e2e.py`): the startup left unfinished, the password exchange left unfinished, and the idle in a transaction, waiting for a connection, each cut within the time and with the right code; an idle client that is not in a transaction is *not* cut; a client that keeps working in a
transaction is not cut; **a query that runs longer than the idle-in-transaction timeout is not idle** and **a client that waited for a connection is not cut off while it runs** (the two stale-deadline cases the first version of the tests missed); a real cancel stops `pg_sleep(20)` with `57014` and the connection goes on; wrong secret, wrong process, process zero, a client with no
server connection, and malformed cancels do nothing; each client's key is the pooler's own and different. Of 15 mutants of the new code the first run killed 11, **let 2 survive and could not match 1**: the survivors were the two stale-deadline cases above (a deadline set by the previous answer, or by queueing, firing during the work the client was waiting for); both now have a test, and
the unmatched one (cancels never sent) is killed. **One mutant still survives and is equivalent**: not clearing a client's queue deadline when it is given a server connection, because a queued client always has bytes held back, and forwarding them clears the deadline in the same step; the line is kept as the one that says what is meant.
Running two test runs at once on the same ports made eight tests error at once; that was the runs colliding, not the code, and on a quiet machine all pass.

**Still not here, and why.**

* **A server connection is made with a blocking connect.** When one dies it is replaced by logging in while the loop waits; that is a millisecond to a local server and the connect's timeout to one that is not answering, during which no client is served. lex-sys has no non-blocking connect (`tcp_connect` waits), so this needs a language change, as `conn_nodelay` and `copy_within` did: a `tcp_connect` that
  returns when the connection is started and says when it is complete through the poller.
* **No shutdown that drains.** lex-sys has no signal handling, so a stop is a kill: clients are cut, which is what a restart of the pooler costs now.
* **The password is a command-line argument** (section 9), the same for the timeouts' arguments being positional, which is awkward and will be replaced by a configuration read from a file once there is a file capability to hold for it.
* **One pool**: one user, one database, one server, and 200 clients at most (fixed at build); a second pool is a second process.
* **No TLS** on either side, no `LISTEN`/`NOTIFY` (messages to an idle server connection are dropped), no session pooling mode (a client that needs session state needs a server connection of its own).
* **Not measured since P1:** the cost of the timeout scan (464 slots a turn, every 100 ms) and of the cancel path are not in section 8's benchmark; the benchmark was run before them.
