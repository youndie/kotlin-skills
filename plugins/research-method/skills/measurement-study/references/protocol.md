# The protocol: how a run is taken so that it can be compared

Read with Step 4 of the skill. Every rule here is a mistake somebody has already paid for; the
address after it is where. Repositories and commits: [sources.md](sources.md).

## Contents

- [The generator and the subject's cores](#the-generator-and-the-subjects-cores)
- [Rounds: interleaving, warm-up, reset](#rounds-interleaving-warm-up-reset)
- [The operating point](#the-operating-point)
- [Units and instruments](#units-and-instruments)
- [Memory under a limit](#memory-under-a-limit)
- [Soaks and long runs](#soaks-and-long-runs)
- [Logs](#logs)

## The generator and the subject's cores

- **The generator never shares the subject's cores.** Sharing them, it does not merely add noise; it
  competes for the cores being measured, the subject receives less load than was ordered, and it
  looks healthier than it is — the error always points the safe way. Two arrangements keep them
  apart:
  - **another host** — required for throughput at saturation, tail latency and pauses, where the
    rest of a shared machine still reaches the subject: kesh measures with "one subject per host",
    no second resident process beside it (kesh@0ff8899:docs/services/bench.md §3). xyk's
    `bench/run.sh` refuses its throughput run otherwise, and its `--same-host` mode produces pilots
    "whose numbers cannot be quoted against the criterion" (xyk@471cb39:bench/run.sh);
  - **disjoint cpusets on one host**, applied to every thread and checked — enough for CPU per
    request at a fixed rate and for a survival count: xyk's memory harness puts the subject on cores
    0–3 and the generator on 12–19 (bench/memory.sh), and zavarnik's engine numbers were taken with
    all 104 threads reading `Cpus_allowed_list: 0-7`. "Applied to every thread" is the trap: `taskset
    -pc <pid>` pins one thread, and a whole phase there was measured unpinned
    (zavarnik@4fd354d:docs/research/research-engines.md §1.1).

  The pinning lives in the script that starts the subject, not in a sentence asking people to
  remember it.
- **The generator's own ceiling is measured first, per endpoint**, by raising the offered rate
  against a target that can absorb it until dropped iterations appear. xyk's pair: 1 000 to 8 000
  rps delivered in full at p50 about half a millisecond, strain from 16 000
  (xyk@471cb39:docs/research/measurements-2026-09-15/throughput-pilot.md). Anything below that
  belongs to the subject.
- **A generator pool is a concurrency cap.** Under an arrival-rate executor a virtual user is busy
  for the whole round trip, so the most a pool can offer is `VUs ÷ latency`. xyk's 200 VUs at 380 ms
  could not offer more than 526 rps, and three arms came out at 523, 568 and 630 — "a shared
  ceiling" that was arithmetic. The same file then records the correction: 200 connections were a
  property of the offered load in the criterion, so the cap was the answer, not a defect
  (throughput-pilot.md, both sections). Decide which it is before the run, in the item.
- **A generator in the subject's process measures the pair.** booblik priced it: 9.2× on the median
  and 19 % of the ceiling, so numbers for a report come from a separate machine
  (booblik@7fa5834:docs/benchmarking.md, rule 6).
- **An identical maximum across different implementations belongs to the harness.** The same `max`
  for three runtimes is a property of the stand — a lost connection attempt retried by the kernel
  shows up this way — not of any of them.
- **The control arm must come out fastest.** xyk's harness requires the arm that touches no database
  to beat the two that do; a pilot where it did not was declared void by that rule
  (throughput-pilot.md), and a later run where the control equalled the ingest arm (434 against 437)
  became the finding: the database was not the cost
  (xyk@471cb39:docs/research/measurements-2026-09-16/throughput-three-columns.md).

## Rounds: interleaving, warm-up, reset

- **Arms are interleaved, rounds repeated.** pgo's micro driver first ran all of one arm's repeats
  and then all of the other's; the unit control — an operation the change cannot affect — moved
  31.5 % with non-overlapping intervals. That was drift between two blocks of time
  (pgo-native-spike@7bd8918:scripts/bench_stats.py).
- **Round 1 is discarded as warm-up, declared before the run.** On xyk and on pgo it turned out to
  measure nothing — "the rule is kept because it costs nothing" (B-03; three-columns.md). On a JIT it
  measures a lot: bochka's cipher arm had a spread of 4.58× until two passes were thrown away, then
  1.08×, because the intrinsic is compiled only after the loop is seen (bochka@85ded2b:BACKLOG.md,
  M-190). The first run after any restart measures warm-up, and **two sweeps that both start from a
  restart agree with each other** — agreement proves only what they share.
- **A settle between arms, and a check that the host is idle — that can itself fail correctly.** pgo
  found its idle gate broken twice: a load-average threshold a busy run could never reach, so it
  timed out and continued through `|| true`; and a `/proc/stat` parser assuming eight columns where
  Linux prints ten, which reported nine busy cores on a four-core box sixty times a round and carried
  on (pgo docs/backlog/B-03-the-ruler.md, "Four harness defects").
- **State that accumulates between runs is reset before every run**, not between groups.
  Interleaving keeps the comparison honest under a monotonic drift; it does not make the numbers
  readable, because the drift goes into the spread and eats the resolution. konekt's simulator ticked
  every subscriber ever signed in, the staircases had signed in 57 000, and the remaining runs moved
  to a reset stand (konekt@5ba737b:docs/backlog/B-117-what-the-stack-costs-measured-under-load-and-over-time.md).
- **A pair harness keeps both arms resident.** For CPU per request that is harmless — it is read per
  process. For a pause or a tail latency it is not: on a small host the "idle" second process has its
  own collector, timers and threads. Measure a pause with one subject on the host — kesh's rule, "no
  second resident process shares the subject's host" (docs/services/bench.md §3) — and alternate arms
  by start, not by round.
- **Runs compared are runs of one session, back to back.** "The same host" is not enough: a control
  in booblik differed by 37 % from the same configuration on the same machine on another day
  (docs/benchmarking.md, rule 3).

## The operating point

- **Sweep before comparing**, and compare where a difference can appear: below the knee both arms
  are fine, above it both are drowning, and "no difference" at either end is a wrongly chosen point,
  not a result.
- **Choose the rate by a rule written down first.** pgo's: each endpoint at 50–70 % of its own
  saturation, every run stating delivered against offered and p50; a run whose delivered rate falls
  short, or whose p50 has left the flat part, is not used. The rate is one number per endpoint,
  identical across arms (pgo docs/research/source-brief.md); when the arms differ in capacity, it is
  taken from the weaker arm's knee, or the weaker arm is measured saturated. Saturated readings inflate shares (55.55 %
  against 14.92 %); near-idle readings inflate the kernel (pgo BRIEF.md A2.2).
- **The workload must reach the path the question is about.** konekt's reading profile never opened
  one screen, so no allocation figure had ever covered it; a static rule pointed there first
  (konekt@5ba737b:docs/backlog/B-126-the-load-profile-never-opens-the-roaming-screen.md).
- **"Everything survived" is the hypothesis that the load was too weak.** A first search for bochka's
  OOM floor with one light client let every limit live; with four clients listing recursively the
  floor appeared at once — 576Mi lives, 512Mi is killed — and the probe turned out to be part of the
  measurement: with `httpGet` instead of `exec`, 512Mi lived, because the forked shell cost about
  64 MiB (bochka@85ded2b:BACKLOG.md, M-148). Check a quantity that had to move — committed heap,
  cgroup peak, collections — and name in advance an arm that must fail.
- **A result that confirms what was hoped for is re-measured on another input**: another order of
  magnitude, another shape, another client. A mechanism that depends on size has a boundary, and
  naming it is cheaper than an over-broad claim.

## Units and instruments

- **CPU per unit of work is the headline; rps sits beside it.** On a small host rps is a sample
  (Kotlin/Native's own spread on four visible cores was 2.3×), and at high rates it measures the
  offered concurrency (pgo CLAUDE.md, "Do not read rps as a verdict"). The ratio of rps understates
  the difference between two engines where CPU per request does not, because one engine can be
  capped by the offered concurrency — 64 connections at p50 0.58 ms is about 110 000 rps by Little's
  law — while the other is capped by the CPU (zavarnik@4fd354d:docs/research/research-engines.md).
  Per byte for a data path (bochka@85ded2b:docs/measurements.md); per batch with the batch size
  fixed in the generator and stated beside every number.
- **Read CPU from the occupancy of the subject's pinned cores, with the process counter beside it.**
  Tick-based `utime+stime` from `/proc/<pid>/stat` overstated by 6.4–7.2 %, constantly, on one
  kernel, and not at all on another where `sum_exec_runtime` could check it; pinned-core occupancy is
  bounded by physics and meets the truth at saturation. "8.81 cores of the eight available" was the
  tell (research-engines.md §1.14). Ratios survive the bias; absolutes do not.
- **A machine-wide estimate charges everything on the box to the arm.** pgo's hogged control reported
  17 113 µs per request for a subject whose own CPU had fallen. The guard that works is machine busy
  over the arms' own CPU — 1.00 on clean rounds, 2.59–2.88 on hogged ones — printed as a column, with
  a row above 1.2 marked `CONTAMINATED` (B-03).
- **`nproc` inside the subject** with every round; see the skill's Step 2.
- **The medium is checked before the number.** A `/tmp` on tmpfs made booblik's probe report `fsync`
  in 0.01 ms after 32 MiB of dirty data — 3.2 TB/s, which arithmetic catches and eyes do not every
  time — so its `MeasurementDir` refuses a volatile filesystem and every probe prints its medium in
  the header (booblik docs/benchmarking.md, rule 7a; bochka docs/measurements.md).
- **Loopback is not a network card.** bochka's zero-copy ratio was 5.3× on loopback and 7.6–8.0× on
  a real NIC; the cheap path barely moved and the copying path got dearer (docs/measurements.md, M-61).
- **The mode is part of the number.** With or without `force()` the same write differs by four
  orders of magnitude in booblik — "a number without the mode is not imprecise, it is meaningless" —
  and the runtime profile is named for the same reason: under the deployment's JVM flags and without
  them are different numbers (docs/benchmarking.md, rules 1–2).
- **A guest's clock can run slow.** screenshot-bench corrects every duration by the ratio of the
  driving machine's wall clock to the guest's over the same runs, ×1.04
  (screenshot-bench@5abe8a9:README.md, Method). Ratios between tools do not depend on it.

## Memory under a limit

The survival test, as xyk's `bench/memory.sh` runs it:

- N rounds per arm (ten), interleaved, each a fresh container under the limit;
- **a positive control limit that must kill**, found by search and re-found when the metric changed;
  a run whose control survives is void;
- **peak from the cgroup's `memory.peak`, kills from `oom_kill` in `memory.events`** — not the
  process's `VmHWM`, which counted the mapped pages of the binary and reported 9 600 kB for a
  container held under an 8 MB limit, a number larger than the limit it was measured against;
- **the thread count beside the peak**: on Kotlin/Native resident memory follows threads rather than
  the live heap, and a peak without threads has no mechanism attached;
- `died-before-serving` and `no-load` are outcomes of their own, never survivals.

For the platform half — allocators, page sizes, what each was measured to buy — see the
`native-service-bootstrap` skill's memory reference in the kotlin-fullstack plugin.

## Soaks and long runs

- **A sign of work right after the start, and a watcher for the end.** Checking that a job started
  proves nothing about it working; and a result promised for a time without a watcher is a result
  nobody reads until somebody asks.
- **The load script carries thresholds, so its exit code means something.** konekt's first soak ran
  twelve hours, measured fifteen minutes of product — tokens fetched once in setup expired after
  their fifteen minutes — and spent the rest on `401`. The progress line ended `✓ [100%]`, which is
  the duration elapsing; the script declared no thresholds, so the generator exited 0; the unit said
  `success`. The re-run declares `checks: ['rate>0.95']`, proved by mutation to exit 99
  (konekt@5ba737b:docs/research/measurements-2026-09-02/soak/README.md).
- **A header is checked against its rows.** The same soak's sampler named thirteen columns and wrote
  twelve, so the column read as `gc_last_pause_ms` was a line count growing 29 → 1 207.
- **A stopping rule is the data, not a clock**: "until every partition has been read to its last
  record", not "thirty seconds of quiet".
- **Growth is attributed to a place before it is called a leak.** booblik's `RssAnon` rose on a
  straight line for hours and then stopped dead: the heap had reached its `-Xmx`, the one region
  that moved in `pmap -X` (booblik@7fa5834:docs/measurements/soak-2026-09/README.md). A rate
  measured inside a cap describes the approach to the cap, not a trend.
- **Samplers write separate files**, and a script that is running is never edited in place.

## Logs

- Every measurement runs as `<script> > logs/b-NN/<date>-<what>.log` from the machine that drives
  the run; the script prints to stdout and keeps no file it needs. A file written on the measuring
  box is a file that can be lost there.
- **The header**: date, host, kernel, cores, `nproc` inside the subject, the host's uptime, binary
  digest, commit, generator and its version, the protocol (rounds, rate, settle). The uptime is there
  because a long-lived stand that fails is first recreated and its host's uptime read, and only then
  is the code suspected: in konekt three mechanisms were proposed for two failed scenarios and all
  three were refuted by measurement, while the build box went on to reboot in the middle of the run
  meant to explain them. A run under which the host restarted is not a run. pgo's B-09 recorded none of this,
  which was invisible until a number from it met a number from elsewhere.
- **Each item's `logs/b-NN/README.md` says what to read the files for.** A retraction is appended
  to the file that carried the original.
- **Evidence directories are emptied at the start of a run**, and a report older than the run's
  start is ignored and said to be there: a run that classified cleanly used to leave the previous
  run's files behind, read as fresh (bochka@85ded2b:ci/s3-tests.sh).
- **A series whose per-run lines were lost is not counted**, whatever its summary says (kesh@0ff8899:bench/reports/b-16/README.md).
