# Libraries that publish their own way, and why

Six repositories publish snapshots by calling sborka's `publish-wip.yaml`: petich, telek, razves,
zavarnik, viddik, oldge-ui. Most of the others take `io.github.youndie.sborka.publish` and write the
workflow themselves; a few take neither. Each divergence below has a reason written down beside it.
Read it before "fixing" the divergence: some have expired, some have not, and a release is the wrong
moment to find out which. Facts are from each repository's `origin/main` at the sha given (smtpkn's
snapshot read from the repository on 2026-10-02).

## Cannot be released as it stands

| repository | what its own path would do | why it is not executed |
|---|---|---|
| **smtpkn** `a89c6d7` | its own `build-logic` convention applying vanniktech directly; `RELEASING.md` releases to Central by running `publishAllPublicationsToMavenCentralRepository` on two machines, a Linux one and a Mac; the snapshot workflow is two jobs, macOS publishing everything and Linux then the Linux half of the TLS module | **one module from two hosts, and the snapshot already shows the result**: the root of `io.github.youndie:smtp-tls-openssl:0.1.0-SNAPSHOT` lists only `linux_x64` — the second job's root replaced the first's, and the macOS artefacts are unreachable through the root coordinate. A release from a machine is the other half of what the skill forbids. The constraint behind it is real (`:smtp-tls-openssl` is a cinterop that needs each platform's headers), and so is the way out: one host that can build every target, or the module split per platform — a decision for the owner before any release |

## Still diverging, for a reason that holds

| repository | how it publishes | why, in its own words or code |
|---|---|---|
| **kore** `c6d00a4` | none of sborka's conventions: plain `maven-publish` from the root build, `group` set in `subprojects { }`, its own manual `publish.yaml`. It does take sborka's version catalog, by coordinate in `settings.gradle.kts`, for the compiler version | `sborka.publish` is fetched through `pluginManagement`, so a build using it "could not even be configured" without the portfolio's repository reachable — and kore sits underneath that machinery. Its workflow carries what sborka's does not: a pre-flight refusing a taken version, a read-back of every POM, a completeness check by module directory (kore #53, #56, #65) |
| **kafkakn** `bd3193e` | `sborka.publish`, but its own `publish.yaml` instead of `publish-wip.yaml` | it builds the librdkafka C bundle first — which is also why `central.yaml` could not release it today; `ci/publish/preflight.sh` asks the server for every coordinate before any upload (`550a2e0`: the first upload's `403` on `kafkakn-core-jvm` was a half-published version averted only by Gradle's task order); an outside build resolves what was published; then it pushes the tag `v<version>` (B-75: "no overwrite guard exists in sborka's publish convention… whatever refuses a second publish of one version has to be here") |
| **mongkn** `b64795d` | `sborka.publish`, its own `publish.yml`, which computes the version itself (`0.1.<run>` unless given one) beside a `-SNAPSHOT` head kept on purpose | it installs `libmongoc-dev` on the runner — `central.yaml` cannot, so mongkn cannot be released through it today, and its `check` needs four MongoDB topologies (`gate=false` would be required too); it publishes `linuxX64` only, and a macOS runner would publish `macosArm64` under its coordinates; a step reads the published `.module` back and fails if `linux_x64` is missing |
| **kvadrant-ui** `f2d437b` | `sborka.publish`; a fixed `version` published on a GitHub release event | the guard lives in the build, not the workflow: a `doFirst` on **every** `PublishToMavenRepository` targeting `wip` asks for its own POM and refuses with "already published… raise `version`". Twice too narrow before that: on the `publishAll…` aggregate, which `publish` never reaches (`23ddf05`), then on the multiplatform task only, while Gradle ran the Android one first and met the server's `409` (`483a814`) |
| **chronik** `879a1b7`, **kontainer** `4259829`, **kompot** `65d4bec` | `sborka.publish` and their own `publish-snapshot.yaml` with the same steps as `publish-wip.yaml`: `setup-kotlin`, the version (`determine-version`; kompot greps the head itself), the publish, a proba job | no reason written; kompot's adds what `publish-wip.yaml` has no input for — proba badges pushed to a branch, and a step that fails when no badge was written. chronik and kompot release to Central through `central.yaml` |
| **razves** | publishes from a Mac | a cinterop on an Apple target is skipped on a Linux host — any C library, the SDK included — so a Linux publish ships a root that names a target nobody built (`cf7c73c`). That is the one real reason for a macOS runner, and then every target goes from it |
| **kotlin-native-rt** `52a5a93` | not Gradle: `scripts/publish.sh` on a tag, under JetBrains' coordinate | it republishes a patched runtime; nothing about a library's conventions applies |

## Converged — the divergence was removed, and the reason is the lesson

* **booblik** (`c0e5b00`, "reach Maven Central through sborka, not around it"): its own
  `publish-central.yml`, a bundle script and 71 lines of signing and javadoc went. Reason: a personal
  account has no organisation secrets, so a Central workflow per library is a copy of the portal
  token and the signing key in every repository — and the hand-written block collided with the
  plugin the convention guards against. Lesson recorded beside it: the absence of a task in
  `tasks --all` is not the absence of support when a property switches it on.
* **chronik** (`6e5e6a4`): `buildSrc`'s own publishing script went, because `sborka.publish` already
  carried the defect found there an hour earlier — a `kotlin("jvm")` module whose publish succeeds
  and uploads nothing. Then `sborka.central=true` (`c489472`), with every POM dependency checked to
  resolve on Central first.
* **appframe** (`bd240db`) dropped a hand-written vanniktech block for `sborka.central`.
* **mongkn** (`3f6196c`) deleted its `publishing.gradle.kts` for the conventions — its `CLAUDE.md`
  still describes the old file, which is the usual way a divergence outlives itself.
* **telek** removed `sborka.central` after deciding against Central (B-05): "a flag that says this
  repository publishes to Maven Central, in a repository that has decided not to, is a sentence that
  outlives its reason".

## The version head, written twice

Several workflows compute the version themselves instead of calling `determine-version`, and each
copy is a second place for the head to live:

* shildik 0.4.1's sources went out as `0.4.0.20` because the workflow spelled the head itself
  (`b0ea2ff`, "read the version head instead of spelling it twice");
* appframe's `deploy.yml` spelled `0.2.0.<run>` beside the same head in `gradle.properties`, so
  moving the head after the 0.2.0 release took two edits, neither was made, and the builds after it
  went out as `0.2.0.29`–`.30`; it reads the head through `determine-version` since `f448c5c`;
* mongkn's `publish.yml` writes `0.1.<run>` itself, beside a `gradle.properties` head that says
  `0.1.0-SNAPSHOT` — two numbers, and neither is read from the other;
* s3kn's manual workflow passes no `-PVERSION` and overwrites one `0.1.0-SNAPSHOT`, so a consumer
  cannot tell two publishes apart;
* kafkakn shipped six builds as one `SNAPSHOT` before every publish got its own number (`e419edd`).

A copy also misses what the action checks: since sborka
[#125](https://github.com/youndie/sborka/pull/125) `determine-version` refuses a head ending in
`-SNAPSHOT`, which it would otherwise publish as `X.Y.Z-SNAPSHOT.N`, and a key or file that is not
there fails with a line naming it instead of going red silently. The other side of that: a
repository moving onto the action with a `-SNAPSHOT` head is refused on its first run. sborka's
`docs/migration.md` counts seven such heads (bochka, booblik, kachok, mongkn, s3kn, smtpkn, tracy),
so the migration's pull request sets the plain `X.Y.Z` of the next release — or, where the head is
kept on purpose, as mongkn's is, passes the whole version to `publish-wip.yaml` instead.

Since sborka [#133](https://github.com/youndie/sborka/pull/133) the action also refuses a head the
remote has already tagged `v<head>` (asked with `git ls-remote`, since a checkout fetches no tags):
its `X.Y.Z.N` would sort above the release and read as a rebuild of it. The error names the next
patch to set, no version is written, and the `tagged` output names the tag. It was a warning first
([#131](https://github.com/youndie/sborka/pull/131)), until oldge-ui, the last caller whose head
stood on a release, moved it (oldge-ui#14). A remote that cannot be asked is still only a warning.
A copy of the version step checks none of this.

## The group, and the credentials it implies

A per-project group — `io.github.youndie.<name>` — is one path prefix on the snapshot repository,
so one write route covers every module and every target the project will ever add. The account's
group, `io.github.youndie`, is a route per coordinate and a new one per target (kafkakn `064ee21`;
oldge-ui and smtpkn still publish under it and say in their docs that a new target needs the token
re-issued). It is also the namespace form Central verifies. A new library starts with its own group.
