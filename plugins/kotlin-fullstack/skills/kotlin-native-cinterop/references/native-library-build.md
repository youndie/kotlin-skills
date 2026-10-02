# Building the native library so it links against Kotlin/Native's sysroot

Referenced from step 3 of [SKILL.md](../SKILL.md). The worked example throughout is kafkakn's C
bundle (`kafkakn@bd3193e:ci/librdkafka/`), because it is the one binding in the portfolio that builds
its own C, for two architectures, and has been bumped and re-measured since.

## The sysroot is the whole problem

Kotlin/Native does not link against the machine's libc. It links against a sysroot it downloads
next to the compiler — on 2.4.20, `~/.konan/dependencies/x86_64-unknown-linux-gnu-gcc-8.3.0-glibc-2.19-kernel-4.9-2`
and `aarch64-unknown-linux-gnu-gcc-8.3.0-glibc-2.25-kernel-4.9-2`. That keeps the binary's own glibc
requirement low, and it means **a C library built on a current distribution references symbols the
sysroot does not have**.

Two numbers for "low" appear in the portfolio, and they are not a contradiction. A small program
references nothing past `memcpy@GLIBC_2.14`: kafkakn's Kafka-free baseline (research §1.2) and
sborka's probe. A service also references `__cxa_thread_atexit_impl@GLIBC_2.18`, weakly (sborka
`research-static-binary.md` §1.2, tracy's row). sborka calls 2.14 the hard floor because that
reference is weak. kafkakn measured the opposite for a weak reference: lld does not mark the version
need weak, and the loader refused `getentropy@GLIBC_2.25` on glibc 2.17 (§2.28, B-44). So treat the
highest version a binary references as its floor, weak or not, until it has been run on something
older. The link failures look like this:

```
ld.lld: error: undefined symbol: mtx_lock / cnd_signal / thrd_create   (C11 threads, glibc 2.28)
ld.lld: error: undefined symbol: strlcpy                                (glibc 2.38)
ld.lld: error: undefined symbol: getentropy                             (glibc 2.25)
ld.lld: error: undefined symbol: __isoc23_strtol                        (the 2.38 headers' redirects)
```

Compilation passes; only the link fails; and the message reads like the library's fault. It is not
specific to any library — `__isoc23_*` appears from merely compiling against current headers.
Apple targets do not have this problem: the library and Kotlin's linker use one SDK (kafkakn's
`build-macos.sh` builds the same sources on a Mac with no overrides).

Two routes were measured, both work, and choosing between them is a decision about **where the
breakage lands**, which is why it is recorded rather than defaulted (kafkakn research D4).

| Route | What it costs | When it breaks |
|---|---|---|
| **A. Build the library in an old-glibc image** — `quay.io/pypa/manylinux2014_<arch>` (glibc 2.17, gcc 10) | a pinned builder image, a build script, sometimes a local patch | when **you** bump the library, deliberately |
| **B. Point the toolchain at the host's sysroot** — `-Xoverride-konan-properties=targetSysRoot.linux_x64=/;crtFilesLocation.linux_x64=usr/lib/x86_64-linux-gnu;libGcc.linux_x64=usr/lib/gcc/x86_64-linux-gnu/13` plus `linkerOpts("-L/usr/lib/x86_64-linux-gnu")` | three keys JetBrains says may change in any patch release (its advice in KT-38876, quoted in sborka `docs/research/research-static-binary.md` D3) | on a Kotlin upgrade, at a moment nobody chose, in every consumer that copied the recipe |

kafkakn took A. A library others link should take A: B's keys are in the **consumer's** build too,
because the consumer's link is the one that meets the sysroot.

## Route A, the way kafkakn's bundle does it

Every line below is there because its absence cost a run.

* **Versions come from the version catalogue** (`librdkafka = "2.13.0"` in `gradle/libs.versions.toml`),
  so a Renovate bump of the library is a bump of the bundle. The dependencies' versions (zlib, zstd,
  OpenSSL) are in the script; they are a decision too.
