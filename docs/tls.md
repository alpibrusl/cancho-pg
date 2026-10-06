# TLS to the server, with lex-sys's own TLS client

> **Status: design, written before the code.** Sections 1 to 10 are the design, with the gates the work must meet (section 10) stated
> before any number. What building it found is recorded in section 11 when it is, and a claim here that a measurement shows wrong is
> corrected in place (marked *Corrected*). The things a person has to decide are section 12, each with a proposed answer.

## 1. What asked for it

`README.md` has listed TLS under "not yet" since slice 1, and `docs/design.md` §5 has it in the queue. Three things make it due now:

* **A database that is not on the same host.** Every deployment of `lexsys-hooks` so far put PostgreSQL on loopback or a private
  network and called that enough. A managed PostgreSQL (and most production clusters) refuses a connection without TLS, or should.
  Today a lex-sys service cannot connect to one at all.
* **`lexsys-hooks`' pure build** (its `docs/pure-tls.md`) delivers webhooks over lex-sys's own TLS client with no foreign function.
  Its database connection is the one connection of that service that still cannot be encrypted, and the only way to encrypt it
  today would be to put OpenSSL back, which is what the pure build exists to remove.
* **Channel binding** (`SCRAM-SHA-256-PLUS`) needs TLS first. It is not built here (section 9); TLS is its prerequisite.

