package com.cognistence.mindbend_gemini_live_audio_example

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.cognistence.mindbend_gemini_live_audio.FarewellDrainGate
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Device-side copy of the drain contract. Not executed in this session.
 * A command acknowledgement must not become a native drain on hardware either.
 */
@RunWith(AndroidJUnit4::class)
class FarewellPlaybackBarrierInstrumentedTest {
    @Test
    fun commandAcknowledgementIsNotANativeDrain() {
        val gate = FarewellDrainGate()
        gate.begin(64)
        val ack = gate.acknowledgeCommand(gate.generation)
        assertEquals("command_ack", ack["evidence"])
        val drained = gate.noteAnchor(1, 40, gate.generation, true)
        assertEquals("native_drain", drained["evidence"])
    }
}
