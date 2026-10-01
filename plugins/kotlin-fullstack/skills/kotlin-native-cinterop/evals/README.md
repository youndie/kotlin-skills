# What this suite checks

Five cases, and **each one is a defect that shipped or was measured in a public repository**, not a
behaviour somebody thought a model might get wrong. This skill's value is in failures that stay
silent — a klib that compiles and does not link, a timeout that does not fire, an image that answers
`/health` and fails the first page — so a case that tests the happy path would test nothing it adds.

| case | where it comes from |
|---|---|
| `linker-options-travel-in-the-klib` | [kafkakn](https://github.com/youndie/kafkakn) B-13/B-15 (`docs/research/research-architecture.md` §2.12): the archives were `linkerOpts` on the module's own binaries; a downstream build resolved the published klib, compiled, and failed to link with 14 undefined symbols while every internal check stayed green. [smtpkn](https://github.com/youndie/smtpkn) M-110 repeated it with a shared OpenSSL |
| `host-built-library-meets-the-sysroot` | kafkakn research §1.3 and decision D4: librdkafka built on a current distribution references `mtx_lock`, `strlcpy`, `getentropy` and `__isoc23_strtol`, which Kotlin/Native's glibc 2.19 sysroot lacks; the fix is the `manylinux2014` bundle in `ci/librdkafka/`, not `manylinux_2_28`. The fixture's build script says that `ev`, like librdkafka, falls back to a bundled tinycthread without C11 threads — without that line an old-glibc image could not be derived from the fixture, and a library that needs `threads.h` would fail at configure there |
| `variadic-function-gets-a-fixed-signature` | `rd_kafka_producev` (variadic, built from `RD_KAFKA_V_*` macros) against `rd_kafka_produceva` (an array): kafkakn research §1.5 and §2.10. The case also guards against the over-correction kafkakn's own text carries — `platform.posix.printf` is bound as `vararg Any?`, so "variadics cannot be called" is false |
| `withtimeout-does-not-bound-a-blocking-call` | [mongkn](https://github.com/youndie/mongkn) research §1.12–1.13: a thread blocked in `mongoc_client_pool_pop` outlived both `withTimeout` and the test framework's timeout; the probe-shaped fix (await a call that is not your child, at most one in flight on the single handle) is the one a readiness probe needs |
| `static-binary-needs-more-than-the-binary` | [sborka](https://github.com/youndie/sborka) `docs/research/research-static-binary.md` §1.5c and [katcher#55](https://github.com/youndie/katcher/issues/55): a static katcher in `scratch` answered `401` and failed the first rendered page with `Failed to open iconv for charset UTF-8 with error code 22`; [kotlin-native-rt](https://github.com/youndie/kotlin-native-rt)'s `iconv-unicode` is the alternative to carrying gconv. The fixture's static recipe is abbreviated (the `konan.properties` overrides are left out) and says so |

## What an expectation is allowed to be

**Observable**: a key in a `.def`, a line that is gone from a build file, a `COPY --from=build`, a
call to `ev_emitv`, a timing measured in the verification. "The binding is correct" is not checkable
by a grader; "build.gradle.kts no longer names `libev.a` in `linkerOpts`" is.

Several expectations check that a **reason** appears — why the own suite could not see the defect,
why `withTimeout` cannot end the call. That is deliberate: an agent that moves the flag without
knowing why moves it back the next time a link fails locally.

Two expectations check that something **false is not said** ("variadics cannot be called at all",
"switching dispatchers makes it cancellable"). Both are sentences that circulated in the portfolio
with the force of a measurement and none behind them.

## The fixtures are small and the library is fictional

`files/setup-fixture.sh` builds the smallest context in which each decision is real. The C library
is `ev` or `db`, not librdkafka or libmongoc, so the agent works from the header and the build file
in front of it rather than from what it remembers about a famous library. Nothing in a fixture has
to compile on the grader's machine: the cases grade decisions and code.

Run them with `claude plugin eval` against this plugin.