The constraint: **no foreign code**. The README's first claim is that `lex-sys authority` on a program that uses `pg` reports the
network, `conn_read`, `conn_write`, `heap` and nothing else. Linking `libpq` or OpenSSL would end that. lex-sys has a TLS client
written in lex-sys, `packages/tls` (lex-sys epic #197, `docs/tls-pure.md` there), and this design uses it.

## 2. What PostgreSQL asks of a client

From the protocol documentation (§55.2.10, "SSL Session Encryption") and libpq:

1. On a fresh TCP connection, before the StartupMessage, the client sends **SSLRequest**: Int32 8, Int32 80877103.
2. The server answers **one byte**: `S` (it will do TLS: the client starts the TLS handshake on the same socket, and the
   StartupMessage and everything after it go inside TLS) or `N` (it will not: the client may send the StartupMessage in the clear,
   or close). A server too old to know the request answers an ErrorResponse; no supported server does.
3. **Nothing may follow the `S` before the handshake.** CVE-2021-23222 was libpq reading bytes that arrived after the `S` and before
   the handshake, which a man in the middle had put there, and treating them as if they had come over TLS. libpq now refuses a
   connection where the server "sent data after the SSL response". (The server side had the same bug, CVE-2021-23214.)
4. **`sslmode`** decides what the client accepts (libpq's meanings): `disable` (no TLS), `allow` and `prefer` (TLS if the server
   offers it, plain otherwise: an attacker who answers `N` gets the plain connection), `require` (TLS, the certificate not checked:
   encrypted, not authenticated), `verify-ca` (the chain checked to a trusted root, the name not), `verify-full` (the chain and the
   name). libpq's default is `prefer`.
5. **PostgreSQL 17 adds direct TLS** (`sslnegotiation=direct`): no SSLRequest, the ClientHello is the first thing sent, and the client
   must offer ALPN `postgresql`, which the server requires.
6. **The server's TLS.** PostgreSQL uses OpenSSL; 16 negotiates TLS 1.3 by default (`ssl_min_protocol_version` is TLSv1.2). It
   **issues no session tickets**, so a client cannot resume a session. *Checked:* a client of the engine that advertised resumption
   to a PostgreSQL 16 server and asked to keep its ticket after a query got none (`tls.save` answered 0).

## 3. What the engine can and cannot do

Read from `packages/tls/tls.ls`, `client.ls`, `message.ls`, `packages/x509/verify.ls` and `names.ls` at lex-sys `653bdd1` (main, after
`e59db18`, which put AES-GCM and GHASH on the hardware instructions):

* **It is socket-agnostic.** `tls.open(heap, slots)` makes an engine of `slots` connections; `seed` keys its DRBG with 32 bytes of the
  caller's entropy; `trust` loads a PEM bundle as the roots; `start(engine, slot, host, now_unix_ms)` begins a handshake; the caller
  moves bytes between the socket and the engine with `feed` (bytes the socket gave), `take` (bytes for the socket), and plaintext with
  `send` and `recv`; `event` says what the slot wants (read, write) or that it is established, closed or failed; `failure` is the
  refusal and `refusal_tag` its name; `eof` says the socket ended; `finish` queues close_notify; `drop` frees a slot and overwrites its
  secrets. **No capability is held**: the engine is pure lex-sys code, and the time and the entropy are numbers and bytes the caller passes.
* **It always verifies the server.** `tls_client.feed` verifies the `Certificate` message against the roots it is given, the host
  given to `start`, and the time. There is no option to skip it, and `x509_verify.verify` has no entry that checks a chain without a
  name: it parses the host first (`x509_names.host_parse`) and compares it with the leaf's subjectAltName after the path is built, in
  the same function. The functions that build the path (`extend`) are private. So **the engine can do `verify-full` and nothing
  weaker**, which decides section 4.
* **A host is a DNS name or an IP literal.** An IP literal sends no `server_name` (RFC 6066) and is matched against the leaf's
  iPAddress SAN; a name is matched against its dNSName SANs (wildcards as RFC 6125 has them). The subject's CN is never used.
* **TLS 1.3, and TLS 1.2 with the extended master secret**; X25519 and P-256/P-384; AES-GCM and ChaCha20-Poly1305; RSA (2048 to 4096
  bits), ECDSA and Ed25519 certificates. **Revocation is not checked** (`docs/tls-pure.md` §5.4 there).
* **No ALPN.** The ClientHello carries no `application_layer_protocol_negotiation` extension. So PostgreSQL 17's direct TLS, which
  requires ALPN `postgresql`, cannot be done with it.
* **No client certificate.** A `CertificateRequest` is answered with no certificate, so a server that authenticates clients by
  certificate (`pg_hba.conf` method `cert`, or `clientcert=verify-full`) refuses the login.
* **Memory.** A slot is about 179 KiB, plus 4,496 bytes for resumption (`docs/tls-pure.md` §7.4 there); the roots have a 1 MiB box,
  of which a bundle uses what its DER takes (one test CA: under 1 KiB; a 128-root system bundle: 138,350 bytes). `box_slice` is a
  `malloc` and a fill; with a zero fill LLVM makes it a `calloc`, so pages that are never written are not resident. *Measured* (Linux,
  arm64, `/proc/self/statm` around `tls.open`): an engine of 1 slot adds 340 pages of address space and nothing measurable to the
  resident set beyond the code; one of 8 slots, 816 pages, the same. A slot becomes resident when a connection uses it.
* **It is not independently reviewed** (lex-sys #209). `lexsys-hooks` keeps OpenSSL as its default for webhooks until that review
  closes. This document does not change that status, and the README will say so next to the feature.

## 4. `sslmode`: `disable` and `verify-full`, and why only those

| mode | offered | why |
|---|---|---|
| `disable` | **yes** | what the client does today: no SSLRequest, the startup in the clear. The default of every function that exists now |
| `verify-full` | **yes** | the only mode the engine can do (section 3): the chain to a root of the trust store given, the server's name, the dates |
| `verify-ca` | **no** | needs a chain checked without a name, which `packages/x509` does not expose (section 3). Adding it is lex-sys work (a public entry that stops before the name check), not this repository's, and it should be asked for by a program that needs it (section 12, question 2) |
| `require` | **no** | libpq's `require` encrypts without authenticating: whoever is in the middle presents any certificate and reads everything. The engine cannot do it (it always verifies), and this design would not offer it if it could: a mode that looks secure and is not is the wrong thing to make easy. A deployment that has no certificate it can verify should say so with `disable` |
| `prefer`, `allow` | **no** | an attacker who answers `N` (one unauthenticated byte) turns them into `disable`. Offering them makes `verify-full`'s guarantee conditional on nobody being in the middle, which is the case TLS is for |
| direct TLS (PostgreSQL 17) | **no** | needs ALPN (section 3) |

`pg.sslmode(text)` reads the mode a configuration names: `disable` and `verify-full` are themselves, **a mode libpq has that is not
offered here (`require`, `verify-ca`, `prefer`, `allow`) is -2**, and anything else -1. A configuration reader can say "not offered"
apart from "misspelt", and a deployment that copied `sslmode=require` from a libpq setup is refused at start with a reason, not
quietly given something weaker or stronger than it asked for.

**The name checked is not the address dialled.** A service that dials `10.0.0.5` (it must: `tcp_connect_start` resolves a name with a
call that waits, `docs/reconnect.md` §2.5) verifies the certificate against the name it is given separately, `db.internal` or
`10.0.0.5` itself (an IP SAN). This is libpq's `hostaddr` beside `host`. An empty name is refused.

## 5. The trust store and the entropy: bytes the program reads

The library reads no file. A program that wants TLS reads the PEM bundle (an operator's CA file, or the system bundle,
`/etc/ssl/certs/ca-certificates.crt` on Debian) and 32 bytes of `/dev/urandom` with its own `Fs`, narrowed to those files, and hands the
bytes over. That keeps `lex-sys authority` exact: the program's report names the two files and nothing wider (`fs_read("/dev/urandom")`
it already has, for the SCRAM nonce). *Corrected (section 11.3):* an `Fs` is narrowed once (`narrow` consumes it), so a program cannot
hold both `Fs("/dev/urandom")` and `Fs("/etc/pg/ca.crt")`: it holds the prefix common to the two, which is `fs_read("")`. The library
still reads nothing; the report of a program that reads both files says `fs_read("")`. `tests/narrow_tls.ls` reads its bundle from
standard input instead and keeps `fs_read("/dev/urandom")`. A capability that splits into two narrowed ones is a lex-sys gap. `lexsys-hooks`' `tlsx.setup` searches four system locations because it needs `Fs("")` anyway;
a library that took `Fs("")` would force that on every program that used it.

* **A bundle with no usable root is refused** at setup, before any connection: a store that trusts nothing would fail every handshake
  with `x509-unknown-issuer`, which is the right outcome reported at the wrong time. A block that is not a certificate is skipped, as the
  engine does (`tls.skipped`).
* **The bundle must fit** the engine's 1 MiB of roots (`x509-chain-too-large` otherwise); the examples read at most 2 MiB of PEM and
  refuse a file that fills the buffer rather than truncate it, as `lexsys-hooks` does.
* **The environment is not read** (`PGSSLROOTCERT`, `PGSSLMODE`): lex-sys has no environment without a foreign call. A program takes them as
  arguments or configuration.

## 6. The blocking client: `pg.ssl`

A new module, `src/ssl.ls` (`pg.ssl`), next to `pg` and `pg.pool`, and a store of its own. **`pg` itself does not import the engine**: a
program that never uses TLS takes the same `pg` it took before, and the `tls` and `x509` modules (nine of them, 2.6 MB of store) are fetched
only by a program that asks for `pg.ssl` or `pg.pool`.

```
let (link, status) = ssl.open(heap, conn, mode, server_name, entropy, pem, clock_unix_ms(clock));  // the Conn moves into the Link
let (hello, s) = ssl.login(heap, link, user, secret, database, nonce);    // as pg.login
let (reply, s) = ssl.simple(heap, link, "select 1");                     // and extended, describing, prepare, prepare_after, run_named
let (reply, s) = ssl.request(heap, link, bytes);                          // any request a pgen module's <name>_start builds
conn_close(ssl.close(heap, link));                                        // close_notify if TLS, the engine freed, the Conn back
```

**One type for both modes.** A `Link` is a `Conn` and an engine of one slot. With `disable` the engine is never started and the functions
read and write the `Conn` as `pg`'s do; with `verify-full` every byte after the `S` goes through the engine. A program chooses the mode from
its configuration and has **one code path**: it does not branch on the mode at every query. (`pg.login`, `pg.simple` and the rest stay as
they are, over a `Conn`, for every program that has them.) The engine of a `disable` link is opened with one slot and never written, so it
costs address space and not memory (section 3).

**How it drives the engine.** The `Conn` is blocking, so the loop is the simple one: `open` writes the SSLRequest, reads the answer into a
buffer of 16 bytes and requires **exactly one byte**: `S`, or `N` (refused under `verify-full` with status 13), and anything else, or more
than one byte (the CVE-2021-23222 shape), is status 14. After `S`: `tls.start`, then until `event` says established or failed, write
everything `take` gives and, when the engine wants to read, `conn_read` and `feed` all of it (what `feed` does not take at once is offered
again). A send is `tls.send` of up to one record at a time, each followed by writing everything `take` gives; a receive is `recv` until the
reply is whole, reading and feeding when `recv` says would-block. A clean close (`close_notify`) where a reply was expected is status 1, as a
closed socket is today; an end of the socket without `close_notify` is status 1 too (a reply cut short is not whole, so nothing truncated
is ever answered as complete).

**The login is shared, not copied.** `pg.login`'s decisions (what the server asked for, the SCRAM challenge, the server's signature) move
into pure functions of `pg` that both `pg.login` and `ssl.login` call; only the sending and the reading differ. `pg.login` keeps its
signature and its behaviour, and the existing suites are the evidence that it did.

