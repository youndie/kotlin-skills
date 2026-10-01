---
name: kotlin-native-cinterop
description: "Bind a C library (or Rust with a C ABI) into Kotlin/Native and ship it: whether to bind at all, building it against Kotlin/Native's old-glibc sysroot, the .def and which flags must live there so a consumer links, ownership across the boundary (memScoped, nativeHeap, StableRef), callbacks on foreign threads, typed errors, variadics, blocking calls under coroutines, signals, tests that can fail (consumer link, release build, allocation counts), the published cinterop klib, and what the runtime image needs. Use for 'bind this C library', 'write a .def', 'cinterop', 'undefined symbol at link', 'the consumer cannot link', 'wrap librdkafka / libmongoc / OpenSSL', 'обернуть C-библиотеку', 'написать .def', 'cinterop не линкуется', 'у потребителя не линкуется'. Not for a service skeleton or image (native-service-bootstrap) or the release procedure (kmp-library-release)."
---

# Binding a C library into Kotlin/Native, and shipping it

This skill takes a C library — or a Rust one exporting a C ABI — from "should we bind it" to a klib a
stranger links and an image that runs it. It ends where neighbours begin: the service around the
binding, its probes and its image recipe are [`native-service-bootstrap`](../native-service-bootstrap/SKILL.md);
the release procedure (version, workflow, proba, tag) is `kmp-library-release`; where each test lives
is [`kmp-testing`](../kmp-testing/SKILL.md).

