# A connection that does not block the loop

> **Status: design, not built.** Written after measuring what the blocking driver costs and what the cheapest
> alternative buys, and with the conclusion that the case for building this is **not throughput**. Every number is
> from `lexsys-web`'s `docs/benchmarks.md` ("On PostgreSQL"), one machine; claims that were not measured say so.

## 1. The question

`pg.extended`, `pg.run_named` and the rest of layer 3 wait for the server. In `http.server`'s one loop a query
inside a handler stops every other client for the length of the round trip. Is it worth building a connection
that does not, and what would it have to do?

## 2. What the measurements say

A one-row lookup on a prepared statement, requests a second (PostgreSQL on its own core; its ceiling over this
protocol is 24,717 a second, from `pgbench`):

| the service | GET one user | GET a page of 20 | creates |
|---|---:|---:|---:|
| one blocking connection | 14,976 | 4,496 | ~2,700 |
| two copies on the same core, sharing a port | 22,604 | 5,456 | |
| three copies | **24,211** | **6,224** | |
| four copies | 23,881 | 5,852 | ~6,300-6,700 |

(Creates are noisy: one copy ranged 2.1k-4.2k over ten runs; four copies 4.9k-7.2k. Medians of five, twice.)

Three things follow, and they are not the ones the first estimate in design.md section 4 expected.

1. **A read is within a few percent of PostgreSQL's own ceiling with three copies and no new code.** The idle
   ~19 microseconds of every 67 in the single-connection service -- PostgreSQL's core waiting while the loop parses
   the next request and renders the answer -- are exactly what a second blocking copy fills. A non-blocking
   connection that pipelined its queries would fill the same gap from inside one process, and cannot do better than
   the ceiling PostgreSQL has. *Throughput on reads is therefore not an argument for building it.*
2. **A write wants several connections, and pipelining does not give them.** Concurrent connections let PostgreSQL
   commit several inserts per `fsync` (group commit). One connection pipelining a hundred `Bind`/`Execute`/`Sync`
   sequences still commits them one `Sync` at a time, in order. So the write case is the case for a **pool**: more
   than one connection, however the I/O is done.
3. **What copies do not give.** They share nothing. A service with state in memory, a cache, a rate limiter, a
   counter -- anything one request leaves for the next -- cannot use them. Each copy holds its own PostgreSQL
   backend (`max_connections` is a budget). And a query that takes a second still blocks *its copy's* clients: one
   slow report stalls every request that happens to be on the same copy, which is a latency property no amount of
   throughput hides. This is the real argument, and it is a robustness one.

So the design below is for a service that needs one of: shared in-process state; a bound on how many backends it
holds that is smaller than the copies it would need; or queries whose duration it does not control. If a service
needs none of them, run copies.

## 3. What exists, and what does not

Verified in `lex-sys` at the revision `lexsys-web` pins (`bbeb75f`), by reading `std/conns.ls`,
`docs/native-sockets.md` and `packages/http-server/server.ls`:

* **A resource that holds many connections.** `Conn` is a resource and no ordinary table can hold one;
  `std.conns.Table` does: `put`, `read`, `write`, `nonblocking`, `watch` / `rewatch` (register a slot with a
  `Poller` under a token), `close`. A second `Table` can hold database connections.
* **Non-blocking I/O on an outgoing connection.** `conn_nonblocking` is explicit and one-way; after it,
  `conn_read` and `conn_write` answer `Again` instead of waiting (`Received::Again`, `Sent::Again`).
* **The `Poller`** is `epoll`/`kqueue`: a set of handles, each named by a token, and `poller_wait` fills `(token,
  readiness)` pairs. A second kind of handle in the same set is what lets one `wait` serve both HTTP clients and
  database connections.
* **The sans-io halves of this driver.** Layers 1 and 2 (encoders, decoders, `size` framing, `ready`) take bytes and
  give bytes; nothing in them waits.

What does **not** exist, in `http.server`:

* **The `Poller` belongs to the `Server`.** `open` takes it by value and `close` ends it; the application has no
  borrow of it, so cannot register a database connection.
* **A request cannot be left unanswered.** `next` makes one connection's request "current" and `respond` answers
  the current one; the next `next` replaces it, and the parse table (`parsed`) is one shared array that the next
  request overwrites. There is no way to say "answer this one later".
* **Tokens are a closed namespace.** Token 0 is the listener and token `k + 1` is connection slot `k`;
  `serve_events` indexes the connection state with `token - 1` and does not check it against the table size, so a
  token for anything else would be read as a connection or trap. Application handles need a range the server
  leaves alone and reports.

