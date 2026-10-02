# Checking a publication as a consumer: proba, and the probes it does not replace

A library's own build cannot tell what a stranger receives: inside it, `project(...)` resolves
anyway, linker options come from the build file, the README is prose, and every target is a source
set rather than a variant. The portfolio has two kinds of answer. **proba** reads what the server
serves, for every coordinate it is given, with no code of the library's own. **Hand-rolled probes**
are separate builds that know only a coordinate and a repository URL and do what a consumer does:
compile source, link a binary, run it. Neither covers the other. Facts below are from each
repository's `origin/main` (proba `d693923`, telek `0399ec6`, smtpkn `a89c6d7`, kafkakn `bd3193e`,
petich `426caa8`).

## What proba is, exactly

* A GitHub Action (`uses: youndie/proba@main`), inputs `coordinate` (one per line), `repository`
  (default Central), `deep` (default `true`), `fail-on` (`defect` by default), `badge-dir`.
* **Cheap tier:** reads `.module`, POM and the artefact over HTTP, follows the root's `available-at`
  to every target. **Deep tier:** a generated `java-library` consumer resolves the coordinate with
  real Gradle (Central, Google and the Plugin Portal declared beside the repository under test) and
  reads the public API out of the jar. **So the deep tier answers for the JVM variant only**; every
  other target's API question is *undetermined*, and it never compiles consumer code, links, or runs.