**What a caller does not have to know:** the engine's slot, its buffers (a region per call, under the 64 KiB a region holds), or the
mode, once `open` is done. (`open` takes the `Conn` by value, and owning a `Conn` discharges `conn_read` and `conn_write`, so its row is
`[heap]`; the functions over a borrowed `Link` carry them.)

## 7. The pool: `pg.pool` over TLS

```
var pl = pool.empty(heap, 4, 64, 131072, 131072);
let (made, roots) = pool.secure(heap, pl, server_name, entropy, pem, clock_unix_ms(clock), clock_ms(clock));   // verify-full
pl = made;                                             // roots >= 1, or 0: nothing in `pem` to trust, or -1: an argument not usable
let (made2, rc) = pool.reconnect(heap, pl, user, password, database, seed, setup, statements, 100, 5000, 5000, 0);
...                                                    // start, revive / tick + adopt, pump, flush, next_done: as before
```

**The pool owns the engine**, one slot per lane, so no signature that exists changes: `pump`, `flush`, `tick`, `adopt` and `revive` take
what they took. `empty` opens an engine of one slot that a plain pool never writes (address space, not memory, section 3); `secure` replaces
it with one of `lanes` slots, seeds it, loads the roots and turns TLS on. It is refused (-1) once the pool has been started or has a
connection.

