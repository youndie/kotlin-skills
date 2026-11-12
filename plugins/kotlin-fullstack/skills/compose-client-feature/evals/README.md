# What this suite checks

Three cases. The first two come from one project; the third is the skill's own central rule,
kept so that fixing the first two cannot quietly cost it.

| case | where it comes from |
|---|---|
| `request-response-screen-has-one-writer` | [shashki](https://github.com/youndie/shashki) sends client work through this skill, and all twelve of its view models are screens with nothing to observe. While the skill named only the derived shape, every one of them came out assigning `_uiState.value = _uiState.value.copy(…)`, nine with `throwable.message` on screen |
| `a-poll-stops-when-the-screen-is-covered` | shashki B-66: the class picker asked for a quote once, so a rider who opened it before any driver was online read *no cars nearby* until a restart. The fix that satisfies only the first half — a loop in `viewModelScope` — goes on asking under the next screen |
| `a-preference-from-another-screen-is-a-flow-in-the-combine` | the derived shape itself. No defect in a public repository is on record for it; it is the control for the other two — a skill that learned the one-writer shape must still derive when there is something to derive from |

## What an expectation is allowed to be

Observable in the files written or in the answer: a construct that is present, one that is
absent, a reason that is stated. Nothing here builds — the fixture has no Gradle wrapper, on
purpose: a case that needed a toolchain would measure the machine it ran on.

Cases 1 and 3 are a pair, and reading one without the other is misleading: an agent that always
writes one `MutableStateFlow` passes the first and fails the third, and one that always writes
`combine` does the reverse.

## Not run yet

This suite was written with the change that added the one-writer shape and has not been run:
there is no baseline, and no evidence yet that an expectation can fail. Run it once without the
skill before trusting a green run with it.

`evals.json` follows the skill-creator shape, as the other suites in this repository do, and is
run by skill-creator's eval loop.
