# What the klib carries, who can build it, and what the image needs

Referenced from steps 8 and 9 of [SKILL.md](../SKILL.md). The release procedure itself — version,
workflow, proba, tag — is `kmp-library-release`'s; this file is what a **cinterop** module adds to it.

## Reading a published cinterop klib

A KMP module with a binding publishes, per native target, the module klib and a second artefact,
`<module>-<target>-<version>-cinterop-<name>.klib`. That second one is a zip, and two commands tell
whether a stranger can link it:

```bash
unzip -p <file>-cinterop-<name>.klib default/manifest | grep -E '^(staticLibraries|linkerOpts)'
unzip -l <file>-cinterop-<name>.klib | grep '/included/'
```

What a healthy one looks like — Ktor's own, from Maven Central (`ktor-client-curl-linuxx64-3.5.2-cinterop-libcurl.klib`):

```
linkerOpts.linux=-lz
staticLibraries.linux=libcurl.a libnghttp2.a libssl.a libcrypto.a
  12193140  default/targets/linux_x64/included/libcrypto.a
   1823084  default/targets/linux_x64/included/libcurl.a
    357716  default/targets/linux_x64/included/libnghttp2.a
   2120142  default/targets/linux_x64/included/libssl.a
```

**No archive under `included/` and no `-l` in `linkerOpts` means the klib carries bindings and no
implementation** — the kafkakn B-13 and smtpkn M-110 defect. Reading the build file does not show
it: the build file is exactly where the options are. A dynamic binding has no `included/` and must
have `linkerOpts` with `-L` and `-l`.

