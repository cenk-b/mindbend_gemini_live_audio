package com.cognistence.mindbend_gemini_live_audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** AudioTrack model: written frames are consumed by the HAL at sampleRate; the head (frames handed to
 *  the HAL) leads the presented position (timestamp) by `latencyFrames`. */
class FakeTrack(override val sampleRate: Int = 24000) : FarewellTrackPort {
    var nano = 1_000L                // monotonic clock; every timestamp is a fresh sample taken "now"
    var written = 0L
    var writtenBytes = 0L
    var head = 0L                    // frames consumed from the track buffer (64-bit truth)
    var headOffset = 0L              // starting raw head, to exercise 32-bit rollover
    var latencyFrames = 1200L
    var timestampsAvailable = true
    var playing = true
    var route = 1
    var writeScript: ArrayDeque<Int> = ArrayDeque()   // per-call override: -N error, or max bytes
    var writes = 0
    override fun write(pcm: ByteArray, offset: Int, size: Int): Int {
        writes++
        val o = writeScript.removeFirstOrNull()
        if (o != null && o < 0) return o
        val n = if (o != null) minOf(o, size) else size
        writtenBytes += n
        written = writtenBytes / 2
        return n
    }
    override fun playbackHeadPosition(): Int = (head + headOffset).toInt()   // wraps at 2^32
    private var presentedFloor = 0L      // presentation never moves backwards (only a flush resets it)
    override fun timestamp(): FarewellTrackTimestamp? {
        if (!timestampsAvailable || !playing) return null
        presentedFloor = maxOf(presentedFloor, maxOf(0L, head - latencyFrames))
        return FarewellTrackTimestamp(presentedFloor + headOffset, ++nano)   // same domain as the head
    }
    override fun isPlaying() = playing
    override fun routedDeviceId() = route
    override fun pause() { playing = false }
    override fun flush() { written = 0; writtenBytes = 0; head = 0; presentedFloor = 0 }
    override fun stop() { playing = false }
    override fun play() { playing = true }
    /** Let `frames` more frames be consumed (bounded by what was written). */
    fun consume(frames: Long) { if (playing) head = minOf(written, head + frames) }
    /** After all audio is consumed, presentation catches up by the latency. */
    fun drainPipeline() { if (playing) { head = written; latencyFrames = 0 } }
}

class LabFarewellPlaybackBarrierTest {
    lateinit var track: FakeTrack
    lateinit var barrier: FarewellPlaybackBarrier
    val events = mutableListOf<FarewellBarrierEvent>()
    var now = 1_700_000_000_000L

    @Before fun setUp() { make() }
    fun make(head0: Long = 0, fallback: Long = -1, wrapOffset: Long = 0) {
        track = FakeTrack().also { it.headOffset = wrapOffset; it.head = head0 }
        events.clear()
        barrier = FarewellPlaybackBarrier(track, { now }, { events += it }, evidenceGraceMs = 1500, headFallbackMarginFrames = fallback,
            nanoNow = { track.nano })
    }
    fun pcm(frames: Int) = ByteArray(frames * 2)
    fun turn(vararg chunks: Int, id: String = "fw_T") {
        barrier.begin(id, 11)
        chunks.forEachIndexed { i, n -> assertTrue(barrier.push(id, i, pcm(n))) }
        barrier.end(id, chunks.size, chunks.sum().toLong())
    }

    @Test fun k1_drainsOnlyWhenPresentedTimestampReachesLastFrame() {
        turn(2400, 2400)
        track.consume(4800); barrier.poll()        // all written frames consumed (head = 4800) ...
        assertTrue("head reached but presentation is still 1200 frames behind: no drain", events.isEmpty())
        now += 50; track.drainPipeline(); barrier.poll()
        assertEquals(listOf(FarewellBarrierEvent.Drained("fw_T", 11, now, 4800, 1, "android_timestamp")), events)
    }

    @Test fun k2_writeBlockingAloneIsNotProof_noProgressMeansEvidenceTimeout() {
        turn(2400)                                 // every write returned the full size
        now += 100 + 1500 + 1; barrier.poll()       // nominal 100 ms + grace, head never moved
        assertEquals(listOf(FarewellBarrierEvent.Unverified("fw_T", 11, "evidence_timeout")), events)
    }

