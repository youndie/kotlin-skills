# A JVM service on PostgreSQL: the pool, migrations, tests, replicas

Referenced from [SKILL.md](../SKILL.md), "Storage". The rest of the skill is written from a server
compiled twice over a document store; three public services are JVM-only over PostgreSQL — Exposed
on JDBC, HikariCP, Flyway, Testcontainers — and what they paid for is here:
[haul](https://github.com/youndie/haul), [konekt](https://github.com/youndie/konekt) and
[shashki](https://github.com/youndie/shashki), read on their `main` on 2026-11-12. The `B-NN`
references are items in the named repository's `docs/backlog/`; each records the measurement.

Nothing here is a default to copy without its reason. The timeouts are haul's, measured against
its probe and its saga; the recipe transfers, the numbers are yours to measure.

## The pool

**A request must not wait for a database that is gone.** Hikari's `connectionTimeout` defaults to
30 s, and Exposed's `transaction` runs its block up to three times on any `SQLException` — and
asking the pool for a connection is inside the block. With PostgreSQL stopped, one page of haul
answered its `503` after **96.8 s**, three waits of 30 s; readiness, which asked the pool once,
after 32 s (haul B-127). What fixed it, in the order it matters:

- `connectionTimeout` of a few seconds (haul: 2 s) with `validationTimeout` under it, since
  Hikari's default 5 s would outlast it. This alone leaves three waits per transaction.
- **One failure per outage, not one per query.** Every user of the database reaches the pool
  through a small `DataSource` wrapper: once an ask timed out *because the database could not be
  reached* (the timeout carries the connection failure as its cause), every ask in the next two
  seconds is refused at once with that cause. The retries, the rest of the page and every other
  request in the window fail on the spot. A pool that merely ran out of connections (a timeout
  with no cause) refuses nobody else.
- Rejected, and worth knowing why: `maxAttempts = 1` on Exposed. It would also drop the retry of
  a statement that met a deadlock or a connection that died under it.

Measured after: the first page 96.8 s → 2.09 s, the next 7 ms.

**Readiness answers inside its probe's timeout.** A probe the kubelet stopped waiting for is a
failure all the same, while the check goes on holding a thread and a place in the pool's queue.
Bound it below the probe's timeout (haul: 750 ms against Kubernetes' default second) with
`withTimeoutOrNull` around `runInterruptible(Dispatchers.IO)` — Hikari answers the interrupt with
an `SQLException` — and catch only `SQLException`, so a cancelled probe is still cancelled.
Readiness after the stop went 30.0 s → 0.76 s. Write the probe's `timeoutSeconds` out in the chart
next to a note naming the budget: a default nobody wrote down is a number nobody keeps in step.

**Work that must not be undone by a blip waits; requests still do not.** Failing fast is right
for a page and wrong for a saga step, which compensates an order the shopper meant to place: any
outage between two seconds and the step's own timeout now failed it (haul B-139). Both live on
one pool, so the difference is carried by the *caller*: a coroutine-context element marks saga
work, and the wrapper gives an ask under it no refusal and asks again while the coroutine is
active. It is a `ThreadContextElement`, because the ask is made by blocking JDBC inside
`withContext(Dispatchers.IO)` on whatever thread the coroutine runs. A second pool with a longer
timeout was rejected: a second set of connections against the server's limit, and a timeout per
pool cannot end at a step's own deadline.

**A pool hands back connections the outage already killed.** Hikari does not check a connection
used within the last 500 ms, so after a restart the pool returns connections the shutdown
terminated and each fails at its *first statement* — after the ask, where no patience applies.
Exposed's three tries then run on three dead connections in milliseconds: a placement meant to
ride out five seconds answered `500` eleven milliseconds after the database came back (haul
B-140). Work that waits therefore asks the connection whether it is alive (`isValid`, one round
trip) and evicts a dead one; ordinary requests keep Hikari's own check.

**Count the connections before the chart allows a replica.** Every pool is `maximumPoolSize`
connections per replica, a rolling deploy runs one replica more than the count, and PostgreSQL's
default limit is 100 with three reserved. haul's chart refuses a values file where
`(replicas + 1) × (poolSize + 3)` passes 97, and its check script renders both sides of that
line. A connection held for the life of the process — a `LISTEN`, a leadership — is opened
**outside** the request pool, or the pool counts it as a leak and requests queue behind it.

**Two smaller ones.** `initializationFailTimeout` makes a wrong password a failed start instead
of a healthy pod that cannot serve (konekt). And the pool's configuration has **one reader**: a
`fromEnv()` on the database module had no callers, the application built the three-argument
constructor, and `DB_POOL_SIZE` was a variable that existed in a script and in no running process
(konekt#35).

**In a repository**, the port is `suspend` and the blocking is hidden in one private helper —
`withContext(Dispatchers.IO) { transaction(database) { block() } }` — so no method can forget the
dispatcher, and the owner (tenant, customer, guest) is in every `where`, never an id a request
carries: "not yours" then has nothing to match.

## Migrations

**The schema is current before anything serves.** Two shapes do this, and both are in use: `main`
migrates before the engine starts (haul — Flyway takes PostgreSQL's advisory lock itself, so a
second replica starting during a rollout waits instead of migrating twice), or a migrate-only
entry point runs in an init container and the application never migrates (konekt). What is not
done is migrating after the port is open. Either way: `validateOnMigrate(true)`, so a pod refuses
a schema migrated by a later version rather than serving against one it does not understand;
`cleanDisabled(true)`; and no `baselineOnMigrate`, which turns "this database has tables I did
not create" into "assume everything before now is fine".

**A migration that has run is immutable, and its comments are part of it.** Flyway records a
checksum per applied version and refuses to start when the file behind it changed. A comment in
an applied migration was corrected — no SQL touched — and the next release could not start: the
init container crash-looped, the deployment never became available, and Helm rolled back on a
ten-minute timeout with a message about readiness. Nothing in that chain says "you edited a
migration" (konekt). The check moved to where the edit happens: a committed file of checksums,
one line per migration, and a test that fails on a changed number. Two details keep it honest.
It is **not a golden to regenerate** — its failure names the consequence (`flyway repair` on
every environment that ran the version), not the file to update. And a second test runs the real
Flyway against a real PostgreSQL and compares what it wrote into `flyway_schema_history` with the
file: a guard that checks its own arithmetic against its own arithmetic agrees with itself
whatever Flyway does.

**During a rolling deploy both versions of the code run against one schema.** So a migration is
judged by whether the code *already running* survives it, which staging — where one process is
replaced at once — cannot show. Anything that takes something away (`DROP COLUMN`, `RENAME`,
`ALTER … TYPE`) is the second half of an expand-and-contract pair, and a gate over the migration
files refuses it without a marker naming the migration that expanded. This is exactly the set a
schema-diff generator emits: Exposed's `generateMigrations` writes the *shortest* SQL that makes
two schemas equal, and a draft that looks finished is what makes a reviewer agree with it.

**Drafts from the generator are renumbered by hand, and a test notices when they are not.** It
names a file by a version stamped to the second, so a run touching several tables writes several
files under one name: they overwrite each other and a table goes missing silently
(JetBrains/Exposed#2897). Where nothing is lost, Flyway refuses the duplicate version — at
deploy time. The test reads the *directory*, not the classpath, and passes on an empty one, so it
first asserts it found files.

**An index on a live table needs two settings, and missing the second is a hang.**
`CREATE INDEX CONCURRENTLY` cannot run in a transaction: the migration opts out with a
`V<n>__<name>.sql.conf` carrying `executeInTransaction=false`. That alone deadlocks on
PostgreSQL, because Flyway's own lock is transactional and waits on the index build that is
waiting on it; set `flyway.postgresql.transactional.lock=false` once, in the configuration, not
per script (flyway/flyway#3840). During a deploy a deadlock reads as a slow rollout. The test for
the recipe asks PostgreSQL whether a writer queued (`pg_blocking_pids`); the two versions that
compared durations could not tell the arms apart on a two-core runner.

## Tests against a real PostgreSQL

**One container for the suite, a new database for each test that needs one.** `CREATE DATABASE`
inside the running container, then migrate it: the test gets *fresh*, not *truncated*, and pays
milliseconds rather than a container start. Route tests that only read share one seeded
database.

**A test closes the pool it opened, and the harness makes a leak fail where it is.** About
twenty tests each left a pool of four connections open for the rest of the suite; past the
container's hundred, whichever test came next waited out Testcontainers' two-minute retry and
failed on `sorry, too many clients already` — in a test that had nothing wrong (haul B-111). The
harness now refuses to open a ninth database and prints where each open one was opened.

**`testApplication` does not stop the application when its block throws** (Ktor 3.6.0: no
`finally`). A failed assertion left the application running — its workers, its Koin graph —
after the test had closed the database under it. Feature modules declared as top-level `val`s are
shared values whose singles keep what they made until a graph is closed, so the *next* test's
graph was handed the dead test's repository on a closed pool and failed on `HikariPool-N has
been closed` (haul B-140). Wrap `testApplication` once, in the project's harness, so the
application is stopped on failure too; a bare `testApplication` over the real module leaks the
same way.

**An outage test measures the outage it got.** Stop the container under the running module, and
count from the stop being asked for to PostgreSQL accepting a connection, on the runner's clock —
then print that timeline. The test above failed one run in five on the hosted runner and never
on the build box, and the premise that the hosted runner was the slower one was wrong: it
stopped the container in 0.16–0.53 s against 0.5–0.9 s, which put the stop inside Hikari's
500 ms window. A test that has to be retried to pass does not say what it holds; the fix was in
the pool.

**Tests seed what they read.** A seed that grew to its production size took the server suite
from about ten minutes to seventeen (haul B-111). The switch that leaves the bulk out is passed
by test code only, and a start that fills completes a database seeded without it — so no stand
can end up short of its rows, and a test holds that.

## More than one replica

**A worker started in every process runs in every replica.** With two, konekt's outbox relay —
no claim on a row — published twenty rows as forty records, and its traffic simulator spent an
allowance twice as fast (konekt B-135). Decide it per worker, before the chart allows a second
pod:

| The worker | On N replicas |
|---|---|
| claims its work in the database (an optimistic status update, `FOR UPDATE SKIP LOCKED`) | runs everywhere; say so in its KDoc |
| has no claim, or acts on the outside world on a timer | runs on the **leader** only |
| holds state in memory that requests read (a bus, a cache of "who is listening") | the state is shared through the database, or is rightly per replica — list which |

**The leader is elected on the database the service already has** (vojak, on PostgreSQL advisory
locks). The singletons start in the leadership's scope and are cancelled when it is lost, inside
a supervisor scope so one failing worker takes neither the others nor the leadership with it. A
held leadership keeps a connection: give the election its own small pool, or grow the pool by
one. **Stopping closes the election first, while the pool is still open**: the successor then
takes over within a poll (0.18 s), where a killed leader's successor waits out the lease (7.8–9.5
s on haul's stand). And `main` is *always* a shared replica, whatever the count — a leader of one
— so there is one code path; only a test passes "alone".

**An in-memory bus is per replica.** haul's live pages moved to `LISTEN`/`NOTIFY` carrying ids,
not payloads: each replica draws the frame for its own listeners from the rows, so a notification
stays far from its 8,000-byte limit, and a replica drops its own echo by origin. One connection
of its own listens, outside the pool. A broker was rejected as a pod of its own for a durability
the pages do not need: a page that misses a move catches up on its next connection.

**Show it with a kill, and with a control.** haul runs its end-to-end walks against two replicas
behind a front that takes turns, and kills the leader with `SIGKILL` while sagas of both
replicas wait inside a step: every saga completes, no order is lost or doubled. Clients resend a
cut read or a keyed write, so placement carries an idempotency key. Each claim has its mutation:
the image without the bus fails the bus test, work run outside the election fails the leader
tests.

**The election's adapter is a dependency like any other.** `vojak-kore` pins kore through `api`,
and kore pins Ktor the same way: taking it would have moved Ktor under konekt's server — a green
build and an `IrLinkageError` at run time. Read the graph before adding the convenient module
(`kmp-library-release`, "A bump moves the graph, not one line").
