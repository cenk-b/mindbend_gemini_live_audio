package com.cognistence.mindbend_gemini_live_audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Regressions for Grok QA round 3 (ports qa/grok_r3/probes/android_r3_attacks.kt). The track is physical: the
 *  head consumes only what was written, presentation lags by latency and never moves backwards, and the bytes a
 *  write() copies are RESIDENT in the track even when the barrier does not count them. */
open class Phys(var latency: Long = 1200) : FarewellTrackPort {
    override val sampleRate = 24000
    var written = 0L
    var head = 0L
    var floor = 0L
    var nano = 5_000_000_000L
    var playing = true
    val residentOrder = mutableListOf<String>()
    override fun write(pcm: ByteArray, offset: Int, size: Int): Int {
        residentOrder += "write:${size / 2}@$written"; written += size / 2; return size
    }
    override fun playbackHeadPosition() = head.toInt()
    override fun timestamp(): FarewellTrackTimestamp? {
        if (!playing) return null
        val lag = if (head < written) latency else 0L
        floor = maxOf(floor, maxOf(0L, head - lag))
        return FarewellTrackTimestamp(floor, ++nano)
    }
    override fun isPlaying() = playing
    override fun routedDeviceId() = 1
    override fun pause() { playing = false }
    override fun flush() { written = 0; head = 0; floor = 0 }
    override fun stop() { playing = false }
    override fun play() { playing = true }
    fun consume(n: Long) { if (playing) head = minOf(written, head + n) }
}

class LabFarewellBarrierR3Test {
    private val now = 1_700_000_000_000L
    private fun pcm(frames: Int) = ByteArray(frames * 2)
    private fun drained(ev: List<FarewellBarrierEvent>) = ev.filterIsInstance<FarewellBarrierEvent.Drained>()

    @Test fun k21_legacyWrittenAfterBeginNeverSitsInsideTheFarewellWindow() {
        // QA-AND-4 (a): begin, THEN 10 000 legacy frames, then a 480-frame farewell (physically at 10000..10480).
        val t = Phys(); val ev = mutableListOf<FarewellBarrierEvent>()
        val b = FarewellPlaybackBarrier(t, { now }, { ev += it }, nanoNow = { t.nano })
        b.begin("fw", 1); assertTrue(b.pushLegacy(pcm(10_000))); assertTrue(b.push("fw", 0, pcm(480))); b.end("fw", 1, 480)
        t.consume(1680); b.poll()
        assertTrue("drained while presentation (${t.floor}) is still inside the legacy prefix: $ev ${b.log}", drained(ev).isEmpty())
        t.consume(10_000); b.poll()
        assertEquals("drains once the farewell itself was presented: $ev ${b.log}", 1, drained(ev).size)
        assertTrue(t.floor >= 10_480)
    }

    @Test fun k22_legacyWriteInFlightAcrossBeginIsCountedBeforeTheFarewell() {
        // QA-AND-4 (b): a pushLegacy blocked inside track.write while begin runs.
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val t = object : Phys() {
            override fun write(pcm: ByteArray, offset: Int, size: Int): Int {
                if (size == 20_000) { entered.countDown(); release.await(2, TimeUnit.SECONDS) }
                return super.write(pcm, offset, size)
            }
        }
        val ev = mutableListOf<FarewellBarrierEvent>()
        val b = FarewellPlaybackBarrier(t, { now }, { ev += it }, nanoNow = { t.nano })
        val w = Thread { b.pushLegacy(pcm(10_000)) }.also { it.start() }
        assertTrue(entered.await(2, TimeUnit.SECONDS))
        b.begin("fw", 1)
        val p = Thread { b.push("fw", 0, pcm(480)) }.also { it.start() }   // must queue behind the legacy write
        Thread.sleep(50); release.countDown(); w.join(2000); p.join(2000)
        b.end("fw", 1, 480)
        t.consume(1680); b.poll()
        assertTrue("drained inside the in-flight legacy audio: $ev ${b.log} ${t.residentOrder}", drained(ev).isEmpty())
        t.consume(10_000); b.poll()
        assertEquals("$ev ${b.log}", 1, drained(ev).size)
    }

    @Test fun k23_legacyInterleavedWithAnOpenFarewellFailsTheTurn() {
        val t = Phys(); val ev = mutableListOf<FarewellBarrierEvent>()
        val b = FarewellPlaybackBarrier(t, { now }, { ev += it }, nanoNow = { t.nano })
        b.begin("fw", 1); assertTrue(b.push("fw", 0, pcm(480)))
        b.pushLegacy(pcm(2400))                                   // between farewell chunks: [start,end) not pure
        assertEquals(listOf(FarewellBarrierEvent.Unverified("fw", 1, "legacy_interleaved")), ev)
    }

