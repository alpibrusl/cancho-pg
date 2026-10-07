# A pool that comes back

> **Status: built (`src/pool.cho`, package `pg.pool`), tested against PostgreSQL 16 and against mock servers, and measured.**
> It is the `revive` that [`nonblocking.md`](nonblocking.md) section 4.2 promised and section 9.3 listed as missing, with one
> difference that the measurements below justify: the attempt is not "a blocking connect and login, bounded". Nothing in it waits.

## 1. The problem

`pg.pool` took connections that were already logged in (`pool.add`), and when one failed it was gone: `lexsys-hooks`, which keeps
its history, its endpoints and its schedules in PostgreSQL through one pool, stayed unready after the database came back until the service was
restarted (`/readyz` 503, the history dropping rows, the management routes answering 503). The first connections were made by blocking
helpers before the loop ran, so the start waited while the database was silent. And the obvious repair, a reconnect in the loop with
the same blocking helpers, would freeze the one thread that serves every request: `tcp_connect` waits for the kernel, `pg.login` waits for
the server, and a SCRAM login is 9 ms of key derivation on top. The baseline in section 6.4 is that loop, measured.

## 2. What it does

```
pool.reconnect(heap, pool, user, password, database, seed, setup, statements, min_ms, max_ms, attempt_ms, request_ms) -> (pool, 0 | -1)
pool.tick(heap, &!pool, &!poller, now_ms) -> int          // once a turn: advance the logins, time things out, answer how many dials are due
pool.adopt(heap, pool, &!poller, now_ms, conn) -> (pool, lane | -1)      // a dialed connection (tcp_connect_start) goes in, the login begins
pool.dial_failed(&!pool, now_ms, errno) -> lane | -1      // the dial failed at once: count it, back off
pool.revive(heap, pool, &Net(""), host, port, &!poller, now_ms) -> pool   // tick, then dial and adopt for each connection due
pool.next_wake(&pool, now_ms) -> ms | -1                  // how long the loop may sleep
pool.statement(heap, script, name, sql) -> script         // add a statement to `setup`; `pgen` modules have `prepare_script(heap) -> (script, count)`
pool.lost(status) -> bool                                 // the status of a request says the connection went: the outcome is unknown
pool.live, connecting, made, reconnects, attempts, failures, losses, changes, lane_state, last_failure, last_loss, last_errno, sqlstate
```

The loop owns the poller and the clock and calls `tick` (or `revive`) once a turn, after that turn's `pump`s. `pump` already moves a login one
step on a poller event, and `tick` does the steps that have something to build, send or compute. A connection that is being made is watched under its
lane's token (`first_token + lane`) like any other, so a loop that waits in its poller wakes when a connect completes or is refused, when the
server answers a message of the login, and when the server hangs up; the only things the poller cannot wake it for are time (a backoff that ends, an attempt that runs out of time, a request that waited too long),
and `next_wake` says when the nearest is. `changes` goes up whenever any connection goes live or dies or an attempt fails, for a loop that wants to
know if there is anything to report (readiness, a metric) without looking at every counter.

### 2.1 The life of a connection (a lane)

```
 never used / down ──(due: its wait is over, its answers taken)──> dialing ──> startup ──> auth ──> [password | SCRAM x3] ──> AuthOk ──> ReadyForQuery
        ^                                                                                                                     │
        │                                                                                                                prepare: the script, one Parse+Sync each
        │                                                                                                                     │
        └─ lost: EOF, read/write error, not the protocol, a FATAL message, a slab overrun, a request that waited too long <── live
```

Any failure before `live` closes the connection and counts as a failed attempt with a reason (`last_failure`); any loss of a live connection
answers every request on it that had no reply with a status (`last_loss`). In both the lane waits before the next attempt:

* The wait after a failed attempt starts at `min_ms` and doubles to `max_ms` (100 ms, 200, 400 ... 5 s is the suggestion). It is per lane, so n lanes
  retry independently and a pool of four against a down database makes four attempts at each step, not four times as many.
