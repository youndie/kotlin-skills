# The snapshot repository: what it refuses, and what a refusal means

The portfolio's snapshots go to one Maven repository (a Reposilite instance). sborka's
`sborka.publish` names it as the `wip` repository, reads its credentials from
`ORG_GRADLE_PROJECT_REPOSILITE_USER` / `…_SECRET`, and `publish-wip.yaml` refuses to start when either
secret arrives empty. Reading is anonymous; writing is not. Everything below was measured by
publishing to it, not read from its documentation.

## Three status codes, three different problems

| answer | what it means | what it is often mistaken for |
|---|---|---|
| `401` | the credentials themselves are missing or wrong | — |
| `403` | the credentials **authenticated**, and the path is not among the ones they may write | "the key is wrong" — re-issuing the same scope changes nothing |
| `409` | that file already exists at that version | a flaky upload, worth a retry |

**`409` arrives on a fixed version even under `/snapshots`.** What makes a version immutable is its
form, not the name of the tree it is in: `0.1.0.7` is a fixed version, and so is `0.1.0`. "Nothing
stops an overwrite in snapshots" was once written into a document and then refuted by a publish.

## Write access is scoped to paths, and every target is its own path

The write token is issued for a list of routes, and a route matches by path prefix with a required
trailing slash: `…/kore-core/` does **not** cover `…/kore-core-jvm/`. So each per-target coordinate
of a multiplatform module needs its own route, and these all arrive as a `403` at the first `PUT`
while the neighbours upload fine:

* **a new module** — kore's fourth module (`kore-booblik`) was refused while the fifteen coordinates
  of the first three went up (kore [#56](https://github.com/youndie/kore/pull/56)); zavarnik's
  `zavarnik-runner` was refused beside the plugin that published, and its classes went into the
  plugin's jar instead of becoming a coordinate;
* **a new target on an old module** — `…-linuxarm64`, `…-iosarm64`: a new directory, a new route;
* **a new group** — appframe's first version under `io.github.youndie` was refused with the same
  token that had written the old group for years.

The cure is to extend the token **before** the publish, with the list derived from the local
publication rather than typed. In a repository on `sborka.publish` that is
`./gradlew publishToMavenLocal -PVERSION=X.Y.Z` and
`find ~/.m2/repository/<group path> -name '*-X.Y.Z.pom'` — the version passed explicitly, or the
tree is `0.1.0-SNAPSHOT`'s; and filtered by it, because `~/.m2` keeps every earlier run. kore, which
registers a directory repository of its own (`localCopy` into `build/published`), re-issued for 19
coordinates derived that way. A hand-written list beside a set
that grows is the defect in a new place — kore's own workflow once published "the three modules
somebody listed" (kore `b2f59bb`).

## A run that stopped halfway leaves a version nobody can finish

A publish writes coordinates one at a time. Stopped after three, it leaves three; the retry hits
`409` on exactly those three and **says nothing about why the first run stopped**. The number is
spent: a version whose `-jvm` files exist and whose root module does not resolves for nobody, and it
cannot be completed. Take the next number.

The pre-flight that makes the second run say the true thing — kore's `publish.yaml`, in outline.
`localCopy` is kore's own repository; under `sborka.publish`, walk `~/.m2/repository/<group path>`
for the version instead (`sborka.publish` registers no directory repository, and
`sborka.snapshotRepository` accepts only http(s)):

```yaml
- name: Produce the publication locally          # nothing over the network yet
  run: ./gradlew publishAllPublicationsToLocalCopyRepository   # a maven { url = build/published }
- name: Refuse a version that already has artefacts
  run: |
    v="${{ steps.ver.outputs.version }}"; taken=0
    for f in $(find build/published -type f \( -name "*-$v.pom" -o -name "*-$v.jar" \)); do
      code=$(curl -s -o /dev/null -w '%{http_code}' "$REPO/${f#build/published/}")
      [ "$code" = 404 ] && continue; echo "$code ${f#build/published/}"; taken=1
    done
    [ "$taken" = 0 ] || { echo "::error::$v already has artefacts - publish a new version"; exit 1; }
```

Seen both ways against the live repository: the spent version is refused by name, the next one
reports free. The same step refuses re-publishing a released version, which would make one
coordinate mean two things. kafkakn runs the equivalent before every publish and tags the commit
with the version it published.

## Merged into `main` is not on the server

A snapshot line publishes when its workflow runs, and some workflows run on a button. s3kn's Apple
targets were merged and never published, because nobody pressed it after the merges; smtpkn's fix
to an unlinkable klib needs a re-publish before a snapshot consumer stops receiving the old one. After a fix that a
consumer is waiting for, check the version the consumer resolves, not the commit on `main`.

## What a local publish proves, and what it cannot

`publishToMavenLocal` (or a directory repository) proves coordinates, variants, file names and the
POM — everything above is checked against it. It cannot prove anything about the server: path scope,
an existing version, an upload that failed. Those are answered only by the server, which is why the
pre-flight asks it and the consumer job reads it after the upload.
