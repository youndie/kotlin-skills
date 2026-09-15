# Build time: what to set, what it bought, and what it did not

Referenced from [SKILL.md](../SKILL.md). Nine questions with their thresholds declared **before**
each measurement, three results that work and still missed their line, one red, and one setting
validated on a second repository.

From the katcher build-time study (2026-09-15), `docs/research/build-time/` in that repository.
Every figure below is measured on a named machine with the campaign's load recorded per run. The
thresholds were declared **before** each measurement, which is why three of these say "works, did
not clear its line" instead of rounding up.

> **How far this has been validated, and where it stops.** `kotlin.incremental.native=true` was
> applied unchanged to a second service (tracy) and reproduced 55% of its relative gain — that one
> line is a recipe. **The CI half — dropping a duplicate link, moving Gradle out of `docker build`,
> pruning a duplicate cache — has been measured on one repository only.** It is written here because
> the mechanism behind each is general and visible in any profile, not because a second service
> confirmed the numbers. Treat the seconds as katcher's and the mechanisms as yours to re-measure.

### What a machine needs before any of this builds at all

Seven independent failures on a freshly provisioned Linux box, each looking like a broken build rather than a
missing package. **This list is worth more than every setting below it**: a setting costs minutes,
a missing `libcrypt.a` costs an hour and points at the linker.

| requirement | how it fails without it |
|---|---|
| **JDK 25 for Gradle itself** | `kore-build` sets a JVM 25 floor at *buildscript* level. `foojay-resolver` provisions toolchains for **compiling** and cannot help — the daemon that reads the build script is a different JVM |
| **`g++-13`, not `g++`** | `libGcc` in `-Xoverride-konan-properties` is pinned to `/usr/lib/gcc/x86_64-linux-gnu/13`. A distribution defaulting to 15 leaves that path absent and the link fails on flags that look wrong |
| **`libcrypt-dev`** | `ld.lld: unable to find library -lcrypt` |
| **`zlib1g-dev`** | `-lz` — and **only the debug link needs it**; the release link succeeds without it, so this surfaces on the second task you run, not the first |
| **`libffi-dev`** | |
| **Reachable `github.com`** | Gradle distributions redirect there from `services.gradle.org`. An IPv6-only host cannot fetch the wrapper, and the error is a Java stack trace inside `org.gradle.wrapper.Install` |
| **Reachable private Maven repo** | if the settings plugin comes from one; an IPv4-only host is the case that bites, since the runner may resolve AAAA first |

**More than 8 GiB of RAM**, if the daemon gets `-Xmx4G`. The release link takes the Gradle daemon
to **5.95 GB RSS** — LLVM allocates outside the Java heap — and then `clang++` asks for its own. On
a 7.7 GiB box the kernel log filled with OOM kills and the third consecutive link died every time.
`-Xmx3g` completes at ~300 s against `-Xmx4G`'s 256–275 s: slower, and it finishes.

> The comment in `server/Dockerfile` — *"gcc 13 here is the version the `libGcc` override names; the
> two move together"* — reads as a historical note and is a working warning. The first port to
> another distribution walked straight into it.

### `gradle.properties`: one line that is worth adding

```properties
kotlin.incremental.native=true
```

**−45.5% on the local debug edit→link loop** (median 8246 ms → 4492 ms, pooled over four campaigns
on one machine). Correctness checked rather than assumed: the native suite runs 129 tests green
under it, three times over.

**Validated on a second repository.** tracy, same setting, no repo-specific edit: −25.1%, which is
55% of katcher's relative gain. That is what lets this line be stated as a recipe rather than as
one project's result.

Nothing else in `gradle.properties` moved the needle, and the rest of the study is why.

### The image: build outside `docker build`, and now with numbers

Step 7 above says build outside and calls multi-stage "not a prohibition". Measured, the
prohibition is close to earned:

| | Gradle inside `docker build` | linked outside, image assembles |
|---|---|---|
| Image job, warm | 402 s | **221 s** |
| `docker build` itself | 474 s | **1 s** |
| configuration + dependency resolution | 84.3 s **every run** | 0 |
| `downloadKotlinNativeDistribution` | 58.2 s across four modules, **every run** | 0 |

**BuildKit cache mounts cannot fix the inside case on a GitHub runner**, and this is reasoning
rather than a measurement: a `--mount=type=cache` lives in the builder's own state and the builder
is fresh each run; `cache-to: type=gha` exports **layers**, not mounts; and layer cache alone
reaches only the base pull and the `apt` layer, because `COPY . .` carries the source and
invalidates everything under it on every commit.

**Run Gradle in the same image the runtime takes its glibc from.** A statically linked binary still
`dlopen`s its gconv converters, so the shared glibc copied into the runtime must be the same *build*
as the `libc.a` the link used. `docker run` against `gradle:<version>` with the runner's
`~/.gradle` and `~/.konan` mounted keeps that pairing while moving the cache problem somewhere
`actions/cache` can solve it:

```yaml
- name: Link the binary, in the image that supplies its glibc
  run: |
    docker run --rm \
      --volume "$PWD":/app --workdir /app \
      --volume "$HOME/.gradle":/home/gradle/.gradle \
      --volume "$HOME/.konan":/root/.konan \
      gradle:9.7.1-jdk25-noble \
      sh -c 'apt-get update -qq && apt-get install -y --no-install-recommends -qq g++-13 >/dev/null \
             && gradle :server:linkReleaseExecutableLinuxX64 --no-daemon'
    sudo chown -R "$(id -u):$(id -g)" "$HOME/.gradle" "$HOME/.konan" server/build
```

