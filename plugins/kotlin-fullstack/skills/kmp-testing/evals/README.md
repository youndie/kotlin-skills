# What this suite checks

Three cases, each a test — or a recording — that was green while guarding nothing.

| case | where it comes from |
|---|---|
| `a-state-behind-stateIn-is-collected` | a `stateIn(WhileSubscribed)` state does nothing until somebody collects it, so `uiState.value` read after construction is the initial value forever. A test written that way passes whatever the view model does |
| `a-record-after-a-copy-change-is-forced` | [haul](https://github.com/youndie/haul) B-84: since viddik 0.6 a record writes only what a verification would reject. Twenty-four goldens went on showing text the code no longer drew — each change a word or a glyph, a few hundred pixels on a full page, under the tolerance |
| `a-storage-test-reads-the-raw-row` | everything that breaks in storage breaks silently: an amount written as text is stored without complaint, and a test that reads it back through the same repository reads it the same wrong way |

## What an expectation is allowed to be

Observable in the test that was written or in the commands that were named. No case runs
anything: the fixtures have no Gradle wrapper, and the second case is about a command and its
reason rather than about pixels.

The second fixture carries a `tolerancePercent = 0.3` with a plausible comment. It is bait in
one direction only: the expectation is that the answer reads it as the reason a plain record
writes nothing, and does not widen it.

## Not run yet

This suite has not been run: there is no baseline, and no evidence yet that an expectation can
fail. Run it once without the skill before trusting a green run with it.

`evals.json` follows the skill-creator shape, as the other suites in this repository do, and is
run by skill-creator's eval loop.
