# Gotchas already paid for, by where they show up

Referenced from [SKILL.md](../SKILL.md). Each row was found by a build, a run or a deploy, not by
reading; the source column says where, with the sha the repository was read at in
[inventory.md](inventory.md). Rows are grouped by **where the failure surfaces**, because that is
what you have in hand when you come here: a red link, a container that exits, a process that hangs,
or — the expensive group — nothing at all.

## At link time

| Symptom | Mechanism | What to do | Source |
|---|---|---|---|
| a stranger's build compiles against your klib and fails to link with `undefined symbol` on every C function; your own suite is green | the archives or `-l` options were named as `linkerOpts` on **your** binaries in `build.gradle.kts`; the published klib says nothing about them | `staticLibraries` (or `linkerOpts`) **in the `.def`**, directories through `extraOpts("-libraryPath", …)`; delete the build-file options so your own tests link the way a stranger's do | kafkakn research §2.12 (B-13: 14 symbols), smtpkn M-110 |
| `undefined symbol: mtx_lock`, `strlcpy`, `getentropy`, `__isoc23_strtol` linking a freshly built C library | Kotlin/Native links against its own sysroot, glibc **2.19** on linux_x64 (2.25 on linux_arm64); a library built by the host compiler references what came later — `__isoc23_*` from the 2.38 headers alone | build the library in an old-glibc image (`manylinux2014`, glibc 2.17), or point the toolchain at the host sysroot with three `konan.properties` keys plus `-L` — keys JetBrains documents as unstable between patch releases. Record which | kafkakn research §1.3, D4 |
| same list, and `manylinux_2_28` was chosen as the old image | glibc 2.28 already has C11 threads, so librdkafka stops using the tinycthread it bundles and `mtx_lock` is back | `manylinux2014`; make the build refuse when `WITH_C11THREADS` appears | kafkakn `ci/librdkafka/oldglibc.Dockerfile`, `inside.sh` |
| `undefined symbol: __aarch64_ldadd4_acq_rel` (and ~100 more) on linuxArm64 | gcc 10 in `manylinux2014_aarch64` emits "outline atomics" — calls into its own libgcc; Kotlin/Native's aarch64 toolchain links an older libgcc | `-mno-outline-atomics` in `CFLAGS`; refuse any archive with `U __aarch64_` | kafkakn §2.28 |
| `undefined reference: strlcpy@GLIBC_2.38 >>> referenced by libbson-1.0.so (disallowed by --no-allow-shlib-undefined)` | linking against the **distribution's** shared library, which was built against the distribution's newer glibc | `--allow-shlib-undefined` in the `.def`'s `linkerOpts` — the loader resolves them at start against the real glibc — and know that the binary now needs that glibc at run time | mongkn research §1.18, smtpkn `smtp-tls-openssl/build.gradle.kts` |
| `unknown argument '-Wl,--allow-shlib-undefined'` | options in a `.def` go straight to `ld.lld`, not through a compiler driver | spell them without `-Wl,` in the `.def`; the binary DSL's `linkerOpts` is a different place with a different spelling | mongkn, smtpkn generated `.def` comments |
| the error changes from `undefined symbol` to `unable to find library -lmongoc-1.0` after moving options into the `.def` | `libraryPaths` acts at the cinterop stage and does not reach the consumer's link | put `-L<dir>` **inside** `linkerOpts` as well | mongkn `mongkn-core/build.gradle.kts` |
| `'openssl/opensslconf.h' file not found` | Debian multiarch keeps it in `include/<triplet>/openssl` | add every include directory that holds a piece of the header set | smtpkn `smtp-tls-openssl/build.gradle.kts` |
| `bits/libc-header-start.h` not found through `limits.h` | `compilerOpts = -I/usr/include` put the distribution's headers in front of the sysroot's libc | `-idirafter /usr/include` | a private study |
| `undefined symbol: __wrap_iconv_open` with the C written after `---` | inline C is compiled into the program's bitcode and the optimiser makes the functions local | compile the C into a static library the klib carries (`staticLibraries`) | kotlin-native-rt `iconv/build.gradle.kts` |
| `ld.lld: duplicate symbol: i2d_SSL_SESSION`, `ssl_load_ciphers`, … | two klibs each carry a static OpenSSL (3.0.13 and Ktor Curl's 3.6.3) | one copy per library per binary: route the second consumer through the first's copy, or keep the two apart. **Never `-z muldefs`** — it would run one version's code against the other's structures, silently | kafkakn B-98 |
| `duplicate symbol: std::panicking::EMPTY_PANIC` | two Rust staticlibs (two sqlx4k drivers) each carry the Rust runtime | one driver per binary; a library depends on the database-agnostic `sqlx4k` and takes a `Driver` from its consumer | shildik `storage-sqlx4k-core/build.gradle.kts`, chronik |
| `undefined symbol: timer_create` | POSIX timers live in `librt` on the toolchain's glibc | `linkerOpts.linux = -lrt` in the `.def` | razves `sampler.def` |
| `-static` fails with seven glibc-internal symbols (five `_dl_*`, plus `__libc_setup_tls` and `__syscall_error`) | not a sysroot defect: `-Bdynamic` from `linkerKonanFlags` comes **after** your `-static` and switches `-lc` back to shared | read the real argv with a shim in place of `linker.linux_x64`; edit the stock value of a key (print it whole — it continues over `\`), never retype it | sborka research §1.5, KT-89362 |

## When the process starts

| Symptom | Mechanism | What to do | Source |
|---|---|---|---|
| `libc.so.6: version 'GLIBC_2.25' not found` on a glibc 2.17 machine, linuxArm64 only | OpenSSL's weak `getentropy` is bound because the aarch64 sysroot is 2.25; lld marks the version need as strong | `--with-rand-seed=devrandom` for the aarch64 OpenSSL; check `w` references too, not only `U` | kafkakn §2.28, B-44 |
| `cannot open shared object file` in the runtime image | a dynamically bound library is in the build machine and not in the image | the runtime package in the image, from the **same distribution version** as the build; sborka's `nativeImageTar` load check refuses the image | mani `server-native/Dockerfile`, sborka `NativeImage.kt` |
| the image starts and the first call into the library fails on a missing symbol | the soname (`libmongoc-1.0.so.0`) is shared across branches, so an image with a different branch starts cleanly | pin the image's distribution to the build's; exercise the library in the smoke test | mani `server-native/Dockerfile` |

## At run time, loudly

| Symptom | Mechanism | What to do | Source |
|---|---|---|---|
| `_mongoc_handshake_freeze(): assertion failed` on the next network call | `mongoc_init()` does not reinitialise after `mongoc_cleanup()`; a reference count took it to zero between tests | a process-wide one-way lifecycle; closing one client never cleans up the library | mongkn research §1.8 |
| the process dies with `SIGABRT` on a database hiccup | a Rust driver built with `panic = "abort"` panics on I/O, TLS and protocol errors | treat every such error as fatal to the process and supervise it; validate inputs before they cross | sqlx4k `sqlx4k-postgres/src/rust/src/lib.rs:365`, `Cargo.toml` |
| the process dies with `SIGABRT` on one write | a `LocalDateTime` on a whole minute is sent as `2030-01-07 11:00`, Rust's parser rejects it and panics | one filter function every value passes through on its way into Rust | sqlx4k `sqlx4k-postgres/src/nativeMain/.../params.kt:149`, `lib.rs:251`; found by one service's smoke test |
| exit 139 under `SIGTERM`, the crashing thread being the receiver | a Kotlin `staticCFunction` signal handler initialised the runtime on a newborn worker before the worker did | signal handlers in C through cinterop, doing an atomic store and nothing else | kore B-64 (16/1 000 → 0/1 000) |
| `PosixException.InterruptedException: pselect failed, EINTR` kills a Ktor CIO server | ktor-network's native selector does not retry `EINTR`; any in-process signal source (a sampling profiler) makes it frequent | no in-process signal sampler against Ktor CIO; your own loops treat `EINTR` as one more turn | pgo-native-spike B-15 (97 Hz: died 2 runs of 3), kesh `EventLoop.kt` |
| a forked child hangs in its first allocation | the GC thread does not survive `fork()`, and the first mutator assist waits for it | a finite `GC.maxHeapBytes` first thing in the child, `_exit` only; budget ~1.4 × used memory for copy-on-write in the parent | kesh B-25 |

## At run time, silently

| Symptom | Mechanism | What to do | Source |
|---|---|---|---|
| the caller of a C-callback-based operation stays suspended forever | an exception thrown inside the callback unwound through the C frames into the Kotlin code that **called into C**, not into the coroutine waiting for the result. In kafkakn that is the polling coroutine around `rd_kafka_poll`, which runs the delivery reports, and the library's own work stopped half-done | catch everything inside the callback and hand the failure to whoever waits | kafkakn research §2.3, `KafkaProducer.native.kt`; [boundary-probes](../examples/boundary-probes.md#an-exception-thrown-out-of-a-callback) |
| `Uncaught Kotlin exception`, exit 134, from a callback | the callback ran on a thread the C library created (a tokio worker under sqlx4k), so no Kotlin frame is above it | the same: nothing is thrown out of a callback | [boundary-probes](../examples/boundary-probes.md#an-exception-thrown-out-of-a-callback) |
| a string with a NUL inside is stored truncated | cinterop turns `const char*` into `String`, and C measures it with `strlen` | `noStringConversion = <function>` and an explicit length; reject NUL where the format cannot carry it | mongkn research §1.15 |
| every topic-level option has its default, the test is green | a fresh `rd_kafka_topic_conf_new()` inherits nothing from the global configuration; the default happened to equal the asserted value | test each option with a value the other side **rejects**; unknown keys fail at construction | kafkakn §2.8, mongkn (`insertOne` passed `NULL` options) |
| `flush` "left -185 messages" | `rd_kafka_flush` returns an error code (`_TIMED_OUT`), not a count | read the header for the return type of every call; a count is `rd_kafka_outq_len` | kafkakn §1.4 |
| every failure reads "All broker connections are down" | `_ALL_BROKERS_DOWN` is an informational summary that arrives last | keep the last error that is not the summary | kafkakn §2.9 |
| 264 826 of 1 000 000 records lost, `failed = 0` | `rd_kafka_produce` only enqueues; a refused record produces no delivery report | count what the caller asked for; a full queue is backpressure and suspends | kafkakn §1.4 |
| `withTimeout(…)` does not fire; the test framework's timeout does not either | the thread is inside a blocking C call; cancellation exists only at suspension points | make the wait cancellable before entering C (a semaphore the size of the pool); job-level timeouts in CI | mongkn research §1.12–1.13 |
| resident memory climbs for days, flat over minutes | a cinterop `Arena` (stately's `Lock`) is allocated per request, and the `close()` that frees it is never called | count malloc chunks or allocator calls, not RSS; give every native allocation an owner whose `close()` someone is obliged to call | kore B-65 |
| a signed request is rejected with `SignatureDoesNotMatch` | libcurl normalises `/a/./b` to `/a/b` after the signature was computed | a live request through the real engine; a `MockEngine` test shows what Ktor built, not what left | s3kn `docs/api/protocol-s3.md` |
| one request answers 200 in the test binary and 500 in the image | test binaries are debug; a fallback relied on behaviour release does not have | run the suite against a release test binary too | mongkn M-91 |

## In the build and the publication

| Symptom | Mechanism | What to do | Source |
|---|---|---|---|
| `BUILD SUCCESSFUL` and no macosArm64 artefact | cinterop for an Apple target needs the macOS SDK; on a Linux host it is SKIPPED and takes `compileKotlinMacosArm64` with it | publish a cinterop module's Apple targets from a Mac, or keep the binding off Apple targets; check that the compile task **executed** | kore B-64 |
| `BUILD SUCCESSFUL` in 8 s on linux-aarch64 | Kotlin/Native has no linux-aarch64 host; every compile task is SKIPPED | fail the configuration on that host; cross-link `linuxArm64` test binaries on x86-64 and run them on arm64 | mongkn §1.18, kore |
| `Unresolved reference 'rdkafka'` in `compileNativeMainKotlinMetadata` only | with two native targets `nativeMain` is a shared compilation that sees no per-target binding | `kotlin.mpp.enableCInteropCommonization=true` | kafkakn §2.28, kore `gradle.properties` |
| `warning: -linker-option(s)/-linkerOpts option is not supported by cinterop`, then `undefined symbol` downstream | `linkerOpts(…)` inside `cinterops { }` become `-linker-option`, which cinterop drops | linker options in the `.def` | KGP 2.4.20 `CInteropProcess`; [boundary-probes](../examples/boundary-probes.md#where-linker-options-and-archives-have-to-be-written) |
| a check on the manifest calls a healthy static klib empty | `extraOpts("-staticLibrary", …)` copies the archive into `included/` without writing the `staticLibraries` key | read `included/`, or name the archives in the `.def` | [boundary-probes](../examples/boundary-probes.md#where-linker-options-and-archives-have-to-be-written) |
| the klib still carries the old archives after the bundle was rebuilt | archives reach cinterop through `extraOpts`, which Gradle cannot see into, so the task stays up to date | declare the archives as inputs of the interop task | kafkakn §2.28 trap 2 |
| the macOS half of a version cannot be resolved through the root coordinate | two hosts published one module; the second upload rewrote the root `.module` with its own variants only | one host publishes the root and every target of a module | smtpkn snapshot, read 2026-10-01 |
| the ABI check fails on the other host with one changed line | the klib dump records `// Targets: [...]`, and a binding to a system library (mongkn, smtpkn) declares only its host's target | take and check the dump on the published target | mongkn §1.19 |

## When measuring

| Symptom | Mechanism | What to do | Source |
|---|---|---|---|
| the binding "costs nothing" in a size probe | the release linker dropped a library nothing called | the probe constructs and closes the real thing | xyk `link-probe.md` |
| `_ZN…` symbols charge the Kotlin/Native runtime 31 times its size | Rust's legacy mangling shares Itanium's prefix | classify Rust (`17h<hash>E` suffix) before C++ | razves B-05 |
| `grep -a 'abc' binary.kexe` finds nothing that is there | Kotlin/Native stores string literals in UTF-16 | search `pattern.encode('utf-16-le')`; symbols are ASCII | pgo-native-spike `bench/build-arm.sh` |
| `nm -u` says the archive needs `mtx_lock` from libc | `nm -u` lists undefined symbols per member, including ones another member defines | ask the pair: defined anywhere (`[TtWw] sym$`), referenced undefined (`U sym$`) — and, on aarch64, weak (`w`) | kafkakn `inside.sh` |
| a static-binary report shows zero dependencies on every variant | `readelf` was missing and its stderr went to `/dev/null` | preflight the tools and stop when one is absent | sborka `static-probe` |
