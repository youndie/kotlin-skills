---
id: source-brief
title: "<Topic> — the pre-registration, frozen"
type: research
status: active
date: <YYYY-MM-DD>
---

<!-- For a study that writes its own brief. A brief received from someone else goes below the marker
exactly as it arrived, and this template is not used. Everything above the marker may be edited;
nothing below it may be, including where it turns out wrong — that is what BRIEF.md's amendments are
for. Fill it in, then `python3 scripts/brief_freeze.py --record docs/research/source-brief.md` and
commit both files before the first measurement. -->

What follows is the pre-registration of this study, as written on <date> before any measurement.
`make check` hashes every byte below the marker. The pins, the answers to the believed list and the
amendments are in `BRIEF.md`.

<!-- ---8<--- everything after this line is the received text, byte for byte ---8<--- -->
# Pre-registration: <the question, in one line>

**Question:** <one sentence; the thing a reader wants answered, not the method>
**Budget:** <per step, in working days — RQ0 n, RQ1 n, …>. A step that overruns is recorded as
"not completed", with the reason, and the next step starts.
**Output:** `docs/research/<date>-<topic>.md`, the raw logs under `logs/`, <a recipe, a patch set>.
**Non-goals:** <what this study will not produce: a library, an upstream patch, a maintained fork,
other targets>. An item proposing one does not belong in the backlog.

## Verdicts

- **Green:** the effect is real, the lever is shown engaged, and the effect clears the threshold
  below on the subject that matters.
- **Red:** the lever engaged and nothing moved, or the step could not be made to work inside its
  budget.
- **Grey:** anything that is neither. The results say which green condition it missed; no run can
  fall between.
- **Not measured:** with the reason, and how strong the reason is — a blocker is weaker than a
  declared rule that fired.

## Research questions

| RQ | Question | Green | Red | Budget |
|---|---|---|---|---|
| RQ0 | <feasibility: can the thing be done at all> | <observable fact> | <observable fact, or "not reached within N days"> | n d |
| RQ1 | <the ceiling: how much is there to gain, measured before any work is judged> | | | n d |
| RQ2 | <the mechanism, priced in isolation> | | | n d |
| RQ3 | <the effect on the real subject> | | | n d |

<Why each threshold sits where it does, as arithmetic: "a 5–15 % return on a 40 % bucket is 2–6 %
of a request, which can clear the macro floor; on a 20 % bucket it cannot".>

## Thresholds and resolution

- **Unit:** <µs of CPU per request from the occupancy of the subject's pinned cores, with the
  process counter beside it | CPU per byte | per batch of N lines | p99 of …>. rps is recorded and
  decides nothing.
- **The ruler:** the baseline against itself, interleaved, <n> rounds, round 1 discarded, on every
  metric a verdict rests on. Estimator: the paired per-round difference with a 95 % interval.
- **Effect:** distinguishable, at least <floor> % **and** at least twice the ruler. Micro:
  non-overlapping 99 % intervals and at least <x> %, with a unit control beside every arm.
- A difference inside its interval is reported as "below resolution, effect under N %", N being the
  interval; one outside it but short of the effect line is reported as measured and misses the
  threshold. Neither is ever reported as zero.

## Kill criteria

The study stops, and the stop is written up with the same care as a result, when:

| # | Fires when | What is still written up |
|---|---|---|
| 1 | <RQ0 red: the thing cannot be done within its budget> | the obstacles in the order they were hit |
| 2 | <the ruler is wider than the effect floor> | the macro half ends; the micro half may finish |
| 3 | <the ceiling is too low for any effect to clear the floor> | where the cost actually is |
| 4 | <a control inverts and stays unexplained for n days> | the inversion and what was tried |

## Arms and controls

Every arm is built from the same source revision and flags, apart from the ones named. Each arm's
binary digest is recorded when it is built and compared with the baseline's: a flag the toolchain
ignores produces the baseline under another name.

| Arm | What differs | Role |
|---|---|---|
| A0 | nothing — the build that actually ships | baseline |
| A1 | <the change> | the main effect |
| A2 | <the change applied with uninformative input — a profile from another workload, a shuffled table> | separates "the lever works" from "any rebuild moves the number" |

Controls carried by every measuring item, shown in the same log as the result:

- **positive control:** <a case that must come out a particular way — a hogged arm outside the
  ruler, a limit that must kill, a run that must lose records>;
- **known-order pair:** <a variant that does everything another does plus one step; if it comes out
  cheaper, the run is void>;
- **lever engaged:** <the evidence read from the measured process — counts of functions the change
  reached, mappings in `/proc/<pid>/maps`, a hit rate, a kernel counter>;
- **load delivered:** <the generator's summary and a question to the subject, every round>.

## Protocol

- **Hosts:** the generator never shares the subject's cores — another host, or disjoint cpusets
  applied to every thread and checked; saturation, tail latency and pauses on another host.
- **Generator ceiling:** measured per endpoint before any arm is read.
- **Operating point:** one offered rate per endpoint, identical for every arm, at <50–70 %> of the
  weaker arm's own saturation; every run states delivered against offered and p50, and a run whose
  delivered rate falls short is not used. Open-loop load wherever a percentile decides.
- **Rounds:** <n>, arms interleaved, round 1 discarded; <what the stand accumulates> reset before
  every run.
- **Memory:** cgroup `memory.peak` and `oom_kill`, threads beside every figure.
- **Logs:** `<script> > logs/b-NN/<date>-<what>.log` from the driving machine, with the header:
  host, kernel, `nproc` inside the subject, uptime, binary digest, commit, generator version.

## Believed and not yet checked

Each is answered in BRIEF.md, by the item that checks it, before anything rests on it.

- <a premise inherited from another project — and which verdict rests on it>

## Predictions

- **H1** — <prediction, and the evidence it rests on>.

## Threats to validity

- <one subject, one target, one workload shape — the verdicts are stated for the pinned setup>
- <what the microbenchmark cannot say about the service>
