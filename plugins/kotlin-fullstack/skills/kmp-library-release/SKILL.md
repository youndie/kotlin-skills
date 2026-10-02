---
name: kmp-library-release
description: "Cut and verify a release of a Kotlin Multiplatform library or a Gradle plugin: snapshot or release, the pre-flight (a free version number, a coordinate on every module, api versus implementation, the ABI dump on its own host, targets against consumers, the order between our own libraries), publishing through sborka's workflows, never by hand, waiting for every module, checking as a consumer with proba plus the probes it cannot replace (a native link, an Android consumer, the README snippet), the tag naming the built commit, moving the consumers. Use for 'release the library', 'publish to Maven Central', 'cut 0.3.0', 'publish a snapshot', 'the new version does not resolve', 'выпусти библиотеку', 'опубликуй на Central', 'новая версия не резолвится', 'проверь, что опубликовалось'. Not for module layout (kmp-project-structure), tests (kmp-testing) or a service image (native-service-bootstrap)."
---

# Releasing a Kotlin Multiplatform library

This skill is about **getting a version from a green `main` to a consumer that resolves it**: the
order of a release and how to prove each step happened. Where a module belongs and which targets a
library has is [`kmp-project-structure`](../kmp-project-structure/SKILL.md); its tests are
[`kmp-testing`](../kmp-testing/SKILL.md); a C binding and the klib that must carry it is
[`kotlin-native-cinterop`](../kotlin-native-cinterop/SKILL.md); an image whose tag must name a
commit is [`native-service-bootstrap`](../native-service-bootstrap/SKILL.md). The skill ends when the
consumers that should move have moved, or the bump has been handed to Renovate on purpose.