    @Test fun k3_timestampUnavailableIsExplicitlyUnverified_notInvented() {
        track.timestampsAvailable = false
        turn(2400); track.drainPipeline(); barrier.poll()
        assertTrue(events.isEmpty())
        now += 2000; barrier.poll()
        assertEquals(listOf(FarewellBarrierEvent.Unverified("fw_T", 11, "evidence_unavailable")), events)
    }

    @Test fun k4_headFallbackOnlyWhenConfigured_andOnlyWithMargin() {
        make(fallback = 2400)
        track.timestampsAvailable = false
        turn(2400); track.consume(2400); barrier.poll()
        assertTrue("head == end but margin not passed", events.isEmpty())
        track.writtenBytes += 4800; track.written += 2400; track.consume(2400); barrier.poll()   // later legacy audio pushes the head on
        assertEquals("android_playback_head+margin", (events.single() as FarewellBarrierEvent.Drained).evidence)
    }

    @Test fun k5_partialWritesAreAccountedAndErrorsFail() {
        track.writeScript = ArrayDeque(listOf(1000, 1000, 2800))     // 4800 bytes in three partial writes
        turn(2400)
        assertEquals(3, track.writes)
        track.drainPipeline(); barrier.poll()
        assertEquals(2400L, (events.single() as FarewellBarrierEvent.Drained).framesPlayed)
        make(); track.writeScript = ArrayDeque(listOf(-6))           // ERROR_DEAD_OBJECT
        barrier.begin("fw_T", 11)
        assertTrue(!barrier.push("fw_T", 0, pcm(480)))
        assertEquals(FarewellBarrierEvent.Unverified("fw_T", 11, "write_error(-6)"), events.single())
    }

    @Test fun k13_oddBytePartialWritesCarryAcrossCallsWithoutLosingAFrame() {
        track.writeScript = ArrayDeque(listOf(1001, 1001, 2798))   // splits frames mid-sample
        turn(2400)
        assertEquals(2400L, barrier.run { track.written })
        track.drainPipeline(); barrier.poll()
        assertEquals(2400L, (events.single() as FarewellBarrierEvent.Drained).framesPlayed)
    }

    @Test fun k6_zeroWritesFromAPausedTrackAreAStall() {
        track.writeScript = ArrayDeque(listOf(0, 0, 0))
        barrier.begin("fw_T", 11)
        assertTrue(!barrier.push("fw_T", 0, pcm(480)))
        assertTrue((events.single() as FarewellBarrierEvent.Unverified).reason.startsWith("write_stalled"))
    }

    @Test fun k7_playbackHeadRolloverIsExtended() {
        val nearWrap = 0xFFFF_FFFFL - 1000            // raw head about to wrap
        make(wrapOffset = nearWrap)
        assertEquals(nearWrap, barrier.extendedHead())
        track.written = 0; track.writtenBytes = 0
        turn(2400)
        track.consume(2400); val h = barrier.extendedHead()
        assertEquals(nearWrap + 2400, h)
        assertTrue("raw 32-bit value wrapped", track.playbackHeadPosition().toLong() and 0xFFFF_FFFFL < 2400)
        track.drainPipeline(); barrier.poll()
        assertTrue(events.single() is FarewellBarrierEvent.Drained)
    }

    @Test fun k8_routeChangePauseFlushAndStopInvalidate() {
        for ((act, reason) in listOf<Pair<(FakeTrack, FarewellPlaybackBarrier) -> Unit, String>>(
            Pair({ t, b -> t.route = 2; b.poll() }, "route_changed"),
            Pair({ t, b -> t.pause(); b.poll() }, "not_playing"),
            Pair({ _, b -> b.flushTrack("barge_in_flush") }, "barge_in_flush"),
            Pair({ _, b -> b.invalidate("recovery_restart") }, "recovery_restart"),
        )) {
            make(); turn(4800); track.consume(1000); barrier.poll()
            act(track, barrier)
            track.drainPipeline(); now += 5000; barrier.poll()
            assertEquals(reason, listOf(FarewellBarrierEvent.Unverified("fw_T", 11, reason)), events)
        }
    }

    @Test fun k9_headRegressionWithoutFlushIsUnverified() {
        turn(4800); track.consume(3000); barrier.poll()
        track.head = 100; barrier.poll()           // e.g. HAL reset after an unreported route switch
        assertEquals(listOf(FarewellBarrierEvent.Unverified("fw_T", 11, "head_regressed")), events)
    }

