# What this suite checks

Three cases, each a defect a service hit with a green build and a green suite.

| case | where it comes from |
|---|---|
| `the-id-comes-from-the-path` | the reference project's ownership hole: ownership was checked against the id in the path while the write was addressed by the id in the body, so a `PATCH` to your own record with a stranger's id in the body rewrote theirs — and answered `200` |
| `a-defaulted-lambda-under-singleOf` | the lazily failing binding: a constructor that gained a defaulted parameter stayed registered with `singleOf`, the pod started healthy, `/health` stayed green, and one route answered `500` on its first request. `verify()` does not see a parameter that has a default |
| `a-worker-on-two-replicas` | [konekt](https://github.com/youndie/konekt) B-135: with two instances its outbox relay, which had no claim on a row, published twenty rows as forty records. The change that looks complete is one line in a values file |

## What an expectation is allowed to be

Observable in the files written or in the answer. Several expectations check that a **reason**
is stated, because each of these defects is one where the right code written without its reason
is undone by the next change: the explicit Koin lambda gets "simplified" back to `singleOf`, the
`copy(id = path.id)` reads as redundant.

The third case also checks what the answer does **not** claim. Nothing in the fixture can run two
replicas, so an answer that says the duplicate publish "was tested" has described a hope.

## The fixtures do not build

`setup-fixture.sh` writes sources and no Gradle wrapper. A case that needed a toolchain and a
database would measure the machine it ran on; these are about a decision made while reading code.

## Not run yet

This suite has not been run: there is no baseline, and no evidence yet that an expectation can
fail. Run it once without the skill before trusting a green run with it.

`evals.json` follows the skill-creator shape, as the other suites in this repository do, and is
run by skill-creator's eval loop.