* A connection that was live for at least a second and is then lost is retried **at once** (its wait goes back to `min_ms`): a backend killed by an
  administrator is replaced before the next request, while a server that accepts every login and drops the connection straight away is retried
  at the backoff, not in a loop.
* An attempt has `attempt_ms` from the adoption of its socket to `live`, the statements included; it covers a server that accepts and says nothing, one
  that answers a byte a second, and a key derivation that was asked to be a million iterations.

### 2.2 What a caller sees

* `submit` answers `-3` while no connection is live: the request was not queued, so it did not run. (It was already so.)
* A request that was queued or sent on a connection that is lost is handed back by `next_done` in its place in the order, with `status` one of
  **1** the server closed the connection, **3** a read failed, **6** a write failed, **8** a reply larger than the input slab, **10** not the protocol, **11** the server
  sent a FATAL error (shutdown, a terminated backend, an idle timeout: its `V` severity, or `S` for a server that has no `V`), **12** no answer within `request_ms`.
  `pool.lost(status)` is true for these and only these. **A refusal by the server is not one of them**: it is a reply with `status` 0 whose
  `pg.failure(reply) >= 0` is the ErrorResponse. So "the connection was lost, whether it ran is unknown" and "the server said no" are different
  answers, as they must be to decide whether a write may be sent again. Codes 1, 3, 6, 8 and 10 are the old ones with the old meaning.
* A request that was submitted and answered before the loss keeps its reply: the replies a connection got are given out first.
* Prepared statements are per connection. A new connection gets the same `setup` script (a Parse and a Sync for each, `statements` of them) before it is
  live, so `bind_named` on a name works on the new connection exactly as on the first; a statement the server now refuses (the schema moved) fails the attempt with
  `last_failure` 9 and the server's SQLSTATE in `sqlstate`, and the pool does not go live on a connection without its statements.

### 2.3 What `reconnect` is given, and why

* **`seed`**: 16 or more unpredictable bytes, read once by the caller from `/dev/urandom` (as `examples/psql.cho` does for its nonce). The
  nonce of each SCRAM login is 18 bytes of HMAC-SHA-256 under the seed of a counter and the lane, in base64. The pool has no file capability and gets none: that
  keeps `cancho authority` of a program as it was. An empty seed refuses SCRAM servers (status 7, as `pg.login` with no nonce) and works with trust and cleartext.
* **`password`** and the rest of the login are copied into the pool, which is where the pool keeps the secret it needs on every reconnect; `close` frees them.
* **`request_ms`** is the only defence against a connection that stops without a close (a cable cut, a firewall that drops state): TCP would
  find out in minutes to hours, and the pool has no socket option to change that. 0 means no timeout; otherwise it must exceed the slowest query,
  because a request that waits longer loses the connection under it (status 12) and PostgreSQL cancels what it was running. An *idle* connection that
  has silently died is found by the first request that waits.

### 2.4 Why the pool does not dial

`cancho authority` of a program that uses `pg` says `net_out("host:port")` because the program narrowed its `Net` to one address and `pg` takes a
`Conn`, never a `Net`. A library function that dials must take `Net("")` (the language has no way to be generic over the bound), and a program
that passes a narrowed `Net` to it is a type error. So the pool never holds or takes a `Net`: the loop dials, with its own, narrowed capability,
and hands the connection over (`adopt`). `revive` is that loop for a program that has the whole network anyway, and it is the only function
of the pool whose row names `net_out("")`; a program that does not call it does not get it (`tests/narrow_use.cho`, checked by
`reconnect_test.py`, reports `net_out("127.0.0.1:5432")` and nothing wider). Nothing was added to what the pool performs: `heap`, `conn_read`, `conn_write`,
`poll`, and the `net_out` of the program's own dial.

### 2.5 Compiler gaps this ran into

* **`tcp_connect_start` resolves a name with a call that waits** (`getaddrinfo`), as its documentation says. An IP literal does not. A service that must
  reconnect to a host *name* can stall its loop for as long as the resolver takes; give the pool an address. Nothing in the pool can fix that.
