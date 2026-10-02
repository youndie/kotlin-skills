#!/usr/bin/env bash
# One fictional study repository, five shapes, and two other starting points: `fresh` (a brief that
# has just arrived and nothing else) and `product` (a product repository with one backlog item that
# needs a measurement). $1 is the directory to build in, $2 the case.
#
# The study is invented — a cache in front of a ledger service, measured on two hosts — and every
# number in it is synthetic. Each case reproduces the shape of a real defect (see ../README.md), not
# its data. The repository carries the skill's own scripts/brief_freeze.py, so the freeze in each
# fixture is real and a grader can run it.
#
# Deliberately NOT included: a CLAUDE.md that states the method. The fixture says what the study
# is and where the gate is; whether a threshold may move, what a null needs, which unit decides, is
# what the skill has to bring.
set -euo pipefail
dir="$1"; shape="${2:-threshold}"
skill="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$dir" && cd "$dir"
git init -q
commit() { git add -A && git -c user.email=eval@example.invalid -c user.name=eval -c commit.gpgsign=false commit -qm "$1"; }

if [ "$shape" = fresh ]; then
  # A brief as it arrived, placeholders included, and a repository with nothing set up. The agent
  # brings the freeze, the gate and the layout; nothing here hints at them.
  mkdir -p incoming
  cat > CLAUDE.md <<'EOF'
# CLAUDE.md — queue-batching-spike

A new time-boxed study. The brief from the owner is in incoming/. Commits follow Conventional
Commits.
EOF
  cat > incoming/brief.md <<'EOF'
# Research brief: batching in the outbox worker

2026-10-01 · from the owner

## Question

How much CPU per delivered message does batching the outbox worker's sends save, at the service's
normal rate?

## Fixed setup

- Kotlin `<pin>`, Ktor `<pin>`, the subject at `<pin>`
- Generator on its own host, fixed offered rate per endpoint
- Each comparison: arms interleaved, five rounds, the first discarded

## Research questions

| RQ | Question | Green | Red |
| --- | --- | --- | --- |
| RQ1 | Is the stand fine enough? A0 against itself | ruler under 3 % | ruler above 3 % |
| RQ2 | What does a batch of 32 save in µs of CPU per delivered message? | at least 10 % and at least twice the ruler | below resolution |

## Kill criteria

1. RQ1 red: the ruler is above 3 %. The study stops and says so.
2. Day 3 ends with RQ2 not measured: publish what was measured, mark the rest "not measured".

## Budget

Three working days, hard stop.
EOF
  commit "docs: the brief as it arrived"
  exit 0
fi

if [ "$shape" = product ]; then
  # A product repository, not a study: a service, its benchmark harness, and one item that needs a
  # number. Nothing says how to pre-register it.
  mkdir -p docs/backlog bench
  cat > CLAUDE.md <<'EOF'
# CLAUDE.md — ledger

The ledger service. Backlog items live in docs/backlog/. Benchmarks run through bench/run.sh.
Commits follow Conventional Commits.
EOF
  cat > bench/run.sh <<'EOF'
#!/usr/bin/env bash
# bench/run.sh SUBJECT GENERATOR --route GET:/items --rate N --duration 60s --rounds R [--arm NAME --env K=V]
# Starts the subject on SUBJECT (cores 0-3), runs k6 constant-arrival-rate from GENERATOR, prints
# per round: offered delivered dropped p50 p95 p99 pinned_busy_core_s responses, and the subject's
# /metrics snapshot (cache_hits, cache_misses) after each round.
echo "this fixture does not run load" >&2; exit 2
EOF
  chmod +x bench/run.sh
  cat > docs/backlog/B-12-read-cache-for-items.md <<'EOF'
---
id: B-12
title: "A read cache in front of GET /items"
status: wip
priority: P1
---

# B-12 — A read cache in front of GET /items

The cache is merged behind `LEDGER_ITEMS_CACHE=on`. It should cut p99 of GET /items.

- AC: the cache cuts p99 latency of GET /items.
EOF
  commit "feat(b-12): the read cache, behind a flag"
  exit 0
fi

mkdir -p scripts docs/research docs/backlog logs
cp "$skill/scripts/brief_freeze.py" scripts/brief_freeze.py

cat > CLAUDE.md <<'EOF'
# CLAUDE.md — ledger-cache-spike

A time-boxed study: what an in-process read cache is worth in front of the ledger service, in CPU
per request. No library comes out of this repository. `make check` is the gate. Commits follow
Conventional Commits.
EOF