**A secure pool makes its own connections.** `add` takes a `Conn` that was logged in elsewhere; a TLS session cannot move from another
engine into this one, so `add` on a secure pool refuses the connection (-1, closed). A secure pool is used with `reconnect`, which is how
`lexsys-hooks` uses the pool already.

**The login gains three phases, all on the poller's events and the loop's turns, nothing waiting:**

```
connect ──(writable: connected)──> SSLRequest written ──(readable)──> the answer: exactly 'S' ──(tick: tls.start)──> handshake ──(established)──> startup ... as before
                                                                     'N' → 13, anything else → 14                    a refusal → 15
```

The answer is read in the clear into the lane's input and must be exactly one byte (a second byte in the same read is 14). `tls.start` needs
the time, which `pump` is not given, so the handshake begins in `tick` (it is a phase with work, as the SCRAM steps are). The handshake then
moves on `pump` (ciphertext read, fed, the engine's answer written) and `tick` (anything the engine has to write). Once established, the
StartupMessage and everything after it go through the engine.

**The I/O of a live TLS lane.** Writing: the plaintext queued by `submit` is given to `tls.send` a record at a time, and the ciphertext `take`
gives is written to the socket; what the kernel does not take waits in the lane's ciphertext buffer (20,480 bytes: one record with room)
and the lane is watched for writing until both the plaintext and the ciphertext are gone. Reading: `recv` into the lane's input slab; when
the engine has nothing, the socket is read (4,096 bytes) and fed. **A level-triggered poller does not see plaintext the engine holds**: when
the input slab is full the engine may still hold decrypted bytes the kernel no longer has, and nothing would wake the loop for them. So a lane
that stopped reading for room is marked, `next_wake` answers 0 for it once `next_done` has made room, and `tick` moves what the engine holds
into the slab (no socket read is needed for it, so `tick`'s row is unchanged). *Corrected (section 11.3):* that was half of it. The answers
`tick` completes that way are announced by no event either, and a loop that takes answers after its poller wait would sleep its whole
timeout with them ready; so `next_wake` also answers 0 in a turn whose `tick` completed answers.

**Time.** The certificates are checked at the Unix time. The pool's clock is the loop's monotonic `now`; `secure` takes both clocks once and the
pool checks certificates at `now + (unix_ms - now_ms)`. A monotonic clock does not jump when the host's clock is set; a loop that wants
the pool to follow such a step calls `pool.wall(pool, unix_ms, now_ms)` when it likes (section 12, question 4).

**Failures.** A failed attempt is `last_failure` 13 (the server answered `N`), 14 (the answer was not one byte `S` or `N`) or 15 (the TLS
handshake failed: `pool.tls_failure(pool)` is the engine's code and `tls.refusal_tag` of it the reason, `x509-name-mismatch`,
`x509-unknown-issuer` ...). A failed attempt waits its backoff as every other does: a server whose certificate is wrong is retried at 100 ms,
200 ms ... `max_ms`, never faster, and never accepted. A live connection whose TLS fails (a record that does not authenticate) is lost with
**status 15**, which `pool.lost` now includes; an end of the socket without `close_notify` is status 1, as an end is today. The engine's slot is
dropped (its secrets overwritten) whenever the lane's connection is closed, for any reason.

## 8. What a refusal looks like

Every status has a stable tag, `pg.status_tag(status)`, and a TLS refusal has the engine's own (`tls.refusal_tag(code)`, the table of
`docs/tls-pure.md` §8 in lex-sys):

| status | tag | meaning |
|---:|---|---|
| 0 | `ok` | |
| 1 | `pg-closed` | the server closed the connection (or the socket ended without `close_notify`) |
| 2 | `pg-would-block` | a read or write would block |
| 3 | `pg-read-failed` | a read failed |
| 4 | `pg-refused` | the server answered a login with an error |
| 5 | `pg-auth-unsupported` | an authentication this cannot do (MD5) |
| 6 | `pg-write-failed` | a write failed |
| 7 | `pg-scram-failed` | SCRAM failed on the client's side |
| 8 | `pg-too-large` | a reply larger than the pool's slab |
| 9 | `pg-statement-refused` | the server refused a statement of the pool's script |
| 10 | `pg-protocol` | not the protocol |
| 11 | `pg-fatal` | the server ended the session (FATAL) |
| 12 | `pg-timeout` | no answer within the request timeout |
| **13** | `pg-ssl-not-offered` | `verify-full` was asked for and the server answered `N` |
| **14** | `pg-ssl-bad-answer` | the answer to SSLRequest was not one byte `S` or `N` (an ErrorResponse, another byte, bytes after it) |
| **15** | `pg-ssl-failed` | the TLS handshake or a record failed; the engine's code says why, and its tag is the one to show |
| **16** | `pg-ssl-setup` | TLS could not start: a mode that is not offered, no entropy, a trust store with no root, a server name empty or over 255 bytes |
| 20 | `pg-connect-failed` | the pool's dial failed |
| 21 | `pg-attempt-timeout` | the pool's attempt ran out of time |

`examples/psql_tls.ls` prints `ERROR <tag>` and exits with the status, so a test asserts the reason, not only that it failed:
`ERROR x509-name-mismatch` for a wrong name, `ERROR x509-unknown-issuer` for a trust store that does not hold the server's root.

## 9. Costs, and what is not done

**Authority.** No `Ffi` and nothing foreign: `lex-sys authority` of a program that uses `pg.ssl` or a secure `pg.pool` is what it was, plus
`fs_read` of the CA file the program reads. The report must stay `bounded`. A test runs `lex-sys authority` on two programs, the blocking
example and the narrowed pool program, and asserts it.

**Memory.** Per TLS connection the engine's slot, about 184 KiB once used, and in the pool 24 KiB of buffers per lane (the ciphertext
waiting for the kernel, and a read). The roots: what the bundle's DER takes. A plain pool or a `disable` link: an engine of one slot that is
never written (address space only, section 3). Measured in section 11.

