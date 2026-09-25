# Two allocators under a container limit — the measurements

Referenced from step 1 of [SKILL.md](../SKILL.md). The settings themselves are carried by
`sborka.native-service` and the budget is read by `kore`; what is here is the evidence for the
numbers and the method for taking your own, which is the part no convention can apply for you.

**`fixedBlockPageSize=16` — the convention sets it; what follows is what it buys.** It is a
`binaryOption` on the executable, and `sborka.native-service` applies it to the executable it already
configures: a service that takes the plugin is not in the first row of the table below and never had
to know the option's name. `nativeService.allocatorPageSize` changes the number and `0` leaves the
compiler's default — read the rest to decide whether your service is one that should, not to decide
whether to add a line.

The Kotlin/Native allocator keeps a page per size class **per thread** (256 KiB by default), a
thread holds it for as long as it lives, and `Dispatchers.IO` grows threads under concurrency. Resident memory follows the **number of
threads**, not the live heap, and no GC setting bounds it: these are pages, not objects. Measured on
katcher — same binary, same image, `--memory=192m --cpus=1`, 50 concurrent requests for pages
rendered out of SQLite:

| | RSS at rest | peak under a 1 GiB limit | survived 192Mi |
|---|---|---|---|
| default | 56–68 MB | 252–329 MB | **0 / 8**, `exit=137` |
| `fixedBlockPageSize=16` | 22–26 MB | 47–62 MB | 8 / 8 |
| `-Xallocator=std` | 21–22 MB | 85–161 MB | 3 / 3 |

