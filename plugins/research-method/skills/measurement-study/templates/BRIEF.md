# BRIEF — <the question, in one line>

> **Role of this document: what the study decided around its frozen pre-registration.** The
> questions, their green and red, the thresholds, the kill criteria and the budgets are in
> `docs/research/source-brief.md` — the brief as received, or the study's own written from
> `templates/source-brief.md` — and `make check` holds every byte of it. This file carries the record
> of that freeze, the pins, the answers to what was believed, and the amendments: appended, dated,
> with a reason; nothing is edited away.

<!-- Paste here, on its own line, what `python3 scripts/brief_freeze.py --record
docs/research/source-brief.md` prints, and commit it with the frozen file before the first
measurement. Never write that line by hand: the script refuses one without a real digest. -->

**Owner:** <who decides amendments after the window and answers `question` items>
**Window:** open until the first measurement; closed on <date> by <the commit that added the first
file under `logs/`> (B-NN).

## Pins

The placeholders the pre-registration left, resolved before the first measurement and not
re-resolved afterwards. Rows that cannot be pinned yet say so and name the item that pins them.

| Row | Pin | Where it came from |
|---|---|---|
| Toolchain | <version> at tag `<tag>`, commit `<sha>` — a tag is a movable reference | `git ls-remote --tags`, <date> |
| Subject | <repository> at `<sha>`, build options `<…>` | <file:line> |
| Hosts | <subject and generator, or the disjoint cpusets; cores, kernel, `nproc` inside the subject> | probed <date> |
| Generator | <tool and version> | |
| Offered rate | **open** until the weaker arm's knee is measured | B-NN |

## What was believed, answered

| Belief (from the pre-registration) | Answered by | Answer |
|---|---|---|
| <the premise> | B-NN | <address, or "unverified"> |

## Amendments

Made inside the window, before the first measurement. Each says what the pre-registration said,
what changes, the evidence that forced it, and whether it can move a verdict — and if it can only move
one towards green, what is published beside it so that a reader who prefers the original rule gets
that verdict without recomputing. These are held by being appended and by review of
`git log -p BRIEF.md`; the script does not freeze them.

### A1.1 — <title> (<date>, before the first measurement)

<What the pre-registration says. What changes. The measurement elsewhere that motivated it. "No
threshold moves." or "This widens X, which can only move RQn towards green; the original figure is
published beside it.">

## Amendment set 2 — after the window

<Empty, and better left so. An amendment here is made by the owner, says that it is late, fixes an
incoherence rather than an inconvenient number, and is declared before the run it governs; it may
add evidence (more rounds), never relax a threshold to meet a number. A budget extended by the owner
is recorded here too, with the elapsed days still reported.>