**Time.** A full TLS 1.3 handshake on every connection (no resumption: the server issues no tickets, section 2). `lexsys-hooks` measured the
engine's full handshake at about 2.9 ms of CPU on its machine against 0.3 to 0.6 ms for OpenSSL. For a database that is paid once per
connection, not per query; the pool reconnects rarely. Section 11 measures what opening a TLS connection to PostgreSQL costs against a plain one.

**The compiler pin.** The engine needs a lex-sys with `packages/tls` and the crypto it uses: `e59db18` or later. CI's `LEX_SYS_REV` moves to
`653bdd1` (main when this was written), and the two stores are republished with it and checked as CI checks them. *Checked before any
code changed:* republished with `653bdd1`, both stores are byte for byte the committed ones, so the move by itself changes nothing a consumer
has locked.

**Packages.** A `lex-sys.toml` pins the compiler and the `tls` dependency (`packages/tls/.lex-sys-vcs/tls` at the same revision, which brings
`x509` with it through the store's requirements), and `lex-sys install` puts the sources in `build/deps`. The pool's store requires `tls` by
a lock with an origin, so a consumer of `pg.pool` gets `tls` fetched with it; `pg.ssl` is a third store, `.lex-sys-vcs-ssl`, requiring `pg` and
`tls`; `pg` requires nothing new. **What that costs a consumer of the pool that never uses TLS**: the compiler pin above, the build time of the
nine modules, and the module name `tls` in its program, which `lexsys-hooks`' OpenSSL build already uses for its own module (section 12,
question 1).

