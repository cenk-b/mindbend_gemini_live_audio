package com.cognistence.mindbend_gemini_live_audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Like a real AudioTrack (API 36 javadoc): flush() is a NO-OP while the track is playing; pause() may throw. */
class PlatformPhys : Phys(latency = 0) {
    var pauseThrows = false
    var pauseIgnored = false          // a pause() that does not take effect (track keeps playing)
    override fun flush() { if (!playing) super.flush() }
    override fun pause() { if (pauseThrows) throw IllegalStateException("pause() called on uninitialized AudioTrack."); if (!pauseIgnored) super.pause() }
    /** API 36: stop() resets the head to 0 but (MODE_STREAM) does NOT discard the queued audio. */
    override fun stop() { playing = false; head = 0 }
    override fun play() { playing = true }
}

/** Regressions for Grok QA round 5 (ports qa/grok_r5/probes/android_r5_attacks.kt). */
class LabFarewellBarrierR5Test {
    private val now = 1_700_000_000_000L
    private fun pcm(frames: Int) = ByteArray(frames * 2)
    private fun barrier(t: Phys, ev: MutableList<FarewellBarrierEvent>) = FarewellPlaybackBarrier(t, { now }, { ev += it }, nanoNow = { t.nano })

    /** Runs a 480-frame farewell after everything else; returns true when it drained although orphan frames sit
     *  in front of it (the false drain). */
    private fun falseDrainAfter(b: FarewellPlaybackBarrier, t: Phys, ev: MutableList<FarewellBarrierEvent>): Boolean {
        ev.clear()
        b.begin("fw_new", 7)
        if (b.push("fw_new", 0, pcm(480))) b.end("fw_new", 1, 480)
        t.head = minOf(t.written, 480); b.poll()
        return ev.any { it is FarewellBarrierEvent.Drained } && t.written > 480
    }

    @Test fun k30_overlappingFlushesNeverPublishASyncedCursorEarly() {
        // Same thread: nativeFlush re-enters flushTrack, then tries to write 10 000 frames before the outer resets.
        run {
            val t = Phys(latency = 0); val ev = mutableListOf<FarewellBarrierEvent>(); val b = barrier(t, ev)
            var legacyOk = true
            b.flushTrack("outer") { t.flush(); b.flushTrack("inner") { t.flush() }; legacyOk = b.pushLegacy(pcm(10_000)) }
            assertFalse("no write may start while the OUTER flush is still running", legacyOk)
            assertFalse("false drain behind orphan frames: ${b.log}", falseDrainAfter(b, t, ev))
        }
        // Two threads: the inner flush completes inside the outer nativeFlush; a writer then tries to slip in.
        run {
            val t = Phys(latency = 0); val ev = mutableListOf<FarewellBarrierEvent>(); val b = barrier(t, ev)
            var legacyOk = true
            b.flushTrack("outer") {
                t.flush()
                Thread { b.flushTrack("inner") { t.flush() } }.apply { start(); join(2000) }
                Thread { legacyOk = b.pushLegacy(pcm(10_000)) }.apply { start(); join(2000) }
            }
            assertFalse(legacyOk)
            assertFalse("false drain behind orphan frames: ${b.log}", falseDrainAfter(b, t, ev))
        }
    }

    @Test fun k31_theDefaultFlushReallyDiscardsOnAPlayingTrack_andANonDiscardingFlushIsUnsynced() {
        // API 36: flush() is a no-op while playing. The default nativeFlush must pause first.
        run {
            val t = PlatformPhys(); val ev = mutableListOf<FarewellBarrierEvent>(); val b = barrier(t, ev)
            b.pushLegacy(pcm(10_000)); t.consume(2000)
            b.flushTrack("default_while_playing")
            assertEquals("discarded", 0L, t.written)
            assertTrue("track playing again after the flush", t.playing)
            assertFalse(falseDrainAfter(b, t, ev))
            assertTrue("a correct flush lets the farewell drain: $ev ${b.log}", ev.any { it is FarewellBarrierEvent.Drained })
        }
        // Since R6 a caller hook cannot replace the barrier's own discard: a hook that only calls flush() (a no-op
        // while playing) still finds the track already discarded by the barrier's pause+flush.
        run {
            val t = PlatformPhys(); val ev = mutableListOf<FarewellBarrierEvent>(); val b = barrier(t, ev)
            b.pushLegacy(pcm(10_000)); t.consume(2000)
            b.flushTrack("no_op_hook") { t.flush() }
            assertEquals(0L, t.written)
            assertFalse("false drain behind orphan frames: ${b.log}", falseDrainAfter(b, t, ev))
        }
        // pause() throws inside the default flush: unsynced, never a trusted empty cursor.
        run {
            val t = PlatformPhys(); val ev = mutableListOf<FarewellBarrierEvent>(); val b = barrier(t, ev)
            b.pushLegacy(pcm(10_000)); t.pauseThrows = true
            try { b.flushTrack("pause_throws") } catch (_: IllegalStateException) {}
            t.pauseThrows = false
            assertFalse("false drain behind orphan frames: ${b.log}", falseDrainAfter(b, t, ev))
        }
    }

