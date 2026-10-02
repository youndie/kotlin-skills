# CLAUDE.md — <study name>

<!-- Copy into the study repository as CLAUDE.md (or the file its agent reads). Everything in angle
brackets is filled in; every rule left in place has a defect behind it, named in the
measurement-study skill. Delete a rule only together with the reason it does not apply here. -->

A research study under per-step budgets. One question: <the question>. **<No library comes out of
this repository and nothing goes upstream>** — the deliverables are <a document, its raw logs, a
recipe, a patch set>.

## Where to start a session

1. `docs/research/research-architecture.md` — the evidence this study starts from. Without it the
   items look like "do the obvious thing", and the obvious thing is wrong in <n> places:
   - **<a premise of the brief that turned out wrong>** (§1.x) — <what is true instead, and what
     would go wrong if the brief were followed literally>.
2. `docs/research/source-brief.md` — the pre-registration, frozen: questions, thresholds, kill
   criteria. `BRIEF.md` — its record, the pins, and the amendments, which are the operative text
   wherever they differ from it.
3. `backlog.md` — the queue, the stages, and which item owns each kill criterion.

## The rule that governs everything here

> **A threshold moves before the first measurement or it does not move.**

The amendment window closed on <date> (B-NN). A number that comes in on the wrong side of a line
after that is a result; if a threshold turns out to have been badly chosen, that is a stated
limitation in the write-up, beside the number it affected. Decisions that *would* move a bar go to
the owner as a `question` item and come back as a dated amendment.

## The second rule

> **A green without its positive control is not a green.**

A profiler that resolves nothing, a grammar that puts everything in one bucket, a protocol that
cannot see a difference anybody can see, a harness that never started — all produce exactly the
evidence a pass produces. Every measuring item names a case that must come out a particular way and
shows it doing so in the same log.

## What not to do

- **Do not report a number without the run that produced it.** Every figure has a path into
  `logs/`. A retraction is appended; the original is not edited away.
- **Do not set two numbers side by side without one line saying same host, same run — yes or no.**
- **Do not read rps as a verdict.** <The unit> is the verdict; rps is recorded beside it.
- **Do not take a number without `nproc` as observed inside the subject.**
- **Do not take a measurement outside the harness**, however quick the diagnostic feels.
- **Do not report a difference inside its interval as zero.** It is "below resolution, effect under
  N %", with N stated; one outside it but short of the effect line is reported as measured.
- **Do not publish a null without the lever shown engaged in the measured process.**
- **Do not extend a budget.** A step that overruns is recorded as "not completed" with the reason,
  and the next step starts. An extension by the owner is an amendment with a date.
- **Do not treat this repository's own tools as verdicts.** Print a reader's reconciliation and its
  unattributed rows rather than folding them away.
- **Do not let this become <a library, a plugin, an upstream patch>.** All are non-goals of the brief.
- <a rule this study paid for itself, with the item that paid for it>

## Where the work runs

<Which machine builds, which hosts measure (subject and generator, never the machine that compiles),
and how a run's output reaches the repository.> **A run log is captured by the machine that drives
the run**: `<script> > logs/b-NN/<date>-<what>.log`, the script printing everything to stdout and
keeping no file it needs.

## Pull requests

<Whether the loop merges its own pull requests, stated by the owner on a date, and what does not
change when it does: `make check` green before the merge with its log in the pull request body, an
item `done` only when its acceptance was exercised, a `question` item waiting for a person. The loop
itself is the backlog-item skill.>

## Language

<The language of documents, code, commits and pull requests.>

## Checks

```bash
make check
```

The documentation checks; the freeze — `scripts/brief_freeze.py`, `--history --window logs` and
`--control`; and every reader whose output became a number, run against inputs whose answer is known.
Whatever is not in `make check` is not a gate, and a gate counts only when its run is seen to finish:
a run that never starts or never ends looks exactly like a run that passed. CI runs exactly
`make check` with the whole history (`fetch-depth: 0`); the pull request links the finished run or
carries its log.
