package com.cognistence.mindbend_gemini_live_audio

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.Handler
import android.os.Looper
import android.os.Process
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class MindbendGeminiLiveAudioPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler {
    private lateinit var applicationContext: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var capturedAudioChannel: EventChannel
    private lateinit var eventChannel: EventChannel

    private val mainHandler = Handler(Looper.getMainLooper())
    private val playbackExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val isSessionRunning = AtomicBoolean(false)
    private val playbackGeneration = AtomicLong(0)

    private var capturedAudioSink: EventChannel.EventSink? = null
    private var eventSink: EventChannel.EventSink? = null

    private var audioManager: AudioManager? = null
    private var previousAudioMode: Int? = null
    private var previousSpeakerphoneOn: Boolean? = null

    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private var acousticEchoCanceler: AcousticEchoCanceler? = null
    private var noiseSuppressor: NoiseSuppressor? = null
    private var automaticGainControl: AutomaticGainControl? = null

    private var captureThread: Thread? = null
    private var playbackStarted = false

    private var disableNoiseSuppressor = false
    private var disableAutomaticGainControl = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "mindbend_gemini_live_audio/methods")
        methodChannel.setMethodCallHandler(this)

        capturedAudioChannel =
            EventChannel(binding.binaryMessenger, "mindbend_gemini_live_audio/captured_audio")
        capturedAudioChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    capturedAudioSink = events
                }

                override fun onCancel(arguments: Any?) {
                    capturedAudioSink = null
                }
            },
        )

        eventChannel = EventChannel(binding.binaryMessenger, "mindbend_gemini_live_audio/events")
        eventChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            },
        )
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startSession" -> result.success(startSession())
            "stopSession" -> {
                stopSessionInternal(restoreAudioState = true)
                result.success(null)
            }
            "pushPlaybackPcm" -> {
                val bytes = call.arguments as? ByteArray
                if (bytes == null) {
                    result.error("invalid_playback_bytes", "pushPlaybackPcm expects Uint8List bytes.", null)
                    return
                }
                pushPlayback(bytes)
                result.success(null)
            }
            "flushPlayback" -> {
                flushPlaybackInternal()
                result.success(null)
            }
            "markPlaybackComplete" -> {
                markPlaybackCompleteInternal()
                result.success(null)
            }
            "setDebugOptions" -> {
                val args = call.arguments as? Map<*, *>
                disableNoiseSuppressor = args?.get("disableNoiseSuppressor") as? Boolean ?: false
                disableAutomaticGainControl = args?.get("disableAutomaticGainControl") as? Boolean ?: false
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopSessionInternal(restoreAudioState = true)
        methodChannel.setMethodCallHandler(null)
        capturedAudioChannel.setStreamHandler(null)
        eventChannel.setStreamHandler(null)
        playbackExecutor.shutdownNow()
    }

    @Synchronized
    private fun startSession(): Map<String, Any?> {
        if (isSessionRunning.get()) {
            return startResult(
                aecActive = true,
                nsActive = noiseSuppressor?.enabled == true,
                agcActive = automaticGainControl?.enabled == true,
                transportMode = "native_aec",
                errorCode = null,
            )
        }

        try {
            audioManager = applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            previousAudioMode = audioManager?.mode
            previousSpeakerphoneOn = audioManager?.isSpeakerphoneOn
            audioManager?.mode = AudioManager.MODE_IN_COMMUNICATION
            audioManager?.isSpeakerphoneOn = true

            val captureBufferSize = maxOf(
                AudioRecord.getMinBufferSize(
                    CAPTURE_SAMPLE_RATE_HZ,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                ),
                3200,
            )

            val record = AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                CAPTURE_SAMPLE_RATE_HZ,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                captureBufferSize,
            )
            if (record.state != AudioRecord.STATE_INITIALIZED) {
                record.release()
                return fallbackResult("audio_record_init_failed")
            }

            if (!AcousticEchoCanceler.isAvailable()) {
                record.release()
                restoreAudioManagerState()
                return fallbackResult("aec_unavailable")
            }

            val echoCanceler = AcousticEchoCanceler.create(record.audioSessionId)
                ?: run {
                    record.release()
                    restoreAudioManagerState()
                    return fallbackResult("aec_create_failed")
                }
            echoCanceler.enabled = true

            val ns = NoiseSuppressor.create(record.audioSessionId)?.apply {
                enabled = !disableNoiseSuppressor
            }
            val agc = AutomaticGainControl.create(record.audioSessionId)?.apply {
                enabled = !disableAutomaticGainControl
            }

            val playbackBufferSize = maxOf(
                AudioTrack.getMinBufferSize(
                    PLAYBACK_SAMPLE_RATE_HZ,
                    AudioFormat.CHANNEL_OUT_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                ),
                4800,
            )
            val track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(PLAYBACK_SAMPLE_RATE_HZ)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(playbackBufferSize)
                .build()

            if (track.state != AudioTrack.STATE_INITIALIZED) {
                track.release()
                ns?.release()
                agc?.release()
                echoCanceler.release()
                record.release()
                restoreAudioManagerState()
                return fallbackResult("audio_track_init_failed")
            }

            audioRecord = record
            audioTrack = track
            acousticEchoCanceler = echoCanceler
            noiseSuppressor = ns
            automaticGainControl = agc
            playbackStarted = false
            isSessionRunning.set(true)
            playbackGeneration.incrementAndGet()

            track.play()
            record.startRecording()
            startCaptureLoop(captureBufferSize)

            return startResult(
                aecActive = true,
                nsActive = ns?.enabled == true,
                agcActive = agc?.enabled == true,
                transportMode = "native_aec",
                errorCode = null,
            )
        } catch (t: Throwable) {
            emitEvent("error:android_start_failed")
            stopSessionInternal(restoreAudioState = true)
            return fallbackResult("android_start_failed")
        }
    }

    private fun startCaptureLoop(bufferSize: Int) {
        val record = audioRecord ?: return
        captureThread?.interrupt()
        captureThread = Thread {
            Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
            val buffer = ByteArray(minOf(bufferSize, 640))
            while (isSessionRunning.get()) {
                val read = record.read(buffer, 0, buffer.size)
                if (read > 0) {
                    emitCapturedAudio(if (read == buffer.size) buffer.clone() else buffer.copyOf(read))
                } else if (read < 0) {
                    emitEvent("error:android_capture_read_$read")
                    break
                }
            }
        }.apply {
            name = "MindbendGeminiLiveAudioCapture"
            start()
        }
    }

    private fun pushPlayback(bytes: ByteArray) {
        if (bytes.isEmpty() || !isSessionRunning.get()) {
            return
        }
        val generationAtEnqueue = playbackGeneration.get()
        playbackExecutor.execute {
            if (!isSessionRunning.get() || generationAtEnqueue != playbackGeneration.get()) {
                return@execute
            }
            val track = audioTrack ?: return@execute
            if (!playbackStarted) {
                playbackStarted = true
                emitEvent("playback_started")
            }
            var offset = 0
            while (offset < bytes.size && isSessionRunning.get()) {
                if (generationAtEnqueue != playbackGeneration.get()) {
                    return@execute
                }
                val written = track.write(bytes, offset, bytes.size - offset, AudioTrack.WRITE_BLOCKING)
                if (written <= 0) {
                    if (generationAtEnqueue != playbackGeneration.get()) {
                        return@execute
                    }
                    emitEvent("error:android_playback_write_$written")
                    return@execute
                }
                offset += written
            }
        }
    }

    private fun flushPlaybackInternal() {
        if (!isSessionRunning.get()) return
        val nextGeneration = playbackGeneration.incrementAndGet()
        playbackExecutor.execute {
            if (!isSessionRunning.get() || nextGeneration != playbackGeneration.get()) {
                return@execute
            }
            val track = audioTrack ?: return@execute
            try {
                track.pause()
                track.flush()
                track.play()
                playbackStarted = false
                emitEvent("interrupted")
                emitEvent("playback_stopped")
            } catch (t: Throwable) {
                emitEvent("error:android_flush_failed")
            }
        }
    }

    @Synchronized
    private fun markPlaybackCompleteInternal() {
        // Native playback completion is inferred from chunk idle timing in Dart.
        // Do not flush or stop queued audio here.
    }

    @Synchronized
    private fun stopSessionInternal(restoreAudioState: Boolean) {
        isSessionRunning.set(false)
        playbackGeneration.incrementAndGet()
        playbackStarted = false

        captureThread?.interrupt()
        captureThread = null

        try {
            audioRecord?.stop()
        } catch (_: Throwable) {
        }
        audioRecord?.release()
        audioRecord = null

        try {
            audioTrack?.pause()
            audioTrack?.flush()
            audioTrack?.stop()
        } catch (_: Throwable) {
        }
        audioTrack?.release()
        audioTrack = null

        acousticEchoCanceler?.release()
        acousticEchoCanceler = null
        noiseSuppressor?.release()
        noiseSuppressor = null
        automaticGainControl?.release()
        automaticGainControl = null

        if (restoreAudioState) {
            restoreAudioManagerState()
        }
    }

    private fun restoreAudioManagerState() {
        try {
            previousAudioMode?.let { audioManager?.mode = it }
            previousSpeakerphoneOn?.let { audioManager?.isSpeakerphoneOn = it }
        } catch (_: Throwable) {
        }
    }

    private fun fallbackResult(errorCode: String): Map<String, Any?> {
        stopSessionInternal(restoreAudioState = true)
        return startResult(
            aecActive = false,
            nsActive = false,
            agcActive = false,
            transportMode = "legacy_half_duplex",
            errorCode = errorCode,
        )
    }

    private fun startResult(
        aecActive: Boolean,
        nsActive: Boolean,
        agcActive: Boolean,
        transportMode: String,
        errorCode: String?,
    ): Map<String, Any?> =
        mapOf(
            "aecActive" to aecActive,
            "nsActive" to nsActive,
            "agcActive" to agcActive,
            "transportMode" to transportMode,
            "captureSampleRateHz" to CAPTURE_SAMPLE_RATE_HZ,
            "playbackSampleRateHz" to PLAYBACK_SAMPLE_RATE_HZ,
            "errorCode" to errorCode,
        )

    private fun emitCapturedAudio(bytes: ByteArray) {
        val sink = capturedAudioSink ?: return
        mainHandler.post {
            sink.success(bytes)
        }
    }

    private fun emitEvent(value: String) {
        val sink = eventSink ?: return
        mainHandler.post {
            sink.success(value)
        }
    }

    private companion object {
        const val CAPTURE_SAMPLE_RATE_HZ = 16_000
        const val PLAYBACK_SAMPLE_RATE_HZ = 24_000
    }
}