These are changes to a package in `lex-sys`, with its own documentation, tests and published store, and every
downstream lock pins its source hash. They are the larger half of the work and belong in that repository's own
design document (a `docs/http-server.md` section) when this is built.

## 4. The design

### 4.1 `http.server`: hold, answer, the poller, and events that are not HTTP

Five additions, each small, none changing what exists:

| | |
|---|---|
| `poller(srv) -> &!Poller` | a unique borrow of the server's poller, for `Table.watch` of the application's own handles |
| `first_token(srv) -> int` | the first token the server will not use (`limit + 1`); the application numbers its handles from there |
| `foreign(srv) -> &[int]`, `foreign_count(srv)` | the `(token, readiness)` pairs of the last `wait` that were not the listener or an HTTP connection; `serve_events` skips them instead of indexing with them |
| `hold(srv) -> int` | leave the request in hand unanswered: the connection is marked held (no further request is taken from it, no input is treated as "ready" for it), the current request is cleared, and the slot is answered. The request's bytes stay in the connection's buffer. |
| `answer(srv, slot, bytes) -> int` | `respond` for a held slot: delivers the bytes, advances the connection past the request, clears the hold and, if more requests are buffered behind it, queues the connection again |

A held connection must still obey the idle sweep (a client that goes away is closed and its in-flight query's tag
becomes stale: `answer` on a closed slot answers -1), and still count towards the connection limit.

What the application loses at `hold`: the views. `head`, `parsed` and `body` are borrows of the shared parse table
and the connection buffer, valid for the request in hand. The application therefore decides *before* holding which
route it is and what it will need after, and keeps those as ints in its own per-slot record (the route id, the
`Connection: keep-alive` flag, the id from a path). A handler whose answer needs the request body after the
query -- a create that echoes the body -- re-renders from the database's `RETURNING` row instead, which is what
`users_pg`'s `row_json` already does for a read.

### 4.2 `pg`: a pool whose I/O does not wait

A **`Pool`** is a resource owning a `conns.Table` of logged-in connections and, per connection, slabs of the same
kind `http.server` uses: an output queue, an input accumulator, and a FIFO of in-flight request tags. Layer 3
becomes:

| | |
|---|---|
| `pool.open(heap, net, host, port, user, db, secret, n)` | connect, log in (blocking, once, before the loop serves anyone), prepare every statement on each connection, set each non-blocking; answers the pool or a status |
| `pool.watch(pool, poller, first_token)` | register every connection for reading under tokens `first_token ..` |
| `pool.submit(heap, pool, tag, request) -> (pool, int)` | queue an encoded `bind_named` message on the connection with the fewest in flight, remember `tag`, try to write now, and register for write-readiness if the kernel did not take it all. Answers -1 if every connection is at its in-flight limit (back-pressure: the caller answers 503 or defers) |
| `pool.pump(heap, pool, token, readiness) -> pool` | for a `foreign` event of this pool: read what is there, write what was queued, and move every reply that now ends in `ReadyForQuery` to a done queue |
| `pool.next_done(heap, pool) -> int` | the tag of the next finished request, or -1; `pool.reply(pool)` the reply bytes for it; `pool.status(pool)` 0 or a failure code |

The reply is exactly what `pg.run_named` answers, so layer 2 and every generated accessor are unchanged.

**One connection, pipelined, or many?** The pool has `n >= 1` connections and pipelines on each: PostgreSQL runs the
queued `Bind`/`Execute`/`Sync` sequences in order and answers each with its own `ReadyForQuery`, so the pool needs no
parsing beyond finding the next `Z` message (`pg.size` and `pg.kind`, which exist). `n = 1` gives the read case;
`n > 1` gives group commit for writes (section 2, point 2).

**Failure.** A connection that errors or is closed by the server fails every tag in its FIFO with a status the
application turns into a 503, is closed, and is marked dead. Reconnecting is the pool's job on a timer
(`pool.revive`, run from the loop's own tick: a blocking connect and login, bounded, with a back-off, preparing the
statements again). The first version does not revive and says so; a restart of the service is the answer until it does.

### 4.3 The loop

```
srv  = server.open(...);  pool = pool.open(...);  pool.watch(pool, server.poller(srv), server.first_token(srv))
loop:
    srv = server.wait(heap, srv, clock, listener, 1000)
    for each (token, readiness) in server.foreign(srv):           pool = pool.pump(pool, token, readiness)
    while t = pool.next_done(pool) >= 0:                           // finished queries: answer their requests
        out = finish(heap, record[t], pool.reply(pool), ...)       // a `match` on the record's route; one function
        server.answer(srv, t, out)
    while slot = server.next(srv) >= 0:                            // new requests
        if the route needs no database:  server.respond(srv, out)
        else:  record[slot] = (route, keep, ...);  pool.submit(pool, slot, query_start(...));  server.hold(srv)
```