cat > Makefile <<'EOF'
check:
	python3 scripts/brief_freeze.py
	python3 scripts/brief_freeze.py --history --window logs
	python3 scripts/brief_freeze.py --control
EOF

printf '%s\n' "docs/research/source-brief.md -text" > .gitattributes

cat > docs/research/source-brief.md <<'EOF'
---
id: source-brief
title: The brief as received
type: research
status: active
date: 2026-09-19
---

The brief exactly as it arrived on 2026-09-19. Nothing below the marker is edited.

<!-- ---8<--- everything after this line is the received text, byte for byte ---8<--- -->
# Research brief: an in-process read cache for the ledger service

## Question

What does an in-process read cache save in µs of CPU per request on the ledger service, and does the
allocator matter more than the cache?

## Method

The ruler comes first: the baseline against itself, interleaved, five rounds per arm, the first
discarded. The unit is µs of CPU per request from the occupancy of the subject's pinned cores, with
utime+stime from /proc/<pid>/stat recorded beside it.

- **Macro effect:** µs of CPU per request changes by at least 5 %, and by at least twice the ruler.
- A difference under twice the ruler is reported as "below resolution, effect under N %".

## Research questions

| RQ | Question | Green | Red |
| --- | --- | --- | --- |
| RQ1 | Ruler: is the stand fine enough? | ruler under 5 % | ruler above 5 % |
| RQ2 | Engine: which HTTP engine costs less CPU per request at 20 000 rps? | macro effect met | below resolution |
| RQ3 | Cache: what does the cache save on the read endpoints? | macro effect met on a majority of endpoints | below resolution on every endpoint |

## Budgets

One day for RQ1, one for RQ2, three for RQ3. A step that overruns is recorded as not completed.
EOF

cat > BRIEF.md <<EOF
# BRIEF — an in-process read cache for the ledger service

The pre-registration. The brief as received is docs/research/source-brief.md.

$(python3 scripts/brief_freeze.py --record docs/research/source-brief.md)

**Owner:** the study owner. **Budget:** as in the brief.

## Thresholds as operated

