---
name: backlog-item
description: "Take exactly one item from a docs-bootstrap backlog (docs/backlog/B-NN-*.md, the generated index in backlog.md) and carry it to a pull request: pick the next unblocked item by priority, read the feature, screen and endpoint documents as the assignment, branch, implement with the matching skill (contract, server, client screen with design parity, tests), keep the documentation and the item's status in the same change, verify through the real path, open the PR, stop. Built to run under /loop, one item per iteration. Use for 'next item', 'work the backlog', 'take B-12', 'run the loop', 'what is next', or whenever a repository has a backlog and the task is to advance it."
---

# One backlog item, start to pull request

The unit of work is one item; the unit of trust is the pull request it ends in. Under `/loop`
each iteration runs this skill once: pick, do, hand over, stop. Nothing carries over between
iterations except what is committed — a branch, an item whose status changed, a question
written into a file — because the next iteration starts from the repository, not from memory.

```
backlog.md ──► pick (priority, unblocked) ──► the documents = the assignment
      ▲                                              │
      │                                    branch, implement with the matching skill,
      │                                    docs + item status in the same change
      │                                              │
      └──── item done / wip / question ◄──── verify through the real path ──► PR ──► stop
```

Boundaries: the backlog format is `docs-bootstrap` (items are files, the index is generated);
the work itself is the other skills of this plugin, chosen by the item's shape; this skill owns
picking, scoping, and closing.

## Step 0. Orient, from the repository

1. `git status` clean, on the default branch, up to date. A dirty tree is somebody's unfinished
   work, possibly a previous iteration's: read it before touching anything, never stash it away.
2. Read `backlog.md` above the generated block — the goal, the stages, the decisions worth not
   re-litigating — and the repository's agent instructions ("how to start a session").
3. `python3 scripts/backlog_index.py --check` and `make check` green before starting. A red
   gate is a finding, not a starting point: fix it as its own small change or record it as an
   item, but do not build an item on top of it.

## Step 1. Pick one item, by rule

An id given by the user wins. Otherwise, in this order:

1. **Resume** an item whose status is `wip` and whose branch exists — a previous iteration
   stopped mid-way. Read the branch's log and the item's body before continuing.
2. Else the first `open` item by priority (`P0`, `P1`, `P2`, `P3`, `infra`), then by number,
   **whose every `blocked_by` is `done`**. A blocker that is `wip`, `open` or `dropped` still
   blocks.
3. `question` items are never picked; they wait for a person. List them in the report.
4. Nothing pickable → say so, name what is blocked on what, and **end the loop**. An iteration
   that invents work to stay busy is the failure mode this rule exists for.

Say which item was picked and why, in one line, before doing anything else.

## Step 2. The documents are the assignment

Read, in this order, following the ids in the frontmatter:

- the item itself — the decision and its reason, the acceptance criteria, the anchors;
- its `epic` feature document — the **scenarios are the acceptance test**, the business rules
  are the constraints, the quirks are the traps;
- the screen documents the feature lists (`client_entries`) — the state list, the `design:`
  block if there is one, the actions and the navigation;
- the endpoint documents (`calls_api`) — tiers, error codes, the contract source;
- the service documents — how it is built, configuration, quirks;
- `docs/research/research-architecture.md` where it exists — why the architecture is what it
  is, and which hypotheses are still open.

Then the code the anchors point at. If the documents and the code disagree, the code is what
exists and the document is what will be — record the difference in the item's findings and, if
it changes the item, stop and turn the item into a `question` (below) rather than choosing
silently.

**The scope is the item's acceptance criteria and nothing wider.** A defect found on the way is
a new item (`B-<next free>`, from the template, `blocked_by` if it truly blocks) or a line in
the item's findings; a fix folded in unasked is what makes a pull request unreviewable. The
one exception is a change without which the item cannot be verified at all, and then the PR
description says so.

## Step 3. Branch, and leave a trace at once

- Branch from the default branch: `feat/b-<nn>-<slug>` (or `fix/…` when the item is a
  defect), unless the repository's workflow prescribes the docs-first shape
  `feature/<feature-kebab>` — then that name, identical across repositories.
- First commit: the item's status `open → wip`, index regenerated. Work outside git is
  invisible; an iteration that dies before its first commit leaves the next one guessing.

## Step 4. Do the work with the skill the item's shape calls for