The tag is the HTTP connection's slot, so `record` is an array indexed by slot and there is nothing to allocate per
request. Because a connection is held until its answer, one client sees its answers in the order of its requests.
There is no `async`, and none is needed: `finish` is the continuation, chosen by `match` on an int, which is what a
language without closures has instead.

### 4.4 `pgen`

Each query becomes two functions: `name_start(heap, params...) -> Buffer` (the encoded `bind_named` message, no
connection argument) and the accessors, which are unchanged. The blocking `name(heap, conn, ...)` stays for programs
that block. `prepare_all` stays and is called per connection by `pool.open`.

## 5. Alternatives, and why not

* **Copies sharing a port.** Built and measured; it is the baseline this has to beat and, for a read-heavy service
  without shared state, the right answer. Not an alternative to build, a reason not to build this too early.
* **A thread per connection, or a thread pool.** `spawn` takes a captureless function and one owned capability
  payload; a worker that needs the database connection, a heap and a channel back to the loop needs more than one
  leaf (`threads.md` closed this as not yet). No.
* **A connection pooler in front (pgbouncer).** It multiplexes backends but the client is still blocking on its
  socket: the loop waits exactly as before. It helps `max_connections`, not this.
* **Pipelining on one connection only.** Fills the idle gap for reads; commits writes one at a time. Rejected as the
  whole design, kept as what each pool connection does.

## 6. What would have to be true to build it, decided before it is built

Criteria, written down now so the benchmark that follows cannot be read generously:

1. **Correct before fast.** Every end-to-end test of `users_pg` passes unchanged (the 29 of `lexsys-web`,
   Schemathesis included), and a differential run of the blocking and the non-blocking service over the same
   request sequence returns the same answers.
2. **The property that is the point.** While one request's query is pending -- a `pg_sleep(1)` behind a test-only
   route -- `GET /health` answered by the same process returns in under 5 ms, 100 times in a row. The blocking
   service fails this by construction; the copies fail it for the copy that holds the sleeping request.
3. **Reads.** One process, one connection reaches at least 22,000 `GET one user` a second (two copies reached 22,604;
   the ceiling is 24,717). If it does not, the cost of the machinery is not paid back and it is not worth keeping.
4. **Writes.** One process with a pool of four connections reaches at least what four copies did (about 6,300
   creates a second, over at least ten runs, with the spread reported).
5. **Failure.** Killing the PostgreSQL backend mid-flight answers every in-flight request with a 503, loses none and
   duplicates none, and the service keeps serving the routes that need no database.
6. **Size.** The `http.server` additions stay under about 150 lines and the pool under about 500; past that it is a
   different project and the question is asked again.

Criteria 3 and 4 are predictions, not results: a single loop does the HTTP parsing, the JSON and the pool's own
bookkeeping on one core, and 22,000 requests a second leaves about 45 microseconds each, of which PostgreSQL's
own protocol handling is some part. It may not fit. If it does not, criterion 2 and the shared state of section 2
are the remaining reasons, and whether they are enough is a decision for whoever owns the service, not for the
benchmark.

## 7. Order of work

1. `http.server`: the five additions of 4.1, in `lex-sys`, with their own tests (a held request is answered later;
   a held connection takes no new request; a closed held slot answers -1; a foreign token is reported and never
   indexed) and a section in `docs/http-server.md`.
2. `pg.Pool` with `n = 1`, tested against a real server and against a mock that answers in pieces, late and not at all.
3. `pgen`'s `_start` functions; `users_pg` on one non-blocking connection; criteria 1-3.
4. `n > 1`; criterion 4. Then failure (5), then `revive`.

## 8. Open questions

* **`hold` and HTTP pipelining.** A client that pipelined three requests has two more in the buffer behind the held
  one. The design says they wait; whether `wait` may *read* more input from a held connection (it must, or the
  kernel buffer fills and the client stalls) and how much is a limit that needs a number.
* **Statement lifetime across `revive`.** Preparing again is cheap; whether a request in flight on a dead connection
  may be retried (it is safe for a read, and for a write only if it never reached the server, which the client
  cannot tell) is a policy the service owns, and the pool should say `unknown`, not guess.
* **Cancellation.** A client that disconnects while its query is pending: the query still runs. PostgreSQL's cancel
  request goes on a second connection; whether to send it, and when, is not decided.
* **Where `pool` lives.** In `pg` or beside it. It needs `std.conns` and the `Poller`, which `pg` does not import today;
  the sans-io layers are better kept free of both.
