# The Kotlin API over a raw binding

Referenced from steps 5 and 6 of [SKILL.md](../SKILL.md). Written for this repository against a
fictional C library, `ev` (a handle, an asynchronous submit with a completion callback, a
connection pool); every shape is one a portfolio binding uses, and the comment over each block says
which. Assumes Kotlin 2.2+ and kotlinx.coroutines 1.10+, `@OptIn(ExperimentalForeignApi::class)`
throughout.

## Who frees what — one block per owner

```kotlin
// 1. Call-scoped: memScoped. Everything allocated in the block is freed when it ends, so a pointer
//    from here must not outlive the call — a library that KEEPS a pointer it was given needs memory
//    it owns (nativeHeap, freed when the library is done with it).
fun Ev.version(): String = memScoped {
    val buffer = allocArray<ByteVar>(64)
    val rc = ev_version(handle, buffer, 64.convert())
    if (rc != EV_OK) throw EvException.of(rc, "version")
    buffer.toKString()                                // copies: the String survives the scope
}

// 2. Library-allocated: freed by the library's own function, never by free() — it may have its own
//    allocator (getaddrinfo → freeaddrinfo in metrik's HostResolver.native.kt; tjFree in a private
//    study; bson_destroy in mongkn).
fun Ev.describe(): String {
    val info = ev_describe(handle) ?: throw EvException.of(ev_last_error(handle), "describe")
    try {
        return info.pointed.name?.toKString() ?: ""
    } finally {
        ev_info_free(info)
    }
}

// 3. Long-lived: nativeHeap, freed by an owner with a close() that somebody is obliged to call.
//    kesh's epoll loop allocates its event array this way and frees it in `finally` when the loop
//    ends. stately's Lock HAS a close() that frees its Arena; koin-ktor's per-call scope never called
//    it, and that is 64 bytes per request (kore B-65). A close() nobody calls owns nothing.
class Poller : AutoCloseable {
    private val events = nativeHeap.allocArray<ev_event>(MAX_EVENTS)
    override fun close() = nativeHeap.free(events)
}

// 4. Kotlin bytes handed to C for the duration of one call: usePinned, with the length explicit.
//    The .def says `noStringConversion = ev_put_string`, so the function takes a pointer and a length
//    rather than a String — cinterop's String conversion stops at the first NUL (mongkn §1.15).
//    noStringConversion applies to EVERY `const char*` of the function, so `key` loses its String
//    conversion too and goes in as `key.cstr` (boundary-probes.md).
fun Ev.putString(key: String, value: String) {
    val bytes = value.encodeToByteArray()
    if (bytes.isEmpty()) {                            // addressOf(0) on an empty array throws
        check(ev_put_string(handle, key.cstr, null, 0.convert()) == EV_OK)
        return
    }
    bytes.usePinned { pinned ->
        check(ev_put_string(handle, key.cstr, pinned.addressOf(0), bytes.size.convert()) == EV_OK)
    }
}
```

## A completion callback into a suspended coroutine

