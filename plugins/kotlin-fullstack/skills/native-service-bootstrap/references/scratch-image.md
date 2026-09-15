# `FROM scratch` — the decision, the condition, and what travels with the binary

Referenced from step 7 of [SKILL.md](../SKILL.md). The recipe itself is deliberately not here
either: it pins five `konan.properties` keys that an upstream fix is about to make unnecessary, so
it lives in sborka's research, in a form that runs.

#### `FROM scratch` — the decision, and where the recipe actually lives

**The recipe is not in this file, on purpose.** It pins five `konan.properties` keys, and
[KT-89362](https://youtrack.jetbrains.com/issue/KT-89362) removes the need for two of them — a copy
here would keep prescribing a link that has stopped being the right one, and it would keep building,
which is how the wrong version survives. It lives in sborka, in two runnable forms:

* **[`docs/research/static-probe/build.gradle.kts`](https://github.com/youndie/sborka/blob/main/docs/research/static-probe/build.gradle.kts)** —
  the link modes as Gradle, `-PlinkMode=statichost` being the one that reaches `scratch`, with
  [`experiments.sh`](https://github.com/youndie/sborka/blob/main/docs/research/static-probe/experiments.sh)
  running the whole matrix and printing a report.
* **[`research-static-binary.md`](https://github.com/youndie/sborka/blob/main/docs/research/research-static-binary.md)** —
  §1.5a why five properties and not one, §1.5b the same recipe on a real service, §1.5c what the
  image needs beside the binary, §1.6a where each link flag comes from, D3 the decision.

Take the flags from there when the task calls for them; do not reconstruct them from meaning. The
`linkerKonanFlags` value in particular is the stock one **minus `-Bdynamic` and nothing else**, its
value continues onto a second line in `konan.properties`, and a version rewritten from understanding
loses `--gc-sections` and costs 316 488 bytes for nothing. That mistake has been made once already.

**There is no `image { base = scratch }` in sborka, and that is a decision rather than a gap** (D3).
An option in a shared convention that breaks on a Kotlin patch release, silently, inside somebody
else's service, costs more than the 9 MB it saves. The first consumer is
[katcher#55](https://github.com/youndie/katcher/issues/55) — the recipe in one service's own
Dockerfile, where a Kotlin bump breaking it is that repository's problem. It becomes a convention
when `-static` means static without overrides.

What this step still decides, because none of it is a flag:

**Order: distroless first, `scratch` only if it is still wanted afterwards.**
`debian:bookworm-slim` → `gcr.io/distroless/cc-debian13` is one line and about **65 MB** of base
image (75 → 10), with `ca-certificates` already in there. `scratch` on top of that adds about **6 MB
to pull** and all of the work above. On katcher the whole distance was **15 542 820 → 9 570 311 bytes
to pull** (`docker image inspect .Size` is the uncompressed size on overlay2 and the compressed one
on the containerd snapshotter — two different numbers behind one field; quote which). One check
before the move: `readelf -d` on the real binary — `stageNativeImage` has already written it to
`<baseName>.needed.txt`.

**The condition without which `scratch` is not taken at all: the binary must be linked inside the
image.** The shared glibc beside it comes out of the build stage and must be the same build the
`libc.a` was linked against. While the binary is built on the runner — which is what the heading of
this step recommends, for the minutes — donor and link match only by an agreement of the form
"runner `ubuntu-24.04` ↔ donor `ubuntu:24.04`", and `ubuntu-latest` updates itself, silently. The
fork named on metrik: move the build inside the image (buildx caching gives some of the minutes
back), pin both sides, or do not do `scratch` at all. And the more non-base content the image has,
the less it buys: metrik also carries the dashboard's wasm bundle, katcher does not.

**`FROM scratch` is not one `COPY`.** Five paths travel with the binary — `ld.so.cache`, the loader,
`libc.so.6`, the whole `gconv` directory and `zoneinfo` — because Ktor's charset layer on
Kotlin/Native *is* glibc `iconv` and `iconv_open` uses `dlopen`; a static binary can still `dlopen`.
An image with the binary alone starts, serves static files, answers `401` everywhere and returns
`500` on the first page behind authentication with `Failed to open iconv for charset UTF-8`. The
paths, their provenance (`strace`, not reasoning), the price of taking the gconv directory whole
(2 811 555 bytes) and the fact that `zoneinfo` is insurance nothing reads are §1.5c above.

**What `scratch` costs:** no shell, nothing to `kubectl exec` into, no `/tmp`, no `ca-certificates`
(outbound https needs those copied too). The directory of the database file must exist: `WORKDIR`
creates it, and in the cluster a volume is mounted over it.

**And the check without which all of this is pointless:** the smoke test must reach a **rendered
page**, not a status code. `GET /` → `401` passes on an image that cannot render anything — it is
what let the static build look finished for two days. katcher has `dev/image-smoke.sh`: it signs in
with the two proxy headers, creates an app, reveals its key, sends a crash and requires the group
page to render `YYYY-MM-DD HH:MM` — as its own job in CI, against the real image, not one built
locally.

The full model with a multi-stage build and pre-compressed static files is `examples/deploy.md`.