**The two mounts are at different paths and that asymmetry is measured, not sloppy.**
Kotlin/Native uses `$HOME/.konan` and the container runs as root, so `/root/.konan` is right.
Gradle in that image does **not** honour `GRADLE_USER_HOME`: set to `/root/.gradle` and asked
directly, the container answered `0 /root/.gradle` and `1.3G /home/gradle/.gradle`. Three green
runs passed with half the cache going nowhere — the job built, the smoke test passed, the timing
even improved, because the `~/.konan` half was real. The only complaint was one line in the
`actions/cache` post step.

`.dockerignore` must then un-exclude **one path by name**:

```
**/build/
!server/build/bin/linuxX64/releaseExecutable/server.kexe
```

Widening that to `**/build/bin/` readmits every target's output and puts back the hundreds of
megabytes the file exists to keep out.

### CI caches: one entry per directory

The `~/.konan` cache in Step 9 works, and that is measured rather than assumed: **`T_first_compile`
median 70 s** over eight runs against a 90 s threshold, with an **8/8 hit rate**.

**Do not add a second cache action for the same directory.** A setup action that already caches
`~/.konan` plus a hand-written `actions/cache` below it is two entries for one directory under two
keys: 13 s spent restoring what was restored 13 s earlier, and on a version-catalogue bump both
save the same ~1 GB twice. Check what the setup action already does before adding the block from
Step 9.

### Tried, and it did not pay

Every one of these was applied, measured and then not adopted — or adopted without clearing the
line it was given. Recorded because a recipe that lists only its wins teaches people to expect
wins.

| tried | result | why it is here |
|---|---|---|
| `-Xmx10g` for the Gradle daemon | **9.96%** on the release link, against a 10% line | Works, never cleared its threshold, and on a 7.7 GiB box it is not a variant but an impossibility. Dropped |
| Drop the duplicate release link from CI | CI **−43%**, `T_pr` **−22.2%** against a 25% line | The gate moved to the neighbouring job: cutting CI below the Image job's time stops moving `T_pr` at all |
| Link outside `docker build` | **45.0%** against a 50% line | Removed everything outside the link; what remains is the link, and RQ0 measured that as 79.7% LLVM |
| `--no-configuration-cache` in CI | **3.7 s**, in the direction of *slower* | The mechanism is real — the entry is stored on every CI run and reused on none, because it lives in the project's `.gradle/` and every run is a fresh checkout. It just costs less than the runner's own variation. **An article's ~30 s did not transfer** |
| Remote build cache | nothing to compare | `gradle/actions/setup-gradle` already restores `~/.gradle`, which contains `caches/build-cache-1`, hitting 8 of 8 runs. Standing up a Develocity server would answer a question the repository does not have |
| Removing the largest dependency | **−20.2%** on the release link, for **−19.2%** of binary size | Works, and costs a feature — see below |

**Three of those land just short of a line drawn before measuring, and the pattern has a cause:
each lever stops where something *else* becomes binding.** The heap ran out against native memory
the Java heap does not own; the CI cut ran out against the neighbouring job; the docker change ran
out against the link itself. Thresholds written as though levers act alone will be missed by levers
that queue.

### Binary size is a real lever, and it is paid for in features

Removing the largest removable dependency took the binary **16,704,336 → 13,495,008 bytes (−19.2%)**
and the release link **110.13 s → 87.90 s (−20.2%)**. A ratio of **1.05**: link time follows input
size within the noise, which is what you would expect when 79.7% of the link is LLVM.

So size *is* the lever — and the only contributor large enough to matter was an endpoint the
service actually serves. **"Shrink the binary" and "drop a feature" are the same sentence** on a
service this size.

Two things about size tools, both learned the hard way:

* **Package attribution is direct contribution.** A report attributing 7.7% of the file to a
  dependency undercounted its removal by two and a half times — transitive pull-in and the dead code
  eliminated afterwards are not in that row. **Rank candidates with it; do not predict the saving
  from it.**
* **A quarter of the file is symbol tables and debug info**, attributed to nobody and never seen by
  LLVM. That is size which costs a `pull` and not a second of link time. A "make the binary
  smaller" instinct aimed there moves the download and not the clock.

### Measuring your own before/after

Copy `docs/research/build-time/raw/measure-local.sh` from katcher. It runs on the build host
(`RUNNER=`) or drives one over ssh, and the task names are parameters — **which they had to become
the moment a second repository was tried**: katcher picks its native target by host and calls it
`native`, tracy declares `linuxX64()`, so every task name differed, including the one the guard
greps for.

What it refuses to do is the point:

* A timed run whose **compile or link did not execute** prints `void:<reason>`, never a number. A
  probe that appends a *comment* recompiles the file and leaves the klib byte-identical, so the
  build cache answers for the link — the run looks fast and measured nothing. The probe appends a
  top-level `val`.
* A **failed settle** is reported, not swallowed. Its output used to go to `/dev/null`, so the timed
  run after it measured whatever state a failure left behind.
* It **refuses to start** when the tree holding the probe is not the tree being built.
* Every row carries **load before, load after and memory used**. A header taken at the campaign's
  start is the one moment that number is guaranteed to be meaningless: one baseline began at 1.66
  and ended at 124 while its header said 1.66, and a metric drifting 6394 → 8590 → 14572 read as a
  mechanism when it was someone else's build.

And the rule that costs the most to learn: **a baseline is a property of its conditions.** The same
metric on the same machine measured 12 810 ms in one campaign and 8246 ms in another, because the
first interleaved two-minute release links between its samples. Re-measure the baseline inside
every campaign rather than comparing against a number from an earlier one.