* **No generic over `Net(b)`**: a library that dials cannot be used by a program with a narrowed network (known: `agent-toolbox.md` L5). Section 2.4 is the workaround.
* **Standard output is fully buffered when it is a pipe** (`io.write_all` is `putchar`), so a driver whose output a test reads as it comes must write to standard
  error; `tests/reconnect_drive.cho` does. Minimal reproducer: `io.write_all(io, "x\n")` then a sleep, with stdout a pipe: the line arrives when the program exits.
* **A failed `test.assert` is reported as "trapped: killed by signal 4"** with no location, the same as a real trap; the first hour of a bug in a test was spent on a
  size that was 100, not more than 100.

## 3. What changes for an existing caller

Nothing, unless it asks: a pool without `reconnect` does what it did. Specifically,

| | before | now |
|---|---|---|
| `empty`, `add`, `start`, `owns`, `submit`, `flush`, `pump`, `next_done`, `reply`, `status`, `live`, `in_flight`, `close` | | same signatures and behaviour |
| `add` answers | the slot the table gave | the lowest connection not in use (the same number on a fresh pool); `-2` still means the numbers free have answers waiting |
| a request on a lost connection | status 1, 3, 6, 8, 10 | the same, and 11 or 12 where a FATAL message or a timeout is the reason |
| `pump` | | returns as before; a pool that is being made is moved by it too |
| CI compiler | `2704d42` | **`a87f666`** (`tcp_connect_start`); a program that never calls `adopt` or `revive` builds with either |
| `pg` | | new public names: `parse_append`, `sasl_initial`, `sasl_response`, `scram_iterations`, `scram_salt`, `scram_client_final_with`, `pbkdf2_begin`, `pbkdf2_more`; `scram_client_final` is the same function in terms of them |
| `pool` store | requires `size`, `kind` | requires 17 names of `pg` (the CI step locks them); a consumer locks `pg` and `pool` at the same revision |
| `pgen` | | modules have `prepare_script(heap)` as well as `prepare_all(heap, conn)` |

The pool uses more of `pg` now and so a consumer must take both packages from the same commit.

## 4. Using it from a service loop

```
// once, before the loop
var pl = pool.empty(heap, lanes, 64, 131072, 131072);
let (script, count) = queries.prepare_script(heap);                      // the generated module's statements
borrow script as &sr in { let (made, rc) = pool.reconnect(heap, pl, user, pw, db, seed, buffer.bytes(sr), count, 100, 5000, 5000, 0); pl = made; }
borrow mut pl as &!qw in { pool.start(qw, poller, first_token); }        // no connection yet, and nothing waits

// every turn
borrow mut poller as &!pw in { pl = pool.revive(heap, pl, net, "10.0.0.5", 5432, pw, now); }     // or tick + your own dial + adopt
let timeout = min(my_timeout, pool.next_wake(pl, now) if >= 0)
... poller_wait(timeout), then for each event: if pool.owns(pl, token) { pool.pump(...) } ...
if pool.live(pl) == 0 { /readyz: 503 }                                   // without waiting for a restart
```

