# Checks you can believe: harnesses, controls, readers and gates

Read with Step 3 of the skill. This file is about the machinery around a measurement — the harness
that drives load, the control that proves a failure is visible, the reader that turns a log into a
number, the gate that decides "green". Tests of product code are the `kmp-testing` skill's
(kotlin-fullstack plugin); several shapes below recur there because the defect is the same.

Every entry is one shape of the same failure: **a check that cannot fail produces exactly the
evidence a passing check produces.** Each has an example and the mechanism that prevents it.
Repositories and commits: [sources.md](sources.md).

## Contents

- [1. Show it failing, on the axis where failure can appear](#1-show-it-failing-on-the-axis-where-failure-can-appear)
- [2. A control case answers for its own rule](#2-a-control-case-answers-for-its-own-rule)
- [3. Count what was looked at, per subject](#3-count-what-was-looked-at-per-subject)
- [4. The witness must be able to move](#4-the-witness-must-be-able-to-move)
- [5. The treatment happened](#5-the-treatment-happened)
- [6. The load happened](#6-the-load-happened)
- [7. Status, not text](#7-status-not-text)
- [8. Unskippable](#8-unskippable)
- [9. Fresh evidence only](#9-fresh-evidence-only)
- [10. A timeout measures whoever is slowest](#10-a-timeout-measures-whoever-is-slowest)
- [11. Harness defects that read as a pass](#11-harness-defects-that-read-as-a-pass)
- [12. One mechanism at a time](#12-one-mechanism-at-a-time)
- [13. A gate that runs where it can see](#13-a-gate-that-runs-where-it-can-see)

## 1. Show it failing, on the axis where failure can appear

A negative result — "no difference", "nothing leaked", "nothing found" — means nothing until a case
whose answer is known has been shown to come out the other way **by the same instrument**.

- pgo's ruler was a ruler only after a deliberately hogged arm came out 2.19× outside it
  (pgo-native-spike@7bd8918:docs/backlog/B-03-the-ruler.md). xyk's survival count meant something
  only after the same image under a deliberately small limit was killed (xyk@471cb39:bench/memory.sh).
- **The control runs through the same command that produced the negative**, not a similar one. A
  code search for a runner label returned nothing; the same search for a label known to sit in two
  dozen workflow files returned nothing too — the search did not index those files at all.
- **The control sits on an axis where the difference can appear.** proba measured a layout by its
  width, and the right layout and a deliberately broken one gave the same number: a block element
  takes its parent's width either way. The height told them apart.
- **The control also sizes the green.** kafkakn's shutdown control lost exactly one record per
  concurrent sender, which is what turned "the drain took 12–82 ms" from "nothing was in flight" into
  "up to 64 requests were finished each round" (kafkakn@bd3193e:docs/backlog/B-19-close-under-a-real-shutdown.md).
  If a control loses three, the green covers a window of three — write that, not "no losses".
- A claim that something is absent is rewritten, where possible, as a structure that must be
  present: absence has no signature.

## 2. A control case answers for its own rule

- **A mutation must change something.** pgo's freeze control had a case "wrapper prose edited" that
  replaced a heading its wrapper did not contain; the mutated file was the committed file, and the
  case passed for a reason unrelated to its name (pgo-native-spike@7bd8918:scripts/brief_freeze.py
  against docs/research/source-brief.md). This skill's `scripts/brief_freeze.py` mutates by position
  and reports a no-op mutation as a failure of the control.
- **A failing case names the error it must fail with.** Otherwise a neighbouring rule turns it red,
  and switching its own rule off leaves the control green. Each rule of `brief_freeze.py` was switched
  off once to see its case go red.
- **A control feeds the raw format production will hand the reader**, not pre-split fields. pgo's
  attribution control handed `bucket()` symbols already split out; `perf` demangles, a demangled C++
  name has spaces in it, the line parser read the return type as the symbol, and 4–12 points moved
  from the runtime bucket to libc while every row still reconciled (pgo scripts/attribution_control.py).
- **A sum that reconciles is not a correct classification**: it reconciles when everything lands in
  one bucket.

## 3. Count what was looked at, per subject

- **Three numbers, not one: passed, failed, not looked at.** konekt's coverage report printed
  "61 of 66 automated" and promised to check that named tests exist; a test name replaced by a
  nonexistent one did not change the output, because eleven of fourteen lines were resolved to
  "nothing checked here" and the percentage counted them anyway. Prove it by mutation: replace the
  subject with one that does not exist and watch the report change.
- **Fail on zero.** A check that found no subjects says so loudly — the audits in petich print
  "the audit would pass by finding nothing" and fail (petich@426caa8:tools/consumer-coverage-audit.py).
  An identifier spelled inside a guard is the usual way to reach zero: after a rename the guard does
  not disagree, it stops finding its subject.
- **The vacuity counter lives at the level of the subject.** tacku's check that an agent's colour
  marked only a stripe counted hits across four screens; the sum was well above zero while two of the
  four contributed nothing, and a counter per screen found both in one run. Check also that the walk
  reaches every subject: one that does not know a wrapper turns a subject into zero findings, and a
  summed counter swallows the zero.
- **An empty list of checks is not a green one.** A wait loop of the form "no line says pending"
  merged pull requests before their checks existed, twice (youndie/kore#31, youndie/sborka#77). Wait
  for a non-empty list first.

## 4. The witness must be able to move

A check observes its subject through some value. If that value cannot change in the scenario, the
check passes on a broken subject.

- In petich, "a write moves `updated_at`" passed with the column removed from the `UPDATE`: the stamp
  written by the `INSERT` was already in the past. Moving clocks in the subject, with no default,
  made it real.
- **A fallback answers for every name.** A lookup "the serializer for this type exists" passed for a
  made-up name, because the hierarchy had a default deserializer. Assert *whose* answer it is, and keep
  a case with a name that cannot exist.
- **A response synthesised from configuration answers for a nonexistent subject too.** shildik's
  discovery document came back 200 and plausible for a realm that did not exist; only the first
  address in it that reads state refused. Ask what in the answer could have refused.

## 5. The treatment happened

The arm differs from the baseline only if the change reached the process being measured.

- **Read it from the process.** An `LD_PRELOAD` into a `-static` binary is ignored: zero jemalloc
  mappings in `/proc/<pid>/maps`, and a null over it is a no-op. On a dynamic build the same probe
  showed five jemalloc regions and the allocator's symbols in a profile — the difference between a
  null and a no-op (pgo results, "a faster system malloc"). `taskset -pc <pid>` pins one thread, and a
  whole phase was measured unpinned (zavarnik@4fd354d:docs/research/research-engines.md §1.1). kTLS
  was confirmed by the kernel's `TlsTxSw` counter rising by one per request on its port and not on the
  others (bochka@85ded2b:docs/measurements.md). booblik's benchmark fails the run when the deployment
  JVM flags are not in the measured process (booblik@7fa5834:docs/benchmarking.md, `RuntimeFootprint`).
- **Compare arm digests.** A flag the toolchain ignores builds the same bytes.
- **An automated configuration edit asserts that it edited**: a substitution counts its replacements
  (`re.subn`, not `re.sub`), and the run carries a witness of the setting. A matrix of build settings
  measured on a consumer project ran three times on the default — a pattern that matched no block, then
  a replacement that hit a comment above the setting — and was caught each time only because the run
  checked that the number of generated test classes equalled the shard count.
- **Fresh input, so nothing comes back up to date.** screenshot-bench passes a new `-PbenchRun` to
  every measured invocation and reads back the JUnit XML: "a run whose test count is not N is reported
  as invalid, not as fast" (screenshot-bench@5abe8a9:tools/bench.py). A mutation run without
  `--rerun-tasks` can be answered `UP-TO-DATE` on the mutated source.

## 6. The load happened

- **Asked every round, of the generator and of the subject.** xyk's memory harness once mounted its
  scenario where the generator's user could not read it; all forty logs said `permission denied`, and
  the run scored ten survivals in ten for a process nobody talked to. Both stands had a positive
  control and both controls worked: a control proves the stand sees the failure it was built for, and
  nothing else. The harness now refuses a round whose generator summary has no requests
  (xyk@471cb39:bench/memory.sh, "DID THIS ROUND CARRY ANY LOAD?"). Ask the subject too — "how many
  events were stored" is a question a broken generator cannot answer yes to.
- **A suspiciously even secondary number is a clue**, not a property of the stand: a thread count
  that never moves under "200 rps on 50 connections".
- **The generator's exit code means something only if the script declares thresholds** — konekt's
  twelve-hour soak, see the protocol reference.
- **A reconciliation is two-sided.** kafkakn's harness compared rows in SQLite with keys on a topic.
  `sqlite3` was not on the non-interactive `PATH`, every read failed silently, `rows=0`, and
  `missing=0` in every round — an empty side reconciles with anything. The one column an empty read
  could not zero, `extra=707`, gave it away (kafkakn@bd3193e:docs/backlog/B-23-the-sink-that-does-not-wait.md).
  Check for the binaries the harness calls before the first round.

## 7. Status, not text

- **Decide on the exit code; read the output afterwards.** A `grep` for the expected success line
  greens every failure whose wording was not guessed; Gradle's `-q` drops the violation lines a grep
  looks for; a background job's notification reports the last command of the chain, not the build.
  `cmd > log 2>&1; echo "exit=$?"`, then read `log`.
- **A pipeline's status is its last stage's.** `run | grep … | head` returns 0 and nothing when the run
  died at its first line; `head` also turns an inventory into a sample. Write the whole output to a
  file and filter the file, or `set -o pipefail` and treat an empty capture as a failure.
- **Never put a command whose failure is the brake for the next ones into a pipe** inside an `&&`
  chain: a rebase that stopped on a conflict, piped through `tail`, let the commit and the force-push
  after it run.

## 8. Unskippable

A guard at the end of a linear script guards only the paths that reach it. bochka's suite runner
ended with "nothing executed is a failure, not a zero"; a quote broken in the middle of the script
made `set -u` kill it early, and it exited without a number and without a complaint. The guard is now
a flag set beside the printed result and checked in an `EXIT` trap (bochka@85ded2b:ci/s3-tests.sh,
`scored=no` … `scored=yes`).

## 9. Fresh evidence only

- **Empty the evidence directory at the start of a run**, not at the end, and ignore — and mention —
  any report older than the run's start. bochka's runner kept logs only when something asked for them,
  so a clean run left the previous run's files in place, and they were read as a regression
  (bochka@85ded2b:ci/s3-tests.sh).
- **Wait for the end of a run, not for a file to exist**: the previous run's file already exists.
- **One task per invocation when it has its own filters**: Gradle binds `--tests` to the task before
  it, and a task that did not run leaves its old XML behind. Several targets in one mutation run need
  `--continue`, or the second target's stale result is read as the mutant surviving there.

## 10. A timeout measures whoever is slowest

- A suite case that started to time out looked like a regression; the server did its part in 0.32 s,
  and the test's own quadratic comparison loop took 11.57 s. Split the time before raising a limit or
  declaring a slowdown, and write the split beside the new limit.
- A default test timeout fired first and reported a coroutine error, while the real failure — a topic
  never created because the test was run outside its runner — needed a longer wait to surface
  (kafkakn@bd3193e:docs/backlog/B-24-the-central-guard-times-out.md). A red produced by running a check
  the wrong way is not a finding until repeated through its own runner.
- tracy's first hot-path benchmark wrapped each iteration in its own `runBlocking` and reported 2.3 µs
  for a suppressed record: the harness was the thing measured
  (tracy@ae46b16, `HotPathBenchmarkTest.kt`).

## 11. Harness defects that read as a pass

Each of these produced evidence indistinguishable from a working run:

- **`pkill -f` matches its own command line.** pgo's control mode killed the remote shell rather than
  the load (B-03). A watcher built on `pgrep -f` sees itself; ask for the result line, not the process.
- **A port is not free the moment its process is.** `pkill` returns when the signal is sent; the next
  start dies on `EADDRINUSE` — six times out of twelve on xyk, and once as a control round that "read
  exactly like a round that passed" on kafkakn (xyk three-columns.md; kafkakn B-19). Wait for the port.
- **A name built from the round alone replays the previous run.** A topic named after the round, not
  the run, handed kafkakn 2 612 records with no row behind them (B-19).
- **Background servers hold an ssh session's stdin open**, and the start step hangs silently, reading
  as a slow host (pgo B-03: `ssh -n`, `</dev/null`).
- **An accounting check that compares a number with itself** — responses against iterations, which
  are the same count — can never fail. Compare against rate × duration, the side that can disagree
  (pgo B-03).
- **A dependency nobody starts.** A test suite stayed green while another project's container
  happened to be running on the same shared runner; the day it stopped, every case failed, and the
  boundary between green and red matched that container's stop time rather than any commit. Before
  explaining a red, find who provisions the dependency — and if nobody does, explain the past green.

## 12. One mechanism at a time

- **Two guards for one failure hide which one works.** bochka protects a log against torn writes by
  write order and by a CRC; reversing the order passed the whole suite, crash tests included, because
  the CRC caught every torn record. Break each guard alone; if the suite stays green, the test for that
  guard has to look below the outcome — at the bytes.
- **A mutant counts as killed only when the test written for it fails by name.** An exit code of 1 can
  be a neighbouring test or a compile error under `-Werror`: in oldge-ui a reported kill survived when
  re-run with test names, because the last line of the test was a bare finder that asserts nothing
  (oldge-ui@21d0fd7:docs/backlog/B-19-date-picker.md). An aggregate from a mutation tool is evidence; a
  verdict on one mutant from its report is a hypothesis until the substitution is made by hand.

## 13. A gate that runs where it can see

- **Whatever is not in `make check` is not a gate**, and CI runs exactly `make check`. **A gate counts
  only when its run is seen to finish**: a job that never starts, or never ends, looks exactly like one
  that passed (pgo-native-spike@7bd8918:CLAUDE.md, "Checks"). The pull request links the finished run
  or carries its log.
- **A history check on a shallow clone sees one commit and passes.** `brief_freeze.py --history`
  refuses a shallow clone; give its CI job the whole history (`fetch-depth: 0`).
- **A history check sees only what history kept.** git's default simplification drops the commits of
  a merged branch whose result equals the main line, so the script reads `--full-history`; a squash
  merge keeps no branch commits at all, so an edit made and undone inside a squashed branch is gone
  for any check. Merge study branches, or run the history check on the branch before squashing.
- **A check that runs only on the default branch rots unseen**, and a manually triggered one shows its
  last green long after the thing it checks has changed. Compare the date of the last run with the date
  of the last change to its subject.
- **A guard copied from a neighbour comes with its siblings.** A set of guards in another repository is
  a list of defects that already happened there; under a shared build convention they are likely here
  too. Run all of them once before choosing which to copy.
