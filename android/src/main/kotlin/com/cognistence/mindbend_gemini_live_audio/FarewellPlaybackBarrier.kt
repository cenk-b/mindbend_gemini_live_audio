// Android farewell playback barrier. Ported from the Track 21 farewell-barrier lab (six external QA
// rounds); the logic is unchanged apart from type names and [hasLiveTurn]. Pure JVM-testable logic.
//
// WRITE_BLOCKING only proves the bytes were ACCEPTED into the AudioTrack buffer. Playback completion
// of one farewell is proven only by platform playback-position evidence reaching that farewell's last
// written frame:
//   - primary: AudioTrack.getTimestamp() presentation framePosition (monotonic, valid), and
//   - optional fallback: 32-bit playbackHeadPosition (rollover-extended) plus a configured output-latency
//     margin. OFF by default: when only head evidence exists the result is UNVERIFIED, never success.
// Any route change, flush/stop/pause, head or timestamp regression, write error, stall or evidence
// timeout during the turn yields UNVERIFIED.
package com.cognistence.mindbend_gemini_live_audio

data class FarewellTrackTimestamp(val framePosition: Long, val nanoTime: Long)

/** Thin seam over android.media.AudioTrack (MODE_STREAM, PCM16 mono). */
interface FarewellTrackPort {
    val sampleRate: Int
    /** WRITE_BLOCKING write; returns bytes written, or a negative AudioTrack error code. */
    fun write(pcm: ByteArray, offset: Int, size: Int): Int
    /** Raw 32-bit playback head (frames), wraps at 2^32. */
    fun playbackHeadPosition(): Int
    /** getTimestamp(); null when unavailable (not started, route without timestamps, etc.). */
    fun timestamp(): FarewellTrackTimestamp?
    fun isPlaying(): Boolean
    fun routedDeviceId(): Int
    fun pause()
    fun flush()
    fun stop()
    fun play() {}
}

sealed class FarewellBarrierEvent {
    abstract val turnId: String
    abstract val nativeGeneration: Int
    data class Drained(override val turnId: String, override val nativeGeneration: Int, val drainedAtEpochMs: Long,
                       val framesPlayed: Long, val lastSeq: Int, val evidence: String) : FarewellBarrierEvent()
    data class Unverified(override val turnId: String, override val nativeGeneration: Int, val reason: String) : FarewellBarrierEvent()
}

private const val FLUSHED_DURING_WRITE = -100_000

