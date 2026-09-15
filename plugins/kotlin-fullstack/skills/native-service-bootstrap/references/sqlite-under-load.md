# SQLite in a Kotlin/Native service: the pool, the busy timeout and the journal

Referenced from step 4 of [SKILL.md](../SKILL.md). The rules are there; the measurements that set
them, and the two that did **not** reproduce the way the rule was first written, are here.

**And whatever the pool size, set a busy timeout.** SQLite has one writer; the second connection that
wants the write lock gets `SQLITE_BUSY` *immediately* unless something is told to wait. Two different
services were bitten by this in one session of the same project: the Kotlin side hit it while the pool was still
opening its connections (a retry around acquisition fixed that), and the Go twin — `modernc.org/sqlite`
with no `busy_timeout` in its DSN — shed **48.7 % of requests under load** with `500`s while passing a
parity gate that exercised one request at a time. A driver that gives up instead of waiting is *fast
because it is doing less*, which is exactly the shape a comparison table flatters. Set it in the DSN
(`?_pragma=busy_timeout(5000)` for that driver) and add a concurrent burst to any parity check: a gate
that only sends one request at a time cannot see this at all.

**If readers do overlap anyway, you need your own journal truncation.** The symptom looks like
nothing else: `-wal` grows linearly (931 MB in tracy), **the database file stops growing** — the
data is in the journal — reads get more expensive, at a fixed input the number of in-flight requests
grows, threads and arenas follow, and the process is killed on memory although the heap is small.

**Two halves of that sentence did not reproduce on a webhook gateway under continuous ingest, and
the difference matters when you are looking for the symptom.** Measured there (20 min, 200 rps ingest, four overlapping journal readers,
no sweep, 64 MiB): the journal rose to **70.6 MB, then plateaued** and stayed flat for the rest of
the run, while **the database file grew the whole time**, from 3 MB to 55 MB. PASSIVE checkpoints
were copying pages across throughout — what they cannot do while a reader is alive is *reset the
file*, so what you are guaranteed is a high-water mark that is never given back, not unbounded
growth. The degradation was real but arrived as latency rather than as a kill: memory pinned on the
limit for twenty minutes, `/health/ready` intermittently `503`, p99 5.47 s, 87 rps delivered of 200
offered with **zero** rejected. So: **do not wait for the database to stop growing, and do not wait
for an OOM** — watch the `-wal` file itself and the readiness probe. One run, one rate, one service;
the mechanism transfers, the shape of the curve evidently does not.
The cure is to call `PRAGMA wal_checkpoint(TRUNCATE)` yourself, on a timer **and on file size** (a
timer alone is not enough: on a wound-up loop the journal grows between passes). TRUNCATE, not
RESTART: RESTART resets the journal but leaves the file at its peak.

**And the journal must be visible from outside.** `PRAGMA page_count * page_size` **does not include
it** — nor does any size ceiling counting the same pages. In tracy, 931 MB of journal next to a
183 MB database was reported as "well under the limit": the disk guard was looking past the very
file that was filling the disk. Report `walBytes` as its own field, and **without a default in
`@Serializable`**: `encodeDefaults = false` drops a field equal to its default, and zero turns into
an absent key.
