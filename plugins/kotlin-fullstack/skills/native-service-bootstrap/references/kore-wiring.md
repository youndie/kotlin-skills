# kore wiring: nine things the code in step 6 does not show

Referenced from step 6 of [SKILL.md](../SKILL.md). Each of these has already cost somebody time,
and each is a line in that `main` or that module whose reason is not visible in the line.

* **`startForKore()`, not `start()`.** With `wait = true` the main thread never reaches the signal
  wait, the sequence never runs at all, and the process is killed at the end of the grace period —
  from outside, indistinguishable from "it stopped". `wait = false` is not enough either, on both
  targets. On the JVM `start()` registers Ktor's own shutdown hook, the JVM runs hooks
  concurrently, and that one stops the engine at the signal, mid-announce: every probe on a new
  connection was refused 13 ms after `SIGTERM` ([kore#90](https://github.com/youndie/kore/issues/90)).
  On Kotlin/Native Ktor's handler is armed between `start` and kore's own, runs `runBlocking` on the
  signal stack, and a `SIGTERM` in that window **hangs** the process ([kore B-63](https://github.com/youndie/kore/blob/main/docs/backlog/B-63-sigterm-right-after-start-segfaults.md)). `startForKore()`
  closes both; `EngineDrain` refuses to be built beside a JVM hook that is still on.
* **The refusal reads a `DrainGate`, never readiness.** Readiness falls at the start of the announce,
  and the announce exists to keep **serving** while that news reaches every node. A refusal gated on
  readiness answers `503` to exactly the requests the wait is for. It passed every check for weeks,
  because it only shows once the pre-drain wait outlasts the requests in flight. Every service wired
  before kore 0.1.7 did this: `installShutdownRefusal(isShuttingDown = { readiness.isShuttingDown })`
  is the line to look for, and it is deprecated now. The same gate instance goes to
  `installShutdownRefusal` and to `EngineDrain`, which opens it as its first act ([kore B-61](https://github.com/youndie/kore/blob/main/docs/backlog/B-61-refusal-starts-at-the-announce.md)).
* **`reuseAddress = true` on the engine, and a busy port is a configuration error.** CIO defaults the
  flag to `false`. The JVM ignores that, because the JDK opens every server socket with it on;
  Kotlin/Native applies it. So a native process restarted in place — a supervisor, a local loop,
  `--network host` — meets its predecessor's `TIME_WAIT` and cannot bind ([kore B-62](https://github.com/youndie/kore/blob/main/docs/backlog/B-62-native-restart-meets-time-wait.md)). The first
  restart after turning the flag on still cannot: the old listener needed it too. And on native a
  failed bind is not an error message: CIO binds inside its own coroutine, and the process ends with
  `SIGABRT` and fifty lines of stack. If configuration is read through kore's `ConfigSchema`, call
  `requireListenable(portKey, reuseAddress = true)` after reading it. That makes a port something
  already holds a one-line refusal naming the variable, with the same flag the engine uses ([kore B-59](https://github.com/youndie/kore/blob/main/docs/backlog/B-59-a-busy-port-aborts-the-native-build.md)).
* **The database is opened in `main`, before the engine.** Otherwise the release stage has no handle
  on the pool, and closing it is left to `ApplicationStopping` again — that is, in the wrong order.
* **Nobody calls `HealthRegistry.start(scope)` for you.** Without that call `/health/ready` answers
  out of checks that never ran once — `UNKNOWN` forever, which reads as a broken dependency.
* **The deadlines and the chart's `terminationGracePeriodSeconds` are one number in two places.** No
  platform tells a process its real budget; kore takes the one it is *told*. The plan's sum must be
  smaller: in katcher 2 + 10 + 3×3 = 21 against 30.
* **Participants registered in one stage run concurrently.** `runStage` launches all of a stage's
  participants and joins them; only the *stages* are ordered. So `consumer(a)` before `consumer(b)`
  orders nothing, however much it reads like a list of steps. An order needed **inside** a stage is
  written as composition — one participant calling two things in sequence — and an order needed
  between resources is written as a **later stage**. Getting this wrong is quiet: the stage still
  reports `COMPLETED`, and the collision surfaces as an intermittent deadline on a slower machine.
* **`cancel()` is not "stopped", it is "told to stop".** A `stop()` that cancels its loop's job
  without joining it returns while the work is still in flight, and on Kotlin/Native that work is
  often inside an FFI call cancellation never reaches — so it runs on **into the next stage** and
  collides with what that stage does. `cancelAndJoin` in every background loop's `stop()`. A stage
  that suddenly reports 200 µs is not healthy, it is a stage where nobody waited for anything.
  kore's `HealthRegistry` had the same defect ([youndie/kore#79](https://github.com/youndie/kore/issues/79)):
  call `stopAndJoin()` in its participant, not the deprecated `stop()`. **And register that
  participant with `consumer(...)`, never `telemetry(...)`.** A readiness check is a statement
  against the pool, and kore's order is consumers → pools → telemetry (`KoreStage`): telemetry runs
  *after* the pool has closed. "Health" reads like telemetry, and two services put the stop there —
  their check loop outlived the pool it queries, one with a comment saying the next stage closes the
  pool ([metrik#61](https://github.com/youndie/metrik/pull/61),
  [tracy#78](https://github.com/youndie/tracy/pull/78)). The transcript cannot show it: an empty
  telemetry stage and a busy one both report `COMPLETED`, so read where the stop is registered.
* **`/version` is generated source.** Kotlin/Native has neither resources nor a manifest; the plugin
  writes an object and puts it into `commonMain`. `commit` will be `unknown` wherever the build
  context has no `.git` — the usual case being `.dockerignore`. And beware: a file git **tracks**
  but `.dockerignore` excludes reads as deleted inside the build, and the stamp becomes `-dirty`
  forever.
