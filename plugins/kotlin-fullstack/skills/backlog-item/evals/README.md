# Evals for `backlog-item`

`evals.json` follows the skill-creator shape: a prompt, the fixture it runs against, and
expectations a grader can check from the transcript and the repository afterwards.

The fixture is docs-bootstrap's own example (a library lending system, three small services,
six backlog items in every status) with its checkers and a `Makefile`, assembled into a
throwaway git repository by `files/setup-fixture.sh <dir> [pick|resume|dirty]`. The three
variants are the three branches of the skill's Step 0–1: a clean pick, a branch left by a
previous iteration, and a dirty tree.

Run a prompt with the skill and once without, on separate fixture directories, then grade both
against the expectations. One run per variant is not a measurement; two or three are.
