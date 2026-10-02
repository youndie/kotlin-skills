---
name: measurement-study
description: "Run a time-boxed study, spike or measurement campaign so its verdicts survive review: pre-register questions, thresholds, kill criteria and per-step budgets before the first number (frozen by scripts/brief_freeze.py), pin the stand, prove every harness can fail with a positive control, measure by protocol (interleaved arms, a ruler, the generator off the subject's cores, CPU per request rather than rps), keep raw logs as the deliverable, write one verdict per question: green, grey, red or not measured. Also for one measurement inside a product backlog item. Use for 'spike', 'research study', 'benchmark this', 'A/B the build', 'is it faster', 'soak test', 'проведи исследование', 'спайк', 'замерь', 'сравни варианты', 'бенчмарк', 'нагрузочный прогон'. Not for the documentation tree (docs-bootstrap), working a backlog one pull request at a time (backlog-item), or picking a server engine from numbers already measured (kmp-project-structure)."
---

# A measurement study: the questions are fixed before the numbers

A study is bounded work whose output is a **verdict per question**, not code: a spike ("what is
instrumentation PGO worth on a service binary"), a research brief with arms and thresholds, a campaign before a
decision ("which allocator ships"), or one number a backlog item needs. They fail the same way:
the number is right and the sentence beside it is not. The threshold moved to meet the number, the
harness never sent a request, two columns came from two machines, the null was measured over a
lever nobody connected. This skill is the method that makes those failures visible while they are
cheap.

It is distilled from four studies run on one skeleton — the public
[pgo-native-spike](https://github.com/youndie/pgo-native-spike) and three private ones, not named
here — and from the measurement protocols of public product repositories: xyk (two hosts), zavarnik
(the unit and its instrument), bochka, booblik, kesh, konekt, kafkakn, screenshot-bench. Every rule
has a defect behind it; where the defect is public, its address is given. Addresses are
`repo@sha:path` at the commits listed in [references/sources.md](references/sources.md).

**Where it ends.** The documentation layers a study writes into — `docs/research/`, the
file-per-item backlog, its index and checks — are [docs-bootstrap](https://github.com/youndie/docs-bootstrap)'s
format; this skill says what goes into them, not how they are shaped. Working the study's backlog
one item per pull request under `/loop` is `backlog-item`, unchanged; this skill adds what an item
that **measures** must show before it is `done`. Choosing a server engine from numbers already
measured is `kmp-project-structure`; measuring a question those numbers do not answer is this
skill. For Kotlin/Native memory under a container limit, `native-service-bootstrap` carries the
platform half.

**A mechanism compels, this file describes.** The freeze of the pre-registration is a script,
[scripts/brief_freeze.py](scripts/brief_freeze.py), because it was the one rule here that three
studies already enforced by code — in three diverged copies. Where the script and this text
disagree, the script is right.

```
docs/research/source-brief.md: questions, thresholds, kill criteria, budgets — frozen (make check)
   │  BRIEF.md: the record, pins, amendments until the first measurement ──► window closes
   ▼                                                                            ▼
stage 0: pins, the ruler, the generator's ceiling, the controls ──► one item per question ──► logs/b-NN/
                                                                                                  │
                     results: a verdict per question, every number with a path into logs/ ◄──────┘
```

## Step 0. The project's own conventions win

1. Read the repository's `CLAUDE.md`, `BRIEF.md`, `docs/research/research-architecture.md` and
   `backlog.md`. In a study that already runs, **the pins and amendments in BRIEF.md are the
   operative text** wherever they differ from the brief as received, and its rules are followed
   as written; this skill is for a study about to start, or one whose rules are missing.
2. **Measure through the harness the repository already has, never beside it.** Its refusals are
   mistakes already paid for: xyk's `bench/run.sh` refuses to time anything with the generator on
   the subject's cores, because a dozen hand-run diagnostics had to be thrown away — each felt like
   a quick check, and the rule lived in a file header a quick check never reads
   (xyk@471cb39:bench/run.sh).
3. Decide the form. **A study** has its own repository, a brief, a backlog and a deadline. **A
   measurement inside a product item** uses the item's acceptance criteria as its pre-registration
   (see the section near the end). The rules are the same; the freeze is the study's.

Checkable: you can state the question, the owner, the budget, and where the verdict will be written.

## Step 1. Pre-register, before the first number

**What decides a verdict is frozen**: the questions, their green and red, the thresholds, the kill
criteria, the budgets. It lives in `docs/research/source-brief.md`, below the marker line, byte for
byte. A brief received from someone else goes there exactly as it arrived; a brief the study writes
itself is [templates/source-brief.md](templates/source-brief.md), filled in, and goes there the day
the study starts. What the frozen text must hold:

- **research questions** `RQ0…n`, each with a green and a red condition written as observable
  facts. **Anything that is neither green nor red is grey**, and the results say which condition it
  missed — no run falls between (pgo-native-spike@7bd8918:docs/research/source-brief.md);
- **the effect threshold** with its unit, and the resolution rule: an effect counts only if it is
  distinguishable **and** clears a floor **and** twice the ruler (Step 3, Step 5);
- **kill criteria**, each owned by a backlog item. A stop is written up with the same care as a result;
- **budgets per step**. An overrun is recorded as "not completed", with the reason, and the next
  step starts;
- **arms and controls**: every arm from the same source and flags except the ones named, plus an
  arm that separates "the lever worked" from "any rebuild moves the number" — pgo's A4 applied a
  profile from an unrelated workload;
- **the believed-and-unchecked list** and **predictions**, so the results confirm or refute them
  instead of explaining them afterwards; **non-goals**, including "no library comes out of this".

[templates/BRIEF.md](templates/BRIEF.md) holds the rest: the record line, the pins, the answers to
the believed list, and the amendments. The freeze is three lines in `make check` and one in CI:

```bash
python3 scripts/brief_freeze.py --record docs/research/source-brief.md  # once: the line BRIEF.md carries
python3 scripts/brief_freeze.py                          # make check: still those bytes
python3 scripts/brief_freeze.py --history --window logs  # make check: never re-recorded, frozen before logs/
python3 scripts/brief_freeze.py --control                # make check: each rule can fail
# CI: actions/checkout with fetch-depth: 0 — the history check refuses a shallow clone
```

Why bytes and a script rather than "we did not edit it": pgo's freeze rested on a digest in prose and
the received file in somebody's downloads folder until an item moved the text into the repository; a
copy embedded in BRIEF.md with demoted headings could not be hashed as it stood, and a tidying edit
could move it (pgo-native-spike@7bd8918:BRIEF.md, "The brief as received"). Why `--history` in the
gate: the plain check passes a text edited together with its record in one commit. Copy the script
into `scripts/`, keep `docs/research/source-brief.md -text` in `.gitattributes`, and merge study
branches rather than squash them — a squash keeps no trace of an edit made and undone on the branch.
A study that adopts the script after it began — the frozen file committed earlier, its digest kept in
prose or in a copied script — records with `--record PATH --since <the commit that added those
bytes>`: `--history` checks the bytes from that commit and closes the window there, so a freeze that
came first can show it, and one that did not is reported rather than re-dated.

**The window.** Amendments are allowed until the first measurement — appended to BRIEF.md, dated,
each with the evidence that forced it; nothing is edited away. Then the rule three of the four
studies state first and the fourth enforces through its window:

> **A threshold moves before the first measurement or it does not move.**

After that, a number on the wrong side of a line is a result, and a badly chosen threshold is a
limitation written beside the number it affected. The amendments are protected by that convention
and by review of `git log -p BRIEF.md`, not by the script. Two refinements, both from pgo's BRIEF.md:

- **An amendment that can only push a verdict towards green may not stand alone.** Widening the
  "Kotlin code" bucket from `kfun:` to every `k…:` prefix was right, and the `kfun:`-only figure is
  published beside it, so a reader who prefers the literal rule gets its verdict without recomputing
  (A1.3).
- **A late amendment exists, and it is narrow**: made by the owner, saying that it is late, fixing an
  incoherence rather than an inconvenient number, declared before the run it governs. pgo's
  thresholds had been sized against a 5 % bar before the ruler existed; at the measured ±4.64 %,
  "twice the ruler" was 9.3 %, which no green ceiling could reach. No threshold was relaxed: the bar
  fell to the brief's own 5 % floor because eight counted rounds narrowed the ruler to ±2.44 % — a bar
  lowered by adding evidence (amendment set 2). Raising the round count after a number is seen lowers
  the bar too, which is why B-03 left it to the owner rather than deciding it inside the item.

Checkable: `docs/research/source-brief.md` holds every question, threshold and kill criterion below
its marker; BRIEF.md carries its record; `make check` runs all three freeze lines and is green.

## Step 2. Pin the stand, and check what is believed

Fill the pins table: every row a value **and where it came from**.

- **A tag is a movable reference**: pin the commit beside it.
- **An arm is known by its bytes, not by its name**: record each arm's binary digest and compare
  it with the baseline's before the run. A flag the toolchain ignores builds the same bytes — an
  unknown `-Xbinary` option is only a warning on Kotlin/Native — and the "arm" measures the baseline
  against itself (kesh@0ff8899:docs/services/bench.md §3).
- **The commit inside the binary.** A binary that answers `commit: unknown` cannot be tied to its
  numbers (pgo B-19 stamped it in).
- **The host, as the subject sees it**: cores, kernel, and `nproc` *inside* the subject. The same
  binary on the same four cores of CPU, as a quota, held 3 871–3 954 rps; as a cpuset it gave 355–816
  once the generator was pinned away. The first version of that table read 42–378 — "up to ninety
  times" — because the generator was sharing the subject's cores (xyk@471cb39:docs/research/research-architecture.md
  §1.18 and its correction).
- The generator and its version, the subject's build options, the data set, the offered rate's rule.

**Then answer the believed-and-unchecked list.** An inherited fact is a hypothesis with somebody
else's address. xyk inherited "`-Xallocator=std` measured worse on a service with SQLite on the
request path"; on xyk it was the only arm that survived the declared limit at all
(xyk@471cb39:docs/research/measurements-2026-09-16/allocator-decision.md). Grep a quoted sentence at
its address before citing it: pgo's brief credited "the two-host protocol" to a phase that had run
the generator and the subject on one box in every configuration, including the one it called pinned
— the protocol was xyk's (pgo BRIEF.md A1.2; zavarnik@4fd354d:docs/research/research-engines.md §1.1).

Checkable: no pin row without a source; every believed item answered with an address, or marked
unverified with the item that will verify it.

## Step 3. Build the stand, and prove it can fail

Before two arms are compared, the stand earns the right to compare them. In this order:

1. **The generator's ceiling**, per endpoint: offered against delivered against dropped, until it
   strains. xyk's pair offered 8 000 rps with none dropped and strained at 16 000, so nothing seen
   below that belongs to the stand (xyk@471cb39:docs/research/measurements-2026-09-15/throughput-pilot.md).
2. **The ruler**: the baseline against itself, interleaved, with as many rounds as a real comparison.
   Its spread is what "effect" is measured against. pgo: a per-round paired difference with a
   standard deviation of 2.92 % of the mean, ±4.64 % at four counted rounds, ±2.44 % at eight
   (docs/backlog/B-03-the-ruler.md). A ruler wider than the effect floor is a kill criterion.
3. **A positive control per measuring item** — a case whose outcome is known, through the identical
   protocol, in the same log:
   - a ruler must see a difference anybody can see. pgo's hogged arm came out 2.19× the clean one —
     and the same control exposed a defect in the unit: the machine-wide estimate charged the hog to
     the subject, whose own CPU had fallen to 5 671 µs. A control that finds the instrument wrong has
     done its job; the unit got a contamination column (B-03);
   - a survival test must kill: the same image under a deliberately small limit. xyk searched for
     that limit twice, because two first guesses survived and the harness refused to go on both times
     (xyk@471cb39:bench/memory.sh);
   - a loss test must lose: kafkakn's control lost exactly one record per concurrent sender, which
     also says how much the green covers — up to 64 requests caught mid-`send` per round
     (kafkakn@bd3193e:docs/backlog/B-19-close-under-a-real-shutdown.md);
   - a reader or classifier is fed the raw format production will hand it, not pre-split fields: a
     demangled C++ name has spaces in it (pgo scripts/attribution_control.py).
4. **A known-order pair**: a variant that does everything another does, plus one step. If it comes
   out cheaper, the run is void and the stand is fixed — bochka's cipher path came out cheaper than
   the same path without the cipher (bochka@85ded2b:BACKLOG.md, M-190).
5. **The lever engaged**, read from the process being measured. An `LD_PRELOAD` of jemalloc into a
   `-static` binary is ignored — zero jemalloc mappings in `/proc/<pid>/maps` — and a null over it is
   a no-op (pgo results, "a faster system malloc"). `taskset -pc <pid>` pins one thread: 49 threads of
   50 kept all twenty cores, and every number of a phase was taken unpinned (zavarnik §1.1).
6. **Load delivered**, asked every round of the generator's output **and of the subject**. xyk ran
   forty rounds against a generator that could not read its own script and scored "10/10 survived"
   for a process nobody talked to (bench/memory.sh); konekt's twelve-hour soak measured fifteen
   minutes of product and the rest on `401`, and exited 0 (konekt@5ba737b:docs/research/measurements-2026-09-02/soak/README.md).

> **A green without its positive control is not a green.**

A profiler that resolves nothing, a grammar that puts everything in one bucket, a protocol that
cannot see a difference anybody can see, a harness that never started — all produce exactly the
evidence a pass produces. More shapes of the same failure, each with its mechanism:
[references/checks-you-can-believe.md](references/checks-you-can-believe.md).

Checkable: the generator's ceiling, the ruler and each control's outcome are in `logs/` before the
first comparison of two arms; the commit of the first measurement is the window's close, written in
BRIEF.md, and `brief_freeze.py --history --window logs` is green on it.

## Step 4. Measure by protocol

The protocol, with its reasons, is [references/protocol.md](references/protocol.md). Its spine:

- **the generator never shares the subject's cores.** Sharing them, it takes the subject's CPU, the
  subject receives less than was ordered, and survives where on a dedicated pair it dies. Another
  host, or disjoint cpusets applied to every thread (`--cpuset-cpus`, `taskset` at exec — not
  `taskset -pc`, which pins one thread) and checked in `/proc/<pid>/task/*/status`: xyk's survival
  count and zavarnik's CPU per request ran that way. Throughput at saturation, tail latency and
  pauses take another host, one subject per host (kesh@0ff8899:docs/services/bench.md §3). A run
  with shared cores says `gen=local` and is a pilot;
- **arms interleaved, rounds repeated, round 1 discarded**, and state that accumulates between runs
  reset before every run — interleaving cancels a drift in the comparison, it does not make the
  numbers readable (konekt@5ba737b:docs/backlog/B-117-what-the-stack-costs-measured-under-load-and-over-time.md);
- **the operating point chosen by rule**: one offered rate per endpoint, identical for every arm,
  at 50–70 % of the **weaker** arm's own saturation, so that no arm is measured saturated; delivered
  equal to offered, p50 on the flat part. Saturated, pgo's Kotlin share read 55.55 % against 14.92 %
  clean (BRIEF.md A2.2; source-brief.md, "identical across arms");
- **the unit is CPU per unit of work** — µs per request, per byte, per batch with the batch fixed —
  with rps beside it and never as the verdict. At small core counts rps is a sample, at high rates it
  measures the offered concurrency;
- **memory from the cgroup** (`memory.peak`, `oom_kill` in `memory.events`) with the thread count
  beside it, never `VmHWM`;
- **every run's stdout captured into `logs/b-NN/<date>-<what>.log`** by the machine that drives,
  with a header: host, kernel, `nproc` inside the subject, binary digest, commit, generator version.

Checkable: every log has its header; the offered/delivered/dropped accounting closes in every counted
round; no number came from outside the harness.

## Step 5. Read the numbers

How to turn rounds into a claim is [references/reading-the-numbers.md](references/reading-the-numbers.md).
What it insists on:

- **the paired per-round difference with its interval**, because interleaving exists for it; pgo's
  paired reading held at 3.9–5.6 % across four runs while the unpaired one swung fourfold (B-03);
- **verdict words, not signs**: *distinguishable* when the difference lies outside its interval,
  *below resolution, effect under N %* (N the interval) when it lies inside — never "zero". A
  distinguishable difference under the floor or under twice the ruler is reported as measured and
  misses the threshold. A sign that flips between repeats is printed as *noise*
  (kore@c6d00a4:README.md, "The first column is noise and is printed as noise");
- **a ratio carries its base and its absolute**, an absolute carries what bounds it;
- **the unit and the instrument of every term** before two numbers are added or compared;
- **one line under every table that draws from two items or two runs: same host, same run — yes or
  no.** pgo's B-09 logs recorded no host; a column measured later on another machine made an
  ordinary build look 34 % faster than the PGO binary, and that was published. Every measure differed
  by a uniform 1.55–1.68×: a machine, not an effect (B-09, "Iteration 2");
- **a mechanism is named only after one variable on your side moves the signature.**

Checkable: every comparison in the results states its estimator, its interval, its round count, its
same-host line and its verdict word.

## Step 6. A verdict per question, and the write-up

Copy [templates/results.md](templates/results.md). In it:

- **the verdict table first**: question, verdict (`GREEN`, `GREY`, `RED`, `NOT MEASURED` with the
  reason), the number, the item. A qualification that could invalidate the headline comes before
  everything else — pgo's ceiling "was measured on a binary that opts out of the fast allocator";
- **every number has a path into `logs/`**; a number without its run is not reportable;
- **retractions are appended**; the original stays, with the reason it died. A hypothesis is
  refuted at the place it was made;
- **"not measured" says why, and how strong the why is**: a toolchain blocker is a weaker claim than
  a decision taken under a declared rule, and pgo had to correct a results document that reported
  two questions as dropped by a rule that did not name them (BRIEF.md A3.3);
- **the brief's author reviews the table before it is final.** A reviewer who runs nothing and
  recomputes from the premises — sizes from field layouts, the side of a threshold, the denominator —
  finds what the study's own discipline cannot, because it reads the same numbers the same way;
- **stops are taken**: a kill criterion that fires ends that half of the study, and the stop is
  written up; a budget is not extended. If the owner extends one, that is an amendment with a date,
  and the elapsed days are still reported, because how long it took is evidence too.

Checkable: `make check` green, freeze and readers' controls included; each question has a verdict
word; each number in the document resolves to a file under `logs/`.

## A measurement inside a product item

The smaller form, used by xyk (`docs/research/measurements-<date>/`), kesh (`bench/reports/b-NN/`),
bochka (`docs/measurements.md`) and booblik (`docs/benchmarking.md`):

- **the item's acceptance criteria are the pre-registration**: the unit, the arms, the threshold, the
  control and the conditions that void a run are in the item before the first run, and the history
  shows it: `git log --reverse --format='%h %s' -- docs/backlog/B-NN-*.md <raw directory>` lists
  the acceptance commit first, and `git log -p` on the item shows no criterion changed after the first log;
- **the minimum set, even for one number**: a ruler on the metric that decides — the baseline against
  itself at the item's round count; a positive control; the lever shown on, read from the subject
  (for a cache, its hit rate); the load shown delivered;
- **a percentile** needs an open-loop generator — a closed loop slows with the server and never
  takes the slow samples (booblik@7fa5834:docs/benchmarking.md, rule 5) — enough requests per round
  that it rests on more than a handful of samples (a p99 of 1 000 requests is decided by its ten
  slowest), and a ruler of its own: a tail does not share the mean's spread. Between campaigns,
  compare the share of slow runs, not an absolute p99;
- **where it goes**: the repository's convention; without one, `docs/research/measurements-<date>/`
  with the raw runs in `raw/` beside the report (xyk);
- the report says **Result, How, What it does not show**, with the binary digest and the commit in
  the header, and a series whose per-run lines were lost is not counted (kesh@0ff8899:bench/reports/b-16/README.md);
- **two campaigns are comparable only through an arm measured in both**: xyk's Go twin, the same
  binary a day apart, 601 against 620 rps, is what let two allocator campaigns be set side by side
  (allocator-decision.md);
- a decision may rest on the one criterion that separates the arms, and says so: neither allocator
  came within a factor of three of the throughput line, so memory decided;
- **CI does not measure performance.** It checks for collapse against a floor an order of magnitude
  below the slowest host (booblik@7fa5834:ci/benchmark-floor.sh), or a ratio between two paths in
  the same run: tracy's hot-path test asserted 30 µs, calibrated on an idle twenty-core box, and went
  red on a shared runner about 3.4× slower on unchanged code, while the ratio between its two paths
  read 335 there and 309 on CI (tracy@ae46b16, `HotPathBenchmarkTest.kt`).

Checkable: the acceptance commit precedes the first raw file; the report names its unit, rounds,
ruler, control and lever evidence; every number resolves to a raw file.

## The study repository

```
BRIEF.md                         the freeze record, pins, answers, amendments   (templates/BRIEF.md)
CLAUDE.md                        the study's rules for an agent    (templates/study-instructions.md)
backlog.md, docs/backlog/B-NN-*  stage 0 = pins, ruler, controls; one item per question   (docs-bootstrap)
docs/research/source-brief.md    questions, thresholds, kill criteria — frozen  (templates/source-brief.md)
docs/research/research-architecture.md   the evidence the study starts from, verified vs believed
docs/research/<date>-<topic>.md  the results                       (templates/results.md)
logs/README.md, logs/b-NN/       raw runs: the deliverable; the README exists from day one
scripts/                         brief_freeze.py and every reader that turns a log into a number,
                                 each with a control on known input
Makefile                         `make check`: docs checks, the three freeze lines, every reader's control
```

Whatever is not in `make check` is not a gate, and a gate counts only when its run is seen to finish:
a run that never starts or never ends looks exactly like a run that passed (pgo-native-spike@7bd8918:CLAUDE.md,
"Checks"). CI runs exactly `make check` on the whole history; the pull request links the finished run
or carries its log.

## What not to do

- **Do not move a threshold after the first number**, and do not add rounds after seeing one
  without the owner's dated amendment. Report the number against the line that was declared.
- **Do not report a number without the run that produced it**, and do not edit a retracted one
  away.
- **Do not read rps as a verdict**, and do not quote an absolute taken with the generator on the
  subject's cores.
- **Do not set two numbers side by side without the same-host line.**
- **Do not take a measurement outside the harness**, however quick the diagnostic feels.
- **Do not report a difference inside its interval as zero.** It is below resolution, under N %.
- **Do not publish a null without its lever shown engaged**, or a survival without the load shown
  delivered.
- **Do not extend a budget**; record the step as not completed and start the next.
- **Do not let the study become the product.** A library, a plugin or an upstream patch is a non-goal
  until the brief says otherwise; an item proposing one does not belong in the backlog.