    @Test fun k10_sequenceTotalsZeroChunkAndReplacement() {
        barrier.begin("fw_T", 11); barrier.push("fw_T", 0, pcm(480))
        assertTrue(!barrier.push("fw_T", 0, pcm(480)))
        assertEquals("duplicate_seq", (events.single() as FarewellBarrierEvent.Unverified).reason)
        make(); barrier.begin("fw_T", 11); barrier.end("fw_T", 0, 0)
        assertEquals("end_totals_mismatch", (events.single() as FarewellBarrierEvent.Unverified).reason)
        make(); barrier.begin("fw_A", 11); barrier.push("fw_A", 0, pcm(480)); barrier.begin("fw_B", 12)
        assertEquals(FarewellBarrierEvent.Unverified("fw_A", 11, "replaced"), events.single())
    }

    @Test fun k11_farewellEndFrameAccountsForQueuedLegacyAudio() {
        barrier.pushLegacy(pcm(24000))             // 1 s of conversation audio still queued
        turn(2400)
        track.consume(24000); now += 1000; track.latencyFrames = 0; barrier.poll()
        assertTrue("legacy audio presented, farewell not yet", events.isEmpty())
        track.consume(2400); barrier.poll()
        assertEquals(2400L, (events.single() as FarewellBarrierEvent.Drained).framesPlayed)
    }

    @Test fun k14_invalidateIsNotBlockedByABlockingWrite() {
        // WRITE_BLOCKING can block for a long time (paused/slow sink). Invalidation (route change,
        // barge-in) must not wait for it, and the farewell must never drain afterwards.
        val gate = java.util.concurrent.CountDownLatch(1)
        val blocking = object : FarewellTrackPort by track {
            override fun write(pcm: ByteArray, offset: Int, size: Int): Int { gate.await(); return track.write(pcm, offset, size) }
        }
        val b = FarewellPlaybackBarrier(blocking, { now }, { events += it }, nanoNow = { track.nano })
        b.begin("fw_T", 11)
        val writer = Thread { b.push("fw_T", 0, pcm(2400)) }.also { it.start() }
        Thread.sleep(50)                           // writer is now blocked inside write()
        val t0 = System.nanoTime()
        val inv = Thread { b.invalidate("route_changed") }.also { it.start() }
        inv.join(500)
        val tookMs = (System.nanoTime() - t0) / 1_000_000
        gate.countDown(); writer.join(1000)
        assertTrue("invalidate waited ${tookMs} ms for the blocking write", !inv.isAlive && tookMs < 200)
        assertEquals(listOf(FarewellBarrierEvent.Unverified("fw_T", 11, "route_changed")), events)
        b.end("fw_T", 1, 2400); track.drainPipeline(); b.poll()
        assertEquals(1, events.size)
    }

    @Test fun k16_headRegressionAcrossTheWrapIsARegressionNotAForwardJump() {
        // AND-2 regression: with head fallback enabled, a backward step across 2^32 must not look like progress.
        val nearWrap = 0xFFFF_FFFFL - 100
        make(fallback = 0, wrapOffset = nearWrap)
        track.timestampsAvailable = false
        turn(4800)
        track.consume(300); barrier.poll()                   // raw head wrapped to 199
        assertTrue(events.isEmpty())
        track.head = 50; barrier.poll()                      // HAL reset: raw back to 0xFFFFFFCD
        assertEquals(listOf(FarewellBarrierEvent.Unverified("fw_T", 11, "head_regressed")), events)
    }

    @Test fun k17_headAndTimestampAreJudgedRelativeToTheAnchoredOrigin() {
        // AND-2 follow-up: the head/timestamp domain (frames since track start, here offset near the 32-bit wrap)
        // differs from the barrier's written-frame domain; drains are judged relative to the anchored origin.
        make(wrapOffset = 0xFFFF_FFFFL - 100)
        turn(4800)
        track.consume(4800); barrier.poll()
        assertTrue("absolute head is ~2^32 but the farewell has not been presented: $events", events.isEmpty())
        track.drainPipeline(); barrier.poll()
        assertTrue(events.single() is FarewellBarrierEvent.Drained)
        // After a flush the origin is re-anchored on the empty track.
        make(); barrier.pushLegacy(pcm(2400)); track.consume(2400)
        barrier.flushTrack("flush"); events.clear()
        track.latencyFrames = 1200; turn(2400); track.consume(2400); barrier.poll()
        assertTrue(events.isEmpty())
        track.drainPipeline(); barrier.poll()
        assertEquals(2400L, (events.single() as FarewellBarrierEvent.Drained).framesPlayed)
    }