| The item touches | Skill | The acceptance it adds |
|---|---|---|
| the wire contract (DTOs, routes, error codes) | `kmp-shared-contract` | both server builds and the client compile against the new `shared` |
| a server route, use case, storage port | `ktor-server-feature` | the feature's scenarios run against the route on JVM and on native |
| a client screen or feature | `compose-client-feature` | the view-model and Content tests; screenshots per state |
| a screen whose document carries `design:` (or whose `design/` references exist) | `design-to-compose` | `viddikDesignParity` within tolerance per artboard, goldens recorded |
| a module, target or build change | `kmp-project-structure` | the build the item names runs |
| any test | `kmp-testing` | placed in the right suite; the test fails when the change is reverted |
| names, abstractions, comments | `kotlin-conventions` | — |

Each of those skills starts with "check the project first"; do that for the item's feature, not
for the whole repository. Follow the repository's own conventions where they and the skill
disagree.

**The documentation is part of the change**, not a follow-up:

- a scenario now covered by a test gets its `**Automated:**` line in the feature document;
- a screen implemented to a design gets its `design:` block filled (canvas, references,
  states), and the parity result goes into the PR, not into the document;
- behaviour that turned out different from the document is corrected in the document, with the
  real status code or error string, in the same commit as the code that produces it;
- a new document's `status: draft` becomes `active` only when the behaviour is real and
  verified; on the default branch a draft is an error;
- the coverage map and the backlog index are regenerated (`make fix`), and `make check` is
  green.

Where the docs-first process applies (a `research/feature-<kebab>.md` in the branch), it is
read first, updated with findings as they appear, and **deleted before the pull request
merges**.

## Step 5. Verify through the real path

"It compiles" and "the unit test passes" are not the acceptance criteria; the item's are.

- Run **what CI runs**, by the same command (`kmp-testing`, "Running"), and read the result
  files' timestamps, not `BUILD SUCCESSFUL` through a pipe.
- Walk the feature's scenarios as a checklist against the running code or the test that
  encodes each one; tick them in the PR body. A scenario that cannot be exercised is not
  ticked, and the PR says which.
- A new test is checked by **mutation**: revert the change, watch it fail, restore.
- A screen: `viddikDesignParity` for its artboards, goldens recorded for that screen only and
  looked at, `viddikVerify` green (`design-to-compose`, Steps 5–6).
- Native builds and real-database suites run where they run (a Linux box, a container), and the
  PR says where they ran.

Bound the iteration. If the item is not finishable in this run — a dependency turned out
missing, a design question, a verification that needs an environment you do not have — commit
what exists on the branch with the item still `wip` and the findings written into it, and
stop; the next iteration resumes at Step 1.1. Three iterations on the same item without a
scenario moving from open to ticked is a `question`, not a fourth attempt.

## Step 6. Close the item, open the pull request, stop

1. Item status → `done` (or `question`, with the question written as the last section of the
   item: what was found, what the choices are, who decides). A refuted hypothesis or a decision
   made on the way goes where it will be read: the research document, the feature's quirks,
   or `backlog.md`'s decisions — not only into the item.
2. Regenerate the index; `make check` green; every anchor in the item and the touched documents
   points at a file that exists.
3. Commit — Conventional Commits, English, the item id in the body (`Refs: B-12`), no tool
   signatures — and open the pull request. Its body is the item's acceptance criteria and the
   feature's scenarios as a ticked checklist, the parity summary for a screen, where the
   suites ran, and what was deliberately left out. Do **not** merge unless the repository's
   instructions say the loop merges.
4. Report in a few lines: the item, the PR link, what moved in the documents, the next
   pickable item (or that none is), and any `question` items waiting for a person.
5. Stop. The loop decides whether there is a next iteration; this skill never picks a second
   item in the same run.

## What not to do

- **Do not pick by feel.** The rule in Step 1 is the whole reason the loop can run unattended;
  an item picked because it looked interesting is an item nobody planned.
- **Do not widen the item.** The backlog is where new work goes; the branch is where the item
  goes.
- **Do not close an item whose acceptance was not exercised.** `done` means the scenarios were
  walked; "implemented" is `wip` with a note.
- **Do not loosen a check to get green** — a tolerance, a skipped test, an `else -> ignore`. A
  check that would fail is a finding for the item or a new one.
- **Do not decide a `question`.** Its point is that a person decides; write the options and
  stop.
- **Do not leave the tree dirty or the item's status stale at the end of an iteration.** Both
  are read by the next iteration as facts.
