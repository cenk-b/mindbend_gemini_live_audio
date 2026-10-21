package com.cognistence.mindbend_gemini_live_audio_example

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.cognistence.mindbend_gemini_live_audio.FarewellBarrierEvent
import com.cognistence.mindbend_gemini_live_audio.FarewellPlaybackBarrier
import com.cognistence.mindbend_gemini_live_audio.LifetimeAudioTrackPort
import com.cognistence.mindbend_gemini_live_audio.RetiringPlaybackLifetime
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * The plugin's FarewellPlaybackBarrier on a REAL android.media.AudioTrack through the plugin's own
 * LifetimeAudioTrackPort and RetiringPlaybackLifetime, polled every 10 ms like the plugin. Silent PCM.
 */
@RunWith(AndroidJUnit4::class)
class AttributedFarewellBarrierInstrumentedTest {
    private lateinit var track: AudioTrack
    private lateinit var lifetime: RetiringPlaybackLifetime
    private lateinit var barrier: FarewellPlaybackBarrier
    private val events = CopyOnWriteArrayList<FarewellBarrierEvent>()
    private val poller = Executors.newSingleThreadScheduledExecutor()

    @Before
    fun setUp() {
        track = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(24_000).setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(maxOf(AudioTrack.getMinBufferSize(24_000, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT), 4800))
            .build()
        val t = track
        lifetime = RetiringPlaybackLifetime(stop = { t.pause(); t.flush(); t.stop() }, release = { t.release() })
        barrier = FarewellPlaybackBarrier(LifetimeAudioTrackPort(track, lifetime), { System.currentTimeMillis() }, { events.add(it) })
        track.play()
        poller.scheduleAtFixedRate({ if (lifetime.isRetired()) barrier.invalidate("playback_retired") else barrier.poll() },
            10, 10, TimeUnit.MILLISECONDS)
    }

    @After
    fun tearDown() {
        poller.shutdownNow()
        lifetime.cancel().get(5, TimeUnit.SECONDS)
    }

    private fun await(turnId: String, timeoutMs: Long = 8000): FarewellBarrierEvent {
        val end = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < end) {
            events.firstOrNull { it.turnId == turnId }?.let { return it }
            Thread.sleep(10)
        }
        throw AssertionError("no outcome for $turnId; events=$events log=${barrier.log}")
    }

    private fun writeOnDataLane(op: () -> Unit) {
        val latch = java.util.concurrent.CountDownLatch(1)
        lifetime.submit { try { op() } finally { latch.countDown() } }
        assertTrue(latch.await(10, TimeUnit.SECONDS))
    }

    @Test
    fun realTrackDrainsWithTimestampEvidence() {
        writeOnDataLane { barrier.pushLegacy(ByteArray(9600)) }
        barrier.begin("fw_A", 1)
        writeOnDataLane { for (i in 0 until 4) assertTrue(barrier.push("fw_A", i, ByteArray(4800))) }
        val t0 = System.currentTimeMillis()
        barrier.end("fw_A", 4, 9600)
        val e = await("fw_A")
        assertTrue("expected drain, got $e log=${barrier.log}", e is FarewellBarrierEvent.Drained)
        e as FarewellBarrierEvent.Drained
        assertEquals("android_timestamp", e.evidence)
        assertEquals(9600L, e.framesPlayed)
        assertEquals(3, e.lastSeq)
        android.util.Log.i("T21_NATIVE", "real AudioTrack drained endToDrainMs=${e.drainedAtEpochMs - t0}")
    }

    @Test
    fun pauseMidFarewellIsUnverified() {
        barrier.begin("fw_P", 1)
        writeOnDataLane { assertTrue(barrier.push("fw_P", 0, ByteArray(96000))) } // 2 s
        barrier.end("fw_P", 1, 48000)
        Thread.sleep(300)
        track.pause() // a platform pause behind the barrier
        val e = await("fw_P")
        assertTrue("got $e", e is FarewellBarrierEvent.Unverified)
    }

    @Test
    fun barrierOrderedFlushMidFarewellIsUnverifiedAndTheNextFarewellStillDrains() {
        barrier.begin("fw_F", 1)
        writeOnDataLane { assertTrue(barrier.push("fw_F", 0, ByteArray(96000))) }
        barrier.end("fw_F", 1, 48000)
        Thread.sleep(300)
        writeOnDataLane { barrier.flushTrack("barge_in") }
        val e = await("fw_F")
        assertTrue("got $e", e is FarewellBarrierEvent.Unverified)
        assertEquals("barge_in", (e as FarewellBarrierEvent.Unverified).reason)
        barrier.begin("fw_G", 2)
        writeOnDataLane { assertTrue(barrier.push("fw_G", 0, ByteArray(9600))) }
        barrier.end("fw_G", 1, 4800)
        val g = await("fw_G")
        assertTrue("post-flush farewell must drain: $g log=${barrier.log}", g is FarewellBarrierEvent.Drained)
    }

    @Test
    fun retiringTheLifetimeMidFarewellIsUnverified() {
        barrier.begin("fw_R", 1)
        writeOnDataLane { assertTrue(barrier.push("fw_R", 0, ByteArray(96000))) }
        barrier.end("fw_R", 1, 48000)
        Thread.sleep(200)
        lifetime.cancel().get(5, TimeUnit.SECONDS)
        val e = await("fw_R")
        assertTrue("got $e", e is FarewellBarrierEvent.Unverified)
    }
}
