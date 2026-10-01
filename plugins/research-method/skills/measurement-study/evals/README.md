# Evals for `measurement-study`

`evals.json` follows the skill-creator shape: a prompt, the fixture it runs against, and
expectations a grader can check from the transcript and the repository afterwards.

Five cases are defects that happened, re-staged on a fictional study — a read cache in front of a
"ledger" service — with synthetic numbers chosen to be internally consistent. Each prompt is the
request a hurried owner would plausibly make, and doing what it literally says produces the defect.
That is their design: the skill's value is refusing the plausible step, not executing the obvious
one. Two more cover the paths the skill exists for when nothing has gone wrong yet: setting a fresh
study up, and pre-registering one measurement inside a product item.

| case | where the defect comes from |
|---|---|
| `threshold-moved-after-the-first-number` | pgo-native-spike: the ruler measured ±4.64 % at four counted rounds, so "twice the ruler" was 9.3 % and no green ceiling could clear it. The study raised the round count by a dated owner's amendment that names itself as late and relaxed no threshold — the bar fell to 5 % because more rounds narrowed the ruler — and B-03 left the round count to the owner rather than deciding it inside the item (`BRIEF.md`, amendment set 2; `docs/backlog/B-03-the-ruler.md`, "Not covered") |
| `null-over-a-lever-that-never-engaged` | pgo-native-spike's results document: the pinned build is `-static`, so `LD_PRELOAD` of jemalloc is ignored — zero jemalloc mappings in `/proc/<pid>/maps` — and a probe against it "measures nothing and would report it as 'jemalloc does not help'"; the probe was re-run on a dynamic build of the same commit with the preload shown engaged (`docs/research/2026-09-20-instrumentation-pgo.md`) |
| `two-hosts-in-one-table` | pgo-native-spike B-09, "Iteration 2": the micro logs recorded no host; a column measured later on another machine made an ordinary build look 34 % faster than the PGO binary and was published; the gap was a uniform 1.55–1.68× on every measure. The fix was three builds, nine interleaved rounds, one machine, one session, and the rule "same host, same run — yes or no" in `CLAUDE.md` |
| `rps-is-not-the-verdict` | zavarnik's engine phase: the ratio of rps understated the difference between engines where µs of CPU per request did not, because one engine was capped by the offered concurrency and the other by the CPU; the process counter overstated by 6.4–7.2 % on that kernel, so the pinned-core figure is the unit (`docs/research/research-engines.md`); pgo-native-spike's `CLAUDE.md`, "Do not read rps as a verdict" |
| `a-harness-that-never-sent-a-request` | xyk's survival harness: all forty generator logs said `permission denied` on the scenario, and the run scored ten survivals in ten for a process nobody talked to, while the positive control was killed exactly as designed (`bench/memory.sh`, "DID THIS ROUND CARRY ANY LOAD?"); konekt's soak that exited 0 after twelve hours, fifteen minutes of them product (`docs/research/measurements-2026-09-02/soak/README.md`) |
| `a-fresh-study-frozen-and-gated` | pgo-native-spike B-14: the freeze rested on a digest in prose and a file in somebody's downloads folder until the received text was moved into the repository and hashed by `make check` (`docs/backlog/B-14-make-the-freeze-checkable-from-the-repo.md`, `BRIEF.md` "Provenance"); the placeholders a brief leaves are pins resolved in BRIEF.md, not edits to the brief (`BRIEF.md`, "The pins the brief left as placeholders") |
| `a-measurement-inside-a-product-item` | the small form of xyk (`docs/research/measurements-2026-09-16/`), kesh (`bench/reports/`) and booblik (`docs/benchmarking.md`, rule 5: only an open loop measures a tail); the case a reviewer of this skill got stuck on — "the cache must cut p99" with no ruler on p99, no lever evidence and no proof that the criteria predate the run |

## What an expectation is allowed to be

**Observable**: a file that exists or does not, a line that was or was not added, a statement in
the answer, the exit code of `scripts/brief_freeze.py`. "The verdict is right" is not checkable;
"results.md does not say the ordinary build beats the PGO build" is.

Several expectations check for a **reason** in the answer — the window closed, the binary is static,
the logs come from two machines — because an agent that refuses for no stated reason will comply the
next time the request is phrased differently.

## The fixture

`files/setup-fixture.sh <dir> <threshold|preload|hosts|rps|noload|fresh|product>` builds a git repository with
the study's `BRIEF.md`, a received brief frozen by the skill's own `scripts/brief_freeze.py` (copied
in, so the freeze is real and a grader can run it), a draft results document, the backlog item the
case is about and its logs. It carries a `CLAUDE.md` that says what the study is and where the gate
is, and deliberately not the method: whether a threshold may move, what a null needs and which unit
decides are what the skill has to bring. Its `make check` runs all three freeze lines.
`fresh` builds a repository holding only the brief as it arrived; `product` a service repository with
its benchmark harness and one backlog item.

Run each prompt with the skill and once without, on separate fixture directories, and grade both
against the expectations. One run per variant is not a measurement; two or three are.