    @Test fun k32_aWriteFromInsideNativeFlushNeverDeadlocksBehindAParkedWrite() {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val t = object : Phys(latency = 0) {
            override fun write(pcm: ByteArray, offset: Int, size: Int): Int {
                if (size == 20_000) { entered.countDown(); release.await(3, TimeUnit.SECONDS) }
                return super.write(pcm, offset, size)
            }
        }
        val ev = mutableListOf<FarewellBarrierEvent>(); val b = barrier(t, ev)
        val w = Thread { b.pushLegacy(pcm(10_000)) }.apply { isDaemon = true; start() }
        assertTrue(entered.await(2, TimeUnit.SECONDS))
        val flusher = Thread {
            b.flushTrack("barge_in") { t.flush(); b.pushLegacy(pcm(100)); b.begin("fw_x", 1); b.push("fw_x", 0, pcm(10)) }
        }.apply { isDaemon = true; start() }
        flusher.join(1000)
        val stuck = flusher.isAlive
        release.countDown(); w.join(2000); flusher.join(2000)
        assertFalse("flushTrack re-entering a write deadlocked behind the parked write", stuck)
    }

    @Test fun k33_theBarrierItselfProvesTheDiscard_aHeadOfZeroIsNotProof() {
        // Grok R6: playing track, head never moved (0), 10 000 frames queued. A caller hook that only calls flush()
        // (a no-op while playing) must not leave the track trusted: the barrier pauses before flushing itself.
        run {
            val t = PlatformPhys(); val ev = mutableListOf<FarewellBarrierEvent>(); val b = barrier(t, ev)
            b.pushLegacy(pcm(10_000))
            b.flushTrack("noop_head0") { t.flush() }
            assertEquals("the barrier's own pause+flush discarded", 0L, t.written)
            assertFalse("false drain behind orphan frames: ${b.log}", falseDrainAfter(b, t, ev))
        }
        // stop() zeroes the head without discarding: a hook that stops instead of flushing is still discarded by the
        // barrier's own flush (the track is not playing at that point).
        run {
            val t = PlatformPhys(); val ev = mutableListOf<FarewellBarrierEvent>(); val b = barrier(t, ev)
            b.pushLegacy(pcm(10_000)); t.consume(2000)
            b.flushTrack("stop_then_play") { t.stop(); t.play() }
            assertFalse("false drain behind orphan frames: ${b.log}", falseDrainAfter(b, t, ev))
        }
        // A pause that does not take effect: flush() would be a no-op, so the track must stay unsynced.
        run {
            val t = PlatformPhys(); val ev = mutableListOf<FarewellBarrierEvent>(); val b = barrier(t, ev)
            b.pushLegacy(pcm(10_000)); t.pauseIgnored = true
            b.flushTrack("pause_ignored")
            t.pauseIgnored = false
            assertFalse("false drain behind orphan frames: ${b.log}", falseDrainAfter(b, t, ev))
            assertEquals("track_unsynced", (ev.first() as FarewellBarrierEvent.Unverified).reason)
        }
        // An unsynced flag (orphan write) is not cleared by a flush whose discard cannot be shown.
        run {
            val t = PlatformPhys(); val ev = mutableListOf<FarewellBarrierEvent>(); val b = barrier(t, ev)
            b.onTrackFlushed("late")                         // after the fact: unsynced
            t.flush(); b.pushLegacy(pcm(10_000))             // (this write is refused? no: allowed, the track holds audio)
            t.pauseIgnored = true; b.flushTrack("resync_cannot_pause"); t.pauseIgnored = false
            assertFalse("false drain behind orphan frames: ${b.log}", falseDrainAfter(b, t, ev))
        }
    }
}