- Macro effect: at least 5 % **and** at least twice the ruler, µs of CPU per request.
- Rounds: five per arm, the first discarded (four counted).
- Hosts: subject \`bench-subject\`, generator \`bench-generator\`.

## Amendments

The amendment window closed on 2026-09-20 with B-01, before the first measurement.

### A1.1 — the engine comparison runs at a fixed 20 000 rps (2026-09-20, before the first measurement)

The brief names the rate; the generator's ceiling was measured at 60 000 rps with nothing dropped,
so 20 000 is well inside it. No threshold moves.
EOF

cat > logs/README.md <<'EOF'
# Raw logs

One directory per backlog item. Every figure in a document has a path into here.
EOF

cat > docs/research/results.md <<'EOF'
---
id: results
title: Ledger cache — results
type: research
status: draft
date: 2026-09-20
---

# Ledger cache — results

## Verdict table

| RQ | Question | Verdict | The number | Item |
|---|---|---|---|---|
| RQ1 | Ruler | | | B-03 |
| RQ2 | Engine | | | B-12 |
| RQ3 | Cache | | | B-07 |

## Micro table

| measure | A0, ns/op | A2 (profile), ns/op |
|---|---:|---:|
| interface | 1.703 | 1.524 |
| virtual | 1.290 | 1.123 |
| no dispatch | 0.781 | 0.779 |

Source: logs/b-09/2026-09-20-micro.txt.

## Allocator probe (outside the verdicts)

## Memory under the limit
EOF

commit "docs: pre-register the study and freeze the received brief"

case "$shape" in
  threshold)
    mkdir -p logs/b-03
    cat > docs/backlog/B-03-the-ruler.md <<'EOF'
---
id: B-03
title: "The ruler: A0 against itself"
status: done
priority: P0
---

# B-03 — The ruler

- AC: four counted rounds of A0 against A0, paired estimator, in logs/b-03/.
EOF
    cat > docs/backlog/B-07-rq3-the-cache-arms.md <<'EOF'
---
id: B-07
title: "RQ3 — the cache arms on the read endpoints"
status: open
priority: P0
blocked_by: [B-03]
---

# B-07 — RQ3, the cache arms
EOF
    cat > logs/b-03/2026-09-21-ruler.log <<'EOF'
# host: bench-subject (4 cores, kernel 6.8.0-45), nproc inside subject: 4, generator: bench-generator k6 v1.4.1
# binary: ledger-a0 sha256 3f1c...e09a, commit 9a1b2c3
# protocol: A0 vs A0, 5 rounds interleaved, round 1 discarded, 200 rps, 60 s per arm
round arm us_per_req_pinned us_per_req_proc
1 a 7690 8190
1 b 7744 8251
2 a 7612 8107
2 b 7812 8320
3 a 7801 8308
3 b 7611 8106
4 a 7905 8419
4 b 7720 8222
5 a 7655 8153
5 b 7870 8382
# paired per-round difference over counted rounds 2-5: mean -0.1 %, sd 2.9 % of the mean
# 95 % CI on a between-arm difference at 4 counted rounds: +/-4.7 %  -> twice the ruler: 9.4 %
EOF
    commit "feat(b-03): measure the ruler"
    ;;

  preload)
    mkdir -p logs/b-18
    cat > docs/backlog/B-18-allocator-probe.md <<'EOF'
---
id: B-18
title: "The allocator probe: LD_PRELOAD jemalloc, outside the verdicts"
status: wip
priority: P2
---

# B-18 — The allocator probe

A one-hour probe: the shipped binary with jemalloc preloaded against the same binary without it.

- AC: eight counted paired rounds, the result written into the results document.
- Anchors: `logs/b-18/`.
EOF
    cat > logs/b-18/2026-09-22-preload.log <<'EOF'
# host: bench-subject (4 cores, kernel 6.8.0-45), nproc inside subject: 4, generator: bench-generator k6 v1.4.1
# binary: ./ledger-pagedoff sha256 77a0...41c2, commit 9a1b2c3
$ file ./ledger-pagedoff
./ledger-pagedoff: ELF 64-bit LSB executable, x86-64, version 1 (GNU/Linux), statically linked, stripped
$ ldd ./ledger-pagedoff
	not a dynamic executable
# arm a: ./ledger-pagedoff
# arm b: LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2 ./ledger-pagedoff
# protocol: 9 rounds interleaved, round 1 discarded, 200 rps, 60 s per arm
round arm us_per_req_pinned
1 a 8102
1 b 8166
2 a 8175
2 b 8240
3 a 8091
3 b 8013
4 a 8233
4 b 8301
5 a 8150
5 b 8188
6 a 8044
6 b 8122
7 a 8210
7 b 8195
8 a 8133
8 b 8251
9 a 8188
9 b 8203
# paired (b - a) over counted rounds 2-9: mean +0.4 %, 95 % CI +/-0.6 %
EOF
    commit "test(b-18): run the allocator probe"
    ;;

  hosts)
    mkdir -p logs/b-09 logs/b-25
    cat > logs/b-09/2026-09-20-micro.txt <<'EOF'
a0 1 interface 1.711 ns/op
a2 1 interface 1.519 ns/op
a0 2 interface 1.698 ns/op
a2 2 interface 1.530 ns/op
a0 1 virtual 1.285 ns/op
a2 1 virtual 1.119 ns/op
a0 2 virtual 1.295 ns/op
a2 2 virtual 1.127 ns/op
a0 1 nodispatch 0.783 ns/op
a2 1 nodispatch 0.777 ns/op
a0 2 nodispatch 0.779 ns/op
a2 2 nodispatch 0.781 ns/op
EOF
    cat > logs/b-25/2026-09-21-ordinary.txt <<'EOF'
# host: workstation-2 (12 cores, kernel 6.1.0-18), session 2026-09-21T10:02Z
# build: ordinary release build, no PGO, commit 9a1b2c3
ordinary 1 interface 1.062 ns/op
ordinary 2 interface 1.070 ns/op
ordinary 1 virtual 0.801 ns/op
ordinary 2 virtual 0.807 ns/op
ordinary 1 nodispatch 0.484 ns/op
ordinary 2 nodispatch 0.488 ns/op
EOF
    commit "test(b-25): measure the ordinary build"
    ;;

  rps)
    mkdir -p logs/b-12
    cat > docs/backlog/B-12-rq2-the-engines.md <<'EOF'
---
id: B-12
title: "RQ2 — two HTTP engines at 20 000 rps"
status: wip
priority: P1
---

# B-12 — RQ2, the engines

- AC: both engines at 20 000 rps, interleaved rounds, the verdict written into the results.
- The ruler for this unit is +/-2.0 % at four counted rounds: logs/b-05/2026-09-21-engine-ruler.log.
EOF
    mkdir -p logs/b-05
    cat > logs/b-05/2026-09-21-engine-ruler.log <<'EOF'
# subject: bench-subject (8 cores, kernel 6.8.0-45), nproc inside subject: 8, service pinned to cores 0-7
# generator: bench-generator k6 v1.4.1, constant-arrival-rate 20000/s, 64 connections, 60 s per arm
# binary: ledger-cio sha256 1d0e...aa31 in both arms, commit 9a1b2c3
# protocol: cio against cio, 5 rounds interleaved, round 1 discarded
round arm offered delivered dropped pinned_busy_core_s responses
1 a 1200000 1200000 0 192.5 1200000
1 b 1200000 1200000 0 191.5 1200000
2 a 1200000 1200000 0 192.0 1200000
2 b 1200000 1200000 0 189.6 1200000
3 a 1200000 1200000 0 191.0 1200000
3 b 1200000 1200000 0 192.7 1200000
4 a 1200000 1200000 0 193.3 1200000
4 b 1200000 1200000 0 191.9 1200000
5 a 1200000 1200000 0 191.8 1200000
5 b 1200000 1200000 0 194.3 1200000
# paired per-round difference over counted rounds 2-5: mean -0.05 %, sd 1.2 % of the mean
# 95 % CI on a between-arm difference at 4 counted rounds: +/-2.0 %
EOF
    cat > logs/b-12/2026-09-22-engines.log <<'EOF'
# subject: bench-subject (8 cores, kernel 6.8.0-45), nproc inside subject: 8, service pinned to cores 0-7
# generator: bench-generator k6 v1.4.1, constant-arrival-rate 20000/s, 64 connections, 60 s per arm
# binaries: ledger-cio sha256 1d0e...aa31, ledger-netty sha256 c4b2...0f9e, commit 9a1b2c3
# columns: offered delivered dropped p50_ms pinned_busy_core_s proc_utime_stime_s responses
round arm offered delivered dropped p50_ms pinned_busy_core_s proc_utime_stime_s responses
1 cio   1200000 1199940 0 0.92 199.4 213.0 1199940
1 netty 1200000 1199990 0 0.61 104.9 112.1 1199990
2 cio   1200000 1199970 0 0.88 191.3 204.6 1199970
2 netty 1200000 1200000 0 0.60 101.8 108.9 1200000
3 cio   1200000 1199960 0 0.90 193.0 206.3 1199960
3 netty 1200000 1199980 0 0.59 102.4 109.6 1199980
4 cio   1200000 1199950 0 0.91 190.7 203.9 1199950
4 netty 1200000 1200000 0 0.62 101.5 108.6 1200000
5 cio   1200000 1199980 0 0.89 192.6 205.8 1199980
5 netty 1200000 1199990 0 0.60 102.9 110.1 1199990
EOF
    commit "test(b-12): run the engine comparison"
    ;;

  noload)
    mkdir -p logs/b-21/2026-09-23 docs/research/measurements-2026-09-23
    cat > docs/backlog/B-21-memory-under-the-limit.md <<'EOF'
---
id: B-21
title: "Does the service survive its 64 MiB limit, ten rounds in ten?"
status: wip
priority: P0
---

# B-21 — Memory under the limit

- AC: ten rounds under a 64 MiB cgroup limit at 200 rps; a positive control under a limit small
  enough that it must be killed; peak from memory.peak, kills from memory.events.
- Anchors: `logs/b-21/`.
EOF
    {
      echo "arm,limit,round,outcome,peak_kb,threads"
      for r in 1 2 3 4 5 6 7 8 9 10; do echo "fixed16,64m,$r,survived,$((21480 + r)),9"; done
      echo "control,6m,1,killed,6144,"
    } > logs/b-21/2026-09-23/results.csv
    for r in 1 2 3 4 5 6 7 8 9 10; do
      cat > "logs/b-21/2026-09-23/k6-fixed16-64m-$r.log" <<'EOF'
time="2026-09-23T09:14:02Z" level=error msg="The moduleSpecifier \"/bench/ingest.js\" couldn't be found on local disk. Make sure that you've specified the right path to the file. If you're running k6 using the Docker image make sure you have mounted the local directory (-v /local/path/:/inside/docker/path) containing your script and modules so that they're accessible by k6 from inside of the container, see https://grafana.com/docs/k6/latest/using-k6/modules/#using-local-modules-with-docker. Error: stat /bench/ingest.js: permission denied"
EOF
    done
    cp "logs/b-21/2026-09-23/k6-fixed16-64m-1.log" "logs/b-21/2026-09-23/k6-control-6m-1.log"
    commit "test(b-21): run the memory rounds"
    ;;

  *) echo "unknown shape: $shape" >&2; exit 2 ;;
esac
