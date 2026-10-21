// Track 21: the PLUGIN's FarewellPlaybackBarrier + LifetimeAudioTrackPort + RetiringPlaybackLifetime on a REAL
// android.media.AudioTrack inside an Android emulator, run with app_process (no APK, no Gradle). Writes go
// through the lifetime's data lane and a 10 ms poller runs, exactly like the plugin. Silent PCM.
// Emulator evidence, not physical-device proof. Build/run: run_emulator_probe.sh <adb serial>.
package com.cognistence.mindbend_gemini_live_audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

private class Rig {
    val track: AudioTrack = AudioTrack.Builder()
        .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
        .setAudioFormat(AudioFormat.Builder().setSampleRate(24_000).setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
        .setTransferMode(AudioTrack.MODE_STREAM)
        .setBufferSizeInBytes(maxOf(AudioTrack.getMinBufferSize(24_000, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT), 4800))
        .build()
    val lifetime = RetiringPlaybackLifetime(stop = { track.pause(); track.flush(); track.stop() }, release = { track.release() })
    val events = CopyOnWriteArrayList<FarewellBarrierEvent>()
    val barrier = FarewellPlaybackBarrier(LifetimeAudioTrackPort(track, lifetime), { System.currentTimeMillis() }, { events.add(it) })
    // The plugin's own poller and begin path (farewellBegin): poll from BEGIN on the data lane.
    private val poller = FarewellPoller(Executors.newSingleThreadScheduledExecutor())
    init { track.play() }
    fun begin(turnId: String, gen: Int) = beginFarewellOnDataLane(barrier, lifetime, turnId, gen) { poller.start(barrier, lifetime) }
    /** Queues on the data lane without waiting (a 2 s WRITE_BLOCKING push only returns near its end). */
    fun laneAsync(op: () -> Unit) { lifetime.submit(op) }
    fun lane(op: () -> Unit) {
        val latch = CountDownLatch(1)
        lifetime.submit { try { op() } finally { latch.countDown() } }
        check(latch.await(10, TimeUnit.SECONDS)) { "data lane stuck" }
    }
    fun await(turnId: String, timeoutMs: Long = 8000): FarewellBarrierEvent? {
        val end = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < end) {
            events.firstOrNull { it.turnId == turnId }?.let { return it }
            Thread.sleep(10)
        }
        return null
    }
    fun close() { poller.shutdown(); try { lifetime.cancel().get(5, TimeUnit.SECONDS) } catch (_: Throwable) {} }
}

private var failures = 0
private fun check(name: String, ok: Boolean, detail: String) {
    if (!ok) failures++
    println("${if (ok) "PASS" else "FAIL"} $name :: $detail")
}

