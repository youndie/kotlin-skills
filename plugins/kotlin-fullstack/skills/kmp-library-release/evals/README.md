# What this suite checks

Five cases, and **every one is a defect a real release or a real consumer hit**, not a behaviour
somebody guessed a model might get wrong. A release is the place where a happy-path expectation is
worth least: the build, the tests and the publish were green in each of these, and the failure
arrived later and somewhere else.

| case | where it comes from (public sources) |
|---|---|
| `the-version-exists-when-the-run-ends` | [kompot](https://github.com/youndie/kompot) publishes every module in one run of several minutes. A consumer bumped as soon as `form-standard:0.6.0.10` appeared and got `Could not find …kompot-registry-annotations:0.6.0.10` — a right version, a right repository, a module not uploaded yet |
| `a-new-module-and-its-coordinate` | kompot `bf4109b`, "put the group in the convention, not in each module": six modules without a `group =` line published under a group derived from the root directory, found by a `PUT` to the wrong path. The 403 half is [kore#56](https://github.com/youndie/kore/pull/56): the snapshot token was scoped to artefact paths, and the fourth module's coordinates were not among them |
| `implementation-hides-the-supertype` | kompot `2706e26`, "advertise what each module's public API actually needs": nine modules declared every dependency `implementation`, and a consumer met `Cannot access class …KompotAction` while every check inside the repository was green |
| `a-half-publish-spends-its-number` | [kore#56](https://github.com/youndie/kore/pull/56) and kore's `docs/backlog/B-48-publish-the-whole-module-set.md`: 0.1.1 stopped on a 403 after three jars, the retry printed three 409s that no longer mentioned the 403, and the number was left as debris; the release went out as 0.1.2 behind a pre-flight that refuses a taken version |
| `a-bump-moves-the-family` | [mani#184](https://github.com/youndie/mani/pull/184): kore 0.1.12 carries `ktor-server-core` 3.6.0 through `api`, Gradle lifted that one module and left the rest of Ktor on 3.5.2, and every `call.receive` failed at runtime with `IrLinkageError` while compile and link were green |

## What an expectation is allowed to be

**Observable.** A line that changed in a build file, a number that was or was not used, a command
proposed, a reason stated. "The release is safe" is not checkable; "the answer does not re-run the
publish under 0.1.1" is.

Several expectations check that a **reason** appears, not only that the action is right. For a skill
whose value is the order of a release and the evidence after each step, an agent that does the right
thing without knowing why — waits for the run but cannot say what a sibling's `Could not find` would
have meant — will skip the step the next time the context shifts slightly.

## The fixtures are a fictional library

`files/setup-fixture.sh` builds "ledger" in the smallest shape in which each decision is real: two
modules where one exposes the other's type, a third module about to be published for the first
time, the log of a publish that stopped halfway, and a service consuming a library that exposes Ktor.
Nothing in them can publish anywhere — the snapshot repository in the log is
`snapshots.example.invalid` — because a case about what to check before an upload must not be able
to perform one. The library publishes under an account-wide group (`io.github.example`) and is not
on sborka's conventions, both on purpose: the first is the shape in which a path-scoped token refuses
a new module, the second makes a release case say what adopting the conventions involves. An unknown
shape exits 2 rather than leaving an empty directory that looks like a fixture.

Run them with `claude plugin eval` against this plugin.