    @Test fun k24_aWriteThatLandsAfterAFlushMakesTheTrackUnsynced() {
        // QA-AND-5: flush happens while a write is in flight; the write then copies into the EMPTY track (resident),
        // so the barrier's cursor cannot be trusted until a flush with no write in flight.
        for (partial in listOf(false, true)) {
            val t = object : Phys(latency = 0) {
                var calls = 0
                lateinit var onFlush: () -> Unit
                override fun write(pcm: ByteArray, offset: Int, size: Int): Int {
                    calls++
                    if (partial && calls == 1) { val part = minOf(2000, size); written += part / 2; return part }
                    if ((partial && calls == 2) || (!partial && calls == 1)) onFlush()
                    return super.write(pcm, offset, size)
                }
            }
            val ev = mutableListOf<FarewellBarrierEvent>()
            val b = FarewellPlaybackBarrier(t, { now }, { ev += it }, nanoNow = { t.nano })
            t.onFlush = { b.flushTrack("barge_in_flush") { t.written = 0; t.head = 0; t.floor = 0 } }
            b.begin("fw_old", 1); b.push("fw_old", 0, pcm(10_000)); ev.clear()
            b.begin("fw_new", 2); b.push("fw_new", 0, pcm(480)); b.end("fw_new", 1, 480)
            t.head = 200; b.poll(); t.head = 480; b.poll()
            assertTrue("partial=$partial drained behind ${t.written - 480} orphan frames: $ev ${b.log}", drained(ev).isEmpty())
            assertEquals("partial=$partial", "track_unsynced", (ev.first() as FarewellBarrierEvent.Unverified).reason)
            // A later flush with no write in flight re-synchronises the track.
            b.flushTrack("resync"); ev.clear()
            b.begin("fw_ok", 3); b.push("fw_ok", 0, pcm(480)); b.end("fw_ok", 1, 480)
            t.head = 480; b.poll()
            assertEquals("partial=$partial resync: $ev ${b.log}", 1, drained(ev).size)
        }
    }

    @Test fun k25_coarseTimestampCadenceStillObservesTheCrossingThroughTheHead() {
        // QA-AND-6: the HAL timestamp present at begin is older than begin (not fresh); the next quantum (544 frames)
        // jumps past a 480-frame farewell. The head (read live) is below the end after begin, so the crossing is armed.
        val t0 = 5_000_000_000L
        var nowNano = t0; var wall = now
        val t = object : FarewellTrackPort {
            override val sampleRate = 24000
            var head = 0L; var frame = 0L; var tsNano = t0 - 1L
            override fun write(pcm: ByteArray, offset: Int, size: Int) = size
            override fun playbackHeadPosition() = head.toInt()
            override fun timestamp() = FarewellTrackTimestamp(frame, tsNano)
            override fun isPlaying() = true
            override fun routedDeviceId() = 1
            override fun pause() {}
            override fun flush() {}
            override fun stop() {}
        }
        val ev = mutableListOf<FarewellBarrierEvent>()
        val b = FarewellPlaybackBarrier(t, { wall }, { ev += it }, nanoNow = { nowNano })
        b.begin("fw_q", 1); b.push("fw_q", 0, pcm(480)); b.end("fw_q", 1, 480)
        t.head = 544; t.frame = 544; t.tsNano = t0 + 20_000_000; nowNano = t.tsNano
        b.poll()
        assertEquals("heard audio must drain: $ev ${b.log}", 1, drained(ev).size)
        // ...but a first observation where BOTH counters are already past the end stays fail-closed.
        val t2 = Phys(latency = 0); val ev2 = mutableListOf<FarewellBarrierEvent>()
        val b2 = FarewellPlaybackBarrier(t2, { wall }, { ev2 += it }, nanoNow = { t2.nano })
        b2.begin("fw_late", 1)
        b2.push("fw_late", 0, pcm(480)); t2.head = 480        // consumed before any poll ran
        b2.end("fw_late", 1, 480); wall += 10_000; b2.poll()
        assertTrue("first observation already past the end: $ev2", drained(ev2).isEmpty())
    }