* **Sources are downloaded on the host, not in the container.** `manylinux2014` carries curl 7.29
  with NSS, and a TLS failure to a download host would look like a build failure. The tarballs are
  mounted read-only and the container runs without a network, which also makes the build repeatable.
  The script prints each tarball's sha256; it does not compare it with a pinned value — that is a
  gap, not a feature (see the report's follow-ups).
* **The cache is outside the source tree** (`~/.cache/kafkakn/librdkafka-<version>[-linuxArm64]`):
  it is large, it is build output, and a path without the architecture is how one bundle overwrites
  the other.
* **It refuses to build under emulation**: `docker info --format '{{.Architecture}}'` must equal the
  requested architecture. arm64 is built on an arm64 Docker (Docker Desktop on an Apple-silicon Mac
  is one), not through qemu.
* **Static archives only, `-fPIC -O2`**; OpenSSL `no-shared no-zlib no-tests`; librdkafka
  `--enable-static --enable-ssl --enable-zlib --enable-zstd --disable-curl --disable-gssapi`.
* **What configure chose is asserted, not assumed.** The build prints the selected features and
  refuses when TLS is off, and refuses when `WITH_C11THREADS` appears in `config.h` — the whole route
  depends on librdkafka falling back to the `tinycthread` it bundles. That is also why the image is
  `manylinux2014` and **not `manylinux_2_28`**: 2.28 has C11 threads and `mtx_lock` comes straight
  back.
* **perl modules**: OpenSSL 3's `Configure` needs `IPC::Cmd`, which that image's perl lacks; the
  failure ("Can't locate IPC/Cmd.pm") reads as an OpenSSL problem.

### The check that proves the route held

After the build, ask every archive whether it still expects anything newer than the sysroot from
libc. **Not with `nm -u` alone**: it lists undefined symbols per archive member, including ones
another member of the same archive defines — by that reading librdkafka "needs" `mtx_lock` from libc
where it defines it itself. Ask the pair, with anchored names (`kafkakn@bd3193e:ci/librdkafka/inside.sh`):

```bash
for a in "$OUT"/lib*/lib*.a; do
  for sym in mtx_lock thrd_create cnd_signal strlcpy getentropy __isoc23_strtol; do
    d=$(nm --defined-only "$a" 2>/dev/null | grep -cE "[TtWw] ${sym}$" || true)   # defined here?
    u=$(nm -u "$a" 2>/dev/null | grep -cE "U ${sym}$" || true)                   # expected from outside?
    [ "$d" -eq 0 ] && [ "$u" -gt 0 ] && { echo "$(basename "$a") NEEDS $sym FROM LIBC"; fail=1; }
  done
done
```

Plain `grep strlcpy` also matches `OPENSSL_strlcpy`; anchor the name. The list of symbols is
**librdkafka's known set**, and it is no gate for another library. It also missed a weak reference
on aarch64: see the second trap below.

**The general gate is on the consumer's binary, not on the archives.** Link an executable in a build
outside the repository, with no overrides and no linker options of its own. A symbol the sysroot
lacks fails that link. Then read the highest glibc version the linked binary needs, which also
catches what bound weakly:

```bash
objdump -T app.kexe | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1     # or: readelf -V app.kexe
```

kafkakn's `ci/b-16/run.sh` does exactly this. It pins `GLIBC_2.17` and fails when the binary
says otherwise. It holds the same `comm` it uses for `ldd` against `/bin/bash` to prove the
comparison can come out non-empty. The `nm` loop above is how you find *which* archive raised the
number; the binary is where you find out that it did.

### linuxArm64 adds three traps

Measured in kafkakn §2.28 (B-39, B-44); none of them showed on x64:

1. **Outline atomics.** gcc 10 in `manylinux2014_aarch64` compiles atomics as calls into its own
   libgcc (`__aarch64_ldadd4_acq_rel` and ~100 more references across librdkafka, libssl, libcrypto);
   Kotlin/Native's aarch64 toolchain links an older libgcc. `-mno-outline-atomics` in `CFLAGS`, and
   the build refuses any archive with `U __aarch64_`.
2. **The aarch64 sysroot is glibc 2.25, not 2.19.** OpenSSL declares `getentropy` weak; on x64 it
   stays unbound, on aarch64 it binds at `GLIBC_2.25` and the loader enforces it — the binary refuses
   to start on glibc 2.17. Fixed with `./Configure … --with-rand-seed=devrandom` for aarch64 only, and
   the check above learns to look at `w` references, which the `U` pair did not see.
3. **The bundle is not a task input** — see step 4 of the skill: a rebuilt bundle at the same path
   left the klib carrying the old archives.

And one about running: Kotlin/Native has no linux-arm64 **host**, so `linuxArm64Test` does not exist
as a task at all. Cross-link the test binary on x64 (`linkDebugTestLinuxArm64`) and run the
`test.kexe` on arm64 hardware — the suite passed 93 of 93 there in kafkakn B-39.

## Patches: a file, applied by a script that refuses three different ways

A local patch is a **file** in the repository, never a `sed` in the build script: a patch that no
longer applies is a conflict somebody sees, a `sed` that no longer matches is a silent no-op followed
by a confusing compile error. kafkakn carries one (`patches/0001-guard-sys-random-include.patch`:
librdkafka includes `<sys/random.h>`, which arrived in glibc 2.25, under `#ifndef _WIN32` while the
call it exists for is guarded by `HAVE_GETENTROPY`).

The bump that makes a patch obsolete arrives on its own, from Renovate, and `patch --forward` says
the same sentence for "upstream fixed it, delete this" and "upstream moved the code, rewrite this".
`apply-patches.sh` asks the source first and prints one of three refusals:

| Refusal | Means | Action |
|---|---|---|
| `PATCH TARGET MISSING` | the file it edits is gone | find where the code went before deciding anything |
| `PATCH OBSOLETE` | it reverses cleanly: upstream does it now | **delete** the patch and the sentences that carry it |
| `PATCH NO LONGER APPLIES` | it neither applies nor reverses | rewrite it, after checking the problem still exists |

**`--forward` is load-bearing on the reverse probe.** GNU patch 2.7.6 given `-R` against a source
the patch is *not* applied to prints `Unreversed patch detected! Ignoring -R.`, applies it forward,
and exits 0 — reporting "already applied" for a pristine source, the one answer that gets a live
patch deleted (kafkakn research §2.16, measured on librdkafka's own `rdrand.c`):

| | unpatched | already patched |
|---|---|---|
| `patch -R --dry-run` | exit 0 | exit 0 |
| `patch -R --dry-run --forward` | **exit 1** | **exit 0** |

`ci/b-22/run.sh` in kafkakn watches all three refusals happen. When the defect is not reported
upstream — kafkakn's is not — this check is the only thing that will ever say a patch has done its
job.

## Route B, if it is taken anyway

For a service's own binary — never for a published library — the override can be the cheaper
choice, and sborka's static-binary research documents it. Two rules from paying for it:

* **Edit a key's stock value; never retype it.** In `konan.properties` a value continues onto the
  next line through `\`, and a `grep` shows one line. Retyping `linkerKonanFlags.linux_x64` to drop
  `-Bdynamic` also dropped `--gc-sections` — 316 488 bytes on katcher, and nothing failed (sborka
  research §1.5). Print the whole value first:
  `awk '/^linkerKonanFlags.linux_x64/{p=1} p{print} p&&!/\\$/{exit}' konan.properties`.
* **Read the linker's real argv before explaining a failure.** A shim in place of `linker.linux_x64`
  that prints `"$@"` and `exec`s the real one costs ten minutes and answered what the written-down
  explanation — an "incomplete sysroot" — had got wrong: a user's `-static` arrived before the
  toolchain's `-Bdynamic` (sborka research §1.5, KT-89362).

## Rust with a C ABI

sqlx4k builds each driver with `cargo build --release --target=<triple>` as a Gradle `Exec` task
the cinterop task depends on, `crate-type = ["staticlib"]`, a header from cbindgen, and the archive
named in `staticLibraries` with `libraryPaths.<target>` per triple (`youndie/sqlx4k@754d1ef:build-logic/…multiplatform.lib.gradle.kts`).
Built on the host, it links against the sysroot without overrides in every service in the
portfolio — "host-built" is not the defect; *what the build references* is, and the `nm` pair is
the check either way. What Rust adds:

* **`panic = "abort"` makes every panic a process exit.** The driver panics on `Io`, `Tls` and
  `Protocol` errors and on a parameter its parser rejects (`sqlx4k-postgres/src/rust/src/lib.rs:237–398`).
  Nothing on the Kotlin side can catch it.
* **One Rust runtime per binary.** Two staticlibs each carry `std`, and `ld.lld` fails with
  `duplicate symbol: std::panicking::EMPTY_PANIC`.
* **Rust's legacy mangling is `_ZN…`**, the Itanium prefix: a size or crash tool that reads it as C++
  charges the Kotlin/Native runtime with tokio (razves B-05).

## A system shared library instead

mongkn and smtpkn build nothing: they bind the distribution's `libmongoc`/`libssl`. The costs move
elsewhere, and each one has bitten:

* the build machine needs the `-dev` package (the unversioned `.so` symlink and the headers), the
  image needs the runtime package, and **from the same distribution version** — the soname is shared
  across branches, so a mismatch starts cleanly and fails on the first call (mani
  `server-native/Dockerfile`);
* the distribution's library was built against the distribution's glibc, so linking against the old
  sysroot needs `--allow-shlib-undefined` in the `.def`, and the binary then needs that glibc at run
  time — its own ceiling (`GLIBC_2.18` at most for a Kotlin/Native service, see above) no longer
  describes it;
* the header set moves between distributions and branches: versioned include directories on
  Homebrew (`include/mongoc-2.1.1/`), multiarch ones on Debian (`include/x86_64-linux-gnu/openssl/`),
  `-lmongoc2` against `-lmongoc-1.0`, and `libmongocrypt` matching a naive `libmongoc*` (mongkn
  research §1.1, §1.18). Resolve them in Gradle with an error naming the package to install;
* the branch you link against changes behaviour (`insertedId` absent on 1.x, mongkn §1.18), so CI
  runs the floor and the ceiling: Linux against 1.26, macOS against 2.x.