fun main() {
    println("T21_EMULATOR_PROBE model=${android.os.Build.MODEL} sdk=${android.os.Build.VERSION.SDK_INT}")
    run {
        val r = Rig()
        r.lane { r.barrier.pushLegacy(ByteArray(9600)) }  // 200 ms ordinary audio ahead
        r.begin("fw_A", 1)
        r.lane { for (i in 0 until 4) require(r.barrier.push("fw_A", i, ByteArray(4800))) }
        val t0 = System.currentTimeMillis()
        r.barrier.end("fw_A", 4, 9600)
        val e = r.await("fw_A")
        val ok = e is FarewellBarrierEvent.Drained && e.evidence == "android_timestamp" && e.framesPlayed == 9600L && e.lastSeq == 3
        check("positive_drain_real_track", ok, "event=$e endToDrainMs=${(e as? FarewellBarrierEvent.Drained)?.drainedAtEpochMs?.minus(t0)}")
        r.close()
    }
    run {
        val r = Rig()
        r.begin("fw_P", 1)
        r.laneAsync { r.barrier.push("fw_P", 0, ByteArray(96000)) }
        r.laneAsync { r.barrier.end("fw_P", 1, 48000) }
        Thread.sleep(300)
        r.track.pause()
        val e = r.await("fw_P")
        check("platform_pause_mid_farewell_unverified", e is FarewellBarrierEvent.Unverified, "event=$e")
        r.close()
    }
    run {
        val r = Rig()
        r.begin("fw_F", 1)
        r.laneAsync { r.barrier.push("fw_F", 0, ByteArray(96000)) }
        r.laneAsync { r.barrier.end("fw_F", 1, 48000) }
        Thread.sleep(300)
        r.barrier.flushTrack("barge_in") // concurrent with the parked write: the barrier's own ordering path
        val e = r.await("fw_F")
        check("barge_in_flush_mid_farewell_unverified", e is FarewellBarrierEvent.Unverified && e.reason == "barge_in", "event=$e")
        // The flush overlapped a parked write, so the track is unsynced. The plugin's farewellBegin resyncs on the
        // data lane (no write in flight) before beginning: the next farewell must drain on the same track.
        val resynced = r.barrier.needsResync()
        r.begin("fw_G", 2)
        val t0 = System.currentTimeMillis()
        r.lane { require(r.barrier.push("fw_G", 0, ByteArray(9600))) }
        r.barrier.end("fw_G", 1, 4800)
        val g = r.await("fw_G")
        check("post_overlapping_flush_resync_then_drain", g is FarewellBarrierEvent.Drained && resynced,
            "resynced=$resynced event=$g endToDrainMs=${(g as? FarewellBarrierEvent.Drained)?.drainedAtEpochMs?.minus(t0)}")
        r.begin("fw_H", 3)
        r.lane { require(r.barrier.push("fw_H", 0, ByteArray(9600))) }
        r.barrier.end("fw_H", 1, 4800)
        check("no_resync_needed_after_clean_flush", r.await("fw_H") is FarewellBarrierEvent.Drained && !r.barrier.needsResync(), "log=${r.barrier.log.takeLast(3)}")
        r.close()
    }
    run {
        val r = Rig()
        r.begin("fw_R", 1)
        r.laneAsync { r.barrier.push("fw_R", 0, ByteArray(96000)) }
        r.laneAsync { r.barrier.end("fw_R", 1, 48000) }
        Thread.sleep(200)
        r.lifetime.cancel().get(5, TimeUnit.SECONDS)
        val e = r.await("fw_R")
        check("retired_lifetime_mid_farewell_unverified", e is FarewellBarrierEvent.Unverified, "event=$e")
        r.close()
    }
    run {
        val r = Rig()
        r.begin("fw_T", 1)
        r.lane { require(r.barrier.push("fw_T", 0, ByteArray(4800))) }
        r.barrier.end("fw_T", 1, 2401)
        val e = r.await("fw_T")
        check("end_totals_mismatch_unverified", e is FarewellBarrierEvent.Unverified && e.reason == "end_totals_mismatch", "event=$e")
        r.close()
    }
    run {
        val r = Rig()
        r.begin("fw_C", 1)
        r.laneAsync { r.barrier.push("fw_C", 0, ByteArray(96000)) }
        r.laneAsync { r.barrier.end("fw_C", 1, 48000) }
        Thread.sleep(150)
        r.barrier.cancel("fw_C", "user_done")
        val e = r.await("fw_C")
        check("cancel_mid_farewell_unverified", e is FarewellBarrierEvent.Unverified && e.reason == "user_done", "event=$e")
        r.close()
    }
    run {
        // Review R1-F3: BEGIN queued behind a long blocking legacy write must still be polled and drain.
        val r = Rig()
        r.laneAsync { r.barrier.pushLegacy(ByteArray(72000)) } // 1.5 s of ordinary audio parks the data lane
        Thread.sleep(50)
        r.begin("fw_Q", 4)
        r.laneAsync { r.barrier.push("fw_Q", 0, ByteArray(9600)) }
        r.laneAsync { r.barrier.end("fw_Q", 1, 4800) }
        val e = r.await("fw_Q", 10000)
        check("begin_queued_behind_blocking_write_drains", e is FarewellBarrierEvent.Drained, "event=$e")
        r.close()
    }
    println("T21_EMULATOR_PROBE_RESULT failures=$failures")
    System.exit(if (failures == 0) 0 else 1)
}