**Not done, on purpose or because the engine cannot:** `require`, `verify-ca`, `prefer`, `allow` (section 4); direct TLS (no ALPN); client
certificates; certificate revocation lists (`sslcrl`); session resumption (the server issues no tickets); channel binding
(`SCRAM-SHA-256-PLUS`, which needs the server certificate's hash from the engine: a later step, and with `verify-full` it adds protection only
against a mis-issuing CA); the pooler (`pooler/`) does not speak TLS to its clients or to its server; `pgen` writes no `Link` variants of its
functions (`ssl.request` takes what `<name>_start` builds).

## 10. Tests, and the gates, decided before the numbers

**The server.** `tests/postgres.sh` starts `postgres:16` with `ssl=on` and a certificate from a test CA that `tests/tls_certs.sh` makes
with `openssl` on every run (ECDSA P-256, two days, names `localhost`, `pg.test` and `127.0.0.1`, plus a second CA that issued nothing). Its
`pg_hba.conf` gains a `hostssl` role that is refused without TLS and a `hostnossl` role that is refused with it. A second server, `ssl=off`,
answers `N`. Every existing suite runs against the TLS-enabled server with `disable`, unchanged. CI generates the certificates in the job.

**`tests/tls_test.py`**, against those servers and against mock servers (Python), with the blocking example and a pool driver:

1. `verify-full` by IP literal and by name: connect, log in (trust, cleartext and SCRAM roles), query; `pg_stat_ssl` says the session is TLS.
2. A wrong name: `ERROR x509-name-mismatch`, status 15, nothing sent after the handshake.
3. A trust store of the other CA: `ERROR x509-unknown-issuer`.
4. The `ssl=off` server: `verify-full` refused (`pg-ssl-not-offered`, 13); `disable` logs in and queries.
5. `pg_hba.conf` both ways: the `hostssl` role refused over `disable` with the server's `28000`, accepted over `verify-full`; the `hostnossl`
   role the other way round.
6. Mocks: `S` followed by bytes in the same packet (14, the CVE shape), an ErrorResponse instead of `S`/`N` (14), a garbage byte (14), a
   server that closes after `S` (15, `tls-peer-closed`), one that answers `S` and then sends a ClientHello-sized garbage (15).