A plateau, not a leak: over a five-minute soak the thread count jumps 16 → 73 in the first half
minute and stays at exactly 73, RSS settles at 60–70 MB and does not creep. **But the plateau is a
property of that load, not of the recipe:** in tracy, under continuous ingest, the thread count was
driven by feedback through the journal, and there was no plateau at all — there was a cliff (see WAL
and the shape of a measurement below). **Do not take `-Xallocator=std` by analogy** — for a service
with SQLite on the request path its peak turned out *higher* than with 16 KiB pages, and throughput
lower; on a service without a database it behaved the other way round. The mechanism transfers, the
constant does not — measure on your own service, and always with a positive control (the same image
under a deliberately small limit must be killed, otherwise the harness cannot detect a failure at
all). Details and the upstream address:
[KT-89365](https://youtrack.jetbrains.com/issue/KT-89365).

**The counter-case: a heap of gigabytes on a few threads wants 256 KiB, and pays for 16 in pause.**
Everything above is a service with many threads and a heap of tens of megabytes, where the pages
held per thread *are* the resident set. Turn the shape around and the same option costs something
else. At the end of marking, with the world still stopped, every thread's allocator and the heap run
`PageStore::PrepareForGC` for every size class (Kotlin 2.4.20,
[`alloc/custom/cpp/PageStore.hpp:24`](https://github.com/JetBrains/kotlin/blob/v2.4.20/kotlin-native/runtime/src/alloc/custom/cpp/PageStore.hpp#L24),
called from
[`gc/common/cpp/MainGCThread.hpp:56–69`](https://github.com/JetBrains/kotlin/blob/v2.4.20/kotlin-native/runtime/src/gc/common/cpp/MainGCThread.hpp#L56-L69)):
it walks the used-page list to its tail and frees every page the previous sweep emptied, one at a
time. Linear in the number of pages, inside the pause — and the same heap in 16 KiB pages is sixteen
times as many. Measured on an in-memory store holding about 2 GB live on three threads, CMS, the two
builds interleaved on one host, three runs each, 60 s of write churn:

| | pause p50 | pause p99 | peak RSS |
|---|---|---|---|
| `fixedBlockPageSize=16` | 8.0–10.0 ms | 84–139 ms | 4 237–4 244 MB |
| `fixedBlockPageSize=256` (the compiler's) | 0.76–0.83 ms | 8–18 ms | 4 290–4 304 MB |

Tenfold on the pause for 1 % of memory. Controls moved the objects marked 4.7× and the garbage made
during marking 10×, and the pause followed neither: **it follows the page count, so it grows with
the heap.** That report is not public; the mechanism is the runtime source linked above.

So the rule has two sides, and the convention's default is the first:

| shape | `nativeService.allocatorPageSize` | what goes wrong otherwise |
|---|---|---|
| many threads, a heap of tens of megabytes | **16** (the default) | resident memory — the service is OOM-killed under its limit |
| few threads, a heap of gigabytes | **256** | the collector's stop-the-world pause, an order of magnitude longer |

A service in between measures both — peak memory from the cgroup (below) and the pause from the GC
log — instead of picking a side by analogy. The per-thread cost comes back at 256 KiB with every
thread that touches a size class, so a large heap served by a hundred threads pays both and has to
choose by measurement.

**And read the number the kernel kills on, which is not the process's.** Peak memory comes from the
cgroup — `memory.peak`, with the kill count from `memory.events`' `oom_kill` — and *not* from
`/proc/<pid>/status`'s `VmHWM`. `VmHWM` counts the mapped pages of a ten-megabyte binary among other
things, which are reclaimed rather than charged when memory is tight: on one service it reported
**9 600 kB for a container the kernel was holding under an 8 MiB limit**. That is the tell to watch for — a peak
larger than the limit it is supposedly measured against means the metric is wrong, not the limit.

```bash
cgroup=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' "$NAME").scope
peak=$(awk '{printf "%d", $1/1024}' "$cgroup/memory.peak")            # kB
killed=$(awk '/^oom_kill /{print ($2 > 0)}' "$cgroup/memory.events")
```

**This recipe stays in the skill deliberately, and it is the one thing in this step that does.** It
is method, not configuration: there is nothing to apply it to. When sborka's Brief C
(`research-memory-limit.md`) lands, the harness moves there and this block becomes a citation.

**The process's own side of it is kore's**, since 2026-09-15: `containerMemoryBudget()` reads the
cgroup — both layouts, walking up to the ancestor that actually bounds the pod — and answers
`Bounded` / `Unbounded` / `Unavailable`, three cases because an unreadable cgroup is not an absent
limit. `--print-config` prints it, so the number the kernel will kill on is visible beside the
configuration in the same output. Two things that paragraph used to get wrong and no longer does:
`/sys/fs/cgroup/memory.max` **does not exist on an unconstrained host** (the kernel makes no such
file for a cgroup that cannot be limited), and a container limit does not go in
`GC.targetHeapBytes` — autotune rewrites it after a collection (201 326 592 read back as 5 242 880
on linuxX64/2.4.10). The ceiling is `GC.maxHeapBytes`, and kore's `applyHeapCeiling()` sets it.
**kore does not set it for you**, and neither does this skill: what fraction of a limit should be
heap is the service's measurement, which is exactly what the table above is for.

**Record the peak thread count in the same row.** On this platform resident memory follows the
thread count rather than the live heap, so a peak with no thread count beside it has no mechanism
attached to it — and, as the next section shows, the thread count is also the first place a broken
harness gives itself away.

**`MALLOC_ARENA_MAX=2` — the second allocator, one floor down, and it is also about threads.**
Underneath the Kotlin/Native allocator sits glibc's malloc, and the allocations of sqlx4k's Rust half
go through it too. glibc gives a thread **an arena of its own** whenever the one it wants is busy, up
to eight arenas **per host core** — it does not see the container's quota, so `--cpus=1` on a
twenty-core runner still gets a ceiling of 160. An arena returns pages only from its top, so resident
memory is the sum of every arena's **high-water mark**, not the live heap; in `/proc/pid/smaps` this
is visible literally — anonymous mappings of 6–12 MB on 64 MB boundaries, 120 MB out of 130 in tracy.

It belongs in the image's runtime stage and not in the chart — it is a property of running the
binary under a limit, so `docker run` and the CI smoke have to get it too — and **sborka's reference
Dockerfile already carries the line**: `writeNativeDockerfile` writes it, and a test in the
convention pins it with its value. An A/B on tracy, one box, the same recorded database: `anon` 74 → 49 MB at the tenth minute, 82 → 54 at
the tenth-and-a-half, that is **a third less**. The price is contention on the `malloc` lock: a
service that waits on SQLite and the disk does not pay it, a workload bound by allocation will
regress — measure on your own.

**And here is the measurement that says how hard "measure on your own" is meant.** A Ktor service
with **no database at all** (one route, one JSON object, 2 000 rps, 200 connections, 512 MiB, ten
runs per arm, 2026-09-15):

| | survived | peak RSS |
|---|---|---|
| `fixedBlockPageSize=16` | 10/10 | 65.3 MB |
| `fixedBlockPageSize=16` + `MALLOC_ARENA_MAX=2` | 10/10 | 62.8 MB |
| `-Xallocator=std` | 10/10 | **39.3 MB** |
| `-Xallocator=std` + `MALLOC_ARENA_MAX=2` | **7/10** | **413.7 MB** |

With the Kotlin page cache in charge the cap does nothing — 65.3 against 62.8 MB, inside the spread
of either arm, and identical megabytes per thread. **With `-Xallocator=std` it is a tenfold
regression and an OOM kill**: every uncapped run peaks between 32.6 and 51.4 MB, every surviving
capped one between 277 and 535, and three runs of ten are killed by the kernel at a limit where
nothing else in that study dies.

The mechanism is the one above, running backwards. An arena returns pages only from its top, so
resident memory is the sum of the arenas' high-water marks — and with ninety to a hundred and forty
threads allocating through malloc, **two arenas accumulate between them the churn that thirty-two
spread out**. Fewer arenas is less address space and more retained memory; which of the two wins
depends entirely on how much traffic reaches malloc at all. On tracy, where the Rust half of sqlx4k
is on the request path, capping won by a third. On a service whose allocation never leaves the Kotlin
heap, capping is either free or catastrophic depending on which allocator is underneath it.

**So the rule, stated as a rule:** `MALLOC_ARENA_MAX` is decided by a measurement on the service that
will ship it, and **never combined with `-Xallocator=std` without one**. A positive control is part
of that measurement — the same image under a deliberately small limit must be killed — otherwise a
harness that cannot detect a regression will report its absence.

**A measured setting that nothing asserts gets deleted sooner or later** — which is why that
assertion is in sborka (`NativeImageReferenceTest`, pinning the whole line, value included) and not
copied into every repository's workflow. It covers the reference Dockerfile. It does **not** cover
one that has been hand-edited since, and a service that edits its own owns the check for it.

## Running the measurement so that it can fail

These sat in the chart step, which is the wrong home: they are not about a chart, they are what
separates a memory measurement from a run that looked like one.

* **the memory limit comes after a measurement, and with a positive control.** In katcher it went
  64Mi → 192Mi ("an unexplained crash") → 128Mi, and the last number is twice the measured peak, not
  a round figure. A measurement is only good if the same image under a deliberately small limit
  **is killed**;
* **and the measurement has to hold the input fixed.** A generator with a fixed number of writers
  (`--vus N`) is a closed loop: a server that slows down receives less, so the feedback "slower →
  more requests in flight → slower still" never shows up in it at all. In tracy a five-minute run of
  that shape produced a "plateau", while `constant-arrival-rate` on the same image showed a cliff
  and an OOM at minute 65. A short run in which everything passed proves nothing about a day;
* **and before trusting a run — read the container's environment.** Twice in one session the harness
  lied: an old copy of the script did not pass the variable through, and somebody else's container
  was background noise for one arm of a pair and not for the other.
  `docker inspect --format '{{.Config.Env}}'` right after startup is part of the procedure, not
  pedantry;
* **and ask the subject whether any load arrived, because a generator that never started looks
  exactly like a service that is coping.** Flat memory, flat threads, every probe `200`, zero
  failures — the shape of a pass. In one memory campaign **all forty** generator logs held one
  line, `stat /bench/ingest.js: permission denied`, and the run reported *10/10 survived at 64 MiB*
  for a process nothing had talked to. Re-measured with the generator running, the same default
  allocator was killed **10 times out of 10**. Two assertions, and they are not the same one:
  - **the generator's own output**, per round — `http_reqs` present in k6's summary, or the round is
    recorded as `no-load` and the harness refuses to print a table at all;
  - **the subject's own count of work done**, thirty seconds in — "how many rows have you stored?".
    This is the one that matters, because it is the question a broken generator cannot answer in the
    affirmative, and it needs no cooperation from the generator to ask.

  Note what did *not* save that run: it had a correct positive control, and the control passed. **A
  control proves the stand can detect the failure it was built for, and nothing else** — a control
  for the subject dying is not a control for load being applied. The tell was in the results table
  the whole time: every arm sat at 18 threads under a nominal 200 rps, which was noticed and
  explained away as a weak stand. Under real load the same arms reached 146;
* **and stage the scenario where the generator's user can read it — never bind-mount your working
  tree.** That is what produced the `permission denied` above: a working tree whose files are mode `0600`
  and an image that runs as a non-root user — the container can see the path and not the file. `mktemp -d`, `chmod 755` the directory, `chmod 644` the file, mount that. The same
  applies to any directory the container writes a summary back into (`chmod 777`, it is a temporary
  directory);