`revive` takes the pool by value (a `conns.Table` that grows is consumed by `put`, as in `http.server`'s `wait`), so it is called between the
borrows of the turn. `tests/reconnect_drive.cho` is a whole loop.

## 5. Decisions

1. **Everything is a state machine on the poller's events and the loop's clock.** The first design had `pump` do the whole login. It cannot: the SCRAM
   steps allocate (`pg`'s HMAC returns buffers) and `pump` has no heap, and its signature is what existing callers use. So `pump` does the reads, the
   framing and the transitions that need nothing built, and `tick` the sends and the computing. The cost is that a login is finished by the turn after the event.
2. **PBKDF2 in pieces.** 4096 iterations are about 9 ms in one go on the machine the numbers below come from, and the server chooses the count (the client caps
   it at a million: 4 s). `pg.pbkdf2_begin`/`pbkdf2_more` keep two 32-byte values between turns and the pool does 128 iterations a turn,
   about 270-340 microseconds. While a key is being derived `next_wake` is 0: the loop turns at once instead of sleeping between pieces.
3. **The wait belongs to the lane, not to the pool.** A lane that fails waits on its own, and the pool does not start the dial of lane 2 because lane 1 is waiting.
4. **A connection needs its answers taken before it is remade.** The lost requests' answers sit in the lane's slabs until `next_done` hands them out; the lane is not
   due until they have been, so a new login can never overwrite a reply the caller has not read.
5. **FATAL is read, not inferred.** A backend that is terminated sends an ErrorResponse (`57P01`) and closes; the pool treats a FATAL or PANIC message as the end of the
   session at once, even on an idle connection, rather than when the FIN is read. The distinct status (11) is how a caller sees "the server shut it down" apart from "the line broke".
6. **`SCRAM-SHA-256-PLUS` is not SCRAM-SHA-256.** The mechanism list is names ended by NUL, and the pool looks for `SCRAM-SHA-256\0`. (`pg.login` looks for the prefix; it
   would start an exchange with a server that offers only the channel-binding variant, and fail at its first message. Not changed here.)

## 6. How it was checked

Everything below ran on one machine (4 cores, a Firecracker VM, other work running on it: a load average of 3 to 4.5 during these runs, so the
worst turns are not the pool's alone), against PostgreSQL 16 (a private cluster, trust, cleartext and SCRAM roles as `tests/postgres.sh` makes them), compiler `a87f666`.
`tests/reconnect_measure.py` prints the tables; `tests/pbkdf2_cost.cho` the cost of a piece.

### 6.1 The tests

| | |
|---|---|
| `tests/pg_test.cho` (23, no server) | PBKDF2 in pieces equals PBKDF2 for every cut; SCRAM by its parts equals RFC 7677; the challenge checks answer what the whole answers |
| `tests/pool_test.cho` (8, no server) | which statuses are `lost`; the arguments `reconnect` refuses; nothing due before `start`; the waits 100, 200, 400, 800, 800; two lanes wait separately; `pgen`'s script is a Parse and a Sync each |
| `tests/reconnect_test.py` (34) | the pool against PostgreSQL behind `tests/tcpproxy.py` (killed idle, killed with requests in flight, cut and restored, reset, black-holed, silent, frozen; one of three killed; four of four; flapping; a wrong password; SCRAM and cleartext; an unknown database) and against mock servers (the login in pieces of one byte, a server that is starting up, garbage, a hang-up, MD5, a message out of turn, a refused statement, SCRAM with an impostor of three kinds, a wrong password, a million iterations, 50 million, `SCRAM-SHA-256-PLUS` only, no seed, cleartext, a nonce for every login); `cancho authority` of a narrowed program; the blocking baseline |
| `tests/e2e.py` (46) and the pooler suites | unchanged, and green |

### 6.2 Does the loop wait? (the gate: no caller blocks longer than a stated bound)

`maxbusy` is the longest the driver's loop spent between a return of `poller_wait` and its next call (the clock has a resolution of 1 ms);
`busy>=n` counts turns that took at least n ms. The pool runs in the loop with the poller, a 10 ms wait at most, and `revive` every turn.

| scenario | maxbusy | turns of 1, 2, 5, 10 ms or more | turns |
|---|---:|---|---:|
| 10 kills of one trust connection, remade | 2 ms | 4, 1, 0, 0 | 1919 |
| 10 kills of one SCRAM connection, remade | 12 ms (load 4.5), 2 ms (load 2.7) | 130, 11, 2, 1 (112, 2, 0, 0) | 2247 |
| server away 1, 3, 6, 12 s, then back (7 runs, pool of 2) | 1 ms in all seven | 1 to 6 turns of 1 ms, none of 2 | 1052-2077 |
| a database that drops every packet, 4 s and 8 s (pool of 2) | 1 ms | 2 and 1 turns of 1 ms | 613, 1029 |
| a SCRAM challenge of 1,000,000 iterations (mock, 3 s) | 4-8 ms at load 3.5 (the test bound is 50) | | 8,400-9,500 |

The piece of key derivation that a turn does costs 265-342 us (128 iterations; `tests/pbkdf2_cost.cho`, at a load of 3), and the 4096 iterations
in one go 8.1-9.7 ms. So the bound a turn is held to is about one piece per login that is deriving a key (a pool of 4 logging in together: about
1.3 ms) plus the ordinary work of a turn; and the largest turn seen, 12 ms, is one in 2247 at a load average of 4.5, i.e. the scheduler (the same
scenario at a load of 2.7: 2 ms). The test asserts a gross bound of 50 ms and, as the structural check that the derivation is in pieces,
that a SCRAM login of 4096 iterations takes at least 30 turns of the loop and at most 150 ms. A mutant that derives the key in one turn
fails both the million-iteration test and the structural one.

**The same job done the blocking way** (`tests/stall_baseline.cho`: tick every 10 ms, then at 0.5 s `tcp_connect` and `pg.login`): against a server that accepts and
does not answer, or a listener that drops the packets, the last tick is at 500 ms and none follows for the 7.5 s the test then waited before killing it: the loop is gone as
long as the server is. The pool, in those two scenarios, has a longest turn of 1 ms.

### 6.3 How fast is it back

Loss to live again, the one connection killed with `pg_terminate_backend` 10 times, 1.2 s apart (so each loss is retried at once), pool with waits 100 ms to 5 s:

| login | median | max | min |
|---|---:|---:|---:|
| trust | 52 ms | 147 ms | 35 ms |
| SCRAM-SHA-256 | 57 ms | 92 ms | 44 ms |

(Most of that is the tick-to-tick latency of a login that is a handful of round trips: dial, startup, auth, three statements. The loss is noticed
when the FATAL message arrives, with no traffic: `test_a_connection_killed_while_idle...` requires under 500 ms and the replacement under a second, after a kill.)

Server away (the proxy refuses; a pool of 2; waits 100 ms doubling to 5 s) and then back: how long until both are live:

| away | restore to both live | attempts (both lanes, whole run) | failed | reconnects |
|---:|---:|---:|---:|---:|
| 1 s | 0.51 s, 0.50 s | 10 | 6 | 2 |
| 3 s | 0.11 s, 0.11 s | 12 | 8 | 2 |
| 6 s | 0.31 s, 0.31 s | 14-16 | 10-12 | 2 |
| 12 s | 4.31 s | 18 | 14 | 2 |

It is always within the wait the lane was at when the server came back (at most `max_ms`, 5 s here): once a lane has failed, its attempts fall about 0, 0.1, 0.3, 0.7, 1.5, 3.1, 6.3 and 11.3 s
later (the 12 s row: seven failed attempts a lane, the last at about 11.3 s, and the next one due 4.3 s after the server came back: the 5 s wait). Started against a black hole with attempts of 1 s, the first line of output came after 2 ms
(the start does not wait), the lanes made 10 and 12 attempts in 4 and 8 s, every one failed by running out of its second, and the pool was live 1.50 s and 0.11 s after the packets were let through.
A wrong password (SCRAM role, waits 100 to 800 ms): attempts at 0, 100, 300, 700, 1500, 2300, 3100 ms, seven in 4 s, never live, SQLSTATE 28P01 every time, `last_failure` 4.

### 6.4 The gate, item by item

| gate | evidence |
|---|---|
| connection killed while idle | `test_a_connection_killed_while_idle_is_replaced_before_the_next_request`: loss seen < 0.5 s, live again < 1 s, 1 loss, 1 reconnect, every later request right, no 26000 |
| while a query is in flight | `..._with_requests_in_flight_answers_them_as_lost_and_the_next_one_works`: slow requests queued, the backend ended, the ones with no reply answered with status 11 (the FATAL message) or 1, each tag once, later ones right; prepared statements work (no 26000) |
| server restarted | the proxy cut and restored instead (the shared server is not touched): `test_a_server_that_goes_away_and_comes_back` (2 lanes, 2.5 s away, both back within `max_ms` + 0.3 s, `reconnects` 2, ECONNREFUSED recorded, 20+ requests refused at once with -3, none wrong); a reset instead of a FIN too |
| unreachable for N seconds | the table above; the black-holed and silent variants each run out of their attempt time (`last_failure` 21) and come back |
| a wrong password never succeeds and does not spin | `test_a_wrong_password_...`: attempts 5 to 8 in 4 s, all refused 28P01, never made |
| no caller blocks | 6.2 |
| n > 1 independent | `test_each_connection_of_a_pool_is_remade_on_its_own` (one of three ended: live 3, 2, 3; the other two answered with no gap over 0.2 s; one loss, one reconnect), `..._all_the_connections_killed_at_once...` (four remade), `pool_test`'s two lanes with separate waits |
| existing tests unchanged | `tests/e2e.py` 46 of 46 (the pool tests among them), through the pooler proxy as well, the pooler suites, `pg_test` 20 of 20 plus 3 new; none was edited |
| fmt and CI | `cancho fmt --check` clean; every step of `ci.yml` run locally against a private PostgreSQL 16 (the stores included) |
| mutants | 30 single-edit mutants of `pool.cho` and `pg.cho`, section 6.5, all killed |
| `lexsys-hooks` | its sources, as checked out, build against this `pg.cho` and `pool.cho` unchanged |

### 6.5 The mutants (`tests/mutants.py`; each is applied to the file, which is restored from a saved copy and compared with `cmp`)

The backoff does not double; has no cap; a connection that lived a moment is called stable; the FATAL message is not noticed; the requests on a lost connection are not answered; a lost
connection is not counted; an attempt never runs out of time; the first connections count as reconnects; the server's SCRAM signature is not checked; AuthOk is taken before the server proved itself; every login has the
same nonce; one statement too many is waited for; a refused statement is called a refused login; the SQLSTATE is read a byte late; a request that waits for ever is not given up; a connection
is remade before its answers are taken (this one first survived: the answers were always taken within the turn, so the driver got a `lazy` mode that takes them every 300 ms, and a test); a connected socket stays watched for writing; the key is derived in
one turn; the loop is not told there is work to do; an attempt is not counted; the cleartext password is never sent; a failed dial is retried at once; a refused login is called a protocol error; the pool is
made before the loop has started it; a longest wait below the first is accepted; a request timeout is not a lost status; a SCRAM challenge of any size is accepted; a nonce that does not extend ours is accepted;
PBKDF2 in pieces ors instead of xors; PBKDF2 in pieces starts from nothing. **30 killed, 0 survived**, the killing test checked by hand for the suspicious ones.

### 6.6 Not verified, and known limits

* **A real server restart** (`pg_ctlcluster restart`) was not done: the server is shared. The proxy reproduces what a restart does to a connection (a FIN, new connections refused, then accepted),
  and `pg_terminate_backend` reproduces what it does to a backend (a FATAL 57P01 message and a close). Not reproduced: the window in which the server accepts connections and answers
  `57P03 the database system is starting up`; a mock does it (`test_a_server_that_starts_up_slowly...`).
* **TLS** and **MD5** logins: not done, as before; an MD5 server is refused (`last_failure` 5) and retried at the backoff.
* **A host name** in `revive`/`tcp_connect_start` is resolved by a call that waits (section 2.5); only an address was measured.
* **A cable cut with no reset** is found only by `request_ms` (tested with the proxy frozen); an idle connection that dies silently is found by the first request that waits.
* **Darwin**: only Linux was run (`tcp_connect_start` says the same of itself).
* **Retrying a request** is the caller's: the pool says the outcome is unknown and does not retry. A request that was only queued when the connection was lost did not reach the server, but the pool does
  not track it (a `-3` from `submit` is the only answer that means "did not run").
* The CI pin moved to `a87f666`: only checked here by running the CI steps by hand, not on GitHub's runner.
