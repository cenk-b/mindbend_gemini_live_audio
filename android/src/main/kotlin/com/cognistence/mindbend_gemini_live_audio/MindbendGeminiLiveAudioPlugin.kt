package com.cognistence.mindbend_gemini_live_audio

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioFocusRequest
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.Build
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
    private var audioFocusRequest: AudioFocusRequest? = null

    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private var acousticEchoCanceler: AcousticEchoCanceler? = null
    private var noiseSuppressor: NoiseSuppressor? = null
    private var automaticGainControl: AutomaticGainControl? = null

    private var captureThread: Thread? = null
    private var playbackStarted = false
    private var captureFirstChunkDelivered = false

    private var disableNoiseSuppressor = false
    private var disableAutomaticGainControl = false
    private var noisyReceiverRegistered = false

    private val audioFocusChangeListener =
        AudioManager.OnAudioFocusChangeListener { focusChange ->
            val name =
                when (focusChange) {
                    AudioManager.AUDIOFOCUS_GAIN -> "gain"
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT -> "gain_transient"
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE -> "gain_transient_exclusive"
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK -> "gain_transient_may_duck"
                    AudioManager.AUDIOFOCUS_LOSS -> "loss"
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> "loss_transient"
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> "loss_transient_can_duck"
                    else -> "unknown_$focusChange"
                }
            emitEvent(
                "audio_focus_change",
                mapOf("focusChange" to name),
            )
            if (
                focusChange == AudioManager.AUDIOFOCUS_LOSS ||
                    focusChange == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT ||
                    focusChange == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK
            ) {
                emitEvent("interruption_began")
            } else if (
                focusChange == AudioManager.AUDIOFOCUS_GAIN ||
                    focusChange == AudioManager.AUDIOFOCUS_GAIN_TRANSIENT ||
                    focusChange == AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE ||
                    focusChange == AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
            ) {
                emitEvent("interruption_ended")
            }
        }

    private val becomingNoisyReceiver =
        object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (AudioManager.ACTION_AUDIO_BECOMING_NOISY == intent?.action) {
                    emitEvent("route_changed", mapOf("reason" to "becoming_noisy", "route" to currentRouteDescription()))
                }
            }
        }

    private val audioDeviceCallback: AudioDeviceCallback? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            object : AudioDeviceCallback() {
                override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
                    emitEvent(
                        "route_changed",
                        mapOf("reason" to "devices_added", "route" to currentRouteDescription()),
                    )
                }

                override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                    emitEvent(
                        "route_changed",
                        mapOf("reason" to "devices_removed", "route" to currentRouteDescription()),
                    )
                }
            }
        } else {
            null
        }

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
                    emitEvent("capture_sink_attached")
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
                    emitEvent("event_sink_attached")
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
            requestAudioFocus()
            registerRouteObservers()

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
            captureFirstChunkDelivered = false
            isSessionRunning.set(true)
            playbackGeneration.incrementAndGet()

            track.play()
            record.startRecording()
            startCaptureLoop(captureBufferSize)
            emitEvent(
                "session_ready",
                mapOf(
                    "captureSampleRateHz" to CAPTURE_SAMPLE_RATE_HZ,
                    "playbackSampleRateHz" to PLAYBACK_SAMPLE_RATE_HZ,
                    "route" to currentRouteDescription(),
                ),
            )
            emitEvent(
                "capture_ready",
                mapOf(
                    "captureSampleRateHz" to CAPTURE_SAMPLE_RATE_HZ,
                    "route" to currentRouteDescription(),
                ),
            )
            emitEvent(
                "playback_ready",
                mapOf(
                    "playbackSampleRateHz" to PLAYBACK_SAMPLE_RATE_HZ,
                    "route" to currentRouteDescription(),
                ),
            )

            return startResult(
                aecActive = true,
                nsActive = ns?.enabled == true,
                agcActive = agc?.enabled == true,
                transportMode = "native_aec",
                errorCode = null,
            )
        } catch (t: Throwable) {
            emitEvent("error", mapOf("code" to "android_start_failed"))
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
                    emitEvent("error", mapOf("code" to "android_capture_read_$read"))
                    break
                }
            }
        }.apply {
            name = "MindbendGeminiLiveAudioCapture"
            start()
        }
    }

    private fun requestAudioFocus() {
        val manager = audioManager ?: return
        val attributes =
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest =
                AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                    .setOnAudioFocusChangeListener(audioFocusChangeListener)
                    .setAudioAttributes(attributes)
                    .setAcceptsDelayedFocusGain(false)
                    .build()
            val result = manager.requestAudioFocus(audioFocusRequest!!)
            emitEvent(
                "audio_focus_request",
                mapOf("granted" to (result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED)),
            )
        } else {
            @Suppress("DEPRECATION")
            val result =
                manager.requestAudioFocus(
                    audioFocusChangeListener,
                    AudioManager.STREAM_VOICE_CALL,
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT,
                )
            emitEvent(
                "audio_focus_request",
                mapOf("granted" to (result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED)),
            )
        }
    }

    private fun abandonAudioFocus() {
        val manager = audioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let { manager.abandonAudioFocusRequest(it) }
            audioFocusRequest = null
        } else {
            @Suppress("DEPRECATION")
            manager.abandonAudioFocus(audioFocusChangeListener)
        }
    }

    private fun registerRouteObservers() {
        if (!noisyReceiverRegistered) {
            applicationContext.registerReceiver(
                becomingNoisyReceiver,
                IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
            )
            noisyReceiverRegistered = true
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            audioDeviceCallback?.let { callback ->
                audioManager?.registerAudioDeviceCallback(callback, mainHandler)
            }
        }
        emitEvent("route_applied", mapOf("route" to currentRouteDescription()))
    }

    private fun unregisterRouteObservers() {
        if (noisyReceiverRegistered) {
            try {
                applicationContext.unregisterReceiver(becomingNoisyReceiver)
            } catch (_: Throwable) {
            }
            noisyReceiverRegistered = false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            audioDeviceCallback?.let { callback ->
                audioManager?.unregisterAudioDeviceCallback(callback)
            }
        }
    }

    private fun currentRouteDescription(): String {
        val manager = audioManager
        if (manager == null) return "unknown"
        val parts = mutableListOf<String>()
        parts += "speaker=${manager.isSpeakerphoneOn}"
        parts += "mode=${manager.mode}"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val outputs =
                manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).joinToString(",") { device ->
                    "${device.type}:${device.productName ?: "unknown"}"
                }
            val inputs =
                manager.getDevices(AudioManager.GET_DEVICES_INPUTS).joinToString(",") { device ->
                    "${device.type}:${device.productName ?: "unknown"}"
                }
            parts += "inputs=[$inputs]"
            parts += "outputs=[$outputs]"
        }
        return parts.joinToString(" ")
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
                emitEvent(
                    "playback_started",
                    mapOf("bytes" to bytes.size, "route" to currentRouteDescription()),
                )
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
                    emitEvent("error", mapOf("code" to "android_playback_write_$written"))
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
                emitEvent("interrupted", mapOf("route" to currentRouteDescription()))
                emitEvent("playback_stopped", mapOf("route" to currentRouteDescription()))
            } catch (t: Throwable) {
                emitEvent("error", mapOf("code" to "android_flush_failed"))
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
        captureFirstChunkDelivered = false

        if (restoreAudioState) {
            restoreAudioManagerState()
        }
    }

    private fun restoreAudioManagerState() {
        try {
            unregisterRouteObservers()
            abandonAudioFocus()
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
            if (!captureFirstChunkDelivered) {
                captureFirstChunkDelivered = true
                emitEvent(
                    "capture_first_chunk",
                    mapOf("bytes" to bytes.size, "route" to currentRouteDescription()),
                )
            }
            sink.success(bytes)
        }
    }

    private fun emitEvent(type: String, details: Map<String, Any?> = emptyMap()) {
        val sink = eventSink ?: return
        mainHandler.post {
            val payload = hashMapOf<String, Any?>(
                "type" to type,
                "platform" to "android",
                "atMs" to System.currentTimeMillis(),
            )
            payload.putAll(details)
            sink.success(payload)
        }
    }

    private companion object {
        const val CAPTURE_SAMPLE_RATE_HZ = 16_000
        const val PLAYBACK_SAMPLE_RATE_HZ = 24_000
    }
}