    /** QA-AND-1 (Grok R1): head and timestamp move independently. */
    class SplitTrack(var head: Long, var ts: FarewellTrackTimestamp?) : FarewellTrackPort {
        override val sampleRate = 24000
        override fun write(pcm: ByteArray, offset: Int, size: Int) = size
        override fun playbackHeadPosition() = head.toInt()
        override fun timestamp() = ts
        override fun isPlaying() = true
        override fun routedDeviceId() = 1
        override fun pause() {}
        override fun flush() {}
        override fun stop() {}
    }

    @Test fun k18_timestampThatContradictsTheHeadNeverDrains() {
        // A. flush rebases the head to 0 but the HAL keeps the pre-flush framePosition.
        val a = SplitTrack(80_000, FarewellTrackTimestamp(80_000, 0)); val ea = mutableListOf<FarewellBarrierEvent>()
        val ba = FarewellPlaybackBarrier(a, { now }, { ea += it })
        ba.begin("fw_old", 1); ba.push("fw_old", 0, pcm(4800)); ba.end("fw_old", 1, 4800)
        ba.flushTrack("barge_in_flush") { a.head = 0 }; ea.clear()
        ba.begin("fw_retry", 2); ba.push("fw_retry", 0, pcm(2400)); ba.end("fw_retry", 1, 2400); ba.poll()
        assertTrue("A: $ea", ea.none { it is FarewellBarrierEvent.Drained })
        // C. timestamp already past the end while the head has consumed nothing.
        val c = SplitTrack(0, FarewellTrackTimestamp(2400, 0)); val ec = mutableListOf<FarewellBarrierEvent>()
        val bc = FarewellPlaybackBarrier(c, { now }, { ec += it })
        bc.begin("fw_c", 1); bc.push("fw_c", 0, pcm(2400)); bc.end("fw_c", 1, 2400); bc.poll()
        assertTrue("C: $ec", ec.none { it is FarewellBarrierEvent.Drained })
        // D. 64-bit framePosition vs 32-bit head origin (head low bits 1000, framePosition 2^32 + 1000).
        val d = SplitTrack(1000, FarewellTrackTimestamp((1L shl 32) + 1000, 0)); val ed = mutableListOf<FarewellBarrierEvent>()
        val bd = FarewellPlaybackBarrier(d, { now }, { ed += it })
        bd.begin("fw_d", 1); bd.push("fw_d", 0, pcm(480)); bd.end("fw_d", 1, 480); bd.poll()
        assertTrue("D: $ed", ed.none { it is FarewellBarrierEvent.Drained })
        // E. timestamp from the future (nanoTime ahead of now) is not yet evidence.
        val e = SplitTrack(0, null); val ee = mutableListOf<FarewellBarrierEvent>()
        val be = FarewellPlaybackBarrier(e, { now }, { ee += it }, nanoNow = { 1_000_000_000L })
        be.begin("fw_e", 1); be.push("fw_e", 0, pcm(2400))
        e.ts = FarewellTrackTimestamp(0, 1_000_000_000L); be.end("fw_e", 1, 2400)      // fresh, below the end
        e.head = 2400; e.ts = FarewellTrackTimestamp(2400, 1_500_000_000L); be.poll()
        assertTrue("E: $ee", ee.isEmpty())
        e.ts = FarewellTrackTimestamp(2400, 1_000_000_000L); be.poll()
        assertTrue("E': consistent, past timestamp drains: $ee", ee.single() is FarewellBarrierEvent.Drained)
    }