class FarewellPlaybackBarrier(
    private val track: FarewellTrackPort,
    private val nowMs: () -> Long,
    private val emit: (FarewellBarrierEvent) -> Unit,
    /** Extra wait beyond the farewell's nominal duration before declaring evidence unavailable. */
    private val evidenceGraceMs: Long = 1500,
    /** If >= 0, playbackHead may prove drain once head >= end + this many frames. -1 = timestamp required. */
    private val headFallbackMarginFrames: Long = -1,
    /** Monotonic clock in the AudioTimestamp.nanoTime domain (System.nanoTime on Android). */
    private val nanoNow: () -> Long = System::nanoTime,
    /** How far a presented timestamp may lead the consumed head before the two are declared inconsistent. */
    private val timestampLeadToleranceFrames: Long = 2400,
) {
    private class Turn(val id: String, val generation: Int, val routeAtBegin: Int, val beganAtMs: Long, val beganAtNano: Long) {
        /** QA-AND-4: taken at the FIRST farewell write, under the write gate, after every earlier write has been
         *  accounted. Everything in [startFrame, endFrame) is therefore farewell audio. */
        var startFrame: Long? = null
        var expectedSeq = 0
        var frames = 0L
        var endFrame: Long? = null
        var lastSeq = -1
        var deadlineMs = Long.MAX_VALUE
        var terminal = false
        var lastTimestampFrame = -1L
        var sawBeforeEnd = false             // a fresh, consistent timestamp BELOW the end frame was observed (QA-AND-2)
    }

    private var turn: Turn? = null
    private var writtenFrames = 0L          // frames accepted into the track since its last flush
    private var carryByte = false           // odd partial write: a frame is split across writes
    private var flushGeneration = 0         // bumped by every flush; writes started earlier never count (QA-AND-3)
    /** Serialises ALL writes (farewell and legacy) so the frame cursor and the track contents advance together
     *  (QA-AND-4). Distinct from the state lock: invalidate/poll/flush never wait for a parked WRITE_BLOCKING (AND-1). */
    private val writeGate = Any()
    private var writeInFlight = false
    private var flushing = false
    private var flushDepth = 0
    /** QA-AND-5: a write was in flight when the track was flushed, so bytes may sit in the track that the cursor
     *  does not count. Cleared only by a flush with no write in flight; until then every farewell fails closed. */
    private var unsynced = false
    private var headSampled = false         // first sample anchors the extension
    /** Track position (head / timestamp domain) that corresponds to writtenFrames == 0, anchored at construction
     *  and after every flush. PRECONDITION (handoff): the barrier is created on a fresh or just-flushed track and
     *  ALL writes to that track go through it; otherwise the two domains cannot be related. */
    private var headOrigin = 0L
    private var lastRawHead = 0L
    private var lastExtendedHead = 0L
    var epoch = 0
        private set
    val log = mutableListOf<String>()

    init { extendedHead() }

    /** Rollover-extended playback head in frames: accumulates the SIGNED modular 32-bit delta between samples,
     *  so a forward wrap is progress and a backward step - including one across the wrap - is a regression
     *  (finding AND-2). Valid as long as it is sampled at least once per 2^31 frames (~12 h at 48 kHz). */
    fun extendedHead(): Long {
        val raw = track.playbackHeadPosition().toLong() and 0xFFFF_FFFFL
        if (!headSampled) {
            headSampled = true; lastRawHead = raw; lastExtendedHead = raw
            headOrigin = raw
            return raw
        }
        val delta = (raw - lastRawHead).toInt().toLong()   // two's-complement: in [-2^31, 2^31)
        lastRawHead = raw
        lastExtendedHead += delta
        return lastExtendedHead
    }

    /** True while a farewell turn can still drain or fail. The plugin polls only while this holds. */
    @Synchronized fun hasLiveTurn(): Boolean = turn?.terminal == false

    @Synchronized fun begin(turnId: String, nativeGeneration: Int) {
        turn?.takeIf { !it.terminal }?.let { fail(it, "replaced") }
        epoch++
        val t = Turn(turnId, nativeGeneration, track.routedDeviceId(), nowMs(), nanoNow())
        turn = t
        log += "begin $turnId written=$writtenFrames"
        if (unsynced) fail(t, "track_unsynced") else if (flushing) fail(t, "track_flushing")
    }

    /** Ordinary (non-farewell) audio keeps the existing path; it only advances the frame accounting. Legacy audio
     *  between a farewell's first chunk and its END would sit inside [startFrame, endFrame): that fails the turn. */
    fun pushLegacy(pcm: ByteArray): Boolean {
        // Checked BEFORE the write gate: a write re-entered from nativeFlush must not wait behind a parked write
        // (which is itself waiting for the flush) - Grok R5.
        synchronized(this) { if (flushing) return false }
        return pushLegacyGated(pcm)
    }

    private fun pushLegacyGated(pcm: ByteArray): Boolean = synchronized(writeGate) {
        synchronized(this) {
            turn?.takeIf { !it.terminal && it.startFrame != null && it.endFrame == null }?.let { fail(it, "legacy_interleaved") }
        }
        writeAll(pcm) >= 0
    }

    /** The lock is NOT held across the blocking AudioTrack.write (finding AND-1): invalidation and polling
     *  must stay prompt while a WRITE_BLOCKING call is parked. The outcome is re-checked against the epoch
     *  captured before the write, so a farewell invalidated mid-write can never be completed by it. */
    fun push(turnId: String, seq: Int, pcm: ByteArray): Boolean {
        val epochAtStart: Int
        synchronized(this) {
            val t = turn ?: return false
            if (t.id != turnId || t.terminal) return false
            if (t.endFrame != null) { fail(t, "push_after_end"); return false }
            if (seq != t.expectedSeq) { fail(t, if (seq < t.expectedSeq) "duplicate_seq" else "missing_seq"); return false }
            if (pcm.isEmpty() || pcm.size % 2 != 0) { fail(t, "bad_pcm"); return false }
            if (track.routedDeviceId() != t.routeAtBegin) { fail(t, "route_changed"); return false }
            if (flushing) { fail(t, "flushing"); return false }   // never wait on the write gate during a flush
            t.expectedSeq++            // reserve this sequence number before releasing the lock
            epochAtStart = epoch
        }
        val written = synchronized(writeGate) {
            synchronized(this) {
                val t = turn
                if (t == null || t.id != turnId || t.terminal || epoch != epochAtStart) return false
                if (t.startFrame == null) { t.startFrame = writtenFrames; log += "start $turnId=$writtenFrames" }
            }
            writeAll(pcm)
        }
        synchronized(this) {
            val t = turn ?: return false
            if (t.id != turnId || t.terminal || epoch != epochAtStart) return false   // invalidated during the write
            if (written < 0) { fail(t, "write_error($written)"); return false }
            if (written != pcm.size) { fail(t, "write_stalled($written/${pcm.size})"); return false }
            t.frames += pcm.size / 2
            return true
        }
    }

    /** Loops over partial WRITE_BLOCKING results. Caller holds the write gate, NOT the state lock. Returns total
     *  bytes, a negative AudioTrack error, or FLUSHED_DURING_WRITE. */
    private fun writeAll(pcm: ByteArray): Int {
        val gen = synchronized(this) { flushGeneration }
        var off = 0
        var zeroWrites = 0
        while (off < pcm.size) {
            synchronized(this) {
                // QA-AND-5: never start a write into a track that is being, or has been, flushed since we began.
                if (flushGeneration != gen || flushing) return FLUSHED_DURING_WRITE
                writeInFlight = true
            }
            val n = try { track.write(pcm, off, pcm.size - off) } finally { synchronized(this) { writeInFlight = false } }
            synchronized(this) {
                if (flushGeneration != gen) {
                    // The flush overtook this write; whatever it copied may be resident and uncounted.
                    if (n > 0) { unsynced = true; log += "unsynced: write returned $n after a flush" }
                    return FLUSHED_DURING_WRITE
                }
                if (n > 0) account(n)
            }
            if (n < 0) return n
            if (n == 0) { if (++zeroWrites >= 3) return off; continue }   // paused/stopped track: stall
            zeroWrites = 0
            off += n
        }
        return off
    }

    /** Frame accounting across odd partial writes; caller holds the state lock. */
    private fun account(n: Int) {
        var bytes = n
        if (carryByte) { writtenFrames += 1; bytes -= 1; carryByte = false }
        writtenFrames += bytes / 2
        if (bytes % 2 == 1) carryByte = true
    }

    @Synchronized fun end(turnId: String, totalChunks: Int, totalFrames: Long) {
        val t = turn ?: return
        if (t.id != turnId || t.terminal) return
        if (totalChunks <= 0 || totalChunks != t.expectedSeq || totalFrames != t.frames) { fail(t, "end_totals_mismatch"); return }
        t.endFrame = t.startFrame!! + t.frames
        t.lastSeq = totalChunks - 1
        // The deadline covers EVERYTHING still ahead of the farewell's last frame (queued legacy audio included),
        // not just the farewell's own duration (found by the k15 legacy_mid fuzz op).
        val remaining = maxOf(0L, t.endFrame!! - (lastExtendedHead - headOrigin))
        val nominalMs = remaining * 1000 / track.sampleRate
        t.deadlineMs = nowMs() + nominalMs + evidenceGraceMs
        log += "end $turnId endFrame=${t.endFrame} deadline=${t.deadlineMs}"
        poll()
    }

    /** Called on the playback executor (e.g. every 10 ms) while a turn awaits evidence. */
    @Synchronized fun poll() {
        val t = turn ?: return
        if (t.terminal) return
        if (track.routedDeviceId() != t.routeAtBegin) { fail(t, "route_changed"); return }
        val prevHead = lastExtendedHead
        val head = extendedHead()
        if (head < prevHead) { fail(t, "head_regressed"); return }
        val origin = headOrigin
        val consumed = head - origin                         // frames the HAL has taken, barrier domain
        // Timestamps are sampled from BEGIN on (not only after END), so a crossing is observed even when END
        // arrives after a short farewell already finished presenting.
        // QA-AND-6: the live head also arms the crossing (it has no nanoTime, it is read now): if the HAL has not
        // consumed the farewell yet, the drain that follows is an observed crossing even when the timestamp
        // cadence jumps over a short farewell. The drain itself still needs a fresh, consistent timestamp.
        val headBound = t.endFrame ?: t.startFrame?.let { it + t.frames }
        if (headBound != null && t.frames > 0 && consumed < headBound) t.sawBeforeEnd = true
        val ts = track.timestamp()
        var crossed = false
        // Only a FRESH sample counts: taken at or after this turn began (a pre-flush/pre-turn sample is stale) and
        // not from the future.
        if (ts != null && ts.nanoTime >= t.beganAtNano && ts.nanoTime <= nanoNow()) {
            val presented = ts.framePosition - origin       // into the barrier's written-frame domain
            // QA-AND-1: nothing can be presented that the HAL has not consumed. Far ahead of the head means the
            // counters are not in one domain (non-rebased framePosition after a flush, 64-bit framePosition vs
            // 32-bit head origin, bogus HAL value): fail. QA-AND-2: ANY lead is not evidence; such a sample is
            // ignored entirely (no drain, and it does not become the monotonic floor).
            if (presented > consumed + timestampLeadToleranceFrames) { fail(t, "timestamp_ahead_of_head"); return }
            if (presented <= consumed) {
                if (presented < t.lastTimestampFrame) { fail(t, "timestamp_regressed"); return }
                t.lastTimestampFrame = presented
                // Below the farewell's end (before END: below the frames written so far, which the end can only
                // exceed). QA-AND-2: the drain must be an observed CROSSING, never a first sample already past it.
                val bound = t.endFrame ?: t.startFrame?.let { it + t.frames }
                if (bound != null && presented < bound) t.sawBeforeEnd = true
                else if (t.endFrame != null && t.sawBeforeEnd && consumed >= t.endFrame!!) crossed = true
            }
        }
        val end = t.endFrame ?: return
        if (!track.isPlaying()) { fail(t, "not_playing"); return }
        if (crossed) { drained(t, "android_timestamp"); return }
        if (ts == null && headFallbackMarginFrames >= 0 && consumed >= end + headFallbackMarginFrames) {
            drained(t, "android_playback_head+margin"); return
        }
        if (nowMs() > t.deadlineMs) {
            fail(t, if (ts == null) "evidence_unavailable" else "evidence_timeout"); return
        }
    }

    @Synchronized fun cancel(turnId: String, reason: String) {
        val t = turn ?: return
        if (t.id == turnId) invalidate(reason)
    }

    /** Pause/flush/stop/route/recovery from the plugin: the active farewell can never drain. */
    @Synchronized fun invalidate(reason: String) {
        epoch++
        turn?.takeIf { !it.terminal }?.let { fail(it, reason) }
    }

    /** The ONLY trustworthy flush (stop, barge-in, recovery, resync): the barrier orders it (QA-AND-5, Grok R4).
     *  Phase 1, under the state lock: invalidate, bump the flush generation, and stop new writes from starting.
     *  A write already parked in WRITE_BLOCKING may still copy into the track after the native flush. If one is in
     *  flight, the track is marked unsynced. Any write that returns during or after the flush finds the generation
     *  changed and also marks it unsynced; its bytes are never counted.
     *  Phase 2: run the native flush outside the lock (it may block).
     *  Phase 3: reset the cursor and re-anchor the head on the emptied track.
     *  A flush with no write in flight, and none returning during it, leaves the track SYNCED. That is the only
     *  way to clear `unsynced`. */
    /** [insideFlush] is an adapter hook run INSIDE the flush, after the barrier's own discard (Grok R6: only a
     *  discard the barrier performs itself - pause, verified not playing, flush - can make the track synced; a
     *  caller lambda, a no-op flush on a playing track or stop() cannot be told apart from it by a head of 0). */
    fun flushTrack(reason: String, insideFlush: () -> Unit = {}) {
        val nativeFlush = { discardAndResume(reason, insideFlush) }
        synchronized(this) {
            invalidate(reason)
            flushGeneration++
            flushDepth++
            flushing = true
            // Only the OUTERMOST flush may clear an earlier unsynced state (Grok R5: overlapping flushes).
            unsynced = if (flushDepth == 1) writeInFlight else (unsynced || writeInFlight)
            log += "flush $reason" + (if (writeInFlight) " (write in flight: unsynced)" else "") + (if (flushDepth > 1) " (nested)" else "")
        }
        var flushed = false
        try { nativeFlush(); flushed = true } finally {
            synchronized(this) {
                // A native flush that threw may or may not have emptied the track: the cursor is unknowable.
                if (!flushed) { unsynced = true; log += "flush $reason threw: unsynced" }
                // Post-condition: a discarding flush resets the playback head to 0 (API 36; seen on the emulator).
                // A non-zero head means nothing was discarded (e.g. flush() on a PLAYING track is a no-op).
                val rawHead = track.playbackHeadPosition().toLong() and 0xFFFF_FFFFL
                if (flushed && rawHead != 0L) { unsynced = true; log += "flush $reason did not reset the head ($rawHead): unsynced" }
                flushDepth--
                if (flushDepth == 0) {         // only the outermost flush publishes the new (empty) cursor
                    writtenFrames = 0; carryByte = false; headSampled = false; lastRawHead = 0; lastExtendedHead = 0
                    extendedHead()   // re-anchor on the now-empty track
                    flushing = false
                }
            }
        }
    }

    /** AudioTrack.flush() is a NO-OP on a playing track (API 36 javadoc; Grok R5): pause first, VERIFY the track is
     *  no longer playing, flush, run the adapter hook, then resume. A pause that did not take effect means flush()
     *  could not discard: the track stays unsynced (Grok R6). Never stop(): it zeroes the head without discarding. */
    private fun discardAndResume(reason: String, insideFlush: () -> Unit) {
        val wasPlaying = track.isPlaying()
        track.pause()
        if (track.isPlaying()) synchronized(this) { unsynced = true; log += "flush $reason: pause did not take effect: unsynced" }
        track.flush()
        insideFlush()
        if (wasPlaying) track.play()
    }

    /** A flush the barrier did NOT order (reported after the fact). A write may have landed in the emptied track
     *  AND been accounted before this call (QA-AND-5, Grok R4), so the cursor cannot be trusted: always unsynced
     *  until a later [flushTrack]. */
    @Synchronized fun onTrackFlushed(reason: String) {
        invalidate(reason)
        flushGeneration++
        unsynced = true
        log += "flushed $reason (after the fact: unsynced until flushTrack)"
        writtenFrames = 0; carryByte = false; headSampled = false; lastRawHead = 0; lastExtendedHead = 0
        extendedHead()
    }

    private fun drained(t: Turn, evidence: String) {
        t.terminal = true
        val at = nowMs()   // captured ONCE at the verified boundary
        log += "drained ${t.id} at=$at via $evidence"
        emit(FarewellBarrierEvent.Drained(t.id, t.generation, at, t.frames, t.lastSeq, evidence))
    }

    private fun fail(t: Turn, reason: String) {
        if (t.terminal) return
        t.terminal = true
        epoch++
        log += "unverified ${t.id} $reason"
        emit(FarewellBarrierEvent.Unverified(t.id, t.generation, reason))
    }
}
