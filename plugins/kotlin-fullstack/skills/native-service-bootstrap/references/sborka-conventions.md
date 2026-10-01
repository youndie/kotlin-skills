# What the sborka conventions enforce, so that step 1 is description and not instruction

Referenced from step 1 of [SKILL.md](../SKILL.md).

[sborka](https://github.com/youndie/sborka) carries `io.github.youndie.sborka.native-service` and
`io.github.youndie.sborka.kmp`, and between them they hold every mechanism named in step 1. The
conventions are published as snapshots to a private Maven repository and resolve through
`id("io.github.youndie.sborka.settings")`; katcher and metrik already apply it. An outside reader
gets the same value from the reasoning below and from sborka's sources, which are public.

That division is the point of this section. **The convention is where a setting is changed; this
file is where it is explained.** A number written in both places drifts in one of them, and the one
that keeps building is the one that is wrong — so when the two disagree, sborka is right and this
paragraph is stale.

What is enforced, rather than recommended:

* **The allocator page size** — `binaryOption("fixedBlockPageSize", …)`, 16 KiB by default, right
  for many threads and a small heap; `nativeService.allocatorPageSize` changes it — 256 for a heap
  of gigabytes and few allocating threads, where the page count sets the collector's pause (not
  with many: the reference has the table) — and `0` leaves the compiler's 128. A check on the stand reads the option
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

**What is deliberately not in it, with the reason:** the `FROM scratch` static recipe (step 7 and [scratch-image.md](scratch-image.md) — sborka's
D3 declines to hand out an option that pins five `konan.properties` keys JetBrains may change in a
patch release) and any choice of targets (four repositories leave out four different targets for four
different reasons, and one convention would delete four arguments rather than one duplication).

**Who applies it, as of 2026-10-01:** [keel](https://github.com/youndie/keel) does
(`server/build.gradle.kts`), so a service started from step 0 gets the convention, not a
hand-rolled executable. katcher and metrik still declare `executable { entryPoint = … }` by hand and
copy the `.kexe` out of `bin/…` in their Dockerfile — worth knowing while reading them as models of
style. Adopting the convention in a service that already ships is a migration of its own.
