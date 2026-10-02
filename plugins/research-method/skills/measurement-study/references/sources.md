# Sources

The addresses in this skill are `repo@sha:path`, read from `origin/main` at these commits. All of
the repositories are public, under `github.com/youndie/`. Three of the four studies the skill was
distilled from are private and are not named or quoted; where a rule rests only on them, it is
stated with its mechanism and without an address.

| Repository | Commit | What the skill takes from it |
|---|---|---|
| pgo-native-spike | `7bd8918` | the study skeleton: `BRIEF.md` with pins and three amendment sets, `CLAUDE.md` and its rules, `docs/research/source-brief.md` (the received brief, frozen), the ruler and its paired estimator (`docs/backlog/B-03-the-ruler.md`, `scripts/ruler_stats.py`, `scripts/bench_stats.py`), the host-less logs (`B-09`, "Iteration 2"), the attribution control (`scripts/attribution_control.py`), the results document `docs/research/2026-09-20-instrumentation-pgo.md`, and one of the three `scripts/brief_freeze.py` copies |
| xyk | `471cb39` | the two-host protocol (`bench/run.sh`, `bench/columns.sh`), the survival harness on disjoint cpusets and its controls (`bench/memory.sh`), `docs/research/measurements-2026-09-15/throughput-pilot.md`, `docs/research/measurements-2026-09-16/throughput-three-columns.md`, `…/allocator-decision.md`, quota against cpuset and its correction (`docs/research/research-architecture.md` §1.18) |
| zavarnik | `4fd354d` | CPU per request as the unit, `taskset -pc` pinning one thread, the bias of tick-based process accounting on one kernel: `docs/research/research-engines.md` §1.1, §1.14 |
| bochka | `85ded2b` | ratios over absolutes, CPU per byte, the spread column and its 1.3 limit, loopback against a NIC, kTLS confirmed by a kernel counter (`docs/measurements.md`); the impossible ordering and the JIT warm-up (`BACKLOG.md` M-190); the OOM floor and the probe's own cost (`BACKLOG.md` M-148); the evidence directory and the `EXIT` trap (`ci/s3-tests.sh`); the bounded ratio (`CLAUDE.md`) |
| booblik | `7fa5834` | one session only, open loop, the generator in the subject's process, the medium checked first, CI checks collapse only (`docs/benchmarking.md`, `ci/benchmark-floor.sh`); the soak and its regions (`docs/measurements/soak-2026-09/README.md`) |
| kesh | `0ff8899` | the report shape Result / How / What it does not show, digests in the header, a lost series not counted (`bench/reports/b-11`, `b-16`, `b-17`, `b-18`); one subject per host and arm digests compared because an unknown `-Xbinary` option is only a warning (`docs/services/bench.md` §3) |
| konekt | `5ba737b` | the soak that measured fifteen minutes of product (`docs/research/measurements-2026-09-02/soak/README.md`), the reset stand (`docs/backlog/B-117-…`), the load profile that never reached a screen (`docs/backlog/B-126-…`) |
| kafkakn | `bd3193e` | the control that sizes the green and the harness wrong twice by being green (`docs/backlog/B-19-close-under-a-real-shutdown.md`), the one-sided reconciliation (`B-23-the-sink-that-does-not-wait.md`), the timeout that named the wrong cause (`B-24-the-central-guard-times-out.md`) |
| kore | `c6d00a4` | a sign that flips printed as noise, a column that reads backwards (`README.md`, "What it costs") |
| tracy | `ae46b16` | relative assertions instead of absolute thresholds, a harness that measured itself (`agent/src/desktopNativeTest/kotlin/io/github/youndie/tracy/agent/HotPathBenchmarkTest.kt`) |
| s3kn | `1f04db1` | a saturated thread does not name its owner (`BACKLOG.md` M-110) |
| katcher | `1c92fc7` | the image sizes as pull bytes measured on the finished images (`server/Dockerfile`, the comment above the stages) |
| screenshot-bench | `5abe8a9` | fresh inputs, test counts read back, the clock correction, disclosure of interest (`README.md`, `tools/bench.py`) |
| petich | `426caa8` | audits that fail on finding nothing (`tools/*-audit.py`) |
| oldge-ui | `21d0fd7` | a mutant counted killed by exit code alone (`docs/backlog/B-19-date-picker.md`) |
| docs-bootstrap | `7e42b87` | the documentation and backlog format a study writes into (`SPEC.md` §3.5–3.6) |

Issues and pull requests cited by number: youndie/katcher#55 (a sum in mixed units),
youndie/booblik#68 (two true citations, an untested inference), youndie/kore#31 and
youndie/sborka#77 (a wait that merged before the checks existed).

Lessons taken from the owner's working notes rather than from a repository file name the project
only where it is public, carry no address, and quote their numbers as the notes record them; a
lesson from a private project is stated by its mechanism alone.
