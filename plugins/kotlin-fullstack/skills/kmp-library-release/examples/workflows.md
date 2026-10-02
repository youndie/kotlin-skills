# Workflows: a snapshot line, a release, the check after it

Three pieces. The first is trimmed from oldge-ui's `.github/workflows/publish.yaml`; the second and
third were written for this repository around sborka's `central.yaml` and proba's action, in the
shape the portfolio's libraries use them. None of them is a template to copy blind: Step 0 of the
skill — the repository's own release path wins — applies to each.

## 1. A snapshot on every push to `main`, through `publish-wip.yaml`

```yaml
# .github/workflows/publish.yaml — the library's side. Everything else is sborka's reusable workflow:
# checkout, setup-kotlin, the version from determine-version (head + run number), the check, the
# publish, and the proba job on what the server now serves.
name: publish

on:
  push:
    branches: [ main ]
  workflow_dispatch:

jobs:
  publish:
    uses: youndie/sborka/.github/workflows/publish-wip.yaml@main
    with:
      # Linux unless the build needs Apple tooling for its own reasons (oldge-ui's goldens are a claim
      # about the Mac's rasteriser). Apple klibs cross-compile on Linux. Either way: ONE host for the
      # root and every target.
      runner: ubuntu-latest
      konan-cache: true
      # In a step of its own, before the publish: the publish is the step that cannot be taken back.
      check: check
      tasks: publishAllPublicationsToWipRepository
      test-results: true
      # `group:artifact`, no version — the workflow appends the one it produced. The root of a
      # multiplatform module is enough for resolution: its metadata sends Gradle to the target. Every
      # PUBLISHED module, though — this list is written by hand beside a set that grows, and a module
      # missing here is a module nobody reads after the upload.
      coordinates: |
        io.github.example.ledger:core
        io.github.example.ledger:standard
    # By name, never `secrets: inherit`: this hands them to a workflow in another repository.
    secrets:
      REPOSILITE_USER: ${{ secrets.REPOSILITE_USER }}
      REPOSILITE_SECRET: ${{ secrets.REPOSILITE_SECRET }}
```

What the caller still has to bring, because `publish-wip.yaml` does not do it today: a pre-flight
that refuses a version already on the server, when the line can ever re-publish a number
([references/snapshot-repository.md](../references/snapshot-repository.md)), and any non-JVM consumer
probe ([references/consumer-probes.md](../references/consumer-probes.md)).

## 2. A release to Maven Central

```bash
# 0. The pre-flight of the skill's step 1 is done, on the tree the local publication produced:
./gradlew publishToMavenLocal -PVERSION=X.Y.Z          # without -PVERSION: 0.1.0-SNAPSHOT
find ~/.m2/repository/io/github/example/ledger -name '*-X.Y.Z.pom' | sort   # the list, below

# 1. The tag names the commit that will be built — the green head of main, by sha.
git tag -a vX.Y.Z -m "X.Y.Z" <sha> && git push origin vX.Y.Z

# 2. One dispatch, in sborka, where the signing key and the portal token live. The dispatch is
#    asynchronous and the run's title names no library, so `gh run list --limit 1` straight after
#    it can be the previous run — somebody else's library. Find it by time, then by its log.
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh workflow run central.yaml -R youndie/sborka \
  -f repository=youndie/<name> -f ref=vX.Y.Z -f version=X.Y.Z \
  -f konan-cache=true                       # only if the build has Kotlin/Native targets
run=""
until [ -n "$run" ]; do sleep 5
  run=$(gh run list -R youndie/sborka --workflow central.yaml --event workflow_dispatch \
    --json databaseId,createdAt -q "[.[] | select(.createdAt >= \"$since\")] | last | .databaseId // empty")
done
gh run watch -R youndie/sborka "$run" --exit-status
gh run view -R youndie/sborka "$run" --log | grep -F "uploading youndie/<name> X.Y.Z"   # yours, or stop

# 3. A person: the deployment on the Central portal → read the file list → Publish.
# 4. Wait for the files, every coordinate, not the first one.
for a in core core-jvm core-linuxx64 standard standard-jvm standard-linuxx64; do
  printf '%s ' "$a"; curl -s "https://repo1.maven.org/maven2/io/github/example/ledger/$a/maven-metadata.xml" \
    | grep -c "<version>X.Y.Z</version>"
done
```

The list in step 4 is the local tree's (the `find` in step 0), not a list typed from memory: a
coordinate missing from it is a coordinate nobody checks. `headSha` of that run is sborka's commit,
not the library's — what was built is the `ref` you passed, and the run's "sources identical to
vX.Y.Z" line says how it relates to the tag.

## 3. The consumer check after a release

```yaml
# .github/workflows/release-check.yaml — run by hand once the files are on repo1.
name: release-check
on:
  workflow_dispatch:
    inputs:
      version: { description: "X.Y.Z, without the v", required: true, type: string }

jobs:
  jvm:
    runs-on: ubuntu-latest
    steps:
      - uses: youndie/proba@main
        with:
          repository: https://repo1.maven.org/maven2      # the default; said out loud on purpose
          coordinate: |
            io.github.example.ledger:core:${{ inputs.version }}
            io.github.example.ledger:standard:${{ inputs.version }}
          fail-on: defect
          # One SVG per coordinate, written before anything is decided — which makes its absence
          # the sign that the checker never ran (kompot's publish-snapshot.yaml, after proba#10).
          badge-dir: badges
      - name: The checker ran, for every coordinate
        if: always()
        run: |
          n=$(ls badges/*.svg 2>/dev/null | wc -l)
          echo "badges written: $n of 2"
          [ "$n" -eq 2 ] || { echo "::error::the consumer check did not run for every coordinate"; exit 1; }

  native:
    # The half proba cannot answer: a binary linked from the published klibs, with ONLY the
    # repositories a stranger has — no snapshot repository, no mavenLocal.
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: youndie/sborka/.github/actions/setup-kotlin@main
        with: { konan-cache: "true" }
      - run: ./gradlew -p ci/consumer linkDebugExecutableLinuxX64 runDebugExecutableLinuxX64
          -PledgerVersion=${{ inputs.version }} -PledgerRepository=https://repo1.maven.org/maven2
```

Read both summaries for counts — coordinates checked, a binary linked and run — not for a green
tick: a consumer job that fails at "Set up job" or checks nothing looks the same from the run list
as one that passed. The badge step turns the first of those into a red job; *undetermined* findings
still pass it, so the summary is read regardless.
