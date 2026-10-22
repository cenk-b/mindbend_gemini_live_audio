package com.cognistence.mindbend_gemini_live_audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/** Seeded randomized stress of the Android barrier against the FakeTrack model. SAFETY is checked against
 *  the model's ground truth at the moment of emission: a Drained event is only legal when the presented
 *  position truly covers the farewell's last frame and nothing disturbed the turn. LIVENESS: an undisturbed
 *  turn always drains. FUZZ_SEEDS env (default 5000). */
class LabFarewellBarrierFuzzTest {
    @Test fun k15_seededInterleavingsNeverDrainEarlyOrTwice() {
        val seeds = System.getenv("FUZZ_SEEDS")?.toIntOrNull() ?: 5000
        var drained = 0; var unverified = 0; var undisturbed = 0
        for (seed in 0 until seeds) {
            val r = Random(seed)
            val track = FakeTrack().also { it.headOffset = if (r.nextInt(4) == 0) 0xFFFF_FFFFL - r.nextLong(5000) else 0 }
            var now = 1_700_000_000_000L
            val events = mutableListOf<FarewellBarrierEvent>()
            var endFrameTruth = -1L
            var disturbed = false
            val ops = mutableListOf<String>()
            lateinit var b: FarewellPlaybackBarrier
            b = FarewellPlaybackBarrier(track, { now }, { e ->
                if (e is FarewellBarrierEvent.Drained) {
                    val presented = track.head - track.latencyFrames
                    assertTrue("seed=$seed drained before the last frame was presented: presented=$presented end=$endFrameTruth ops=$ops",
                        endFrameTruth >= 0 && presented >= endFrameTruth && track.playing)
                    assertTrue("seed=$seed drained a disturbed turn ops=$ops", !disturbed)
                }
                events += e
            }, evidenceGraceMs = 300, nanoNow = { track.nano })
            b.extendedHead()
            if (r.nextBoolean()) { val legacy = 1 + r.nextInt(4800); b.pushLegacy(ByteArray(legacy * 2)); ops += "legacy$legacy" }
            var start = -1L                       // ground truth: written cursor at the FIRST farewell write
            b.begin("fw_T", 11)
            val n = 1 + r.nextInt(5)
            var frames = 0L
            var ended = false
            var seq = 0
            val steps = n + 2 + r.nextInt(12)
            // A poll that observes a paused track after END is a legitimate unverified ("not_playing").
            fun poll() { if (ended && !track.playing) disturbed = true; b.poll() }
            // Physical model (production polls every ~10 ms): one 10 ms step consumes 240 frames; once the buffer
            // runs dry, presentation catches up with the head; new audio after a dry spell refills the pipeline lag.
            fun step() {
                track.consume(240)
                if (track.playing && track.head == track.written) track.latencyFrames = maxOf(0L, track.latencyFrames - 240)
                poll()
            }
            fun refill() { if (track.head == track.written) track.latencyFrames = 1200 }
            for (i in 0 until steps) {
                val op = when {
                    seq < n && r.nextInt(3) == 0 -> "push"
                    seq == n && !ended && r.nextInt(3) == 0 -> "end"
                    else -> listOf("consume", "consume", "poll", "time", "route", "pause", "resume", "flush", "invalidate",
                        "dup_push", "wrong_end", "partial", "no_ts", "regress", "push_after_end", "legacy_mid")[r.nextInt(16)]
                }
                ops += op
                when (op) {
                    "push" -> { refill(); if (start < 0) start = track.written; val f = 1 + r.nextInt(1200); if (b.push("fw_T", seq, ByteArray(f * 2))) frames += f else disturbed = true; seq++ }
                    "partial" -> if (seq < n) {
                        refill(); if (start < 0) start = track.written; track.writeScript = ArrayDeque(listOf(1 + r.nextInt(400), 1 + r.nextInt(400)))
                        val f = 1 + r.nextInt(1200); if (b.push("fw_T", seq, ByteArray(f * 2))) frames += f else disturbed = true; seq++
                    }
                    "end" -> { ended = true; endFrameTruth = start + frames; if (!track.playing) disturbed = true; b.end("fw_T", n, frames) }
                    "wrong_end" -> if (seq == n && !ended) { b.end("fw_T", n, frames + 1); ended = true; disturbed = true }
                    "consume" -> repeat(1 + r.nextInt(12)) { step() }
                    "poll" -> poll()
                    // Wall time passes: a playing track consumes and presents audio at the sample rate.
                    // Wall time passes in 10 ms poll steps (production polls continuously): a playing track consumes
                    // and presents audio at the sample rate.
                    "time" -> repeat(1 + r.nextInt(40)) { now += 10; step() }
                    "route" -> { track.route++; disturbed = true; if (r.nextBoolean()) poll() }
                    "pause" -> { track.pause(); if (r.nextBoolean()) poll() }
                    "resume" -> track.playing = true
                    "flush" -> { b.flushTrack("flush"); disturbed = true }
                    "invalidate" -> { b.invalidate("recovery"); disturbed = true }
                    "dup_push" -> if (seq > 0) { b.push("fw_T", seq - 1, ByteArray(2)); disturbed = true }
                    "push_after_end" -> if (ended) { b.push("fw_T", seq, ByteArray(2)); disturbed = true }
                    "no_ts" -> { track.timestampsAvailable = false; disturbed = true }
                    // QA-AND-4: legacy before the first farewell chunk is fine (the farewell starts after it); between
                    // chunks it must fail the turn; after END it is appended behind the farewell.
                    "legacy_mid" -> { refill(); val f = 1 + r.nextInt(2400); if (seq > 0 && !ended) disturbed = true; b.pushLegacy(ByteArray(f * 2)) }
                    "regress" -> if (track.head > 10) {
                        // Production polls continuously (<= 10 ms), so the pre-regression head is observed first.
                        // A regression that no poll ever observes is invisible to ANY sampler (handoff requirement).
                        b.poll(); track.head -= 1 + r.nextLong(track.head - 1); disturbed = true; b.poll()
                    }
                }
            }
            // Settle: finish the turn as an undisturbed client would, then let time run out.
            while (seq < n && !disturbed) { refill(); if (start < 0) start = track.written; val f = 1 + r.nextInt(1200); if (b.push("fw_T", seq, ByteArray(f * 2))) frames += f; seq++ }
            if (!disturbed) track.playing = true
            if (!ended && !disturbed) { ended = true; endFrameTruth = start + frames; b.end("fw_T", n, frames) }
            if (!disturbed) repeat(400) { now += 10; step() }
            b.poll(); now += 10_000; b.poll()
            val why = "seed=$seed ops=$ops events=$events log=${b.log}"
            assertTrue("at most one terminal event: $why", events.size <= 1)
            if (ended) assertEquals("exactly one terminal event once END was accepted or attempted: $why", 1, events.size)
            when (val e = events.firstOrNull()) {
                is FarewellBarrierEvent.Drained -> { drained++; assertEquals(why, frames, e.framesPlayed); assertEquals(why, n - 1, e.lastSeq) }
                is FarewellBarrierEvent.Unverified -> { unverified++; assertTrue("undisturbed turn must drain: $why", disturbed) }
                null -> {}
            }
            if (!disturbed) undisturbed++
        }
        println("k15 seeds=0..${seeds - 1} drained=$drained unverified=$unverified undisturbed=$undisturbed")
        assertTrue(drained > seeds / 20); assertTrue(unverified > seeds / 20)
    }
}