    @Test fun k19_staleTimestampInsideTheToleranceNeverDrainsNorPoisons() {
        // QA-AND-2 (Grok R2): a pre-flush timestamp stuck at 2000 (within the old 2400 tolerance) must not prove
        // a 480-frame farewell, and must not become the monotonic floor for later, corrected samples.
        val nano = 5_000_000_000L
        val a = SplitTrack(2000, FarewellTrackTimestamp(2000, nano)); val ea = mutableListOf<FarewellBarrierEvent>()
        val ba = FarewellPlaybackBarrier(a, { now }, { ea += it }, nanoNow = { nano })
        ba.flushTrack("barge_in_flush") { a.head = 0 }; ea.clear()
        ba.begin("fw_short", 2); ba.push("fw_short", 0, pcm(480)); a.head = 480; ba.end("fw_short", 1, 480); ba.poll()
        assertTrue("stuck timestamp drained: $ea", ea.none { it is FarewellBarrierEvent.Drained })
        // poison: stale sample first, then a corrected rebase on a long turn must still be able to drain
        val c = SplitTrack(0, FarewellTrackTimestamp(2000, nano)); val ec = mutableListOf<FarewellBarrierEvent>()
        val bc = FarewellPlaybackBarrier(c, { now }, { ec += it }, nanoNow = { nano })
        bc.begin("fw_long", 1); bc.push("fw_long", 0, pcm(24_000)); bc.end("fw_long", 1, 24_000)
        bc.poll()
        c.head = 100; c.ts = FarewellTrackTimestamp(100, nano); bc.poll()
        assertTrue("stale sample poisoned monotonicity: $ec", ec.isEmpty())
        c.head = 24_000; c.ts = FarewellTrackTimestamp(24_000, nano); bc.poll()
        assertTrue("corrected counters drain: $ec", ec.single() is FarewellBarrierEvent.Drained)
        // positive control: consistent counters, presentation lags the head, drains only on the timestamp
        val d = SplitTrack(0, FarewellTrackTimestamp(0, nano)); val ed = mutableListOf<FarewellBarrierEvent>()
        val bd = FarewellPlaybackBarrier(d, { now }, { ed += it }, nanoNow = { nano })
        bd.begin("fw_ok", 1); bd.push("fw_ok", 0, pcm(2400)); bd.end("fw_ok", 1, 2400)
        d.head = 2400; d.ts = FarewellTrackTimestamp(1200, nano); bd.poll(); assertTrue(ed.isEmpty())
        d.ts = FarewellTrackTimestamp(2400, nano); bd.poll(); assertTrue(ed.single() is FarewellBarrierEvent.Drained)
    }

    @Test fun k20_flushDuringABlockingWriteDoesNotInflateTheNextFarewell() {
        // QA-AND-3 (Grok R2): bytes accounted by a write that a flush discarded must not shift the next turn.
        val entered = java.util.concurrent.CountDownLatch(1); val flushed = java.util.concurrent.CountDownLatch(1)
        val nano = 5_000_000_000L
        val t = object : FarewellTrackPort {
            var head = 0L
            override val sampleRate = 24000
            var first = true
            override fun write(pcm: ByteArray, offset: Int, size: Int): Int {
                if (first) { first = false; entered.countDown(); flushed.await(2, java.util.concurrent.TimeUnit.SECONDS) }
                return size
            }
            override fun playbackHeadPosition() = head.toInt()
            override fun timestamp() = FarewellTrackTimestamp(head, nano)
            var playing = true
            override fun isPlaying() = playing
            override fun routedDeviceId() = 1
            override fun pause() { playing = false }
            override fun play() { playing = true }
            override fun flush() {}
            override fun stop() {}
        }
        val ev = mutableListOf<FarewellBarrierEvent>()
        val b = FarewellPlaybackBarrier(t, { now }, { ev += it }, nanoNow = { nano })
        b.begin("fw_old", 1)
        val w = Thread { b.push("fw_old", 0, pcm(10_000)) }.also { it.start() }
        entered.await(2, java.util.concurrent.TimeUnit.SECONDS)
        b.flushTrack("barge_in_flush"); flushed.countDown(); w.join(2000)
        ev.clear()
        // QA-AND-5 (R3) supersedes the R2 expectation: a write in flight across the flush may be RESIDENT, so the
        // cursor is untrusted and the next farewell fails closed (never an inflated or deflated end frame) ...
        b.begin("fw_new", 2)
        assertEquals(listOf(FarewellBarrierEvent.Unverified("fw_new", 2, "track_unsynced")), ev)
        assertTrue("no inflated start", b.log.none { it.startsWith("start fw_new=10000") })
        // ... until a flush with no write in flight re-synchronises the track; then the farewell counts only itself.
        b.flushTrack("resync"); ev.clear()
        b.begin("fw_ok", 3); b.push("fw_ok", 0, pcm(480)); b.end("fw_ok", 1, 480)
        t.head = 480; b.poll()
        assertTrue("the next farewell drains on its own frames: $ev log=${b.log}", ev.singleOrNull() is FarewellBarrierEvent.Drained)
    }

    @Test fun k12_lateEventsAfterTerminalAreIgnored() {
        turn(2400); track.drainPipeline(); barrier.poll(); barrier.poll()
        barrier.invalidate("late")
        assertEquals(1, events.size)
    }
}