    @Test fun k26_evidenceDeadlineCoversLegacyQueuedAheadOfTheFarewell() {
        // Found by the k15 legacy_mid op: the deadline ignored queued legacy audio, so a farewell behind 3 s of
        // conversation audio timed out (fail-closed, but heard audio ended UNVERIFIED).
        var wall = now
        val t = Phys(); val ev = mutableListOf<FarewellBarrierEvent>()
        val b = FarewellPlaybackBarrier(t, { wall }, { ev += it }, evidenceGraceMs = 300, nanoNow = { t.nano })
        b.pushLegacy(pcm(72_000))                                    // 3 s queued
        b.begin("fw", 1); b.push("fw", 0, pcm(2400)); b.end("fw", 1, 2400)
        repeat(400) { wall += 10; t.consume(240); b.poll() }          // 4 s of real-time playback, polled every 10 ms
        assertEquals("$ev ${b.log}", 1, drained(ev).size)
    }

    @Test fun k27_writeAccountedBetweenNativeFlushAndANotificationIsNeverTrusted() {
        // QA-AND-5 (Grok R4): native flush empties the track; the parked write then copies 10 000 frames into it and
        // is ACCOUNTED; only then does the after-the-fact notification arrive. The cursor reset to 0 is a lie.
        val t = Phys(latency = 0); val ev = mutableListOf<FarewellBarrierEvent>()
        val b = FarewellPlaybackBarrier(t, { now }, { ev += it }, nanoNow = { t.nano })
        b.begin("fw_old", 1)
        t.flush()                                       // native flush already happened (not ordered by the barrier)
        b.push("fw_old", 0, pcm(10_000))                // write lands in the emptied track and is accounted
        b.onTrackFlushed("barge_in_flush")              // late notification
        ev.clear()
        b.begin("fw_new", 2); b.push("fw_new", 0, pcm(480)); b.end("fw_new", 1, 480)
        t.head = 480; b.poll()
        assertTrue("drained behind ${t.written - 480} orphan frames: $ev ${b.log}", drained(ev).isEmpty())
        assertEquals("track_unsynced", (ev.first() as FarewellBarrierEvent.Unverified).reason)
    }

    @Test fun k28_orderedFlush_aParkedWriteThatCompletesDuringTheNativeFlushIsNeverCounted() {
        // The account-then-notify race through the barrier-ordered API: the write is released INSIDE the native flush,
        // copies into the emptied track and returns before phase 3. It must be uncounted and the track unsynced.
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val t = object : Phys(latency = 0) {
            override fun write(pcm: ByteArray, offset: Int, size: Int): Int {
                if (size == 20_000) { entered.countDown(); release.await(2, TimeUnit.SECONDS) }
                return super.write(pcm, offset, size)
            }
        }
        val ev = mutableListOf<FarewellBarrierEvent>()
        val b = FarewellPlaybackBarrier(t, { now }, { ev += it }, nanoNow = { t.nano })
        b.begin("fw_old", 1)
        val w = Thread { b.push("fw_old", 0, pcm(10_000)) }.also { it.start() }
        assertTrue(entered.await(2, TimeUnit.SECONDS))
        b.flushTrack("barge_in_flush") {
            t.flush()                                   // native flush empties the track ...
            release.countDown(); w.join(2000)            // ... and the parked write lands in it and returns
            assertTrue("a new write must not start while flushing", !b.pushLegacy(pcm(10)))
        }
        ev.clear()
        b.begin("fw_new", 2)
        assertEquals("orphan frames resident=${t.written}: $ev ${b.log}", listOf(FarewellBarrierEvent.Unverified("fw_new", 2, "track_unsynced")), ev)
        b.flushTrack("resync"); ev.clear()                 // no write in flight: synced again
        b.begin("fw_ok", 3); b.push("fw_ok", 0, pcm(480)); b.end("fw_ok", 1, 480)
        t.head = 480; b.poll()
        assertEquals("$ev ${b.log}", 1, drained(ev).size)
    }

    @Test fun k29_aNativeFlushThatThrowsLeavesTheTrackUnsynced() {
        val t = Phys(latency = 0); val ev = mutableListOf<FarewellBarrierEvent>()
        val b = FarewellPlaybackBarrier(t, { now }, { ev += it }, nanoNow = { t.nano })
        b.pushLegacy(pcm(10_000))
        try { b.flushTrack("barge_in_flush") { throw IllegalStateException("AudioTrack flush failed") } } catch (_: IllegalStateException) {}
        b.begin("fw", 1)
        assertEquals(listOf(FarewellBarrierEvent.Unverified("fw", 1, "track_unsynced")), ev)
        assertTrue(b.pushLegacy(pcm(10)))       // writes are allowed again (flushing cleared)
    }
}