**For a static binding, `included/` is the reading to trust, not the manifest.** The
`staticLibraries` key is written only when the `.def` names the archives. An archive passed as
`extraOpts("-staticLibrary", …)` lands in `included/` and links for a consumer, while the manifest
says nothing ([probe](../examples/boundary-probes.md#where-linker-options-and-archives-have-to-be-written)).
The reverse trap is worse. `linkerOpts(…)` inside `cinterops { }` reaches cinterop as
`-linker-option` (KGP 2.4.20 `CInteropProcess`), and cinterop drops it with one warning line. The
manifest is empty and the consumer's link fails.

**The size is the archives', not overhead.** kafkakn's cinterop klib went from 76 952 bytes to
11 280 633 when the archives moved in — the compressed form of the 46 MB the link always consumed.

## One copy of each library per binary

Archives inside klibs are linked whole into whatever consumes them, and two klibs carrying the same
library do not link together:

| Pair | Failure | What was decided |
|---|---|---|
| kafkakn-core's OpenSSL 3.0.13 + Ktor Curl's OpenSSL 3.6.3 | `duplicate symbol: i2d_SSL_SESSION`, `ssl_load_ciphers`, … | a native kafkakn service reaches its schema registry over HTTP; the route to HTTPS is a client over kafkakn's own OpenSSL; `-z muldefs` rejected (kafkakn B-98) |
| two sqlx4k Rust drivers | `duplicate symbol: std::panicking::EMPTY_PANIC` | one driver per binary; shared code depends on the database-agnostic `sqlx4k` artefact |

So **a library that bundles a common C dependency (OpenSSL, zlib) owes its README one sentence**:
what it bundles, at which version, and which other klibs it therefore cannot be linked beside.
Before choosing to bundle, look at what your consumers already link: a native service that makes
HTTPS calls already carries Ktor Curl's OpenSSL.

## Which host can build which target

| Target | Built on | Trap |
|---|---|---|
| `linuxX64`, `linuxArm64` | any Linux or Mac host **that has the bundle for that target** — a Mac built a `linux_x64` cinterop and linked an ELF from a Linux-built archive ([probe](../examples/boundary-probes.md#one-host-another-targets-klib)) | the cinterop needs the headers and archives *of the target*, not its host; a system-library binding (mongkn, smtpkn) has them only for its own host, so it builds only that target |
| `macosArm64`, iOS | **a Mac** | on a Linux host the Apple cinterop is SKIPPED and takes `compileKotlinMacosArm64` with it, inside a green build and a publication without the target (kore B-64). A module *without* cinterop cross-compiles Apple klibs on Linux fine — the rule is about the binding |
| `linuxArm64` tests | cross-linked on x86-64, run on arm64 | Kotlin/Native has no linux-arm64 host: `linuxArm64Test` is not a task, and Gradle answers `ambiguous` rather than "skipped" |

**A module is published by one host.** smtpkn's snapshot workflow publishes `smtp-tls-openssl` from
a macOS job and then from a Linux job. Read back on 2026-10-01: `smtp-tls-openssl-macosarm64` was
uploaded at 18:47, and the root `smtp-tls-openssl-0.1.0-20260917.185325-6.module` uploaded at 18:53
lists only the `linuxX64` variants. A macOS consumer asking for the root coordinate has nothing to
resolve.

**How one host gets every target's klib.** A bundle is a set of files: headers and archives. Each
bundle is built where it must be built — the Linux ones in the old-glibc image, the arm64 one on
arm64, because kafkakn's script refuses emulation, the macOS one on a Mac. Each is uploaded as a CI
artefact. **One** publishing job downloads all of them, points each target's cinterop at its own
bundle, and publishes the root and every target together. When an Apple target has a binding, that
job runs on a Mac, and the Linux bundles come to it as files. A binding to a **system** library
cannot do this, because the publishing host has no other platform's `-dev` package. Its options are a
module per platform, each with its own coordinate and its own host, or a move to a bundle.

**What the release workflow cannot do today.** sborka's `central.yaml` runs Gradle on a runner. It
cannot build a C bundle first, install a system package, or take bundles as inputs. So a binding
library has no sanctioned path to Central yet (`kmp-library-release` says the same). That is a
missing input in sborka — bundle artefacts passed to the publishing job — and not a reason to
publish from a laptop.

`kotlin.mpp.enableCInteropCommonization=true` is needed as soon as a shared native source set
(`nativeMain`, `linuxMain`) uses the binding with two targets beneath it; without it only
`compileNativeMainKotlinMetadata` fails, so only a full `./gradlew build` shows it.

## The check after publishing: resolve, link, run — from the repository

| Check | What it proves | What it misses |
|---|---|---|
| compile a consumer against the coordinate (kafkakn `ci/publish/verify-published.sh`) | metadata resolves, variants exist | **everything about the link** — a bindings-only klib compiles |
| link and run a consumer with an empty cache and **no linker options of its own** (kafkakn `ci/b-13/run.sh`, smtpkn `tools/consumer-check`, kotlin-native-rt `iconv/check/check.sh`) | the klib carries what it needs; the `.so` is found at start | a runtime image that lacks what the build machine has |
| run that consumer in the runtime image | the image carries the libraries and files | — |

The consumer must not live in the library's Gradle build (a sibling module shares its options), and
its own build file says in a comment that a linker option may never be added to it.

## The runtime image

What a binary needs depends on how the library came in:

| Library came in as | The image needs | The glibc it needs |
|---|---|---|
| static archives inside the klib (kafkakn, Ktor Curl, sqlx4k) | nothing for the library; whatever the archives import from libc (Curl: `libz`) | what the archives reference — kafkakn raised a plain binary's `GLIBC_2.14` to `GLIBC_2.17`, `manylinux2014`'s floor (research §1.2, pinned by `ci/b-16/run.sh`) |
| a system shared library (mongkn, smtpkn) | the runtime package, **from the build machine's distribution version** | the shared library's, which `--allow-shlib-undefined` let through the link |
| a fully static binary | the gconv tree, `libc.so.6`, the loader and `/etc/ld.so.cache` from the **build stage** — or iconv-unicode | none at start; the build stage's at the first `iconv_open` |

**Read what the binary asks for, not what you think it links.** `readelf -d <binary> | grep NEEDED`
and `readelf -V` for the highest `GLIBC_` version. sborka does both for a service:
`stageNativeImage` writes `<baseName>.needed.txt`, and `nativeImageTar` refuses to write an image
whose base cannot load the binary (interpreter, every `NEEDED` transitively, every symbol version).
`-Wl,--as-needed` (in `sborka.kmp`) drops the three `NEEDED` entries Kotlin/Native declares and
nothing calls.

**What no ELF entry names, and therefore no check above sees:**

* **CA certificates.** An OpenSSL inside a klib reads a path compiled into it — Ktor Curl's is
  `/etc/ssl/certs/ca-certificates.crt` (kafkakn B-98). `debian:*-slim` and `ubuntu:24.04` do not have
  it; `distroless/cc` does. Without it every TLS call fails on certificate verification, which reads
  like a configuration error. `caInfo` on the engine points elsewhere.
* **gconv modules.** glibc's `iconv` `dlopen`s even the UTF-16 converter, and Ktor's charset layer on
  Kotlin/Native is glibc `iconv`. A static binary in `scratch` serves `401`s and fails the first
  rendered page with `Failed to open iconv for charset UTF-8 with error code 22` (sborka research
  §1.5c, katcher#55). Either copy the whole gconv directory, `libc.so.6`, the loader and
  `ld.so.cache` from the build stage — copies from the host or another image of the same version
  give the same error — or link `io.github.youndie.kotlin-native-rt:iconv-unicode`, which wraps
  `iconv` for the five Unicode charsets (published to the project's own snapshot repository, not to
  Maven Central, as of 2026-10-01). The full recipe and its costs:
  [native-service-bootstrap's scratch-image.md](../../native-service-bootstrap/references/scratch-image.md).
* **Anything else the library `dlopen`s.** `nm -D <binary> | grep dlopen` (or `nm` on a static one)
  says whether to look; `strace -e trace=openat` on a real request says what.

**The smoke test exercises the library**, not the process: a request that reaches the binding (a
produce, a query, a rendered page), because a container that starts and answers `/health` has proven
none of the rows above.