7. The pool over TLS: 8 lanes on one engine, 2,000 requests, every answer right; a `pg_terminate_backend` of every backend, all replaced over TLS;
   **the server restarted** (`docker restart`, the test's own container) with requests in flight, the pool back and answering; a wrong name and
   an unknown CA: never live, `last_failure` 15 with the engine's code, retried at the backoff; the `ssl=off` server: 13 at the backoff; the
   plaintext the engine holds when the slab is full is delivered (a reply larger than one read, with answers taken late).
8. `lex-sys authority` of the TLS example and of a narrowed pool program: no `ffi`, `bounded`.
9. Unit tests (no server): `pg.sslmode`, `pg.status_tag` of every status, the SSLRequest bytes, the answer rules, and the pool's refusal of
   `secure` after `start` and of `add` on a secure pool.

**Mutants** of the new negotiation code (`tests/mutants.py`, extended): the bytes after `S` accepted; `N` accepted under `verify-full`; the
engine's failure not kept; the name ignored (the address used); a lane's slot not dropped when it fails; the held plaintext never drained;
`status 15` not `lost`; the handshake started before the answer is read; the pool's wall clock off by the offset's sign; `add` accepted on a
secure pool. Each must fail a test.

**The gates**, which the work must meet to be called done:

1. Every check CI runs passes: the unit suites, `lex-sys fmt --check`, the end-to-end suites (with `disable`, unchanged and against the
   TLS-enabled server), the pooler suites, the three store checks.
2. Every test of the list above passes, in CI's shape, and the TLS tests are in CI.
3. The authority reports of the two programs are `bounded` with no `ffi`.
4. Every mutant is killed, or the reason it survives is written here.
5. The cost of opening a TLS connection is measured against a plain one (CPU and wall time, the median of many) and stated, whatever it is.
6. The loop of a secure pool is not held by the handshake for longer than the pool's existing bound (`reconnect_test.py`'s 50 ms
   gross bound) on the test machine.

## 11. What was built, and what it measured

*(Filled in when it is.)*

## 12. Open questions, each with a proposed answer

1. **The module name `tls` in every program that uses the pool.** `lexsys-hooks`' default (OpenSSL) build has its own module `tls`, and
   lex-sys has one namespace of modules per program, so taking this pool there collides. *Proposed:* hooks renames its OpenSSL module
   (`ossl`) when it moves its pin to this pool; that module is on its way out (its `docs/pure-tls.md`), and two stores of the pool, one
   with TLS and one without, would be a copy to keep in step for a module that will be deleted.
2. **`verify-ca`.** *Proposed:* not until a program asks. It needs a public, name-free entry in `packages/x509` (lex-sys work), and it is the
   weaker check: any certificate the CA issued is accepted for any server. A private CA per database (the usual reason for `verify-ca`)
   is served as well by `verify-full` with the name the certificate carries (section 4: the name is not the address).
3. **Direct TLS (PostgreSQL 17).** *Proposed:* not now; it needs ALPN in the engine, which is a lex-sys change (a ClientHello extension and a
   check of the server's answer). It saves one round trip per connection, and a pool connects rarely.
4. **The wall clock of the pool.** *Proposed:* the offset taken at `secure` (and `pool.wall` to move it), rather than a new argument to
   `tick`, which every caller would have to change. A certificate's dates are checked to the second; the drift of a monotonic clock over
   the life of a service is seconds, and a host whose clock is stepped by hours has other problems.
5. **The engine is not independently reviewed (lex-sys #209).** *Proposed:* ship it, documented as such in the README beside the feature,
   and let `lexsys-hooks` decide whether its database connection uses it before #209 closes. An unencrypted connection to a remote database
   is worse than an encrypted one by an unreviewed client; the choice is the deployment's, and `disable` stays the default.
6. **Channel binding.** *Proposed:* after this, as its own step: it needs `tls-server-end-point` (a hash of the server's certificate) from the
   engine, which is a small lex-sys addition, and SCRAM's `p=tls-server-end-point` in `pg`.
