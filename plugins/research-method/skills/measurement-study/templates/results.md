---
id: <date>-<topic>
title: <Topic> — results
type: research
status: draft
date: <YYYY-MM-DD>
---

# <Topic> — results

**<Final | Interim, as of date>.** <Two or three sentences: the answer to the question, in words a
reader can repeat, and the one qualification that could change it.> Every number below has a
backlog item, a log under `logs/` and a command behind it; nothing is carried over from another
project or inferred from a prior.

The pre-registration is `docs/research/source-brief.md`, frozen; `BRIEF.md` carries its pins and
<n> amendment sets with the reason for each. The evidence the study started from is
`docs/research/research-architecture.md`.

## Verdict table

| RQ | Question | Verdict | The number | Item |
|---|---|---|---|---|
| RQ0 | <question, as pre-registered> | **GREEN** | <value, unit, estimator and interval, rounds> | B-NN |
| RQ1 | | **GREY** — <which green condition it missed> | | B-NN |
| RQ2 | | **RED** | | B-NN |
| RQ3 | | **NOT MEASURED** — <reason; a blocker, or a declared rule that fired, and which> | — | B-NN |
| — | The ruler | <sd of one paired round, % of mean> | <±x % at n counted rounds>, characterised on <binary class> | B-NN |

**Kill criteria:** <which fired, which did not, which became moot and why>.

## <The qualification that could invalidate the headline>

<It comes first because it can change the reading of everything below: the build the subject was
measured on, the bucket definition, the operating point. Say what was measured to bound it, or that
nothing was.>

## RQn — <question>

**Verdict: <word>.** <One paragraph: the effect in the unit, its interval, the threshold it was
held against, and the verdict word — "distinguishable" (outside its interval), or "below
resolution, effect under N %" (inside it, N the interval).>

| arm | <unit> | spread | rounds |
|---|---:|---:|---:|
| A0 | | | |
| A1 | | | |
| paired difference | <+x %>, 95 % CI <±y %> | | <n> |

Same host, same run: **<yes | no>**. <If no: why the numbers may still be set side by side — an arm
measured in both runs — or that they may not.>

- **Lever engaged:** <the evidence, from the measured process> — `logs/b-NN/<file>`
- **Positive control:** <what had to come out a particular way, and did> — `logs/b-NN/<file>`
- **Load delivered:** <offered / delivered / dropped closes in every counted round> — `logs/b-NN/<file>`
- **What this does not show:** <the subject, the workload shape, the host size it does not speak for>

## Not measured

| RQ | Why | How strong the why is | What would measure it |
|---|---|---|---|

## Amendments that affected the reading

<Each amendment that changed how a number is read, with the figure under the original rule beside
the figure under the amended one.>

## Retractions

<Appended, dated, newest last. What the earlier version claimed, why it died, what replaced it. The
original text stays where it was, marked.>

## Threats to validity

## Reproducing

Pins as in `BRIEF.md`. Commands, in order, each writing to the log it is cited by:

```bash
<script> > logs/b-NN/<date>-<what>.log
```