The material is every binding in the portfolio, read on `origin/main` on 2026-10-01 —
[kafkakn](https://github.com/youndie/kafkakn) (librdkafka, static, built in an old-glibc image),
[mongkn](https://github.com/youndie/mongkn) (libmongoc, the system's), [smtpkn](https://github.com/youndie/smtpkn)
(OpenSSL), [kore](https://github.com/youndie/kore) and [razves](https://github.com/youndie/razves) (C
signal handlers), [kotlin-native-rt](https://github.com/youndie/kotlin-native-rt) (`--wrap`ped iconv),
sqlx4k (Rust drivers), Ktor's Curl engine — and sborka's research on static binaries. Per-binding
detail: [references/inventory.md](references/inventory.md).

**Why this skill is careful: nearly every defect here was silent.** kafkakn's published klib compiled
for a stranger and could not be linked, while eleven backlog items' worth of suite, oracle and gate
stayed green. A green build on a Linux host published no macOS artefact. A coroutine timeout did not
fire around a hung C call. A Rust driver turns an I/O error into a process abort. A string lost its
tail at a NUL. A library ran in the debug test binary and failed in the release one.
So every step below ends in a **fact that can come out red**, and most facts are about the artefact a
stranger gets, not the build that made it. The table of symptoms, by where they surface:
[references/gotchas.md](references/gotchas.md).

**The skill describes; a mechanism compels.** sborka's conventions (`--as-needed`, `needed.txt`,
`nativeImageTar`'s load check) and the repository's own scripts (a bundle build that refuses, a
consumer check) are where rules are enforced. Where this file and a mechanism disagree, the mechanism
is right.

## Step 0. The project's own conventions win

1. Read the repository's `CLAUDE.md` and its research document first. kafkakn's opens with four ways
   "the obvious design is wrong"; mongkn's with three. They are the assignment, not background.
2. Find what exists: the `.def` files (`git ls-files '*.def'`), the `cinterops {` blocks, a bundle
   script (`ci/<lib>/build.sh`), a consumer check (`ci/downstream`, `tools/consumer-check`), a release
   test task. Extend them; do not start a second one beside them.
3. Find a second `settings.gradle.kts`: a nested build that pulls the library by **coordinate** is the
   consumer check, and it must stay free of linker options.

**Checkable fact:** you can name the existing bundle script, consumer check and release test task —
or say that one is missing, which is then part of the work.

## 1. Decide whether to bind at all

A binding brings costs no Kotlin dependency has, and in more places. Before writing a `.def`:

* **The platform may already have it.** `platform.posix`, `platform.linux` (kesh's whole event loop is
  `epoll` through it) and `platform.zlib` ship with the compiler — no `.def`, no archive.
* **A Kotlin library may already have it.** HTTPS: `ktor-client-curl` carries its own static libcurl
  and OpenSSL inside its klib, and `ktor-client-cio` has **no** TLS on native. Hashes and HMAC:
  KotlinCrypto (s3kn's signing is pure Kotlin). gzip: okio's `GzipSink` over `platform.zlib`.
* **What a binding costs, measured:** librdkafka with its TLS, zlib and zstd added 8 656 416 bytes to
  a stripped binary, of which the Kotlin side was ~20 KB (kafkakn research §1.2); Ktor Curl took a
  service binary from 9 662 448 to 18 945 736 bytes (xyk `link-probe.md`). Beyond bytes: a builder
  image and patches to keep, a sysroot question on every Kotlin bump, Apple targets that only a Mac
  can publish, a second static copy of a common library that will not link beside the first (kafkakn
  B-98), and the JVM side written separately.

**Checkable fact:** the research document or decision record names the pure-Kotlin or
already-bundled alternative and why it was rejected.

## 2. Static archives in the klib, or the system's shared library

This one decision sets the build, the consumer's configuration and the image. Take it explicitly.

| | **Static, carried in the klib** (kafkakn, Ktor Curl, sqlx4k) | **System shared library** (mongkn, smtpkn) |
|---|---|---|
| who builds the C | you, in a pinned builder image | the distribution |
| a consumer needs | nothing | the `-dev` package at link time |
| the image needs | nothing for the library | the runtime package, same distribution version as the build |
| glibc at run time | what the archives reference (kafkakn: 2.17) | the shared library's — after `--allow-shlib-undefined` |
| security updates | a rebuild and a release of yours | `apt upgrade` in the image |
| collides with | any other klib bundling the same library | nothing |
| a `scratch` image | possible | not without the library's whole dependency tree |

A library others will link should default to static: its consumers then need no configuration and
no package. A service's own binding to something the distribution maintains well (OpenSSL with its
CVE stream) can reasonably go the other way.

**Checkable fact:** the decision and its reason are written down (kafkakn D4 is the model).

## 3. Build the native library for Kotlin/Native's sysroot

Kotlin/Native links against its own sysroot — **glibc 2.19 on linux_x64, 2.25 on linux_arm64**
(`~/.konan/dependencies/`). A library built by the host's compiler on a current distribution
references what came later, and the **link** fails, naming symbols rather than the cause:
`mtx_lock`, `strlcpy`, `getentropy`, `__isoc23_strtol`. The library is not broken.

Two routes, both measured (kafkakn research §1.3):

* **Build in an old-glibc image** — `quay.io/pypa/manylinux2014_<arch>` (glibc 2.17). Not
  `manylinux_2_28`: it has C11 threads, and librdkafka stops using its bundled fallback. This breaks
  only when you bump the library.
* **Override the toolchain's sysroot** with `-Xoverride-konan-properties`
  (`targetSysRoot`, `crtFilesLocation`, `libGcc`, plus `-L`). JetBrains says these keys may change in
  any patch release, and a published library would push them into every consumer's build. Breaks on a
  Kotlin upgrade nobody chose.

kafkakn's bundle is the reference implementation of the first route: versions from the catalogue,
sources fetched outside the container, a refusal to build under emulation, configure's choices
asserted, local patches as files applied by a script that says whether a patch is obsolete or merely
moved, and **an `nm` check that no archive expects a post-2.19 symbol from libc** — the pair "defined
here?" / "referenced undefined?", because `nm -u` alone lists what a sibling member defines.
linuxArm64 adds outline atomics, a 2.25 sysroot that binds a weak `getentropy`, and no host to run
tests on. All of it, with the commands: [references/native-library-build.md](references/native-library-build.md).

Rust: `cargo build --release --target=<triple>` as an `Exec` task the cinterop task depends on,
`crate-type = ["staticlib"]`. Know that sqlx4k builds with `panic = "abort"` (step 5) and that two
Rust staticlibs in one binary do not link (`duplicate symbol: std::panicking::EMPTY_PANIC`).

**Checkable fact**, on what a consumer gets, not on the bundle: an executable linked by a build
outside the repository — no `-Xoverride-konan-properties`, no linker options of its own — links, and
the highest glibc version it references is the floor you promise:
`objdump -T <kexe> | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1` (`readelf -V` shows the same
needs). kafkakn's `ci/b-16/run.sh` pins `GLIBC_2.17` this way. The bundle script's own `nm` list is
librdkafka's symbols only, and it missed a weak reference on aarch64. The highest version counts
whether the reference is weak or not: lld does not mark the version need weak, and the loader
refused `getentropy@GLIBC_2.25` (kafkakn B-44).

## 4. The `.def` file, and where each flag must live

**Everything a consumer's link needs must be written into the klib, and the `.def` is the place that
does it reliably.** Three other places look as if they should, and do not:

* `linkerOpts` on your binaries reach your binaries only. Your suite links; a stranger's link fails
  with `undefined symbol` on every C function. kafkakn shipped exactly that (B-13: 14 undefined
  symbols downstream, everything inside green), and smtpkn did the same (M-110).
* `linkerOpts(…)` inside `cinterops { }` become `-linker-option`, which cinterop drops with one
  warning line. The manifest stays empty and the consumer's link fails.
* `extraOpts("-staticLibrary", …)` does put the archive into the klib and a consumer links. But the
  manifest gets no `staticLibraries` key, so a check that reads the manifest reports a healthy klib
  as empty.

The last two were probed: [examples/boundary-probes.md](examples/boundary-probes.md#where-linker-options-and-archives-have-to-be-written).

| What | Where | Why |
|---|---|---|
| `headers`, `headerFilter`, `package` | `.def` | the filter keeps the binding to the library's own headers |
| archive names: `staticLibraries = libfoo.a …` | `.def`, names only | cinterop copies them into `default/targets/<target>/included/` |
| archive directories | Gradle: `extraOpts("-libraryPath", dir)` | keeps the `.def` machine-independent |
| `-L<dir> -lfoo` for a shared library | `.def` `linkerOpts` (generated, with resolved paths) | `libraryPaths` alone acts at cinterop time and never reaches the consumer's link |
| `--allow-shlib-undefined` | `.def` `linkerOpts`, **no `-Wl,`** | options from a `.def` go straight to `ld.lld`, which rejects the driver's spelling |
| a platform's extra library (`-lrt` for POSIX timers) | `.def`: `linkerOpts.linux = -lrt` | per-platform keys exist; razves uses this one |
| system headers outside the sysroot | `compilerOpts = -idirafter /usr/include` | with `-I`, the distribution's headers shadow the sysroot's libc |
| a function taking `const char*` that may contain NUL | `noStringConversion = fn` | the default `String` conversion stops at the first NUL |
| function-like macros (`SSL_set_tlsext_host_name(s, n)`) | C after `---`, as `static` functions | cinterop does not see them; object-like constants (`#define TLS1_2_VERSION 0x0303`) arrive as `const val` |
| a symbol the **linker** must find (`__wrap_iconv`) | a static library, never `---` | inline code is optimised into the program's bitcode and goes local |
| linker options for a consumer | the `.def` — **not** `cinterops { linkerOpts(…) }` | cinterop drops those with a warning, and the manifest stays empty |

On the Gradle side: **no `linkerOpts` for the library on any binary** — their absence is what makes
your own tests link the way a stranger's do; the archives declared as **inputs** of the interop task
(`tasks.named(interop.interopProcessingTaskName) { inputs.files(...) }`), or a rebuilt bundle leaves
the klib carrying the old ones (kafkakn B-39); and `kotlin.mpp.enableCInteropCommonization=true` once
two native targets share `nativeMain`. Both shapes, complete:
[examples/def-and-gradle.md](examples/def-and-gradle.md).

**Checkable fact**, on the klib, not the build file. For a static binding,
`unzip -l <…-cinterop-<name>.klib> | grep /included/` lists the archives; this is the reading that
cannot lie, because the manifest key is optional. For a shared library,
`unzip -p <klib> default/manifest | grep '^linkerOpts'` carries `-L` and `-l`. And
`grep -nE '\blinkerOpts[[:space:]]*(\(|\+=|\.add)' build.gradle.kts` finds no call that names this
library. It finds nothing in kafkakn, mongkn and smtpkn, whose files mention `linkerOpts` only in
comments and in the generated `.def` text. Options unrelated to the binding, such as
`-Wl,--as-needed`, may stay.

## 5. The Kotlin API over the raw binding

The generated binding is C with Kotlin syntax. Nothing above the module should see it: callers get
Kotlin types, typed errors and suspend functions, and every rule below lives in one place.

**Ownership — every native allocation has exactly one owner that frees it.**

| Memory | Tool | The rule that was paid for |
|---|---|---|
| for one call | `memScoped { }` | a pointer from it dies with the block; a library that **keeps** a pointer needs memory you own |
| long-lived | `nativeHeap` + an owner with `close()` that someone calls | stately's `Lock` has a `close()` that frees its `Arena`, and koin-ktor never called it: 16 + 48 bytes per request, 154 MB after four days (kore B-65) |
| allocated by the library | the library's own free | `freeaddrinfo`, `bson_destroy`, `tjFree` — a library may have its own allocator |
| Kotlin bytes for one call | `usePinned` + an explicit length | `addressOf(0)` throws on an empty array |
| a Kotlin object handed to C | `StableRef`, disposed exactly once | dispose after the library can no longer call back |

**Callbacks run on whatever thread calls them, and that thread decides what a thrown exception
does.** Both outcomes were probed
([examples/boundary-probes.md](examples/boundary-probes.md#an-exception-thrown-out-of-a-callback)):

* **On a thread Kotlin owns that called into C**, the exception unwinds through the C frames to the
  Kotlin code that made the call, and the library's own work stops half-done. librdkafka's delivery
  reports are this case: they run inside `rd_kafka_poll`, which kafkakn calls from its own polling
  coroutine on `Dispatchers.Default` (`KafkaProducer.native.kt`). The throw lands in that loop, not
  in the coroutine that waits for the report, and kafkakn recorded the result as a caller suspended
  for ever (research §2.3).
* **On a thread the library created**, nothing is above the callback: `Uncaught Kotlin exception`,
  exit 134. sqlx4k's completions are this case. Rust calls them from a tokio worker
  (`runtime.spawn` in `sqlx4k-postgres/src/rust/src/lib.rs`).

So **nothing is thrown out of a callback**: catch everything inside it and hand the failure to
whoever waits. A `staticCFunction` captures nothing, so per-instance state travels through the
library's user-data pointer as a `StableRef`.

**Errors.** Read the header for how each call reports: a return code, an error object, or a
process-wide "last error". `rd_kafka_flush` returns a code, once printed as "-185 messages left";
`_ALL_BROKERS_DOWN` is a summary that hides the cause (kafkakn §1.4, §2.9). Read `errno` on the line
after the failure; `EINTR` is a retry. Map codes to a sealed exception type at the binding, and keep
**backpressure** (a full queue) a distinct, non-failure case. Two error channels that are not
exceptions at all:

* **a Rust panic is a process abort.** sqlx4k builds with `panic = "abort"` and panics on I/O, TLS
  and protocol errors and on a `LocalDateTime` without seconds (`sqlx4k-postgres/src/rust/src/lib.rs`).
  Validate everything on its way in through one function; treat the rest as fatal and supervised;
* **`longjmp`** (libpng) must start and end in C: a jump across Kotlin/Native frames is undefined.

**Options a C API silently drops** look exactly like options that worked: mongkn's `insertOne`
passed `NULL` instead of the options document, kafkakn's fresh topic configuration inherited nothing.
Test every option with a value the other side **rejects**, and fail unknown keys at construction.

**Variadic functions** bind as `vararg variadicArguments: Any?`. That is `platform.posix.printf`'s
shape. On macosArm64 with Kotlin 2.4.20, `snprintf` received an `Int`, a `Long`, a `Double`, a
`String` and a `ULong` correctly, and a `Float` promoted to `double`
([the probe](examples/boundary-probes.md#variadic-functions); one target, so check yours). What is
missing is any type check: each argument's C type comes from the Kotlin value, and the function-like
macros that build argument lists (`RD_KAFKA_V_*`) are invisible. So:
prefer the library's non-variadic sibling (kafkakn moved everything to `rd_kafka_produceva`, an
array of `rd_kafka_vu_t`, §2.10); otherwise a fixed-signature C shim after `---`. (kafkakn's research
§1.5 still says variadics have "no usable shape" — a sentence carried over from its feasibility spike
with no measurement behind it.)

Code for each of these: [examples/kotlin-api.md](examples/kotlin-api.md).

**Checkable fact:** an allocation counter returns to zero over a loop of round trips **and** turns red
when a test leaks on purpose; a test throws inside the callback path and the caller completes.

## 6. Blocking calls, threads and signals

Most C libraries block (libmongoc has no asynchronous API at all). Three rules follow:

1. **Blocking calls go on a dispatcher built for waiting**: `Dispatchers.IO`, or a pool the binding
   owns and closes — not `Dispatchers.Default`. On native `Dispatchers.IO` is an extension that needs
   importing (`import kotlinx.coroutines.IO`, or the package's `*`); without it the compiler says
   `it is internal`, which booblik, kore and mongkn's own research each misread as "absent". On
   native, every thread costs resident memory
   ([native-service-bootstrap](../native-service-bootstrap/references/memory-under-a-limit.md)), and
   for a blocking library the thread count is the throughput knob (mongkn `docs/performance.md`).
2. **A handle that is not thread-safe never crosses a suspension.** Coroutines resume on any thread
   of a pool; `mongoc_client_t` is not thread-safe, so mongkn pops a client from the C pool, uses it
   in one non-suspending block, and pushes it back.
3. **Cancellation never reaches C.** `withTimeout` around a blocking call bounds nothing: the thread
   is inside C, and mongkn's hung pool pop outlived both `withTimeout` and the test framework's own
   timeout (§1.12). What works: make the **wait** a suspension before entering C (a semaphore with one
   permit per pooled connection, §1.13); bound the **answer**, not the thread, by awaiting a call that
   is not your child — and keep at most one such call in flight, or every probe parks another
   thread; set the library's own timeout so the thread comes back; and tell the library to cancel
   where it can. A cancelled `send` in kafkakn may still be delivered (B-73); a cancelled
   sqlx4k query is not cancelled at all (`suspendCoroutine`).

**Signals.** A signal handler written in Kotlin is a C-to-Kotlin bridge: in kore it initialised the
runtime on a newborn worker thread, which then died — 16 crashes in 1 000 against 0 with the same
handler in C (B-64); razves' Kotlin handler hung 3 runs in 10 at 100 Hz. **Handlers are C, through
cinterop, and do one atomic store.** Every loop you own retries `EINTR`; Ktor CIO's native selector
does not, so an in-process signal-based sampler kills a CIO server (pgo-native-spike B-15).
`fork()` from Kotlin/Native leaves the child without its GC thread (kesh B-25).

**Checkable fact:** a test on a **single-thread** dispatcher measures the longest gap while the
binding works (kafkakn §2.13 — a pool hides blocking); a timeout test passes quickly under `runTest`'s
virtual time, which it can only do if nothing is blocked in C (mongkn §1.13).

## 7. Testing a binding

Placement is `kmp-testing`'s. What a binding adds — each check exists because its absence shipped a
defect:

* **A consumer that links and runs**, in a separate build, resolving the published (or locally
  published) coordinate with an empty cache and **no linker options of its own** — kafkakn
  `ci/b-13/run.sh`, smtpkn `tools/consumer-check`. Compiling is not enough: a bindings-only klib
  compiles. The cheapest guard is a deletion — no `linkerOpts` in the library's own build.
* **The suite in release, too.** Test binaries are debug; images ship release. mongkn M-91: one
  request, 200 from the debug binary and 500 from the release one, with the consumer's suite green.
  `binaries.test(listOf(NativeBuildType.RELEASE))` plus a task that runs `releaseTest/test.kexe`.
* **A reference to differ from.** kafkakn's JVM arm on `kafka-clients` runs the same `commonTest`
  against the same broker; mongkn writes with the official JVM driver and reads with its own. A
  binding checked only by itself can be wrong in both directions.
* **Generated inputs for formats**: mongkn's NUL truncation was found by a property test and by
  nothing hand-picked (§1.15).
* **Leaks by counting** — allocator hooks, malloc chunks, `sweptCount` — with a positive control;
  never RSS over minutes.
* **Hangs from outside**: a deadlock in C defeats every in-process timeout, so CI needs a job
  timeout, and razves runs its sampler's survival test against a subprocess.
* **An ABI dump on the published target.** The klib dump records `// Targets:`, and a binding to a
  system library (mongkn, smtpkn) declares only its host's target, so a dump taken elsewhere differs
  in that line (mongkn §1.19). A bundled binding like kafkakn's declares the same Linux targets on
  every host.

**Checkable fact:** CI runs the consumer link-and-run and the release test task, and each has been
seen red once — the consumer against a klib without archives, the release task against a mutant.

## 8. Publishing the klib so a consumer links

The procedure is `kmp-library-release`'s. What a binding adds:

* **Read the published klib** with the two `unzip` commands from step 4, by coordinate, after the
  upload.
* **One copy of a library per binary.** kafkakn-core's static OpenSSL 3.0.13 and Ktor Curl's 3.6.3
  fail together with `duplicate symbol` (B-98). Say in the README what you bundle and beside what it
  cannot link; never `-z muldefs`.
* **Apple targets with a binding need a Mac.** On a Linux host their cinterop is SKIPPED and takes
  `compileKotlinMacosArm64` with it — a green build, a publication without the target (kore B-64).
  Pure-Kotlin modules cross-compile Apple klibs on Linux; this is about the binding.
* **One host publishes a module, root and every target.** smtpkn publishes `smtp-tls-openssl` from a
  Mac and then from Linux. The published root module lists only `linuxX64`, and the macOS artefact
  uploaded six minutes earlier is unreachable through the root coordinate (read back 2026-10-01).
* **So when a binding needs a Mac, the Linux bundles travel to the Mac as files.** A cinterop needs
  the target's headers and archives, not the target's host. A Mac built a `linux_x64` cinterop klib
  and linked an ELF from a Linux-built archive ([probe](examples/boundary-probes.md#one-host-another-targets-klib)).
  The bundles are built where they must be — an old-glibc image, an arm64 runner; kafkakn's script
  refuses emulation. Each one is uploaded as a CI artefact, and one publishing job downloads them
  all. A binding to a *system* library cannot do this: the Mac has no Linux `libssl-dev`. It splits
  into a module per platform, each published by its own host under its own coordinate, or it moves to
  a bundle. sborka's `central.yaml` cannot build a C bundle or take one as an input before Gradle runs
  (`kmp-library-release` says the same). That is a missing input in sborka, not a reason to publish
  by hand.
* **linuxArm64 has no host**: cross-link its test binary and run it on arm64 hardware, with a bundle
  built on arm64.

Detail and the evidence: [references/publishing-and-image.md](references/publishing-and-image.md).

**Checkable fact:** a build outside the repository, knowing only the coordinate and the repository
URL, links and runs on every published target — and the root module lists every target that was
uploaded.

## 9. What the runtime image needs

| The library came in as | The image needs |
|---|---|
| static archives in the klib | nothing for the library; what the archives import (Curl: `libz`) |
| a system shared library | the runtime package from the **build machine's distribution version** — a shared soname across branches starts cleanly and fails on the first call (mani `server-native/Dockerfile`) |
| a fully static binary | the gconv tree, `libc.so.6`, the loader and `ld.so.cache` **from the build stage**, or kotlin-native-rt's `iconv-unicode` |

Read what the binary asks for — `readelf -d` for `NEEDED`, `readelf -V` for the highest `GLIBC_` —
and let sborka check it: `stageNativeImage` writes `<baseName>.needed.txt`, `nativeImageTar` refuses
a base that cannot load the binary. **What no ELF entry names**: CA certificates (an OpenSSL inside a
klib reads a compiled-in path, `/etc/ssl/certs/ca-certificates.crt` for Ktor Curl), gconv modules,
anything `dlopen`ed. The `scratch` recipe is
[native-service-bootstrap's](../native-service-bootstrap/references/scratch-image.md).

**Checkable fact:** the smoke test of the image makes a call that **goes through the binding** — a
produce, a query, a rendered page — not `/health`.

## What not to do

* **Do not put a binding's linker options on your binaries.** The suite links, the artefact does not.
* **Do not build the C on the host and fight the link with overrides** in a library others consume.
* **Do not carry a patch as a `sed`.** A `sed` that stops matching is a silent no-op.
* **Do not use `-z muldefs`** to make two copies of one library link.
* **Do not let an exception or a `longjmp` cross the boundary**, and do not hand a Rust driver a value
  that can make it panic — with `panic = "abort"` there is nothing on the other side to catch it.
* **Do not write a signal handler in Kotlin**, however small its body.
* **Do not wrap a blocking C call in `withTimeout`** and call it bounded; measure `time_total`.
* **Do not trust a green build for a target**: check that `cinterop<Name><Target>` and
  `compileKotlin<Target>` executed and the klib exists — a Linux host skips Apple cinterop, a
  linux-aarch64 host skips everything, and `kotlin.native.ignoreDisabledTargets=true` silences the
  warning about disabled targets.
* **Do not measure a binding's size with a probe that never calls it** — the release linker drops it.
* **Do not inherit a sentence about the boundary without running it.** "Variadics have no usable
  shape", "`Dispatchers.IO` is internal on native" and "an exception in a callback surfaces nowhere"
  all survived reviews, and all three were wrong. Each probe that settled one is a few lines:
  [examples/boundary-probes.md](examples/boundary-probes.md).
