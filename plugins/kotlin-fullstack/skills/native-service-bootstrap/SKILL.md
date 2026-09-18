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

The material comes from two services taken to production:
[katcher](https://github.com/youndie/katcher) and [metrik](https://github.com/youndie/metrik). Steps 1, 6, 7
and 8 were extended on 2026-09-14 from tracy M-137 (the SQLite pool, WAL truncation,
`MALLOC_ARENA_MAX`, the shape of a measurement) and rewritten on 2026-09-14 from the katcher 0.8.0
release — three recipes there (kore, `fixedBlockPageSize`, `FROM scratch`) were taken all the way to
a deploy and measured; their numbers are recorded, not estimated. On 2026-09-15 the mechanisms left:
whatever a Gradle convention or a library can enforce is no longer spelled out here — the allocator
page size, `--as-needed`, the staged binary path and the reference image are `sborka.native-service`
and `sborka.kmp`, ordered shutdown and probes are `kore`, and the static-link recipe is sborka's
research. **This file describes and measures; the convention compels.** Where the two disagree, the
convention is right and the paragraph is stale — which is the whole reason for the split: the next
change to the static recipe ([KT-89362](https://youtrack.jetbrains.com/issue/KT-89362) removes two
of its five property overrides) must not leave an agent applying the old one out of here. The **Build time** section was
added on 2026-09-15 from the katcher build-time study (`docs/research/build-time/` in that
repository): nine questions with their thresholds declared **before** each measurement, three
results that work and still missed their line, one red, and one setting validated on a second
repository. Step 1's `MALLOC_ARENA_MAX`
paragraph gained its counter-example on 2026-09-15, from the Ktor-under-a-container-limit study —
the first measurement here where a recipe from this file made a service **worse**, and the reason the
paragraph now ends in a rule rather than a number. **Step 0 changed on 2026-09-16**: it said "copy
metrik or katcher" and now says "clone [keel](https://github.com/youndie/keel)", because a template
without a domain arrived — and the first service built from it needed no change to any of its
infrastructure files, which is the claim that made the swap worth making rather than the existence of
the repository. Most of the value here is not the templates but the
**"Gotchas already paid for" section**: each of those cost between a day and several months of silent
breakage in production.

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
machine that has never seen the portfolio, of which the build — almost all of it the Kotlin/Native
toolchain — is 82 %. Its image is 13 972 497 bytes.

**This replaces "copy metrik or katcher", and the reason is what a copy costs.** Those two carry a
domain, so copying one starts by deleting things you do not understand, and what you delete is
decided by what you recognise. keel has one entity on purpose and its CI proves it still builds.

They are still worth opening, for a different question: **the idioms there are newer**, and when one
of them disagrees with keel, the living service is usually right and keel is usually behind. Copy
*structure* from keel; copy *style* from metrik or katcher.

Check that the task really is a new service: if a `:server` module already exists and a route has to
be added, that is `ktor-server-feature`, not this skill.

### What keel does not decide for you

Two things it deliberately leaves open, because both are decisions a service makes about itself:

* **outbound TLS.** keel makes no outbound calls, so it ships no HTTP client. `ktor-client-cio` is the
  obvious one to reach for beside `ktor-server-cio` and **it has no TLS on Kotlin/Native** — it
  compiles, links and resolves, and the first `https` request fails at runtime with `TLS sessions are
  not supported on Native platform.` Outbound TLS means `ktor-client-curl`, which links libcurl and so
  changes the runtime image and puts the service outside sborka's `scratch` recipe. Decide it when the
  service is created, not when the first call fails;
* **a chart.** keel ships none: a chart is a decision about a cluster, and step 9 is where it belongs.

## Where this skill ends

**The moment `/health` answers from the image, the skeleton is done.** Everything after that —
ingest, reads, search, background work — is features, and features are built by
`ktor-server-feature`: layers, a repository behind an interface, UseCases, typed `@Resource`.

This is not a formality but the place where the two skills came apart on a live project. In tracy,
milestones M2–M6 were features, but they were done as a continuation of standing the service up —
"we are still bringing up a new service". As a result the feature skill was never opened once,
and the server shipped without layers: repositories exist, but as concrete classes, DI was never
wired, `@Resource` is absent entirely, and the UseCase role is played by `ToolFacade`, which is not
called one.

The cost was not theoretical: the document `endpoint-query.md` promised a `cursor` parameter on
`/api/logs` that the code did not have, and the divergence was found only during a document review
several milestones later. A typed `@Resource` is a contract that **cannot** drift from the document
silently.

On a greenfield the boundary feels blurred, because the feature and the skeleton grow together. The
rule is simple: **the second endpoint in a service is already a feature.**

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
allocator page size that decides whether the service survives its container limit. Everything below
in this step explains what it sets and how to find out whether its numbers are yours; none of it is
a line to copy into a build file.

`macosArm64` is there so tests run on the developer's machine; `linuxX64`/`linuxArm64` are what goes
into the image. `jvm()` is not a luxury: it gives a fast test cycle for common code — but **there is
only one real target, the native one**, and a green `jvmTest` proves nothing about production.

**`fixedBlockPageSize=16` is set by the convention, and `MALLOC_ARENA_MAX=2` rides in the reference
image.** Two allocators sit under a Kotlin/Native service — the runtime's per-thread page cache and
glibc's arenas — and on this platform resident memory follows the **thread count**, not the live
heap. That is why a service dies at a limit its heap is nowhere near.

What the numbers are, why the second one is dangerous to copy (with `-Xallocator=std` it multiplied
peak RSS tenfold and OOM-killed three runs of ten), and how to measure your own service — including
reading the peak from the cgroup rather than from `VmHWM` — is
[references/memory-under-a-limit.md](references/memory-under-a-limit.md). Read it before changing
either number; do not read it to decide whether to add a line, because the lines are already there.

**And the process can read its own limit now.** kore's `containerMemoryBudget()` answers with the
cgroup's number (`Bounded` / `Unbounded` / `Unavailable` — an unreadable cgroup is not an absent
limit), and `--print-config` prints it. The ceiling to act on it with is `GC.maxHeapBytes` via
`applyHeapCeiling()`, **not** `targetHeapBytes`, which autotune rewrites after a collection.
Nothing sets it for you: the fraction is your measurement.

#### What the convention enforces, so that this step is description and not instruction

[sborka](https://github.com/youndie/sborka) carries `io.github.youndie.sborka.native-service` and
`io.github.youndie.sborka.kmp`, and between them they hold every mechanism named in this step. The
conventions are published as snapshots to a private Maven repository and resolve through
`id("io.github.youndie.sborka.settings")`; katcher and metrik already apply it. An outside reader
gets the same value from the reasoning below and from sborka's sources, which are public.

That division is the point of this section. **The convention is where a setting is changed; this
file is where it is explained.** A number written in both places drifts in one of them, and the one
that keeps building is the one that is wrong — so when the two disagree, sborka is right and this
paragraph is stale.

What is enforced, rather than recommended:

* **The allocator page size** — `binaryOption("fixedBlockPageSize", …)`, 16 KiB by default;
  `nativeService.allocatorPageSize` changes it, `0` opts out. A check on the stand reads the option
  back **off the linked binary**, because the obvious version of that check reads `freeCompilerArgs`,
  finds nothing, and goes red on a working build.
* **`MALLOC_ARENA_MAX=2` in the reference Dockerfile**, pinned by a test, with the counter-example
  beside it — so a service switching to `-Xallocator=std` meets the hazard where it is configured
  rather than in a study it never read.
* **`-Wl,--as-needed` on Linux executables** (in `sborka.kmp`: a property of linking on Linux, not of
  being a service). Three `NEEDED` entries nothing calls, gone — and with them the
  `COPY … libcrypt.so.1` line two Dockerfiles carried and the builder/runtime glibc pairing it
  required. Linux only; `ld64` and `lld-link` reject the flag. Measured in
  [research-static-binary](https://github.com/youndie/sborka/blob/main/docs/research/research-static-binary.md)
  §1.3–1.4, taken as D1.
* **`stageNativeImage`** (on `assemble`) puts the release binary at `build/native-image/<baseName>`,
  so a `COPY` does not depend on whether the target was declared `linuxX64()` or `linuxX64("native")`
  — both are live, and a Dockerfile moved between them fails at image build time naming the path and
  not the difference.
* **`<baseName>.needed.txt` and a line in the build log** — what the binary asks the loader for
  (`readelf -d`). Deliberately not a gate: a new dependency must be visible in the log of the build
  that introduced it, not in a container that failed to start.
* **`writeNativeDockerfile`** writes the reference image **once** and refuses to overwrite: base
  image, certificates and glibc are a decision that belongs in a file a person reads.
* **A size budget** — `sborka.binaryBudget=50MiB`. The gate is a separate plugin the *repository*
  applies; the property without it fails the build saying what to add, so a budget nothing measures
  cannot sit there green.

**What is deliberately not in it, with the reason:** the `FROM scratch` static recipe (§7 — sborka's
D3 declines to hand out an option that pins five `konan.properties` keys JetBrains may change in a
patch release) and any choice of targets (four repositories leave out four different targets for four
different reasons, and one convention would delete four arguments rather than one duplication).

**State as of 2026-09-15, so nobody looks for it in vain:** the convention's only consumer is the
`stand/native-service` module inside sborka itself. Neither katcher nor metrik applies it: both
declare `executable { entryPoint = … }` by hand and copy the `.kexe` out of `bin/…` in their
Dockerfile. So **step 0 will hand you the hand-rolled form** — which is not an argument against the
convention, but something to know while reading a living service as the model. Adopting it in a
service that already ships is a migration of its own; standing a new one up is where it is free.

### 2. `ServerConfig` through `expect/actual` — and dying on an empty required value

Kotlin/Native has no `System.getenv`, so reading the environment is `expect fun readEnv(name:
String)` with an `actual` in `jvmMain`/`nativeMain`. Required values are checked in `fromEnv()`:

```kotlin
require(ingestKey.isNotBlank()) { "TRACY_INGEST_KEY is required" }
```

**Failing on purpose is a feature.** An observability service or a data sink that quietly started
without its key is indistinguishable from a healthy one until the first incident. The same principle
applies to an agent living inside somebody else's process.

### 3. `/health` and the first link — proof of the toolchain

Before any business logic: build the native binary and make sure it links, starts and answers. This
is not running ahead; it is the only way to check that cross-compilation is configured, that Ktor
CIO comes up on native and that the config is read. In metrik this landed in M0 beyond the plan and
paid for itself immediately.

The fact to check: `./gradlew :server:linkReleaseExecutableMacosArm64` → run the `.kexe` →
`curl /health` → 200, and with a required variable missing the process dies.

### 4. The database and migrations — before the engine starts

There is no migration framework. A list of SQL statements plus `PRAGMA user_version`, run inside
`runBlocking { }` **before** `embeddedServer(...).start()`: a server that opened its port ahead of a
ready schema would answer the first requests with errors.

The database file and its directory are created by hand through okio (`FileSystem.SYSTEM`) — the
volume in the cluster is mounted empty. The models are
`metrik/server/.../Application.kt:openDatabase` and `katcher/server/.../db/Migrate.kt`.

**Do not call your own migration function `migrate()`.** sqlx4k's driver interface already has a
member of that name, so an extension `suspend fun ISQLite.migrate()` is shadowed by it: `db.migrate()`
compiles, runs the driver's own, creates nothing, throws nothing, and leaves `user_version` at 0. The
service then starts on an empty schema and every route fails on a missing table — with no line
anywhere pointing at the migration. Name it `migrateSchema()`. The general shape of the trap is worth
more than the instance: **an extension function on a third-party interface is silently outranked by a
member of the same name**, and the failure is a no-op rather than an error, so the check is to assert
`PRAGMA user_version` after the call rather than to trust that it ran.

**The pool is two connections, not ten.** The "more is better" default works against the service
twice here. First, every sqlx4k connection is a separate `sqlx-sqlite-worker` thread with its own
page cache and its own malloc arena. Second — and this is the expensive one — **every connection is
one more reader**, and SQLite's automatic checkpoint is only ever PASSIVE: it does not reset the
journal while a single active reader is alive. For a service that is read while it is written, that
window never opens. Measured in tracy (500 writes/s, a read on every tenth): with ten connections
the process is killed under both 256Mi and 128Mi; with two it went twice as far on twice the
database while spending a third of the memory. katcher and shildik arrived at two independently — in
shildik it is written down as the constant `SQLITE_POOL = 2`.

**And whatever the pool size, set a busy timeout.** SQLite has one writer and the second writer gets
`SQLITE_BUSY` *immediately* unless something is told to wait. A driver that gives up instead of
waiting is fast because it is doing less — one twin shed **48.7 % of requests under load** while
passing a parity gate that sent one request at a time.

**If readers overlap, you need your own journal truncation**, on a timer **and** on file size, with
`TRUNCATE` rather than `RESTART`; and the journal has to be visible from outside, because
`page_count * page_size` does not count it. The numbers, the symptom to watch for (it is the `-wal`
file and the readiness probe, not the database file and not an OOM) and the run where the expected
shape did not appear are in
[references/sqlite-under-load.md](references/sqlite-under-load.md).

**Pragmas sent through a pool reach one connection.** `db.execute("PRAGMA ...")` runs on whichever
connection the pool handed out. Only `journal_mode` survives that (it is written into the file
header); `foreign_keys` is saved by sqlx enabling it itself in `after_connect`; but
`synchronous = NORMAL` stays on exactly one connection out of N, and the rest commit with a full
fsync. It is settled by a probe: N concurrent transactions, each running `PRAGMA synchronous;`. The
URL does not fix it — sqlx only knows `mode`, `cache`, `immutable`, `vfs`.

### 5. DI — wire it immediately, and Koin by default

The previous revision said "`ktor-server-di`, not Koin". That is wrong as a rule: Koin 4.2 is
multiplatform, `koin-ktor` is published with `linuxx64`, and services in this portfolio run on it
in production. What leaves `commonMain` on a native build, and what replaces it, is
`ktor-server-feature`'s **Kotlin/Native** bullet and the table it points at.

What matters here is different: **wire DI on the very first repository, not "once there is a
third".** In tracy, `ktor-server-di` made it into the dependencies and was never wired once;
everything was assembled by hand in `Application.kt`, and by the sixth milestone `module()` was
threading five repositories through parameters while the MCP facade took four. The moment when "now
it is time" never arrives: each next repository is cheaper to append to the existing list than to
introduce a container for.

### 6. The lifecycle: kore, not `ApplicationStopping`

Shutdown order, three probes and `/version` are written by every service itself, and every service
quietly breaks one of the three. They exist as a library: [kore](https://github.com/youndie/kore) —
`io.github.youndie:kore-core`, `kore-ktor` and the Gradle plugin `io.github.youndie.kore.build`.
They resolve from a private Maven repository under `io.github.youndie`; not on Central yet.

**Why not by hand.** `EmbeddedServer.stop` runs its steps in the **opposite order** on Kotlin/Native
and on the JVM. Which means `ApplicationStopping` — the place where every example closes the pool
and the broker connection — runs on native **before** the engine drains and on the JVM after, from
one and the same source, and nothing reports this. In katcher a report queue hung there: `SIGTERM`
cancelled the processing of reports already accepted with `202` while the engine kept accepting new
ones.

```kotlin
fun main() {
    val config = getServerConfig()
    val db = initDb(config)                     // migrations here, before the engine
    val probes = Probes(db)                     // startup / readiness / liveness + HealthRegistry

    val server = embeddedServer(CIO, configure = {
        connectors.add(EngineConnectorBuilder().apply { port = PORT; host = HOST })
        shutdownGracePeriod = DEADLINES.drain.inWholeMilliseconds
        shutdownTimeout = (DEADLINES.drain + 5.seconds).inWholeMilliseconds
    }) { module(db, config, probes) }

    server.start(wait = false)                  // NOT true
    probes.start(CoroutineScope(SupervisorJob() + Dispatchers.Default))
    probes.startup.markStarted()

    runBlocking {
        runUntilSignal(DEADLINES, onFinished = { println(it.transcript) }) {
            announce(AnnounceNotReady(probes.readiness))
            drain(EngineDrain(server, DEADLINES.drain, DEADLINES.drain + 5.seconds))
            consumer(queueParticipant(queue))   // finish reading what was accepted
            pool(databaseParticipant(db))       // and only then close the pool
        }
    }
}
```

In the module, three lines — and their order matters too:

```kotlin
installShutdownRefusal(isShuttingDown = { probes.readiness.isShuttingDown })  // BEFORE the routes
installKoreProbes(probes.startup, probes.readiness, probes.liveness)
installKoreVersion(KoreBuildIdentity)
```

Seven things the code does not show, each of which has already cost somebody time:

* **`start(wait = false)`.** With `true` the main thread never reaches the signal wait, the sequence
  never runs at all, and the process is killed at the end of the grace period — from outside,
  indistinguishable from "it stopped".
* **The database is opened in `main`, before the engine.** Otherwise the release stage has no handle
  on the pool, and closing it is left to `ApplicationStopping` again — that is, in the wrong order.
* **Nobody calls `HealthRegistry.start(scope)` for you.** Without that call `/health/ready` answers
  out of checks that never ran once — `UNKNOWN` forever, which reads as a broken dependency.
* **The deadlines and the chart's `terminationGracePeriodSeconds` are one number in two places.** No
  platform tells a process its real budget; kore takes the one it is *told*. The plan's sum must be
  smaller: in katcher 2 + 10 + 3×3 = 21 against 30.
* **Participants registered in one stage run concurrently.** `runStage` launches all of a stage's
  participants and joins them; only the *stages* are ordered. So `consumer(a)` before `consumer(b)`
  orders nothing, however much it reads like a list of steps. An order needed **inside** a stage is
  written as composition — one participant calling two things in sequence — and an order needed
  between resources is written as a **later stage**. Getting this wrong is quiet: the stage still
  reports `COMPLETED`, and the collision surfaces as an intermittent deadline on a slower machine.
* **`cancel()` is not "stopped", it is "told to stop".** A `stop()` that cancels its loop's job
  without joining it returns while the work is still in flight, and on Kotlin/Native that work is
  often inside an FFI call cancellation never reaches — so it runs on **into the next stage** and
  collides with what that stage does. `cancelAndJoin` in every background loop's `stop()`. A stage
  that suddenly reports 200 µs is not healthy, it is a stage where nobody waited for anything.
  kore's own `HealthRegistry.stop()` cancels without joining
  ([youndie/kore#79](https://github.com/youndie/kore/issues/79)); until that changes, give the
  registry a scope of its own and join that scope in the participant.
* **`/version` is generated source.** Kotlin/Native has neither resources nor a manifest; the plugin
  writes an object and puts it into `commonMain`. `commit` will be `unknown` wherever the build
  context has no `.git` — the usual case being `.dockerignore`. And beware: a file git **tracks**
  but `.dockerignore` excludes reads as deleted inside the build, and the stamp becomes `-dirty`
  forever.

The fact to check is not "it compiled" but the transcript: `docker stop` on the container must leave
`SIGNAL / ANNOUNCE / DRAIN / RELEASE_CONSUMERS / RELEASE_POOLS / EXIT` in the log, each with the word
`COMPLETED`. Worth checking in CI as well: shutdown is the one part of the lifecycle nobody watches.

**And check what the stages were supposed to accomplish, not only that they ran.** A participant that
throws is recorded by kore as a failure while its stage still reports `COMPLETED`, so a transcript
check alone goes green over a release step that quietly stopped working. Pair it with one fact on
disk — for a service with a journal, that the journal was folded away; see
[references/sqlite-under-load.md](references/sqlite-under-load.md).

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

Things that have each already cost time:

* **Building Kotlin/Native inside docker takes tens of minutes.** The binary is built on the runner
  (`./gradlew :server:linkReleaseExecutableLinuxX64`) and only copied into the image.
* **`ca-certificates` — check, do not install from memory.** In `debian:*-slim` they really are
  absent, and without them everything outbound over https fails quietly. But in
  `gcr.io/distroless/cc-*` they are **already there** (`etc/ssl/certs/ca-certificates.crt` —
  verified by unpacking the image), and the extra layer is not needed.
* **A multi-stage build works and gives ~55 MB** — tracy is still built that way; **katcher was
  until 2026-09-15 and is not any more**. Running Gradle inside `docker build` costs 84.3 s of
  configuration and 58.2 s of toolchain download on *every* run, because the caches it needs cannot
  persist between runs of a fresh BuildKit builder. Measured numbers and the replacement are in
  **Build time → The image**, below; what is left of the Dockerfile there is assembly, and
  `docker build` takes one second.
* **No library is copied out of the builder, and that is enforced.** `sborka.kmp` links Linux
  executables with `-Wl,--as-needed`, which drops the three `NEEDED` entries the program never calls
  — one of them `libcrypt.so.1`, which `gcr.io/distroless/cc` does not carry and which two
  Dockerfiles here used to drag across by hand. **The line is worth removing for what it takes with
  it:** a copied system library couples the two images by glibc, the builder's having to be **no
  newer** than the runtime's, and the mismatch is invisible at build time and fails at exec:

  ```
  /app/server: libc.so.6: version `GLIBC_2.38' not found (required by libcrypt.so.1)
  ```

  This is how the move to Java 25 broke: the tag `gradle:9.7.0-jdk25` without a suffix is Ubuntu
  26.04 with glibc 2.43, while `distroless/cc-debian12` carries 2.36. The working pair is
  `gradle:9.7.0-jdk25-noble` (2.39) plus `distroless/cc-debian13`. With no copy there is no pair to
  get wrong — but the moment a Dockerfile here adds a `COPY --from=build /lib/…` line it is back, and
  one command settles it: `docker run --rm <build-image> ldd --version | head -1`. The static image
  below is exactly such a case, and it cannot avoid it.
* **The path to the `.kexe` is what breaks a Dockerfile moved between repositories.** `linuxX64()`
  and `linuxX64("native")` put their output at different paths, and `COPY` learns about it at image
  build time. The `sborka.native-service` convention (§1) stages the binary into
  `build/native-image/<baseName>`, and then `COPY` does not depend on what the target was called;
  `writeNativeDockerfile` from the same convention writes the reference two-stage variant — with
  `ca-certificates` on its own line, the glibc-paired images and the `~/.konan` cache mount — once,
  and without overwriting an existing file.
* **`VOLUME ["/data"]`** — the database is the only state there is, and a pod without a volume loses
  it on every move.

#### `FROM scratch`, in one paragraph

Statically linked and no base image underneath — about **6 MB to pull** below `distroless/cc`, and
all of the work. Take distroless first: it is one line and about 65 MB, and `ca-certificates` are
already in it. If `scratch` is still wanted afterwards, the decision, the condition that makes it
possible at all (the binary must be linked **inside** the image) and the five paths that travel
beside it — because a static binary still `dlopen`s its charset converters — are in
[references/scratch-image.md](references/scratch-image.md). sborka's research holds the recipe, and
holds it in a form that runs.

### 8. The chart: probes, secrets, bypassing middleware

Copy `charts/metrik` or `charts/katcher`. What to check with your own eyes:

* **three probes, not one for all of them.** `/health/startup` is a latch; `/health/ready` is
  dependencies *and* the shutdown latch; `/health/live` (and the `/health` alias) is liveness. A
  readiness probe pointed at `/health` is a probe that cannot fail while the process is alive —
  exactly what kore is taken for. A `startupProbe` with `periodSeconds: 1` and
  `failureThreshold: 60` instead of a long `initialDelaySeconds`: the pod enters service when it is
  ready, not at an appointed hour;
* **`terminationGracePeriodSeconds` is part of the contract**, not a default: the shutdown plan is
  checked against the number it was *told*, and the chart has to say the same thing;
* **the memory limit comes after a measurement, and with a positive control** — the same image under
  a deliberately small limit must be **killed**, or the harness cannot detect a failure at all. In
  katcher the number went 64Mi → 192Mi ("an unexplained crash") → 128Mi, twice the measured peak
  rather than a round figure. How to run that measurement so that it can fail —
  a fixed input rather than a closed loop, reading the container's environment, and asking the
  *subject* whether any load arrived — is
  [references/memory-under-a-limit.md](references/memory-under-a-limit.md#running-the-measurement-so-that-it-can-fail),
  and it is worth reading before the first run rather than after the first surprising table;
* secrets through `secretKeyRef`, not as a value in `values.yaml`: the repository is versioned, the
  token is a credential, and it should not end up in `helm history` either;
* a PVC for `/data`;
* **machine routes get their own ingress route around the forward-auth middleware.** The proxy in
  front of the service expects a browser session; an ingest endpoint and an MCP client have none,
  and the request is rejected *before* the check inside the application runs. From outside this is
  indistinguishable from "the server returned 401" — the 401 comes from the proxy. Create the
  bypass route **only when a token/key is set**, otherwise the bypass appears without the
  authentication that replaces it.

### 9. CI: the `~/.konan` cache is mandatory, not an optimisation

```yaml
- uses: actions/cache@v4
  with:
    path: ~/.konan
    key: konan-${{ runner.os }}-${{ hashFiles('gradle/libs.versions.toml') }}
    restore-keys: konan-${{ runner.os }}-
```

LLVM and the sysroots weigh hundreds of megabytes; without the cache every run spends minutes
downloading them. The key is on `libs.versions.toml` because the cache has to be invalidated when the
Kotlin version changes.

`./gradlew build` includes `ktlintCheck` and the tests. `macosArm64` on a linux runner is silenced
with `kotlin.native.ignoreDisabledTargets`.

## Build time

A service that takes three minutes to build is a service nobody rebuilds to check something. The
study — what a fresh machine needs before any of this compiles, the one `gradle.properties` line
worth adding, why the image is assembled outside `docker build` (84.3 s of configuration and 58.2 s
of toolchain download on every run otherwise), the cache entries that pay and the ones that did not,
and how to measure your own before/after without measuring the Gradle cache — is
[references/build-time.md](references/build-time.md).

## Gotchas already paid for

Not "possible problems" but things found by a run and a deploy. The references are to the metrik
research (`docs/research/research-architecture.md` in [metrik](https://github.com/youndie/metrik)).

* **`ktor-client-cio` has no TLS on Kotlin/Native.** It compiles, links and resolves next to
  `ktor-server-cio`, and the first `https` request fails at runtime with `TLS sessions are not
  supported on Native platform.` Outbound TLS means `ktor-client-curl`, which links libcurl — so the
  runtime image gains a shared library and the service leaves sborka's `scratch` recipe, which is
  exactly why that research excludes metrik's `:server` and shildik's `:distribution`. Decide it when
  the service is created; found by the first service built from keel, whose entire job was forwarding
  a payload to somebody else's URL.

| Gotcha | Symptom | What to do |
|---|---|---|
| **`SelectorManager` occupies a `Dispatchers.Default` worker forever** (§1.5) | on a 2-core pod `delay` stops firing **across the whole process**; looks like two unrelated failures | put the selector loop on its own thread: `SelectorManager(newSingleThreadContext(...))`. It does not reproduce on a developer machine with 5 cores, and `--cpuset-cpus` does not help either |
| **A domain name does not resolve** (§1.6) | `connect` fails with `EINVAL`; the same code works on the JVM | resolve it yourself through `getaddrinfo`, **on every connection** (a pod's address changes when it moves). A ready `HostResolver.native.kt` is in metrik |
| **`HttpClient(CIO)` cannot do TLS** (§1.7) | `TLS sessions are not supported on Native platform`; anything https stays silent | `ktor-client-curl` on native targets through `expect/actual`. The klib carries static `libcurl.a`/`libssl.a`/`libcrypto.a` — neither headers on the build machine nor `libcurl4` in the image are needed; `ca-certificates` are |
| **`ktor-server-compression` is JVM-only** (§1.8) | the plugin does not resolve on native | compress ahead of time, while building the image: a `.gz` next to the file |
| **`respondSource` holds the whole body in memory** (§1.8) | 20 parallel bundle downloads → 232 MB against a 256 MB pod limit, OOMKill | an explicit 64 KB loop through `respondBytesWriter` — the peak drops to 157 MB |
| **`ktor-server-call-logging` is not published for native** | the plugin does not resolve; `callIdMdc` is unavailable | `ktor-server-call-id` is published and covers half the job; write the request log yourself |
| **`Dispatchers.IO` is `internal` on Kotlin/Native** | not available in `commonMain` | `SelectorManager()` with no arguments picks a dispatcher itself |
| **`TimeZone.currentSystemDefault()` is not cached on Kotlin/Native** (katcher [#78](https://github.com/youndie/katcher/issues/78), [#79](https://github.com/youndie/katcher/issues/79)) | nothing fails and nothing looks wrong; the same code on the JVM, where the platform caches the zone, costs nothing — so a JVM build of the same service will not show it to you | 33 µs a call against 73 ns for `Clock.System.now()`. Resolve it once into a `val` and pass it: `now().toLocalDateTime(zone)` went 37.6 µs → 277 ns. Grep before shipping, and count the calls per unit of work rather than per file — one row of katcher's error list crossed the lookup three times, twice mapping the row out of the database and once rendering its age, so a page paid for it once per row per pass |
| **Kotlin/Native forbids commas in backticked test names** | compilation fails on the test | rename it |
| **A PASSIVE SQLite checkpoint does not reset the journal while readers are alive** (tracy M-137) | `-wal` grows linearly, the database file stops growing, half an hour later an OOM on a small heap | a 2-connection pool plus your own `wal_checkpoint(TRUNCATE)` on a timer and on size; `walBytes` in the size response |
| **glibc gives malloc an arena per thread, counting host cores** | resident memory follows the thread count; `smaps` shows a dozen anonymous mappings of 6–12 MB on 64 MB boundaries | `sborka.native-service`'s reference Dockerfile carries `ENV MALLOC_ARENA_MAX=2` and a test in the convention pins it — but **only after an A/B on your own service**: on a service without a database it did nothing, and combined with `-Xallocator=std` it multiplied peak RSS by ten and OOM-killed three runs of ten (§1) |
| **`PRAGMA synchronous` reaches one connection out of the pool** | "write throughput differs by a multiple" is true for 1/N of the commits, the rest go with a full fsync | a probe of N concurrent transactions; the only fixes are warming every connection or a knob upstream |
| **A static glibc is not self-contained: `iconv` loads its converters with `dlopen`** (§7) | an image on `scratch` starts, serves static files and `401`, and returns 500 on the first rendered page: `Failed to open iconv for charset UTF-8 with error code 22` | copy `ld.so.cache`, the loader, `libc.so.6` and the **whole** gconv directory — and out of the build stage: `dlopen` requires the same glibc build as the `libc.a`. The five paths and their price: sborka `research-static-binary.md` §1.5c |
| **`unable to find library -lc` on a static link** | reads like a linker-flag problem | `gradle:*-noble` carries no static archives (`libc.a`, `crt1.o`, the gcc directory) — one `g++` install supplies them; the gcc version and `libGcc.linux_x64=…/13` move together |
| **A repository's `org.gradle.jvmargs` may not be in effect at all** (build-time study) | the daemon runs a heap nobody in the project declared; an experiment that edits this value measures an absent variant and reports a clean "no effect" | `~/.gradle/gradle.properties` on the machine wins. Read the running daemon — `pgrep -af GradleDaemon \| grep -oE '\-Xmx[0-9]+[a-zA-Z]'` — before believing the file. Same repository, two machines, opposite answers: one had a home file with `-Xmx5g`, the other none and the project's `-Xmx4G` ran |
| **There is one JVM during a native link, not two** (build-time study) | `kotlin.daemon.jvmargs` is attached to a process that does not exist while linking; `kotlin.native.jvmArgs` has no JVM to size | a census of `java` processes 45 s into a release link shows Gradle daemons and nothing else — the Kotlin/Native compile runs **inside** the Gradle daemon. Tune `org.gradle.jvmargs`, and remember LLVM allocates outside that heap anyway |
| **Two Gradle daemons where you assumed one** | measurements drift for no visible reason; on a small box the release link is OOM-killed | daemons that differ in JVM args or JDK do not reuse each other. `pgrep -c -f GradleDaemon` before a campaign; a stray one from an earlier JDK holds gigabytes |

## What only a deployment checks

The class of bugs "works locally, breaks in the cluster" **exists here and is not covered by tests**.
Known members:

* the `Host` check in the MCP transport: by default only localhost is allowed, and locally the Host
  is always localhost — the test that should have caught this is impossible in principle;
* forward-auth in front of machine routes (see step 8);
* a global `StatusPages` with a redirect to `/login`: right for a browser, but a machine client gets
  a login page instead of an error code. Redirect only for `Accept: text/html`.

**The conclusion worth applying to the plan:** deploy earlier than feels necessary. In katcher the
deploy found two failures, each of which broke an endpoint completely, with 64 green tests.

## What not to do

* **Do not build Kotlin/Native inside docker** — minutes turn into tens of minutes.
* **Do not drag in nginx for static files.** Native Ktor serves them itself: `SystemFileSystem`
  (kotlinx-io) + `respondBytesWriter` + `ContentType.defaultForFilePath`. The caveats about
  compression and memory are above. There is nowhere to get `Last-Modified` from (`FileMetadata` has
  no modification time) — compute an ETag from the content once at startup.
* **Do not rely on a fake where the component swallows its own errors.** A sender, a receiver, a
  notifier must have a test against a real socket and a "send a test one" handle that returns the
  fact of delivery, not the intent. In metrik two such components stayed silent in production for
  months with green tests.
* **Do not put off `LICENSE`.** katcher still has none, which formally makes the repository unusable.
  One file closes it, before the first image is published.

## Examples

`examples/deploy.md` — the Dockerfile with pre-compressed static files, the publish workflow, the key
pieces of the chart.