The shape of sqlx4k's `ffi.kt`: a `StableRef` to the continuation, passed as the C user-data pointer
and resumed from a `staticCFunction`. Two corrections are added. Nothing is thrown out of the callback
(kafkakn research §2.3; [boundary-probes.md](boundary-probes.md#an-exception-thrown-out-of-a-callback)
shows both ways a throw ends). And cancellation is told to the library rather than assumed.

```kotlin
// On whatever thread calls it. That may be a thread the library created (sqlx4k: a tokio worker),
// where a throw is `Uncaught Kotlin exception` and exit 134. Or it may be the thread that called into
// the library (librdkafka: inside rd_kafka_poll), where the throw unwinds into THAT code, leaves the
// library half-done and never reaches the waiting caller. A staticCFunction captures nothing;
// everything it needs arrives through the opaque pointer.
private val onDone = staticCFunction { opaque: COpaquePointer?, result: CPointer<ev_result_t>? ->
    val ref = opaque?.asStableRef<CancellableContinuation<Outcome>>() ?: return@staticCFunction
    val continuation = ref.get()
    ref.dispose()                                     // exactly once, before anything can throw
    val outcome =
        try {
            Outcome.of(result)                        // copy out of C memory before it is freed
        } catch (e: Throwable) {
            Outcome.Failed(e)
        } finally {
            ev_result_free(result)                    // the library allocated it
        }
    continuation.resume(outcome)                      // ignored if the caller was cancelled meanwhile
}

suspend fun Ev.submit(payload: ByteArray): Outcome {
    // BEFORE the StableRef: addressOf(0) throws on an empty array, and a throw after create() would
    // leak the reference.
    require(payload.isNotEmpty()) { "ev_submit takes at least one byte" }
    return suspendCancellableCoroutine { continuation ->
        val ref = StableRef.create(continuation)
        // ev_submit COPIES the payload before it returns — read that in the header. If it kept the
        // pointer, the pinned array would be unpinned by the time the library read it.
        val rc = payload.usePinned { pinned ->
            ev_submit(handle, pinned.addressOf(0), payload.size.convert(), onDone, ref.asCPointer())
        }
        if (rc != EV_OK) {                            // refused: the callback will never come
            ref.dispose()
            continuation.resumeWithException(EvException.of(rc, "submit"))
            return@suspendCancellableCoroutine
        }
        // Cancellation reaches C only through a call like this one. The callback still arrives
        // afterwards and still owns the StableRef; this handler must not dispose it.
        continuation.invokeOnCancellation { ev_cancel(handle, ref.asCPointer()) }
    }
}
```

What this does **not** give: a library without a cancel call keeps working after the caller left,
and a record "cancelled" after it was queued may still be delivered (kafkakn B-73 measured exactly
that on both of its arms). The KDoc says which.

sqlx4k uses `suspendCoroutine`, not the cancellable form (`sqlx4k-postgres/src/nativeMain/.../ffi.kt`),
so a cancelled caller waits for the Rust future regardless.

## A callback that belongs to one instance

A `staticCFunction` has no `this`. kafkakn's error callback wrote to one process-wide slot for that
reason and documents it as a limitation (research §2.9); the way out is the library's user-data
setter (`rd_kafka_conf_set_opaque` there).

```kotlin
class Client : AutoCloseable {
    private val handle: CPointer<ev_t> = checkNotNull(ev_new())
    private val self = StableRef.create(this)

    init {
        ev_set_opaque(handle, self.asCPointer())
        ev_set_error_cb(handle, onError)
    }

    internal fun recordError(code: Int, reason: String?) { /* must not throw */ }

    override fun close() {
        ev_destroy(handle)                            // first: after this the library cannot call back
        self.dispose()                                // then the reference it was calling back through
    }
}

private val onError = staticCFunction { opaque: COpaquePointer?, code: Int, reason: CPointer<ByteVar>? ->
    opaque?.asStableRef<Client>()?.get()?.recordError(code, reason?.toKString())
    Unit                                              // staticCFunction wants `-> Unit`, not `Unit?`
}
```

## Codes into typed errors

```kotlin
// A return code, an error object, or a process-wide "last error" — read the header for which one
// each call uses. kafkakn moved to rd_kafka_produceva partly because it returns an error object
// instead of -1 plus a global (research §2.10); rd_kafka_flush returns a code that once printed as
// "-185 messages left" (§1.4).
sealed class EvException(message: String) : Exception(message) {
    /** Backpressure, not failure: the caller suspends and retries. */
    class QueueFull(message: String) : EvException(message)

    class Rejected(val code: Int, message: String) : EvException(message)

    companion object {
        fun of(code: Int, what: String): EvException {
            val text = ev_strerror(code)?.toKString() ?: "code $code"     // a static string: not freed
            return if (code == EV_ERR_QUEUE_FULL) QueueFull("$what: $text") else Rejected(code, "$what: $text")
        }
    }
}

// errno is per thread and the next C call may overwrite it: read it on the line after the failure.
// EINTR is a signal arriving, not an error — one more turn of the loop (kesh's EventLoop.kt).
fun readSome(fd: Int, buffer: CPointer<ByteVar>, size: Int): Long {
    while (true) {
        val n = read(fd, buffer, size.convert())
        if (n >= 0) return n
        val err = errno
        if (err != EINTR) throw IllegalStateException("read: ${strerror(err)?.toKString()} ($err)")
    }
}
```

## A blocking library under coroutines

```kotlin
// mongkn §1.12–1.13: a thread inside a blocking pool pop cannot be cancelled, so withTimeout and the
// test framework's own timeout both stayed silent while the build hung. The fix makes the WAIT a
// suspension: one permit per pooled connection, so the C pop never blocks.
class EvPool(private val pool: CPointer<ev_pool_t>, size: Int) {
    private val permits = Semaphore(size)

    init {
        ev_pool_set_max_size(pool, size.convert())    // the semaphore and the C pool are ONE number
    }

    suspend fun <T> withConnection(block: (CPointer<ev_conn_t>) -> T): T =
        permits.withPermit {                          // cancellable, holds no thread while it waits
            withContext(Dispatchers.IO) {             // on native: import kotlinx.coroutines.IO
                val conn = checkNotNull(ev_pool_pop(pool))
                try {
                    block(conn)                       // never suspends: the handle stays on this thread
                } finally {
                    ev_pool_push(pool, conn)          // break this and the permits outlive the clients
                }
            }
        }
}

// A readiness probe that must answer in 2 s even when the library hangs. withTimeout around the
// call bounds nothing; awaiting a call that is NOT the probe's child bounds the answer.
class Reachability(private val pool: EvPool) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Mutex()
    private var inFlight: Deferred<Boolean>? = null   // read and written under `lock` only

    suspend fun reachable(): Boolean {
        // AT MOST ONE PING IN FLIGHT. While one hangs, the next probe waits on the same one instead
        // of starting another: each new ping would hold another IO thread and another pooled
        // connection until the library gives up, and probes arrive every few seconds.
        val ping =
            lock.withLock {
                inFlight?.takeIf { it.isActive } ?: scope.async {
                    try {
                        pool.withConnection { ev_ping(it) == EV_OK }
                    } catch (e: EvException) {
                        false
                    }
                }.also { inFlight = it }
            }
        return withTimeoutOrNull(2.seconds) { ping.await() } ?: false
        // The answer is bounded; the thread inside ev_ping is not. It stays there until the
        // library's own timeout, so set one — and measure the probe's time_total, not only its code.
    }
}
```

## A leak check that counts

RSS on Kotlin/Native moves by megabytes with the collector, so a leak of tens of bytes per call is
invisible over minutes. Count instead, and prove the counter can see a leak:

* **the library's allocator hook**, where it has one — mongkn installs a counting
  `bson_mem_vtable_t` through `staticCFunction` (all five pointers, `aligned_alloc` included, or the
  first aligned allocation crashes), runs 100 round trips and asserts a delta of 0, and a second test
  skips `bson_destroy` on purpose and requires the counter to notice
  (`mongkn@b64795d:mongkn-core/src/nativeTest/kotlin/io/github/youndie/mongkn/bson/BsonAllocations.kt`);
* **malloc chunks**, where it has none — how kore B-65 found 16 + 48 bytes per request that RSS
  over minutes did not show;
* **the collector's own count** for Kotlin objects: `GC.lastGCInfo`'s `sweepStatistics["heap"].sweptCount`
  per request, with the poll rate-limited — reading `lastGCInfo` allocates.
