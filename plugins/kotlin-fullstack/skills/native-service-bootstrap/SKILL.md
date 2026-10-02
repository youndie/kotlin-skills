---
name: native-service-bootstrap
description: "Stand up a NEW Kotlin/Native service (Ktor CIO + sqlx4k/SQLite + Helm) from nothing to a deployed image: targets and entry point, config through expect/actual, migrations and the SQLite pool, DI, ordered shutdown and probes through kore, the two allocators that decide whether it survives its container limit, WAL truncation, the runtime image, the chart, CI with a ~/.konan cache. Mechanisms live in sborka's Gradle conventions and in kore; this skill says which to apply and what each was measured to buy. Use for 'bootstrap a new service', 'new Ktor service on Kotlin/Native', 'put the native binary in an image', 'the service is OOM-killed under its limit', 'the WAL keeps growing', 'adopt kore', 'заведи новый сервис', 'подними сервер с нуля', 'сервис убивает OOM под лимитом'. Not for a feature inside a service that already runs — that is ktor-server-feature."
---

# A new Kotlin/Native service: from nothing to a deployed image

This skill is about the **skeleton**, not about features. A feature inside a service that already
runs is [`ktor-server-feature`](../ktor-server-feature/SKILL.md). Tests are
[`kmp-testing`](../kmp-testing/SKILL.md). The documentation tree a service starts with is
[`product-brief`](../product-brief/SKILL.md), which writes for
[docs-bootstrap](https://github.com/youndie/docs-bootstrap).

The material comes from services taken to production — [katcher](https://github.com/youndie/katcher),
[metrik](https://github.com/youndie/metrik), tracy — and every number was measured on a running
service, not estimated.
Whatever a Gradle convention or a library can enforce lives there — `sborka.native-service`,
`sborka.kmp`, `kore` — and not here. **This file describes and measures; the convention compels**;
where the two disagree, the convention is right and the paragraph is stale. Most of the value is the
**"Gotchas already paid for" section**: each cost between a day and months of silent breakage.

## Step 0. Start from keel, not from the template in this file

```bash
git clone https://github.com/youndie/keel <name> && cd <name>
```

Then rename, and renaming is genuinely all of it: the package, the `sborka.group`, the config prefix,
`nativeService { entryPoint; baseName }`, `rootProject.name`. Measured on the first service built this
way — a webhook relay — that came to **249 lines across 32 files, every one of them a substitution**,
against 178 lines of the service's own domain. No file under `Dockerfile`, `Makefile`,
`settings.gradle.kts`, `gradle.properties`, `.github/` or `scripts/` had to change at all.

[keel](https://github.com/youndie/keel) is a template repository: two targets that both run, a store
that works on both, an ordered shutdown, three probes, `/version`, an image, and a documentation tree
that passes its own gate. **Clone to both halves answering `/health/ready` is 3 min 48 s** on a
machine that has never seen the portfolio, 82 % of it the build, nearly all of that the toolchain. It replaces
"copy metrik or katcher" because those carry a domain, and copying one starts by deleting things you
do not understand. They are still worth opening for a different question: their idioms are newer,
and where one disagrees with keel the living service is usually right. Copy *structure* from keel;
copy *style* from metrik or katcher.

Check that the task really is a new service: if a `:server` module already exists and a route has to
be added, that is `ktor-server-feature`, not this skill.

### What keel does not decide for you

* **outbound TLS.** keel makes no outbound calls. `ktor-client-cio`, the obvious client beside
  `ktor-server-cio`, **has no TLS on Kotlin/Native**: it compiles, links and resolves, and the first
  `https` request fails at runtime. Outbound TLS means `ktor-client-curl`, which links libcurl — so it
  changes the runtime image and leaves sborka's `scratch` recipe. Decide it when the service is
  created, not when the first call fails;
* **a chart.** keel ships none: a chart is a decision about a cluster, and step 8 is where it belongs.

## Where this skill ends

**The moment `/health` answers from the image, the skeleton is done.** Everything after it is
features, built by `ktor-server-feature`. On a greenfield the two grow together, and that is where it
failed: in tracy, milestones M2–M6 were done as "still bringing the service up", the feature skill was
never opened, and the server shipped without DI, without `@Resource`, and with a documented `cursor`
parameter the code did not have. The rule: **the second endpoint in a service is already a feature.**

## The order, and why this one

Every step ends in a **checkable fact**, not in "it is written". The order is chosen so that the
toolchain and the deployment break before any code is built on top of them.

### 1. The Gradle skeleton: targets and entryPoint

```kotlin
plugins {
    alias(libs.plugins.kotlinMultiplatform)
    id("io.github.youndie.sborka.native-service")
}

// BEFORE THE TARGET IS DECLARED, and this is not style. The convention configures
// `binaries.executable` from inside `targets.withType(...).configureEach`, so it reads `entryPoint`
// the moment `linuxX64()` declares a binary. A block further down the file is a value set after it
// was read, and the build fails with "property entryPoint has no value available", naming neither
// the ordering nor this place.
nativeService {
    entryPoint = "ru.workinprogress.<name>.server.main"
    baseName = "<name>"
}

kotlin {
    jvm()                       // development and tests only; the native binary is what ships
    jvmToolchain(21)
    macosArm64(); linuxX64(); linuxArm64()
}
```

**The executable itself is not configured here, and that is the point.** `sborka.native-service`
owns `binaries.executable` — the entry point, the binary's name, a stable path to it, and the
allocator page size that decides whether the service survives its container limit. `macosArm64` is
there so tests run on the developer's machine; `linuxX64`/`linuxArm64` are what goes into the image.
`jvm()` gives a fast test cycle for common code — but **there is only one real target, the native
one**, and a green `jvmTest` proves nothing about production.

**`fixedBlockPageSize=16` is set by the convention, and `MALLOC_ARENA_MAX=2` rides in the reference
image.** Two allocators sit under a Kotlin/Native service — the runtime's per-thread page cache and
glibc's arenas — and on this platform resident memory follows the **thread count**, not the live
heap. That is why a service dies at a limit its heap is nowhere near. Three shapes decide otherwise,
each measured:

* **a heap of gigabytes on a few threads** — 16 KiB pages multiply the pages the collector walks with
  the world stopped, the pause grows tenfold for 1 % of memory saved, and the service sets
  `nativeService { allocatorPageSize = 256 }` (with many allocating threads 256 costs more than it
  saves, and the choice is measured);
* **a limit no paged arm survived** — on xyk at 64 MiB, `-Xallocator=std` lived ten rounds in ten
  where 16 KiB pages lived once; its named replacement `-Xbinary=pagedAllocator=false` lived five in
  five, peaking at the limit, and costs **+19 % CPU per request** (paired, ±2.3 %). The convention
  does not offer it; a service that needs it sets it itself, with the measurement beside the line;
* **`MALLOC_ARENA_MAX=2` with the system allocator** — with `-Xallocator=std` it multiplied peak RSS
  tenfold and OOM-killed three runs of ten; on the replacement flag it has not been measured.

The numbers, the two-sided page-size table, and how to measure your own service — including reading
the peak from the cgroup rather than from `VmHWM` — are
[references/memory-under-a-limit.md](references/memory-under-a-limit.md). Read it before changing
either number; do not read it to decide whether to add a line, because the lines are already there.

**And the process can read its own limit now.** kore's `containerMemoryBudget()` answers with the
cgroup's number (`Bounded` / `Unbounded` / `Unavailable` — an unreadable cgroup is not an absent
limit), and `--print-config` prints it. The ceiling to act on it with is `GC.maxHeapBytes` via
`applyHeapCeiling()`, **not** `targetHeapBytes`, which autotune rewrites after a collection.
Nothing sets it for you: the fraction is your measurement.

What else the conventions enforce rather than recommend — `--as-needed`, `stageNativeImage`, the
`needed.txt` report, `writeNativeDockerfile`, the size budget — what they deliberately leave out,
and which living services still configure the executable by hand (katcher, metrik; keel applies
the convention): [references/sborka-conventions.md](references/sborka-conventions.md).

### 2. `ServerConfig` through `expect/actual` — and dying on an empty required value

Kotlin/Native has no `System.getenv`, so reading the environment is `expect fun readEnv(name:
String)` with an `actual` in `jvmMain`/`nativeMain`. Required values are checked in `fromEnv()`:

```kotlin
require(ingestKey.isNotBlank()) { "TRACY_INGEST_KEY is required" }
```

**Failing on purpose is a feature**: a data sink that quietly started without its key looks healthy.

### 3. `/health` and the first link — proof of the toolchain

Before any business logic: build the native binary and make sure it links, starts and answers. It is
the only way to check that cross-compilation is configured, that Ktor CIO comes up on native and that
the config is read. The fact to check: `./gradlew :server:linkReleaseExecutableMacosArm64` → run the
`.kexe` → `curl /health` → 200, and with a required variable missing the process dies.

### 4. The database and migrations — before the engine starts

There is no migration framework. A list of SQL statements plus `PRAGMA user_version`, run inside
`runBlocking { }` **before** `embeddedServer(...).start()`: a server that opened its port ahead of a
ready schema would answer the first requests with errors. The database file and its directory are
created by hand through okio — the volume in the cluster is mounted empty. The models are
`metrik/server/.../Application.kt:openDatabase` and `katcher/server/.../db/Migrate.kt`.

**Do not call your own migration function `migrate()`.** sqlx4k's driver interface already has a
member of that name, so an extension `suspend fun ISQLite.migrate()` is outranked by it: `db.migrate()`
compiles, runs the driver's own, creates nothing, throws nothing, and leaves `user_version` at 0.
Name it `migrateSchema()`, and assert `PRAGMA user_version` after the call rather than trusting that
it ran — **an extension on a third-party interface is silently outranked by a member of the same
name**, and the failure is a no-op, not an error.

**The pool is two connections, not ten.** Every sqlx4k connection is its own worker thread with its
own page cache and malloc arena, and — the expensive part — **every connection is one more reader**,
while SQLite's automatic checkpoint is PASSIVE and never resets the journal under a live reader.
Measured in tracy (500 writes/s, a read on every tenth): ten connections were killed under both
256Mi and 128Mi; two went twice as far on a third of the memory. **Whatever the pool size, set a
busy timeout** — one driver without it shed 48.7 % of requests under load while passing a
one-at-a-time parity gate. **If readers overlap, truncate the journal yourself** (`TRUNCATE`, not
`RESTART`; on a timer and on size) and expose its size, because `page_count * page_size` does not
count it. **And a `PRAGMA` sent through the pool reaches one connection out of N.** The numbers, the
symptoms (the `-wal` file and the readiness probe, not an OOM) and the probes:
[references/sqlite-under-load.md](references/sqlite-under-load.md).

### 5. DI — wire it immediately, and Koin by default

Koin 4.2 is multiplatform and `koin-ktor` is published with `linuxx64`; what leaves `commonMain` on a
native build, and what replaces it, is `ktor-server-feature`'s **Kotlin/Native** bullet. What matters
here: **wire DI on the very first repository, not "once there is a third".** In tracy,
`ktor-server-di` made it into the dependencies and was never wired; by the sixth milestone `module()`
threaded five repositories through parameters. Each next repository is cheaper to append to the list
than to introduce a container for, so the moment never arrives.

**Wire it with kore's `installKoreKoin { modules(…) }` (module `kore-koin`, kore 0.1.12 or later),
not with `install(Koin)`.** koin-ktor's plugin opens a Koin scope for every call. On Kotlin/Native
each scope owns a stately `Lock`, which on Linux is a `pthread_mutex_t` in a cinterop `Arena` that
nothing ever frees, so every request — a 404 and a readiness probe included — leaves 16 + 48 bytes of
malloc behind for good: 154 MB of tracy's 176 MB resident set after four days, with every allocator
recipe applied. Apple targets and the JVM do not leak, so nothing outside a Linux pod shows it.
`installKoreKoin` sets the same container `get`/`inject` already look in, closes it after the engine
stops, and refuses to run next to the plugin; what it gives up is `call.scope` — a service that needs
it keeps the plugin and the leak, and says so in its own docs. How to see the leak,
because RSS will not:
[references/memory-under-a-limit.md](references/memory-under-a-limit.md#a-leak-rss-cannot-show-koin-ktors-scope-per-call).

### 6. The lifecycle: kore, not `ApplicationStopping`

Shutdown order, three probes and `/version` are written by every service itself, and every service
quietly breaks one of the three. They exist as a library: [kore](https://github.com/youndie/kore) —
`io.github.youndie:kore-core`, `kore-ktor` and the Gradle plugin `io.github.youndie.kore.build`,
resolved from a private Maven repository under `io.github.youndie`, not on Central yet. **Take 0.1.9
or later**: each release from 0.1.6 to 0.1.9 fixed something the wiring below relies on.

**Why not by hand.** `EmbeddedServer.stop` runs its steps in the **opposite order** on Kotlin/Native
and on the JVM. So `ApplicationStopping` — where every example closes the pool and the broker
connection — runs on native **before** the engine drains and on the JVM after, from one and the same
source, and nothing reports this. In katcher a report queue hung there: `SIGTERM` cancelled the
processing of reports already accepted with `202` while the engine kept accepting new ones.

```kotlin
fun main() {
    val config = getServerConfig()
    val db = initDb(config)                     // migrations here, before the engine
    val probes = Probes(db)                     // startup / readiness / liveness + HealthRegistry

    val draining = DrainGate()                  // what the refusal reads; NOT readiness

    val server = embeddedServer(CIO, configure = {
        connectors.add(EngineConnectorBuilder().apply { port = PORT; host = HOST })
        shutdownGracePeriod = DEADLINES.drain.inWholeMilliseconds
        shutdownTimeout = (DEADLINES.drain + 5.seconds).inWholeMilliseconds
        reuseAddress = true                     // CIO's default is false, and native applies it
    }) { module(db, config, probes, draining) }

    server.startForKore()                       // NOT start(): not wait = true, and not wait = false
    probes.start(CoroutineScope(SupervisorJob() + Dispatchers.Default))
    probes.startup.markStarted()

    runBlocking {
        runUntilSignal(DEADLINES, onFinished = { println(it.transcript) }) {
            announce(AnnounceNotReady(probes.readiness))
            drain(EngineDrain(server, DEADLINES.drain, DEADLINES.drain + 5.seconds, draining))
            consumer(queueParticipant(queue))   // finish reading what was accepted
            pool(databaseParticipant(db))       // and only then close the pool
        }
    }
}
```

In the module, three lines — and their order matters too:

```kotlin
installShutdownRefusal(draining)                  // BEFORE the routes; the same gate as EngineDrain
installKoreProbes(probes.startup, probes.readiness, probes.liveness)
installKoreVersion(KoreBuildIdentity)
```

Nine things this code does not show, each of which has already cost somebody time — why each one is
there, with the kore issue behind it, is [references/kore-wiring.md](references/kore-wiring.md):

* `startForKore()`, not `start()` — either `wait` value loses the sequence, differently per target;
* the refusal reads a `DrainGate`, never readiness — or it refuses what the announce waits for;
* `reuseAddress = true` and `requireListenable` — a busy port on native is a `SIGABRT`;
* the database opens in `main`, before the engine — or its close falls to `ApplicationStopping`;
* nobody calls `HealthRegistry.start(scope)` for you — readiness stays `UNKNOWN` forever;
* the deadlines and the chart's `terminationGracePeriodSeconds` are one number in two places;
* participants of one stage run **concurrently** — an order between resources is a later stage;
* `cancel()` is "told to stop" — `cancelAndJoin`, and `stopAndJoin()` on `HealthRegistry`;
* `/version` is generated source — `unknown` without `.git`, `-dirty` behind `.dockerignore`.

The fact to check is not "it compiled" but the transcript: `docker stop` on the container must leave
`SIGNAL / ANNOUNCE / DRAIN / RELEASE_CONSUMERS / RELEASE_POOLS / EXIT` in the log, each with the word
`COMPLETED`. **And check what the stages were supposed to accomplish, not only that they ran**: a
participant that throws is recorded as a failure while its stage still reports `COMPLETED`, so pair
the transcript with one fact on disk — for a service with a journal, that the journal was folded away
([references/sqlite-under-load.md](references/sqlite-under-load.md)).

### 7. The Dockerfile: the binary is built **outside**

```dockerfile
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY server/build/bin/linuxX64/releaseExecutable/server.kexe /usr/local/bin/<name>
VOLUME ["/data"]
ENTRYPOINT ["/usr/local/bin/<name>"]
```

* **Building Kotlin/Native inside docker takes tens of minutes.** The binary is built on the runner
  and only copied into the image. A multi-stage build works (~55 MB) but pays 84.3 s of configuration
  and 58.2 s of toolchain download on *every* run; the numbers and the replacement, where
  `docker build` takes one second, are in [references/build-time.md](references/build-time.md).
* **`ca-certificates` — check, do not install from memory.** In `debian:*-slim` they are absent and
  everything outbound over https fails quietly; in `gcr.io/distroless/cc-*` they are already there.
* **No library is copied out of the builder** — `sborka.kmp` links with `-Wl,--as-needed`, which drops
  the `libcrypt.so.1` two Dockerfiles used to drag across. A copied system library couples builder
  and runtime by glibc and fails at exec, not at build:
  [references/scratch-image.md](references/scratch-image.md#the-builderruntime-glibc-pair-and-why-no-library-is-copied).
* **The path to the `.kexe` breaks a Dockerfile moved between repositories** — `linuxX64()` and
  `linuxX64("native")` put it in different places. The convention's `stageNativeImage` puts it at
  `build/native-image/<baseName>`, and `writeNativeDockerfile` writes the reference image once.
* **`VOLUME ["/data"]`** — the database is the only state there is.

**`FROM scratch`** is about **6 MB to pull** below `distroless/cc`, and all of the work. Take
distroless first: one line, about 65 MB, certificates included. If `scratch` is still wanted, the
condition that makes it possible at all (the binary must be linked **inside** the image) and the five
paths that travel beside it — a static binary still `dlopen`s its charset converters — are in
[references/scratch-image.md](references/scratch-image.md).

### 8. The chart: probes, secrets, bypassing middleware

Copy `charts/metrik` or `charts/katcher`. What to check with your own eyes:

* **three probes, not one for all of them.** `/health/startup` is a latch; `/health/ready` is
  dependencies *and* the shutdown latch; `/health/live` (and the `/health` alias) is liveness. A
  readiness probe pointed at `/health` is a probe that cannot fail while the process is alive —
  exactly what kore is taken for. A `startupProbe` with `periodSeconds: 1` and
  `failureThreshold: 60` instead of a long `initialDelaySeconds`;
* **`terminationGracePeriodSeconds` is part of the contract**, not a default: the shutdown plan is
  checked against the number it was *told*, and the chart has to say the same thing;
* **the memory limit comes after a measurement, and with a positive control** — the same image under
  a deliberately small limit must be **killed**, or the harness cannot detect a failure at all. In
  katcher the number went 64Mi → 192Mi ("an unexplained crash") → 128Mi, twice the measured peak.
  How to run that measurement so that it can fail:
  [references/memory-under-a-limit.md](references/memory-under-a-limit.md#running-the-measurement-so-that-it-can-fail);
* secrets through `secretKeyRef`, not as a value in `values.yaml` — nor in `helm history`;
* a PVC for `/data`;
* **machine routes get their own ingress route around the forward-auth middleware.** The proxy
  expects a browser session; an ingest endpoint and an MCP client have none, and the 401 comes from
  the proxy, before the application's own check runs. Create the bypass route **only when a token/key
  is set**, otherwise the bypass appears without the authentication that replaces it.

### 9. CI: the `~/.konan` cache is mandatory, not an optimisation

```yaml
- uses: actions/cache@v4
  with:
    path: ~/.konan
    key: konan-${{ runner.os }}-${{ hashFiles('gradle/libs.versions.toml') }}
    restore-keys: konan-${{ runner.os }}-
```

LLVM and the sysroots weigh hundreds of megabytes, and the key follows `libs.versions.toml` because a
Kotlin bump must invalidate it. If the setup action already caches `~/.konan`, do not add this block —
two entries restore one directory twice. `macosArm64` on a linux runner is silenced with
`kotlin.native.ignoreDisabledTargets`.

## Build time

A service that takes three minutes to build is a service nobody rebuilds to check something. What a
fresh machine needs, the one `gradle.properties` line worth adding, why the image is assembled outside
`docker build`, the caches that paid and the ones that did not, the Gradle daemon you are actually
measuring, and how to measure your own before/after:
[references/build-time.md](references/build-time.md).

## Gotchas already paid for

Not "possible problems" but things found by a run and a deploy. The § references are to the metrik
research (`docs/research/research-architecture.md` in [metrik](https://github.com/youndie/metrik)).

| Gotcha | Symptom | What to do |
|---|---|---|
| **`SelectorManager` occupies a `Dispatchers.Default` worker forever** (§1.5) | on a 2-core pod `delay` stops firing **across the whole process**; looks like two unrelated failures | put the selector loop on its own thread: `SelectorManager(newSingleThreadContext(...))`. It does not reproduce on a developer machine with 5 cores, and `--cpuset-cpus` does not help either |
| **A domain name does not resolve** (§1.6) | `connect` fails with `EINVAL`; the same code works on the JVM | resolve it yourself through `getaddrinfo`, **on every connection** (a pod's address changes when it moves). A ready `HostResolver.native.kt` is in metrik |
| **`HttpClient(CIO)` cannot do TLS** (§1.7) | `TLS sessions are not supported on Native platform`; anything https stays silent | `ktor-client-curl` on native targets through `expect/actual`. The klib carries static `libcurl.a`/`libssl.a`/`libcrypto.a` — neither headers on the build machine nor `libcurl4` in the image are needed; `ca-certificates` are |
| **`ktor-server-compression` is JVM-only** (§1.8) | the plugin does not resolve on native | compress ahead of time, while building the image: a `.gz` next to the file |
| **`respondSource` holds the whole body in memory** (§1.8) | 20 parallel bundle downloads → 232 MB against a 256 MB pod limit, OOMKill | an explicit 64 KB loop through `respondBytesWriter` — the peak drops to 157 MB |
| **`ktor-server-call-logging` is not published for native** | the plugin does not resolve; `callIdMdc` is unavailable | `ktor-server-call-id` is published and covers half the job; write the request log yourself |
| **`Dispatchers.IO` on Kotlin/Native is an extension property** | `Cannot access 'val IO': it is internal in 'kotlinx.coroutines.Dispatchers'`, read as "native has no IO dispatcher" | add `import kotlinx.coroutines.IO`; it exists and works on `linuxX64` and `macosArm64` ([kore B-42](https://github.com/youndie/kore/blob/main/docs/backlog/B-42-dispatchers-io-exists-on-native.md)) — no private thread needed |
| **`TimeZone.currentSystemDefault()` is not cached on Kotlin/Native** (katcher [#78](https://github.com/youndie/katcher/issues/78), [#79](https://github.com/youndie/katcher/issues/79)) | nothing fails; the JVM caches the zone, so a JVM build will not show it | 33 µs a call against 73 ns for `Clock.System.now()`. Resolve it once into a `val` and pass it: `now().toLocalDateTime(zone)` went 37.6 µs → 277 ns. Count the calls per unit of work, not per file — one row of katcher's error list crossed the lookup three times |
| **Kotlin/Native forbids commas in backticked test names** | `jvmTest` is green, the native test compilation fails in CI | rename it; the grep is in `kotlin-conventions`' review greps — run it on `commonTest` before pushing |
| **A PASSIVE SQLite checkpoint does not reset the journal while readers are alive** (tracy M-137) | `-wal` grows linearly, the database file stops growing, half an hour later an OOM on a small heap | a 2-connection pool plus your own `wal_checkpoint(TRUNCATE)` on a timer and on size; `walBytes` in the size response |
| **koin-ktor's `install(Koin)` leaks a native mutex on every request** (kore B-65) | resident memory climbs for days with no load to speak of; RSS over minutes shows nothing | `installKoreKoin { … }` from `kore-koin` (step 5). Check by counting malloc chunks, not RSS |
| **glibc gives malloc an arena per thread, counting host cores** | resident memory follows the thread count; `smaps` shows a dozen anonymous mappings of 6–12 MB on 64 MB boundaries | `MALLOC_ARENA_MAX=2` in the reference Dockerfile — **only after an A/B on your own service**: without a database it did nothing, and with the system allocator it multiplied peak RSS by ten (step 1) |
| **`pagedAllocator=false` buys the memory with CPU** (xyk, pgo-native-spike) | survives a limit the paged arms do not, at +19 % CPU per request | take it only for a limit nothing else survives, measured; spell it `-Xbinary=pagedAllocator=false`, not the deprecated `-Xallocator=std` (step 1) |
| **`PRAGMA synchronous` reaches one connection out of the pool** | "write throughput differs by a multiple" is true for 1/N of the commits | a probe of N concurrent transactions; the only fixes are warming every connection or a knob upstream |
| **A static glibc is not self-contained: `iconv` loads its converters with `dlopen`** (step 7) | an image on `scratch` serves static files and `401`, then 500 on the first rendered page: `Failed to open iconv for charset UTF-8 with error code 22` | copy the loader, `libc.so.6`, `ld.so.cache` and the **whole** gconv directory, out of the build stage: [references/scratch-image.md](references/scratch-image.md) |
| **`unable to find library -lc` on a static link** | reads like a linker-flag problem | `gradle:*-noble` carries no static archives — one `g++` install supplies them; the gcc version and `libGcc.linux_x64=…/13` move together |

## What only a deployment checks

The class of bugs "works locally, breaks in the cluster" **exists here and is not covered by tests**:

* the `Host` check in the MCP transport: by default only localhost is allowed, and locally the Host
  is always localhost — the test that should have caught this is impossible in principle;
* forward-auth in front of machine routes (step 8);
* a global `StatusPages` with a redirect to `/login`: right for a browser, but a machine client gets
  a login page instead of an error code. Redirect only for `Accept: text/html`.

**Deploy earlier than feels necessary.** In katcher the deploy found two endpoint-breaking failures
under 64 green tests.

## What not to do

* **Do not build Kotlin/Native inside docker** — minutes turn into tens of minutes.
* **Do not drag in nginx for static files.** Native Ktor serves them itself: `SystemFileSystem`
  (kotlinx-io) + `respondBytesWriter` + `ContentType.defaultForFilePath`. There is nowhere to get
  `Last-Modified` from — compute an ETag from the content once at startup.
* **Do not rely on a fake where the component swallows its own errors.** A sender, a receiver, a
  notifier must have a test against a real socket and a "send a test one" handle that returns the
  fact of delivery, not the intent. In metrik two such components stayed silent in production for
  months with green tests.
* **Do not put off `LICENSE`.** One file, before the first image is published.

Example: [examples/deploy.md](examples/deploy.md) — the Dockerfile with pre-compressed static files,
the publish workflow, the key pieces of the chart.
