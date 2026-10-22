// Track 21 cross-language E2E: JSON-lines bridge to the PLUGIN's FarewellPlaybackBarrier.kt on a REAL-TIME
// SIMULATED AudioTrack (host JVM). This is simulation, not Android platform evidence; the Android emulator
// instrumented test runs the same barrier on a real AudioTrack. Adapted from the Track 21 lab CLI.
package com.cognistence.mindbend_gemini_live_audio

import java.util.Base64

/** Physically plausible simulated track: consumption advances at sampleRate only while data is available (it
 *  stalls on underrun and resumes at the sample rate); presentation lags consumption by up to latencyFrames while
 *  streaming, catches up at the sample rate once the buffer is dry, and never moves backwards. */
class RealtimeSimTrack(override val sampleRate: Int = 24000, val latencyFrames: Long = 1200, val timestamps: Boolean = true) : FarewellTrackPort {
    @Volatile var written = 0L
    private var writtenBytes = 0L
    @Volatile var playing = true
    @Volatile var route = 1
    private var consumedF = 0.0
    private var presentedF = 0.0
    private var lastNs = System.nanoTime()
    @Synchronized private fun tick() {
        val now = System.nanoTime()
        val dt = (now - lastNs) / 1_000_000_000.0 * sampleRate
        lastNs = now
        if (!playing) return
        consumedF = minOf(written.toDouble(), consumedF + dt)
        val ceiling = if (consumedF < written) consumedF - latencyFrames else consumedF
        presentedF = maxOf(presentedF, minOf(ceiling, presentedF + dt))
    }
    @Synchronized override fun write(pcm: ByteArray, offset: Int, size: Int): Int {
        tick()
        if (!playing) return 0
        writtenBytes += size; written = writtenBytes / 2; return size
    }
    override fun playbackHeadPosition(): Int { tick(); return consumedF.toLong().toInt() }
    @Synchronized override fun timestamp(): FarewellTrackTimestamp? {
        tick()
        if (!timestamps || !playing) return null
        return FarewellTrackTimestamp(maxOf(0L, presentedF.toLong()), System.nanoTime())
    }
    override fun isPlaying() = playing
    override fun routedDeviceId() = route
    override fun pause() { tick(); playing = false }
    /** Like AudioTrack: a no-op while playing; discards everything (cursor and head to 0) when paused/stopped. */
    @Synchronized override fun flush() { tick(); if (!playing) { written = 0; writtenBytes = 0; consumedF = 0.0; presentedF = 0.0 } }
    override fun play() { tick(); playing = true }
    override fun stop() { pause() }
}

private val field = Regex("\"(\\w+)\"\\s*:\\s*(\"([^\"]*)\"|(-?\\d+))")
fun parse(line: String): Map<String, String> = field.findAll(line).associate { m -> m.groupValues[1] to (m.groupValues[3].ifEmpty { m.groupValues[4] }) }
fun esc(s: String) = s.replace("\\", "\\\\").replace("\"", "\\\"")

fun main(args: Array<String>) {
    val timestamps = !args.contains("--no-timestamps")
    val track = RealtimeSimTrack(timestamps = timestamps)
    val lock = Object()
    fun out(s: String) = synchronized(lock) { println(s); System.out.flush() }
    val barrier = FarewellPlaybackBarrier(track, { System.currentTimeMillis() }, { e ->
        when (e) {
            is FarewellBarrierEvent.Drained -> out("""{"event":"drained","turnId":"${esc(e.turnId)}","gen":${e.nativeGeneration},"drainedAtEpochMs":${e.drainedAtEpochMs},"framesPlayed":${e.framesPlayed},"lastSeq":${e.lastSeq},"evidence":"${e.evidence}"}""")
            is FarewellBarrierEvent.Unverified -> out("""{"event":"unverified","turnId":"${esc(e.turnId)}","gen":${e.nativeGeneration},"reason":"${esc(e.reason)}"}""")
        }
    }, evidenceGraceMs = 1500)
    Thread { while (true) { barrier.poll(); Thread.sleep(10) } }.apply { isDaemon = true; start() }
    out("""{"event":"ready","timestamps":$timestamps}""")
    while (true) {
        val line = readLine() ?: break
        val o = parse(line)
        val t = o["turnId"] ?: ""
        when (o["op"]) {
            "begin" -> barrier.begin(t, o["gen"]?.toInt() ?: 0)
            "push" -> {
                val ok = barrier.push(t, o["seq"]?.toInt() ?: -1, Base64.getDecoder().decode(o["b64"] ?: ""))
                out("""{"event":"pushed","turnId":"${esc(t)}","seq":${o["seq"]},"ok":$ok}""")
            }
            "end" -> barrier.end(t, o["n"]?.toInt() ?: 0, o["frames"]?.toLong() ?: 0)
            "cancel" -> barrier.cancel(t, o["reason"] ?: "cancel")
            "externalStop" -> { track.pause(); barrier.invalidate("track_paused") }
            "routeChange" -> { track.route += 1 }
            "quit" -> break
        }
    }
    kotlin.system.exitProcess(0)
}