* *Undetermined* never fails the job — deliberately, so nobody switches the answers off with the
  noise. The price: a check that could not run looks like a check that passed unless the summary is
  read. petich raised its JVM floor to 25 while the action's consumer ran on JDK 21, and all six
  coordinates came back undetermined in a **green** job (petich#11).
* `fail-on: suspicion` counts suspicions **only** — at `d693923` the threshold is
  `count { it.severity == level }`, so that setting would not fail on a defect. Keep the default.
* It can run **before** the upload too: sborka's `check.yaml` points it at a `file://` repository the
  build just wrote, on every pull request, after a proba finding had kept two publishes red unread
  (sborka `367e77e`, `6235e89`).

## Who uses which (at the shas above)

* **proba through `publish-wip.yaml`'s `coordinates:`:** petich, razves, oldge-ui.
* **proba directly in an own workflow:** chronik, kontainer, kompot (six of 34 coordinates, chosen;
  a step fails when no badge was written, so a checker that did not run is red), sborka (pre-merge on
  a local repository, and after every publish).
* **publish-wip without `coordinates:`** — nothing reads the server after the upload: telek, viddik,
  zavarnik.
* **Own read-backs instead:** kafkakn (`ci/publish/*`), kore and mongkn (`curl` of each POM or
  `.module`), bochka (`ci/consume-published.sh`, a fresh project, with a Central-only mode), booblik
  (a `sample` job on the published client).
* **After a Central or Plugin Portal release, nothing runs in CI.** `central.yaml` stops at the
  staged upload; `portal.yaml` publishes outright, and for an approved plugin the version is live when
  the run ends — neither reads anything back. The only Central-side checks so far were by hand:
  petich's native probe with `--repository https://repo1.maven.org/maven2`, bochka's script in
  Central mode, an empty project for viddik 0.4.0.

## The hand-rolled probes

| probe | builds | runs where, when | written to catch |
|---|---|---|---|
| telek `ci/consumer/` | a separate build pinned to the compiler that published; a JVM executable and a **linked** `linuxX64` one; depends on all eight published modules and names their real API | **by hand** — no workflow runs it, although `docs/backlog/B-21-…` says it does | B-18: `apiElements` carried only the stdlib, so the consumer could not write the `@Serializable` the library requires nor name the `CoroutineScope` it takes; B-19: the README's repository block omitted JitPack, which one module needs |
| smtpkn `tools/consumer-check/` | one native executable for the host, **no linker options, ever**; `consumerCheck` links and **runs** it | CI job `consumer` on every pull request, **before** publishing, against a file repository the job wrote | M-110: the published cinterop klib carried no `linkerOpts` and no archives; the repository's own binaries linked, a stranger got `undefined symbol: OpenSSL_version_num` |
| kafkakn `ci/downstream/` | JVM + **linked** `linuxX64` (`linuxArm64` on request); produces 50 records with headers to a real broker, an independent reader counts them | **by hand** (`ci/b-13/run.sh`), cold cache, snapshot repository or a candidate's file repository | B-15: the linuxX64 klib carried bindings without librdkafka's static archives — the suite, the oracle, the publication proof and the gate were all green |
| kafkakn `ci/publish/downstream/` | compiles JVM, `linuxX64` and common metadata against both modules; no link | the manual publish workflow: before upload against `build/local-repo` (six coordinates, file names, **an empty-repository negative control**), after upload with `--refresh-dependencies` and the group purged | "an upload that returned 2xx is not a publication": a `.module` naming an unuploaded variant, a POM under the wrong group, metadata not naming the new version |
| petich `tools/native-consumer-probe/` | one `linuxX64` executable over every module that declares `linuxX64`, derived from the build scripts; **links, does not run** (a Postgres saga run exists, by hand) | CI on every push, **before** publishing, against `mavenLocal`; `--repository <url>` for a release, with Central told `excludeGroup` so last month's release cannot answer | B-02: `No matching variant … 'org.jetbrains.kotlin.native.target' with value 'linux_x64'`; classifies RESOLVED / REFUSED / NOT PUBLISHED; turned red on a source-incompatible API change a green local build missed (B-41) |
| petich `tools/readme-probe/` | splices every ` ```kotlin ` block of the README into a JVM build, against a prelude of declarations only | CI, before publishing | B-45/B-46: eight README examples describing a model the code no longer had |

## What each side catches

| failure | proba | hand-rolled |
|---|---|---|
| a public signature names a type from an `implementation` dependency (JVM) | **yes**, every signature (`api-unreachable`; sborka `367e77e`, petich#7, kompot `5b1dbe3`) | only for the types the probe's source happens to name — telek's fix then found four more modules |
| the consumer must apply something the library needs but hides (`@Serializable`, a compiler plugin) | no — not a type in a signature | telek |
| the root names a target that was never uploaded | **yes**, every target (`dangling-redirect`; razves `cf7c73c`) | only the probe's own targets |
| a declared native target with no variant at all | no | petich (REFUSED vs NOT PUBLISHED) |
| a native klib that resolves and does not link | no | smtpkn (CI), kafkakn, telek (by hand) |
| runtime behaviour, a shared object missing at run time | no | smtpkn runs the binary; kafkakn and petich by hand |
| bytecode newer than the declared floor | **yes** (`bytecode-java-version`, petich#6) | indirectly, when the probe runs on the floor JDK |
| a file named with another version than its coordinate | **yes** (`version-in-declared-name`, kompot#59) | kafkakn and petich audits, locally |
| a module under somebody else's group | **yes** (`component-matches-path`) | — |
| a published module nobody lists | no — the list is written by hand | petich `consumer-coverage-audit.py`; kore reads back by directory |
| the README's install block or examples are wrong | no — its consumer declares its own repositories | telek (repository block), petich readme-probe (examples) |
| an Android consumer silently given the JVM variant | no | **none of the four** — the only guard is on the product side, konekt's `checkAndroidVariants` |
| the check itself did not run | no (a broken `action.yml` failed every caller at "Set up job", proba#10) | kompot's "no badge ⇒ red"; kafkakn's empty-repository control |

## Writing the probe a release needs

Pick by the consumers in step 1e of the skill, not by habit: a library with a native consumer needs
a native probe; one with an Android consumer needs the Android check; one with a README needs the
snippet build.

**A native consumer probe** — the shape all four converged on:

* a separate Gradle build (its own `settings.gradle.kts`, its own wrapper), **outside** the library's
  `settings.gradle.kts`, knowing only the coordinate, the version and the repository URL as
  properties;
* **no linker options, no `cinterop`, nothing copied from the library's build** — smtpkn's says so in
  a comment because the moment one is added the probe tests the library's build file again;
* the repositories a stranger has: the target repository, Central, Google — never `mavenLocal()`
  unless that *is* the target, and the library's group excluded from every other repository so an
  old release cannot answer for the new one;
* a cold cache (`-g "$(mktemp -d)"`, or the group purged) — a warm one answers from yesterday;
* source that names the real public API, then `link…ExecutableLinuxX64` **and run it**: a binary that
  links and fails to find a shared object at start is still a failure a consumer meets;
* a negative control seen once: against an empty repository, or against the version before the fix,
  the probe is red with the message it exists for (petich quotes it in B-02; smtpkn's was red on the
  snapshot before M-110).

**An Android consumer** has no probe in the portfolio yet. The cheapest honest one is konekt's
shape: a build with an Android target that depends on the coordinate and asserts, over
`androidRuntimeClasspath`'s resolved artefacts, that every module of the library arrived as its
`-android` variant and not `-jvm`/`-desktop`. Resolution alone is not the answer — it succeeds
either way.

**The README snippet** compiles against the **published** artefact, not the project: a prelude of
declarations, the ` ```kotlin ` blocks spliced in by marker, `compileKotlin` against the version
being released. kore compiles its README samples inside the build (`samples/readme`), which proves
the code and not the coordinate; kompot checks only that names exist, and says so.

## The check on the check

* Read the summary for a **number**: coordinates checked, a binary linked, records counted. A job
  whose consumer failed to start and a job with nothing to report have the same colour.
* The coordinate list is written by hand beside a set that grows (chronik's workflow says it
  outright); derive it from the local publication, or guard it the way petich does.
* Do not list what proba cannot answer — a version catalog (`versionCatalogElements` only), a ktlint
  rule set (loaded through `META-INF/services`), a Gradle plugin marker (razves dropped them: "red on
  every publish for a reason nobody caused") — and check those by the path that actually uses them,
  as sborka's `publish-snapshot.yaml` does for its catalog and its rule set.
