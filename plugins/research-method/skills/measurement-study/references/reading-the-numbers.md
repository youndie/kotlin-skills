# Reading the numbers: from rounds to a claim

Read with Step 5 of the skill. The question here is never "what is the number" but "what is this
number entitled to say". Repositories and commits: [sources.md](sources.md).

## Contents

- [The ruler and the estimator](#the-ruler-and-the-estimator)
- [Verdict words](#verdict-words)
- [Spread, sign and repeats](#spread-sign-and-repeats)
- [Ratios, absolutes and units](#ratios-absolutes-and-units)
- [Tables that draw from more than one run](#tables-that-draw-from-more-than-one-run)
- [Mechanisms](#mechanisms)
- [Your own tools](#your-own-tools)
- [Writing it down](#writing-it-down)

## The ruler and the estimator

**The ruler is the baseline measured against itself** — the same binary in both arms, interleaved,
with the round count a real comparison will use. Its spread is the resolution of every later claim.

**The estimator is the paired per-round difference**, because pairing is what interleaving is for:
a drift moves both arms of one round together and cancels in their difference, and does not cancel
in a within-arm standard deviation. With `n` counted rounds, `d_i = a_i − b_i` per round:

```
effect   = mean(d) / grand mean                 (as a share)
interval = t(0.975, n−1) · sd(d) / √n / grand mean
```

pgo-native-spike's B-03 is the worked case (docs/backlog/B-03-the-ruler.md):

- the brief said "the spread of that run is the ruler" and never defined spread; three readings of
  one data set differed by a factor of four, and the first write-up used the wrong one;
- on a run that drifted +441 µs a round (R² 0.94), the unpaired reading gave ±13.0 % and the paired
  one ±4.6 %; across four runs the paired reading stayed at 3.9–5.6 % while the unpaired one swung
  fourfold — and an earlier note that "longer settling halves the spread" had been the unpaired
  estimator fooled;
- pooled, sixteen paired differences had a standard deviation of 2.92 % and a mean of +0.28 %, the
  check that two copies of one binary really are one binary;
- the round count decides the bar, and is decided before the comparison:

| counted rounds per arm | 95 % interval on a difference | what binds a 5 % effect floor |
|---:|---:|---|
| 4 | ±4.64 % | twice the ruler: 9.3 % |
| 8 | ±2.44 % | the 5 % floor |
| 16 | ±1.55 % | the 5 % floor |

A reference implementation, with all three readings printed and the verdict naming the one it used,
is `scripts/ruler_stats.py` in pgo-native-spike.

**A ruler belongs to the binary class it was measured on.** pgo's ruler was characterised on a
statically linked binary; a dynamically linked arm ran at a per-round deviation of 7.27 % against
2.92 %, so eight pairs bought ±6.08 % instead of ±2.44 % (the results document, "a faster system
malloc"). Characterise the new class, or add rounds; do not borrow the ruler.

**A spread estimated from a few pairs is itself wide.** The same study tested whether address-space
randomisation caused that spread: 7.27 % with it, 5.93 % without, with 95 % intervals of
[4.81, 14.80] and [3.92, 12.07] — overlapping almost entirely. One run per variant is not a
measurement, and that applies to spreads as much as to means.

## Verdict words

There are three things a comparison can say, and "zero" is not one of them:

- **distinguishable** — the effect is outside its interval: `+19.01 %, 95 % CI ±2.33 %`;
- **below resolution, effect under N %** — the difference is inside the interval; N is stated, the
  observed value and the round count beside it (`+0.65 %, ±6.08 %, eight pairs: under 6.1 %`);
- **too few rounds to say either** — when the interval is wider than any effect worth having.

These words describe the difference against its own interval; the threshold is a separate question.
The effect threshold of a pre-registration asks for a distinguishable difference that is **at least
the floor and at least twice the ruler**; a distinguishable difference short of either is reported as
measured — "+3.1 %, distinguishable, short of the 5 % floor" — and misses the threshold, which makes
the question grey or red by its own table. pgo's brief wrote "a difference under twice the ruler is
below resolution", folding the two together; its own reader keeps them apart
(pgo scripts/ruler_stats.py, `verdict`), and so does this skill. For a microbenchmark the usual form is
non-overlapping 99 % intervals **and** a minimum change, with a **unit control** beside every arm — an
arm performing exactly the priced operation and nothing else; if the unit control separates, that
mode is void whatever the other rows say (pgo scripts/bench_stats.py).

## Spread, sign and repeats

- **The spread is printed beside every value**, and a value whose spread passes a stated limit is
  marked unusable in the output itself. bochka prints the ratio of the dearest run to the cheapest
  and marks anything above 1.3 "too noisy to conclude"; a 1.37× row stays in the table only so as
  not to be lost (bochka@85ded2b:docs/measurements.md).
- **One run per variant is not a measurement.** bochka's first version ran each variant once; one
  variant gave 1.14 and 2.42 CPU-seconds per GiB in two runs in a row while its neighbour repeated to
  a percent — two single numbers would have produced opposite conclusions with equal confidence.
- **An arm changes one thing.** A comparison of "heap 8 KiB" against "direct 256 KiB" moves two
  variables; the third arm, "heap 256 KiB", put both differences inside the noise.
- **A sign that flips between repeats is printed as noise.** kore printed a startup cost of "+1 %";
  three runs of the same harness put the difference at +12 ms, −23 ms and +30 ms against a within-arm
  spread of 250 ms. The cell now says *noise*, and the cost that held its sign in every run — RSS —
  is the one reported (kore@c6d00a4:README.md, "What it costs").
- **A number can carry the right sign and the wrong meaning.** The same table's "stop under load"
  rose 138 %, because the arm without kore dropped every request in flight and the arm with it
  finished them; shown alone, that column reads backwards.
- **Two runs that agree prove only what they share.** Two sweeps that both start from a restarted
  service agree to the percent on warm-up.

## Ratios, absolutes and units

- **A ratio carries its base.** pgo's +19.01 % is the paired estimator; the 1 419 µs gap is 21.0 %
  of the cheaper arm and 17.4 % of the dearer one, and the results print all three.
- **A ratio carries an absolute, and the absolute carries what bounds it.** bochka measured one-byte
  objects taking 5379× their size on ext4 — far past the "only if the difference is several-fold"
  criterion written beforehand — and still declined to optimise: the object ceiling bounds the
  lifetime loss at about 1.77 GiB, a few percent of a disk (bochka@85ded2b:CLAUDE.md). A criterion
  written before the bound was measured can be overtaken by it; re-read the criterion, do not only
  execute it.
- **An absolute threshold on shared hardware measures the hardware.** Assert a ratio between two
  paths measured in the same run, and turn the claim into a counter where one exists ("the block is
  never evaluated") instead of a stopwatch (tracy@ae46b16, `HotPathBenchmarkTest.kt`).
- **Between campaigns, compare only the metric that survived the drift.** When an arm is added to a
  published table, the old arm is rebuilt and run in the same sweep; otherwise "new against old" and
  "today against last week" cannot be told apart.
- **Name the unit and the instrument of every term before adding or comparing.** katcher's case for
  dropping a `scratch` image summed bytes on disk with compressed "to pull" bytes, 17 MB against
  15.5 (youndie/katcher#55); built and measured, it was 9 570 311 against 15 542 820 bytes to pull
  (katcher@1c92fc7:server/Dockerfile, the comment above the stages). Heap from a JVM
  agent and RSS from a native one are two quantities under one name.

## Tables that draw from more than one run

**Every table that sets numbers from two items, two sessions or two hosts side by side carries one
line: same host, same run — yes or no.** pgo's B-09 micro numbers carried no host, no CPU and no
session; that was invisible while every comparison was inside one run. A blog post then added a
column measured fresh on another machine and published the ordinary build as 34 % faster than the
PGO binary. The two sets differed by a uniform 1.55–1.68× across every measure — the signature of a
slower machine. Re-measured as three builds, nine interleaved rounds, one machine and one session,
the route was free within resolution and the effect survived (pgo docs/backlog/B-09-rq2-indirect-call-promotion.md,
"Iteration 2"; CLAUDE.md, "What not to do").

**A uniform ratio across unrelated measures is a property of the stand**, not of the arms. So is an
identical number across different implementations.

**A column measured for one row is written for one row.** Writing a property measured on one module
into every row of a table asserts a uniformity nobody checked, and hides exactly the outlier a reader
would ask about. Leave the other cells "not looked at", or measure the column — usually the same loop.

**A known-order pair that comes out inverted voids the run**, before any spread is looked at: a
spread says "noisy", an impossible order says "wrong instrument" (bochka@85ded2b:BACKLOG.md, M-190).

## Mechanisms

- **A reproducible symptom is not a mechanism.** Reproduction checks the observation; the report
  carries the explanation, and it will be read as checked. Call the lower layer directly, around
  your harness, before naming a cause; if you cannot, publish the observation and the narrowing
  table and leave the "why" empty.
- **Change one variable on your side and see whether the signature moves.** s3kn's flat curve came
  with one thread at 95 % of a core, and the owner was assigned by reasoning to curl's dispatcher. A
  second engine over plain HTTP produced the same curve and the same thread; the same code on
  `Dispatchers.Default` instead of `runBlocking {}` raised the ceiling 2.3× — the caller's context,
  where each part's SHA-256 was computed (s3kn@1f04db1:BACKLOG.md, M-110).
- **Two verified facts joined by an inference nobody ran are not a verified conclusion.** A research
  note cited two true lines of a client — `close()` closes a mailbox; the loop drains pending work by
  failing it — and concluded the client lost its batch on `close()`. It was filed as
  youndie/booblik#68 and closed without a fix: the closed mailbox broke the batching window first,
  and the pending list was empty by the time the drain ran — which a test written before the fix,
  green on the unfixed code, showed in minutes. Run the path; put a middle arm that differs from
  the control by one thing, so that the difference names its mechanism.
- **Before a measurement overturns a claim, ask what else in the frame is wrong.** A screen measured
  55 pixels lower with a safe-area inset than without it, two builds minutes apart, and the claim
  that the inset was right was withdrawn — while the app was running letterboxed in a compatibility
  canvas, whose safe area has nothing to do with the screen's. The black bars had been filed as a
  separate defect; they were the cause.
- **A number used to reject an option may be measuring your adapter to it.** When each option has
  its own harness, the one written second is the one that looks worse. Reproduce the decisive value
  in the smallest way with no harness at all before writing the rejection.

## Your own tools

- **Your tool's output is data, not knowledge.** A summary or a grouping can produce a "fact" about
  the domain that is a bug in the grouping. Look at the raw document before saying it aloud, and
  treat "the tool showed nothing" as no answer rather than a negative one.
- **Print the reconciliation, not only the result**: the identity that must close, and the
  `unattributed` and `unparsed` rows, instead of folding them away (pgo CLAUDE.md on razves).
- **Two buckets with disjoint members and identical counts are a collision.** In pgo, `k[a-z]+:`
  matched `kotlin::`, and the Kotlin-data bucket and the C++ runtime bucket came out equal, twice
  (scripts/attribution_control.py). It is visible only if both are printed.
- **A second implementation of the reader is the cheapest cross-check**, as pgo's second sampler for
  its ceiling (docs/backlog/B-15-second-sampler-for-the-ceiling.md).

## Writing it down

- **The qualification that can invalidate the headline goes first**, above the verdict table if
  need be.
- **Every number has a path into `logs/`**, and every percentage names its base. A number copied into
  a README or a landing page has no way to go stale visibly; before it is published again, it is
  measured again, and the text names the axis — what was measured, with what, and when.
- **A limitation sits beside the number it affects**, not in a closing section.
- **A retraction is appended**, saying what the earlier version claimed; the original is not edited
  away. When a verdict survives a correction with weaker grounds, say that the grounds changed — a
  right verdict with a wrong reason is what the next review leans on.
- **Hand the table to the brief's author before it is final.** In one study the author ran nothing,
  recomputed from the premises — object sizes from field layouts, the denominator of a ratio, the side
  of a threshold — and returned eight objections; none was rejected and two overturned a verdict. The
  study's own discipline had already withdrawn eight claims and had seen none of these, because it
  read the same numbers the same way. An objection that needs a new measurement is a backlog item.
