package com.cognistence.mindbend_gemini_live_audio

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals

class FarewellPlaybackBarrierTest {
    @Test
    fun commandAcknowledgementIsNotANativeDrain() {
        val gate = FarewellDrainGate()
        val begun = gate.begin(100)
        assertEquals("armed", begun["state"])
        val ack = gate.acknowledgeCommand(gate.generation)
        assertEquals("command_ack", ack["evidence"])
        assertNotEquals("native_drain", ack["evidence"])
    }

    @Test
    fun earlyNativeReportOutsideTheNearEndWindowIsNotADrain() {
        val gate = FarewellDrainGate()
        gate.begin(100)
        val early = gate.noteAnchor(1, 10, gate.generation, true)
        assertEquals("none", early["evidence"])
        assertEquals("armed", early["state"])
    }

    @Test
    fun nativeDrainRequiresTheNearEndWindow() {
        val gate = FarewellDrainGate()
        gate.begin(100)
        val drained = gate.noteAnchor(4, 80, gate.generation, true)
        assertEquals("native_drain", drained["evidence"])
        assertEquals("drained", drained["state"])
    }

    @Test
    fun flushClearsDrainEvidenceAndInvalidatesTheGeneration() {
        val gate = FarewellDrainGate()
        val begun = gate.begin(100)
        val generation = begun["generation"] as Long
        gate.noteAnchor(4, 80, generation, true)
        val flushed = gate.noteFlush()
        assertEquals("none", flushed["evidence"])
        assertEquals("flushed", flushed["state"])
        val late = gate.noteAnchor(5, 100, generation, true)
        assertNotEquals("native_drain", late["evidence"])
    }

    @Test
    fun staleGenerationCannotOverwriteANewerDrain() {
        val gate = FarewellDrainGate()
        val first = gate.begin(100)
        val firstGeneration = first["generation"] as Long
        val second = gate.begin(100)
        val stale = gate.noteAnchor(1, 90, firstGeneration, true)
        assertEquals(second["generation"], stale["generation"])
        assertEquals("none", stale["evidence"])
        assertEquals("armed", stale["state"])
    }

    @Test
    fun cancelBlocksRestartAndRejectsTheOldGeneration() {
        val gate = FarewellDrainGate()
        val begun = gate.begin(40)
        val cancelled = gate.cancel()
        assertEquals(true, cancelled["restartBlocked"])
        assertEquals("cancelled", cancelled["state"])
        val late = gate.noteAnchor(1, 40, begun["generation"] as Long, true)
        assertNotEquals("native_drain", late["evidence"])
        val reset = gate.resetForNewSession()
        assertEquals(false, reset["restartBlocked"])
        assertEquals("idle", reset["state"])
    }
}