**The mechanism is not here.** The publication, the coordinate, the version and the signatures are
[sborka](https://github.com/youndie/sborka)'s `io.github.youndie.sborka.publish` and its workflows
(`publish-wip.yaml`, `central.yaml`, `portal.yaml`, `determine-version`, `setup-kotlin`); reading the
publication the way a stranger gets it is [proba](https://github.com/youndie/proba). This file says
in which order to use them and what to check after each; **where it and a workflow disagree, the
workflow is right** and the paragraph is stale. Every rule below is a defect that a green build, a
green test suite and a green publish did not show, and most were found by a consumer.

## Step 0. The repository's own release path wins

1. Read `CLAUDE.md`, `RELEASING.md` if there is one, `gradle.properties` (`version`, `sborka.group`,
   `sborka.central`, `sborka.portal`) and `.github/workflows/`. Name, before anything else: the head
   of the version, the workflow that publishes snapshots, the coordinates it publishes, and where
   they go.
2. Several libraries publish their own way, each for a reason
   ([references/divergent-setups.md](references/divergent-setups.md)). **Do not migrate a release
   path in the middle of a release**; a migration is its own pull request, checked by a snapshot.
3. If the repository already has a pre-flight, a read-back or a consumer probe, it is the gate —
   run it rather than the commands below.
4. **The repository's path wins only if it is one this skill would allow.** A path that publishes
   from somebody's machine, or one module from two hosts, is not executed — stop and report it.
   smtpkn's `RELEASING.md` is both: a local upload to Central from two machines, and the snapshot it
   already produces shows the result — the root of `smtp-tls-openssl` lists only `linux_x64`, the
   macOS half unreachable
   ([references/divergent-setups.md](references/divergent-setups.md#cannot-be-released-as-it-stands)).
5. **A library not on `sborka.publish` cannot use `central.yaml`**, which refuses a tree without
   `sborka.central=true`. Taking the conventions (sborka `docs/migration.md`) is a pull request of
   its own, proven by a snapshot, before the release — not a step inside it.

**Checkable fact:** you can write down the version that the next publish will produce, and the list
of coordinates it will write.

## Snapshot or release

| | snapshot | release |
|---|---|---|
| version | the head in `gradle.properties` plus the run number: `0.4.0.81` | `X.Y.Z`, chosen by a person |
| goes to | the portfolio's snapshot repository, readable anonymously | Maven Central (a Gradle plugin: the Plugin Portal) |
| how | the repository's snapshot workflow, on push or a button | a tag, then `central.yaml` / `portal.yaml` dispatched in sborka |
| can be taken back | never overwritten, but nobody outside depends on it | **never** — Central does not rewrite or remove a version |

**A release is needed when a consumer has to resolve the library without the snapshot repository**,
or when a line has to be promised. It is not needed to ship a fix to our own services: they read
snapshots. Two libraries decided against a release and wrote why: telek
(`docs/backlog/B-05-maven-central.md`) and petich (`docs/backlog/B-27-release-0-3-0-before-the-redesign.md`)
— a version on Central cannot be withdrawn, a deferral can be lifted any morning.

**The number says what changed in the publication, not in the code.** A new target or a new module
changes what resolves for whom: chronik went 0.1.0 → **0.2.0**, not 0.1.1, when `linuxX64` arrived
(chronik `docs/backlog/B-18-release-0-2-0.md`). A package rename on the snapshot line is a breaking
change, and the Central number has to say so even if the snapshot head did not.

**Rehearse a release on a snapshot.** Same tree, same publication path, a number nobody has to live
with; every question except "does Central serve it" is answered there (petich
`docs/backlog/B-15-release-order-and-the-first-native-version.md`, rehearsed on `0.2.0.39`).

## 1. Pre-flight — everything that can be refused before the first PUT

A publish is not atomic: it writes coordinates one by one, and whatever it wrote before it stopped
stays. So everything below is checked **before** the first upload, against the same publication
produced locally: `./gradlew publishToMavenLocal -PVERSION=X.Y.Z`, then
`find ~/.m2/repository/<group path> -name '*-X.Y.Z.pom'` is the list the checks walk. **Pass the
version**: without it sborka's fallback (and mongkn's, smtpkn's) is `0.1.0-SNAPSHOT`, a different
tree. `sborka.publish` registers no directory repository of its own; kore's `localCopy` into `build/`
is the cleaner form, because it starts empty and `~/.m2` does not.

**1a. The version number is free, on every repository it is going to.** The snapshot repository
refuses to overwrite a fixed version (`409`), and Central never accepts one twice. A run that fails
halfway therefore **poisons its number**: kore's 0.1.1 stopped on a `403` after three jars were up,
the retry printed three `409`s that no longer mentioned the `403`, and 0.1.1 stayed as four `-jvm`
jars with no root that resolve for nobody (kore [#56](https://github.com/youndie/kore/pull/56),
`docs/backlog/B-48-publish-the-whole-module-set.md`). **GitHub's "Re-run jobs" keeps the run
number**, so re-running a failed snapshot run asks for the very version it just spent (kafkakn
`docs/backlog/B-75-every-publish-gets-its-own-number.md`). kore and kafkakn refuse a version that
already has any artefact before writing one — a `curl` per file of the local tree; kvadrant-ui puts
the same question in a `doFirst` on every publish task. sborka's conventions do not do it for you.

**The head in `gradle.properties` names the next release, never a tagged one.** Left at `0.1.0`
while `0.2.0` is released, the snapshots that follow come out as `0.1.0.N` — sorting below the
release while carrying newer code (chronik raised it first, B-18); left at `0.2.0` after it, they
sort above it ([step 5](#5-the-tag-names-the-commit-that-was-built)). **Where `determine-version`
computes the version, the head is a plain `X.Y.Z`.** The
action puts the run number on the tail of whatever head it reads, so it refuses a head ending in
`-SNAPSHOT` (in any case) and its error names the `X.Y.Z` to set (sborka
[#125](https://github.com/youndie/sborka/pull/125)); before that check kontainer's first publish
went out on a green run as `0.1.0-SNAPSHOT.1` — neither a numbered snapshot nor a release, and not
a Maven snapshot either, which has to *end* in `-SNAPSHOT` (kontainer `e18d6bb`). A `-SNAPSHOT` head
is still the right default for a build that is never given `-PVERSION` (sborka's fallback; mongkn
keeps one so that such a build cannot look like a release); a repository that keeps it for that
reason passes the whole version to `publish-wip.yaml`'s `version` input, and the action does not
run. A workflow that computes the version itself gets no such check
([references/divergent-setups.md](references/divergent-setups.md#the-version-head-written-twice)).
The head lives in one place — a workflow that spells it again published shildik 0.4.1's sources as
`0.4.0.20` (shildik `b0ea2ff`).

**1b. Every module has its coordinate.** `sborka.group` is required and has no default, on purpose:
in kompot six of eight modules once had no `group =` line and went to a group derived from the root
directory — found by a `PUT` to the wrong path after four minutes of green CI (kompot `bf4109b`).
A plain `kotlin("jvm")` module registers no publication of its own; without `sborka.publish` its
`publish` task succeeds and uploads nothing. Then read the local tree: one directory per module and
target, all under the group you expect, all under one version, file names carrying the full version.
A Gradle plugin's **marker** takes its groupId from the plugin id, not from the group — see the
Plugin Portal section. A new library takes a group of its own, `io.github.youndie.<name>`: one path
prefix on the snapshot repository, where the account's group is a path per coordinate (kafkakn
`064ee21`).

**A coordinate that has never been published may be refused by the repository.** The snapshot
repository's write credentials are scoped to artefact paths, and each per-target coordinate
(`…-jvm`, `…-linuxx64`) is its own path: a new module, or a new target on an old one, gets `403` at
its first `PUT` while its siblings upload. List the new coordinates before the publish and have the
credentials extended first ([references/snapshot-repository.md](references/snapshot-repository.md)).

**1c. A type in a public signature is `api`.** With `implementation(project(":core"))`, the
published api variant advertises nothing of `core`; a consumer of the module alone cannot compile a
reference to a supertype the module hands out — `Cannot access class …`. Inside the repository
nothing shows it: `project(...)` resolves anyway. kompot shipped nine such modules (`2706e26`), and
the next one came from **generated** code: a KSP processor made a public property whose type lived
in an `implementation` dependency, and only the consumer job after the upload went red. Before the
publish, read `apiElements` of the module's `.module` file in the local tree; after it, proba's
`api-unreachable` answers the same question from the artefact.

**1d. The ABI dump is taken on its own host, with every target visible.** Where a repository guards
its published API (kompot: `abiValidation { }` per module, `checkKotlinAbi` inside `check`, and a
script that fails when a published module has no guard — `25133a4`), a break that was intended is
an updated dump in the same change. The klib dump records which targets were visible when it was
taken: regenerated on another OS, or on a machine where an optional target was not found, it is
rewritten silently; it also carries the Maven group in each library's unique name, so a group change
is a new dump. Take it where CI checks it, and **see the check fail on a deliberately broken dump**
before trusting a green one: mongkn's ran on neither OS for a while (`9b6dc6d`), and whether
`checkKotlinAbi` is inside `check` depends on the Kotlin version — booblik wires it by hand.

**1e. The targets against the consumers.** The target list is the repository's argument, not a
convention's. Ask who will consume this version and on what: a native consumer of a jvm-only
release fails with `no matching variant` (chronik 0.1.0); **an Android consumer of a library with no
Android target silently gets the jvm variant** — desktop Compose next to Android Compose on one
classpath, compiling and starting (kompot before `7f3647d`). A module that has never been published
has never compiled its common metadata: a type that exists per platform but not in common fails
only at `compileCommonMainKotlinMetadata`, which a sibling consumer in the same build never runs.
**The JVM floor is a target too:** `sborka.jvmFloor` is the oldest Java a consumer may run, and
raising it takes the library away from everyone below — appframe 0.2.0 on a Java 17 consumer is
`No matching variant … Java 21`.

**1f. Our own libraries go out in dependency order.** If this library exposes another of ours
through `api`, that one is released first and this one pins the released version — otherwise its
POM names a coordinate Central does not have: a green upload and a consumer that cannot build.
chronik 0.2.0 went out before petich 0.2.0 for exactly that reason, and the release notes say so.

**Checkable fact:** the local tree holds every expected coordinate, under one group and one version;
each of them answers `404` on the target repository; the dump check is green on the host CI uses.

## 2. Publish through the workflow, never by hand

**Snapshots** come from the repository's own workflow. Where it calls sborka's `publish-wip.yaml`
(six do: petich, telek, razves, zavarnik, viddik, oldge-ui), that is checkout, `setup-kotlin`, the
version from `determine-version`, an optional check step before the publish, the publish, and —
when `coordinates:` is given — a proba job on what the server now serves. chronik, kontainer and
kompot write the same steps out in their own `publish-snapshot.yaml`; the rest are in
[references/divergent-setups.md](references/divergent-setups.md). The caller workflow is in
[examples/workflows.md](examples/workflows.md).

**A release** is a tag and one dispatch:

```bash
git tag -a vX.Y.Z -m "X.Y.Z" <the green commit> && git push origin vX.Y.Z
gh workflow run central.yaml -R youndie/sborka \
  -f repository=youndie/<name> -f ref=vX.Y.Z -f version=X.Y.Z   # konan-cache=true for native
```

The workflow refuses a repository that is not ours and a tree without `sborka.central=true`, runs
`check` on the tree being uploaded, says whether the sources differ from the tag of the same
version, refuses an empty secret by name and a version with a `v`, and **uploads the bundle
staged**. A person opens the deployment on the Central portal, checks the list of files, and presses
Publish; nothing resolves before that, and nothing can be changed after.

Its inputs besides the three above: `runner` (`ubuntu-latest` or `macos-15`), `konan-cache`, and
`gate` (default `true`). `-f gate=false` is for a repository whose `check` needs what a runner cannot
give — mongkn's needs four MongoDB topologies — and then its own CI, green on the tagged sha, is the
gate you read before dispatching. sborka's `docs/conventions.md` says a library needs nothing but
`sborka.central=true`; **that holds only for a build that needs nothing the runner lacks**.
`central.yaml` cannot install a system package or build a C bundle before Gradle: mongkn's cinterop
needs `libmongoc-dev` (`mongkn-core/build.gradle.kts`), kafkakn builds librdkafka first. Such a
library cannot be released through it today — that is a missing input in sborka, not a reason to
publish by hand.

Why not from a laptop: the signing key and the portal token live once, in sborka's secrets; a local
publish is a version built from a tree nobody can name afterwards, with whichever toolchain was
there. **The runner is Linux even with Apple targets** — their klibs cross-compile; what is real is
that a multiplatform module publishes its root and every target **from one host**, or the root
points at variants nobody built. The one reason for a Mac is a cinterop on an Apple target — any C
library, the SDK included — which a Linux host skips while the build stays green: razves's first
publish shipped a root naming a `macosArm64` variant that was not there, and proba answered with the
404 (razves `cf7c73c`). Then everything goes from the Mac
([`kotlin-native-cinterop`](../kotlin-native-cinterop/SKILL.md#8-publishing-the-klib-so-a-consumer-links)).

**Checkable fact:** the sborka run is green, its log says "sources identical to vX.Y.Z", and the
staged deployment lists every coordinate of the local tree — count them.

## 3. Wait for all of it

**A version exists when the run has finished, not when the first artefact answers.** A consumer
bumped on seeing `form-standard:0.6.0.10` got `Could not find …kompot-registry-annotations:0.6.0.10`
— a right version, a right repository, a module not uploaded yet. From outside it is
indistinguishable from a wrong number. Wait for the run (`gh run watch`, or
`gh run list --workflow <file> --json status,conclusion,headSha`), then ask the repository for
**every** coordinate, roots and per-target modules alike. Checking one module, or the last one
alphabetically, proves nothing about the others: the upload order is whatever order Gradle runs the
publish tasks in (kvadrant-ui's guard met the Android task first, `483a814`). A `central.yaml` run
lives in sborka, so its `headSha` is sborka's; what names the library is the run's title, built
from the dispatch inputs — `central youndie/<name> X.Y.Z from vX.Y.Z`, and `portal …` likewise
(sborka [#124](https://github.com/youndie/sborka/pull/124)). Find yours by that title among the
runs created after your dispatch, not with `gh run list --limit 1`, which can be another library
dispatched a moment earlier ([examples/workflows.md](examples/workflows.md)). The title says what
was asked for; whether it happened is the run's conclusion. Runs dispatched before 2 October 2026
are all titled `central`, so an older release's run is still found by its time and the
`uploading youndie/<name> X.Y.Z` line in its log. On Central, after Publish, the files reach
`repo1.maven.org` within minutes (about ten for appframe 0.2.0); `maven-metadata.xml` of each
artefact listing the version is the answer, not the portal's status.

A workflow that publishes in two jobs is two halves — both have to be green. And a list of
coordinates typed into a workflow is a list that misses the module added last: kore 0.1.0 went out
without `kore-booblik` (`b2f59bb`), and bochka's first tag published one module whose POM named four
that were not there (`0052b60`). Derive the list from the local tree.

**If the run stopped halfway, do not re-run it under the same number** — and "Re-run failed jobs" is
the same number. Read the first failure, not the last: a `403` is the credentials' path scope, a
`401` the credentials themselves, a `409` a number already taken. Fix the cause, take the next
number, and let the debris stay — nothing resolves a version without its root.

## 4. Verify as a consumer

Nothing inside the build that published a library can tell you what a stranger receives. Two kinds
of check do, and they answer different questions.

**proba reads the publication from the other side of the wire.** Six checks: the file a consumer
receives carries the version (`version-in-declared-name`), every target the root points at is there
(`dangling-redirect` — a half-published module), the module document agrees with its path
(`component-matches-path` — a module that inherited somebody else's group), the api variant covers
the siblings the runtime gets (`api-omits-sibling`), every type the public API hands out is nameable
by a consumer (`api-unreachable`), the bytecode's Java is one the metadata admits
(`bytecode-java-version`). Snapshots get it from `publish-wip.yaml`'s `coordinates:`. It also runs
**before** the merge against a `file://` repository the build just wrote — sborka does that since a
`kotlin.Pair` in a public signature kept two publishes red unread (sborka `367e77e`, `6235e89`).
**After a Central release nothing runs it for you**: `central.yaml` stops at the staged upload, so
point a `uses: youndie/proba@main` step at `https://repo1.maven.org/maven2` once the files arrive
([examples/workflows.md](examples/workflows.md)).

**What proba cannot see**, by construction: its confirming tier is a `java-library` consumer, so it
answers for the JVM variant and reports every other target as *undetermined*; it compiles no
consumer code, links no binary and runs nothing. The hand-rolled probes exist for those gaps, and
each was written after a defect proba could not have reported:

| probe | what it does that proba does not | caught |
|---|---|---|
| smtpkn `tools/consumer-check` | links **and runs** a native binary with no linker options of its own, in CI, before publishing | a cinterop klib that resolved and did not link (`undefined symbol`) |
| kafkakn `ci/downstream` | links and runs JVM and `linuxX64` binaries against a real broker (by hand) | static archives missing from the published klib, with every internal gate green |
| petich `tools/native-consumer-probe` | resolves every module that declares `linuxX64` and links; tells "not published" from "no matching variant" | a native target declared and absent; a source-incompatible API change |
| petich `tools/readme-probe` | compiles every README ` ```kotlin ` block against the artefact | eight examples describing a model the code no longer had |
| telek `ci/consumer` | names the real API from outside, copies the README's repository block (by hand) | a required `@Serializable` the consumer could not apply; a repository the README omitted |

**No probe in the portfolio covers an Android consumer**, the one that silently gets the JVM variant.
The comparison in both directions, the rules all four probes converged on, and how to write the
missing one: [references/consumer-probes.md](references/consumer-probes.md).

Three rules about the consumer check itself:

* **It must be seen to run.** A broken byte in proba's `action.yml` failed every caller at
  "Set up job", and kompot's consumer check stayed silent while artefacts kept going out (proba
  [#10](https://github.com/youndie/proba/issues/10); kompot `2dcc16f`, `e5520f7` — now a missing
  badge fails the job). And *undetermined* never fails: when petich raised its JVM floor above the
  checker's JDK, all six coordinates came back undetermined in a green job
  ([petich#11](https://github.com/youndie/petich/issues/11)). Read the summary for a count, not a tick.
* **Do not hand it a question it cannot answer.** A version catalog, a ktlint rule set, a plugin
  marker: sborka and razves left them out of the list and check them by the path that uses them.
* **A real consumer beats a synthetic one.** petich's release rehearsal built two services that
  depend on it against the candidate — and found that `./gradlew build` came back green in thirty
  seconds with 999 tasks up to date: **a green incremental build is a claim about Gradle's inputs,
  not about the dependency that changed**. Run the consumer's tests with `--rerun-tasks`, or read the
  test reports' dates.

**Checkable fact:** proba's summary names every published coordinate with zero defects and no
*undetermined* you cannot explain; the probe for each non-JVM target a consumer uses resolved from
the **target repository only** (for a release: Central and Google, no snapshot repository, no
`mavenLocal`, the group excluded elsewhere), linked and ran; the README snippet compiled.

## 5. The tag names the commit that was built

**Merged is not released.** A fix in `main` reaches nobody until a publish runs from a tree that has
it. The case on record is an image — katcher's chart and docs cited an allocator setting that no
published image carried, because the last publish predated the merge, and one question to the
artefact, not to a log, said so — and a library has the same gap between `main` and the version a
consumer resolves. So:

* the tag is pushed **before** the release and the release is built **from the tag** (`ref=vX.Y.Z`),
  so the tag and the tree are one by construction. The exception is a tag older than the repository's
  ability to publish — bochka's `v0.6.0` predated `sborka.central`, so 0.6.0 went out from `main`
  and the workflow diffed the sources against the tag (`9c86fd9`). That diff only **warns**: read it;
* **right after the tag, the head moves to the next patch**, `X.Y.(Z+1)`, in the first change merged
  after it. Maven's ordering, which Renovate follows, puts `X.Y.Z.N` above `X.Y.Z`: a build under
  the old head outranks the release and reads as a rebuild of it — appframe's stayed at `0.2.0`, and
  a consumer on `0.1.26` was offered `0.2.0.30`, two commits past the release (appframe `f448c5c`).
  A snapshot still outranks the release for a consumer that sees its repository — `X.Y.(Z+1).N`
  too — but its number now says it came after;
* **a tag is never moved, and a version is never re-published under it.** The clearest case is an
  image rather than a library, and the rule is the same: katcher's `0.8.1` had been built before the
  fix it was supposed to carry, and it shipped as `0.8.2` because "republishing 0.8.1 would give the
  same tag two meanings" (katcher `809a27f`). For a library the repository decides it for you —
  a second `PUT` of a released version is a `409`, "the fix is a new tag rather than a retry"
  (bochka `f097e5c`);
* the GitHub release names the version, the tag, the sborka run (it runs in sborka's Actions tab,
  not the library's) and the order relative to our other libraries when there is one;
* a snapshot line that tags every publish (kafkakn tags `v<version>` per run) keeps the same rule:
  the tag is written by the run that built it.

**Checkable fact:** `git rev-parse vX.Y.Z^{commit}` is the commit the sborka run checked out, the
fix you are releasing is in `git log vX.Y.Z`, not only in `git log main`, and the first snapshot
after the tag is `X.Y.(Z+1).<run>` (`determine-version` logs `version is …`), not `X.Y.Z.<run>`.

## 6. Move the consumers — or hand them to Renovate on purpose

Find who takes the library (search the portfolio for its group in catalogs and build files, and for
nested builds with their own `settings.gradle.kts`: a repository can contain its own consumer that
pins a **published** version). Then for each:

* **A bump moves the graph, not one line.** kore's `kore-ktor` carries `ktor-server-core` through
  `api`; bumping kore in mani lifted that one Ktor module to 3.6.0 and left `content-negotiation` on
  3.5.2. It compiled and linked; every `call.receive` failed at runtime with `IrLinkageError`, caught
  only by a test that sent a request on `linuxX64`
  ([mani #184](https://github.com/youndie/mani/pull/184)). Before merging, read
  `dependencies --configuration <target>CompileKlibraries` (or `runtimeClasspath`) for ` -> ` inside
  the family the library exposes, and move the family together.
* **A coordinate or package rename is an import rename**, which is a formatter run, and a consumer
  nested in the library's own repository moves with the version bump, not with the rename.
* **The consumer's own tests prove the bump**, on the target that consumes the library — the native
  half when the library has one.
* **Renovate sees what its file parser sees.** It does not execute sborka's settings plugin, so where
  `mavenCentral()` arrives only through that plugin, Central artefacts are looked up nowhere — mani's
  Dependency Dashboard listed about seventy "Failed to look up" packages while its pull requests
  looked normal. Read that block before saying "Renovate will bring it". And a consumer pinned to a
  snapshot `X.Y.Z.N` is not offered `X.Y.Z`, which sorts below it — that move is a person's.

**Checkable fact:** each consumer that should move has a merged change whose CI ran its tests on the
consuming target, or an open Renovate pull request you have seen.

## Gradle Plugin Portal

**The Plugin Portal is the default for a Gradle plugin**: `plugins { id("…") version "…" }`
resolves through it with nothing declared, while a plugin on Central needs `mavenCentral()` in every
consumer's `pluginManagement` (viddik takes that route and says so in its README). The repository
applies `com.gradle.plugin-publish` itself — with `website`, `vcsUrl` and `tags` per plugin — sets
`sborka.portal=true`, and is published by `portal.yaml` in sborka, which runs
`publishPlugins --validate-only` before the upload. What differs from a library, each found on
zavarnik's first release ([references/gradle-plugin-portal.md](references/gradle-plugin-portal.md)):

* **nothing is staged.** `portal.yaml` publishes; for an approved plugin the version is live the
  moment the run succeeds and cannot be replaced. The irreversible step is the dispatch, so the
  look a person gives a Central deployment comes **before** it here: the tag, the tree, the version;
* **the first version of a new plugin waits for a manual approval** at the portal, usually days; the
  run is green because it uploaded, and the id resolves for nobody until the approval;
* **the marker's groupId is the plugin id**, so moving `sborka.group` does not move the marker — a
  group migration moves the id too, which changes the consumer's `plugins { }` line (viddik);
* `--validate-only` needs the key, so the portal's metadata checks first run on the real run.

**Checkable fact:** `https://plugins.gradle.org/plugin/<id>` lists the version, and an empty build
with only `gradlePluginPortal()` applies it.

## What not to do

* **Do not publish to Central or the Plugin Portal from a machine**, and do not use
  `publishAndReleaseToMavenCentral`: a person looks at what becomes permanent — at the staged
  deployment for Central, before the dispatch for the Portal, where nothing is staged.
* **Do not re-run a failed publish under the same number.** The second run's error is about the
  first run's leftovers.
* **Do not bump a consumer on the first artefact** you see; wait for the run, then check every
  coordinate it takes.
* **Do not resolve a jar-name collision with `duplicatesStrategy`.** Two modules called `core` or
  `agent` at one version put two different files under one name in a distribution's `lib/`;
  dropping one turns a build failure into a `NoClassDefFoundError` in production. Name the artefact
  after the library (`katcher-core`).
* **Do not take a macOS runner because the library has Apple targets.** Take one only when a
  cinterop runs on an Apple target (any C library, the SDK included), and then publish every target
  from it.
* **Do not trust a check that has never failed** — a pre-flight, a read-back, a consumer job, an ABI
  guard. Each was added between releases at some point and first ran on the next one; break it once
  on purpose and watch it go red.
