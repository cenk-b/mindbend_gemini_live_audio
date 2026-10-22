package com.cognistence.mindbend_gemini_live_audio

import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Single-assignment teardown result. CompletableFuture needs API 24; the plugin supports API 23. */
class TeardownResult {
    private val done = CountDownLatch(1)
    @Volatile private var value: String? = null
    private val callbacks = ArrayList<(String) -> Unit>() // guarded by this

    fun complete(state: String) {
        val pending = synchronized(this) {
            if (value != null) return
            value = state
            ArrayList(callbacks).also { callbacks.clear() }
        }
        done.countDown()
        pending.forEach { it(state) }
    }

    /** Runs [callback] once with the result: now if already complete, else on the completing thread. */
    fun thenAccept(callback: (String) -> Unit) {
        val ready = synchronized(this) { value ?: run { callbacks.add(callback); null } }
        if (ready != null) callback(ready)
    }

    val isDone: Boolean get() = done.count == 0L
    fun get(): String { done.await(); return value!! }
    fun get(timeout: Long, unit: TimeUnit): String {
        if (!done.await(timeout, unit)) throw TimeoutException()
        return value!!
    }
}

/** Owns exactly one native resource. No state lock is held across native calls.
 * Stop runs independently of data. Returned means native calls returned, never acoustic silence.
 * A blocked call may return after retirement; its next boundary is another discard, never play.
 */
class RetiringPlaybackLifetime(private val stop: () -> Unit, private val release: () -> Unit) {
    private val data: ExecutorService = Executors.newSingleThreadExecutor { r -> Thread(r, "mb-playback-data").apply { isDaemon = true } }
    private val control: ExecutorService = Executors.newSingleThreadExecutor { r -> Thread(r, "mb-playback-control").apply { isDaemon = true } }
    private val retired = AtomicBoolean(false)
    private val releaseAttempted = AtomicBoolean(false)
    private val cancellation = AtomicReference<TeardownResult?>(null)
    @Volatile var teardownStatus = "not_requested"; private set
    fun isRetired() = retired.get()

    fun submit(operation: () -> Unit) {
        if (isRetired()) return
        try { data.execute {
            if (!isRetired()) try { operation() } catch (_: Throwable) { cancel() }
        } } catch (_: java.util.concurrent.RejectedExecutionException) {
            // Concurrent retirement shut down this lifetime's data lane.
        }
    }

    fun <T> boundary(operation: () -> T): T? {
        if (isRetired()) return null
        return try {
            val value = operation()
            if (isRetired()) { discardLate(); null } else value
        } catch (t: Throwable) { cancel(); throw t }
    }

    fun cancel(): TeardownResult {
        val promise = TeardownResult()
        if (!cancellation.compareAndSet(null, promise)) return cancellation.get()!!
        retired.set(true) // irreversible fence, BEFORE dispatch or callback
        teardownStatus = "requested"
        control.execute {
            teardownStatus = "started"
            var failed = false
            try { stop() } catch (_: Throwable) { failed = true }
            try { if (releaseAttempted.compareAndSet(false, true)) release() } catch (_: Throwable) { failed = true }
            teardownStatus = if (failed) "failed" else "returned"
            promise.complete(teardownStatus)
            control.shutdown()
        }
        data.shutdown() // does not interrupt or join a parked native write
        return promise
    }

    private fun discardLate() {
        // Runs before any further operation on data. This covers late schedule/play returns.
        try { stop() } catch (_: Throwable) { /* retired resource may already be released */ }
    }
}
