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
import android.media.AudioTimestamp
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
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

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
    private val sessionControlGeneration = AtomicLong(0)
    private val sessionExecutor = Executors.newSingleThreadExecutor()
    private val farewellDrain = FarewellDrainGate()
    @Volatile private var playbackLifetime: RetiringPlaybackLifetime? = null
    /** One barrier per AudioTrack lifetime. Every write and flush of that track goes through it. */
    @Volatile private var farewellBarrier: FarewellPlaybackBarrier? = null
    private val farewellPoller: ScheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "mb-farewell-poll").apply { isDaemon = true } }
    private val farewellPollTask = AtomicReference<ScheduledFuture<*>?>(null)

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
                farewellBarrier?.invalidate("audio_focus_loss")
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
                    farewellBarrier?.invalidate("route_changed")
                    emitEvent("route_changed", mapOf("reason" to "becoming_noisy", "route" to currentRouteDescription()))
                }
            }
        }

    private val audioDeviceCallback: AudioDeviceCallback? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            object : AudioDeviceCallback() {
                override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
                    farewellBarrier?.invalidate("route_changed")
                    emitEvent(
                        "route_changed",
                        mapOf("reason" to "devices_added", "route" to currentRouteDescription()),
                    )
                }

                override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                    farewellBarrier?.invalidate("route_changed")
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
            "startSession" -> {
                val requestGeneration = sessionControlGeneration.get()
                sessionExecutor.execute {
                    val payload = startSession(requestGeneration)
                    mainHandler.post { result.success(payload) }
                }
            }
            "stopSession" -> {
                sessionControlGeneration.incrementAndGet()
                playbackLifetime?.cancel()
                sessionExecutor.execute {
                    stopSessionInternal(restoreAudioState = true)
                    mainHandler.post { result.success(null) }
                }
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
            "beginFarewellDrain" -> {
                val frames = (call.argument<Number>("expectedFrames"))?.toInt() ?: 0
                result.success(farewellDrain.begin(frames))
            }
            "cancelFarewellDrain" -> {
                sessionControlGeneration.incrementAndGet()
                val status = farewellDrain.cancel()
                playbackGeneration.incrementAndGet()
                val lifetime = playbackLifetime
                val pending = lifetime?.cancel()
                if (pending == null) result.success(status + mapOf("teardown" to "no_player"))
                else pending.thenAccept { state -> mainHandler.post {
                    result.success(status + mapOf("teardown" to state))
                } }
            }
            "noteFarewellAnchor" -> {
                val seq = call.argument<Number>("seq")?.toInt() ?: -1
                val framesPlayed = call.argument<Number>("framesPlayed")?.toInt() ?: 0
                val generation = call.argument<Number>("generation")?.toLong() ?: -1L
                val nativeDrained = false // caller-supplied booleans are never native evidence
                result.success(
                    farewellDrain.noteAnchor(seq, framesPlayed, generation, nativeDrained),
                )
            }
            "farewellDrainStatus" -> result.success(farewellDrain.status())
            "farewellCapabilities" -> result.success(
                mapOf(
                    "api" to FAREWELL_API_VERSION,
                    "attributedDrain" to true,
                    "platform" to "android",
                    "evidence" to "android_timestamp",
                ),
            )
            "farewellBegin" -> {
                val turnId = call.argument<String>("turnId")
                val nativeGeneration = call.argument<Number>("nativeGeneration")?.toInt()
                val barrier = farewellBarrier
                val lifetime = playbackLifetime
                if (turnId.isNullOrEmpty() || nativeGeneration == null || barrier == null ||
                    lifetime == null || lifetime.isRetired() || !isSessionRunning.get()
                ) {
                    result.success(mapOf("accepted" to false, "reason" to "no_playback"))
                    return
                }
                // On the data lane: behind every earlier write, and never concurrent with one, so the resync
                // flush (the barrier's documented adapter obligation after track_unsynced) can clear it.
                lifetime.submit {
                    if (barrier.needsResync()) barrier.flushTrack("resync")
                    barrier.begin(turnId, nativeGeneration)
                }
                startFarewellPolling(barrier, lifetime)
                result.success(mapOf("accepted" to true))
            }
            "farewellPush" -> {
                val turnId = call.argument<String>("turnId")
                val seq = call.argument<Number>("seq")?.toInt()
                val pcm = call.argument<ByteArray>("pcm")
                val barrier = farewellBarrier
                val lifetime = playbackLifetime
                if (turnId.isNullOrEmpty() || seq == null || pcm == null || barrier == null ||
                    lifetime == null || lifetime.isRetired()
                ) {
                    result.success(false)
                    return
                }
                // Same data lane as legacy audio, so frame accounting follows the track's write order.
                // A rejected write fails the turn inside the barrier and arrives as farewell_unverified.
                lifetime.submit { barrier.push(turnId, seq, pcm) }
                result.success(true)
            }
            "farewellEnd" -> {
                val turnId = call.argument<String>("turnId")
                val totalChunks = call.argument<Number>("totalChunks")?.toInt()
                val totalFrames = call.argument<Number>("totalFrames")?.toLong()
                val barrier = farewellBarrier
                val lifetime = playbackLifetime
                if (turnId.isNullOrEmpty() || totalChunks == null || totalFrames == null ||
                    barrier == null || lifetime == null || lifetime.isRetired()
                ) {
                    result.success(false)
                    return
                }
                // Queued behind every push of this turn on the data lane.
                lifetime.submit { barrier.end(turnId, totalChunks, totalFrames) }
                result.success(true)
            }
            "farewellCancel" -> {
                val turnId = call.argument<String>("turnId")
                val reason = call.argument<String>("reason") ?: "cancelled"
                if (!turnId.isNullOrEmpty()) farewellBarrier?.cancel(turnId, reason)
                result.success(true)
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
        farewellPoller.shutdownNow()
        sessionExecutor.shutdown()
    }

    @Synchronized
    private fun startSession(requestGeneration: Long): Map<String, Any?> {
        if (requestGeneration != sessionControlGeneration.get()) return fallbackResult("session_start_cancelled")
        if (isSessionRunning.get() && playbackLifetime?.isRetired() == true) {
            stopSessionInternal(restoreAudioState = false)
        }
        if (isSessionRunning.get()) {
            return startResult(
                aecActive = true,
                nsActive = noiseSuppressor?.enabled == true,
                agcActive = automaticGainControl?.enabled == true,
                transportMode = "native_aec",
                errorCode = null,
            )
        }

        farewellDrain.resetForNewSession()
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
            var barrierOfLifetime: FarewellPlaybackBarrier? = null
            playbackLifetime = RetiringPlaybackLifetime(
                stop = {
                    // A retired track can never prove a drain.
                    barrierOfLifetime?.invalidate("playback_retired")
                    // Each action is attempted even if another fails.
                    var failure: Throwable? = null
                    try { track.pause() } catch (t: Throwable) { failure = t }
                    try { track.flush() } catch (t: Throwable) { failure = t }
                    try { track.stop() } catch (t: Throwable) { failure = t }
                    failure?.let { throw it }
                },
                release = { track.release() },
            )
            // Created on the fresh track, before any write: the barrier's frame cursor and the track agree.
            barrierOfLifetime = FarewellPlaybackBarrier(
                track = LifetimeAudioTrackPort(track, playbackLifetime!!),
                nowMs = System::currentTimeMillis,
                emit = ::emitFarewellEvent,
            )
            farewellBarrier = barrierOfLifetime
            acousticEchoCanceler = echoCanceler
            noiseSuppressor = ns
            automaticGainControl = agc
            playbackStarted = false
            captureFirstChunkDelivered = false
            isSessionRunning.set(true)
            playbackGeneration.incrementAndGet()

            val lifetime = playbackLifetime!!
            if (requestGeneration != sessionControlGeneration.get()) {
                lifetime.cancel()
                stopSessionInternal(restoreAudioState = true)
                return fallbackResult("session_start_cancelled")
            }
            if (lifetime.boundary { track.play() } == null) {
                stopSessionInternal(restoreAudioState = true)
                return fallbackResult("session_start_cancelled")
            }
            if (requestGeneration != sessionControlGeneration.get()) {
                lifetime.cancel()
                stopSessionInternal(restoreAudioState = true)
                return fallbackResult("session_start_cancelled")
            }
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
        val lifetime = playbackLifetime ?: return
        val barrier = farewellBarrier ?: return
        lifetime.submit {
            if (!isSessionRunning.get() || generationAtEnqueue != playbackGeneration.get()) {
                return@submit
            }
            if (!playbackStarted) {
                playbackStarted = true
                emitEvent(
                    "playback_started",
                    mapOf("bytes" to bytes.size, "route" to currentRouteDescription()),
                )
            }
            // Ordinary audio keeps its path but is written through the barrier's write gate, so the
            // barrier's frame cursor covers every byte this track holds.
            if (!barrier.pushLegacy(bytes)) {
                if (generationAtEnqueue != playbackGeneration.get() || lifetime.isRetired()) {
                    return@submit
                }
                emitEvent("error", mapOf("code" to "android_playback_write_failed"))
            }
        }
    }

    private fun flushPlaybackInternal() {
        farewellDrain.noteFlush()
        if (!isSessionRunning.get()) return
        val nextGeneration = playbackGeneration.incrementAndGet()
        val lifetime = playbackLifetime ?: return
        val barrier = farewellBarrier ?: return
        lifetime.submit {
            if (!isSessionRunning.get() || nextGeneration != playbackGeneration.get()) {
                return@submit
            }
            try {
                // The barrier orders the discard (pause, verify not playing, flush, resume) and
                // re-anchors its cursor on the emptied track. Never stop(): it does not discard.
                barrier.flushTrack("barge_in")
                if (lifetime.isRetired()) return@submit
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
        // A command acknowledgement is not a native drain.
        farewellDrain.acknowledgeCommand(farewellDrain.generation)
    }

    @Synchronized
    private fun stopSessionInternal(restoreAudioState: Boolean) {
        farewellDrain.cancel()
        farewellBarrier?.invalidate("session_stopped")
        farewellBarrier = null
        farewellPollTask.getAndSet(null)?.cancel(false)
        playbackLifetime?.cancel()
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

        playbackLifetime?.cancel()
        playbackLifetime = null
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

    /** Polls the barrier every 10 ms from BEGIN until the turn drains or fails (the barrier needs to
     *  watch the crossing). A retired lifetime fails the turn instead of reading a released track. */
    private fun startFarewellPolling(barrier: FarewellPlaybackBarrier, lifetime: RetiringPlaybackLifetime) {
        val holder = AtomicReference<ScheduledFuture<*>?>(null)
        val task = farewellPoller.scheduleAtFixedRate({
            try {
                if (lifetime.isRetired()) barrier.invalidate("playback_retired") else barrier.poll()
            } catch (_: Throwable) {
                barrier.invalidate("poll_failed")
            }
            if (!barrier.hasLiveTurn()) holder.get()?.cancel(false)
        }, FAREWELL_POLL_MS, FAREWELL_POLL_MS, TimeUnit.MILLISECONDS)
        holder.set(task)
        farewellPollTask.getAndSet(task)?.cancel(false)
    }

    private fun emitFarewellEvent(event: FarewellBarrierEvent) {
        when (event) {
            is FarewellBarrierEvent.Drained -> emitEvent(
                "farewell_drained",
                mapOf(
                    "turnId" to event.turnId,
                    "nativeGeneration" to event.nativeGeneration,
                    "drainedAtEpochMs" to event.drainedAtEpochMs,
                    "framesPlayed" to event.framesPlayed,
                    "lastSeq" to event.lastSeq,
                    "evidence" to event.evidence,
                ),
            )
            is FarewellBarrierEvent.Unverified -> emitEvent(
                "farewell_unverified",
                mapOf(
                    "turnId" to event.turnId,
                    "nativeGeneration" to event.nativeGeneration,
                    "reason" to event.reason,
                ),
            )
        }
    }

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
        /** Attributed farewell playback API. 2 = farewellBegin/Push/End/Cancel + typed drain events. */
        const val FAREWELL_API_VERSION = 2
        const val FAREWELL_POLL_MS = 10L
    }
}

/**
 * Real AudioTrack seam for [FarewellPlaybackBarrier]. Every call goes through the playback lifetime,
 * so a retired track is never touched again: a retired or throwing write reads as a write error and
 * a retired track reads as idle (no timestamp, not playing), which fails an open farewell closed.
 */
internal class LifetimeAudioTrackPort(
    private val track: AudioTrack,
    private val lifetime: RetiringPlaybackLifetime,
) : FarewellTrackPort {
    private val timestamp = AudioTimestamp()
    override val sampleRate: Int = track.sampleRate

    override fun write(pcm: ByteArray, offset: Int, size: Int): Int =
        try {
            lifetime.boundary { track.write(pcm, offset, size, AudioTrack.WRITE_BLOCKING) } ?: WRITE_RETIRED
        } catch (_: Throwable) {
            WRITE_THREW
        }

    override fun playbackHeadPosition(): Int =
        if (lifetime.isRetired()) 0 else try { track.playbackHeadPosition } catch (_: Throwable) { 0 }

    override fun timestamp(): FarewellTrackTimestamp? {
        if (lifetime.isRetired()) return null
        return try {
            synchronized(timestamp) {
                if (track.getTimestamp(timestamp)) FarewellTrackTimestamp(timestamp.framePosition, timestamp.nanoTime) else null
            }
        } catch (_: Throwable) {
            null
        }
    }

    override fun isPlaying(): Boolean =
        !lifetime.isRetired() && try { track.playState == AudioTrack.PLAYSTATE_PLAYING } catch (_: Throwable) { false }

    override fun routedDeviceId(): Int = try { track.routedDevice?.id ?: -1 } catch (_: Throwable) { -1 }

    override fun pause() { lifetime.boundary { track.pause() } }

    override fun flush() { lifetime.boundary { track.flush() } }

    override fun stop() { lifetime.boundary { track.stop() } }

    override fun play() { lifetime.boundary { track.play() } }

    private companion object {
        const val WRITE_RETIRED = -100_001
        const val WRITE_THREW = -100_002
    }
}

/**
 * Ack is not a drain. A flush or a stale generation cannot become native_drain.
 * The near-end window is 32 frames: a native report further out is not playback proof.
 * No Android dependencies, so the JVM unit test can execute it.
 */
class FarewellDrainGate {
    var generation: Long = 0
        private set
    var state: String = "idle"
        private set
    var evidence: String = "none"
        private set
    var framesPlayed: Int = 0
        private set
    var lastSeq: Int = -1
        private set
    var restartBlocked: Boolean = false
        private set
    private var expectedFrames: Int = 0

    @Synchronized
    fun begin(expectedFrames: Int): Map<String, Any?> {
        if (restartBlocked) return status()
        generation += 1
        state = "armed"
        evidence = "none"
        framesPlayed = 0
        lastSeq = -1
        restartBlocked = false
        this.expectedFrames = expectedFrames.coerceAtLeast(0)
        return status()
    }

    @Synchronized
    fun noteAnchor(seq: Int, played: Int, generationAtAnchor: Long, nativeDrained: Boolean): Map<String, Any?> {
        if (generationAtAnchor != generation || state != "armed") return status()
        framesPlayed = played.coerceAtLeast(0)
        lastSeq = seq
        if (!nativeDrained) {
            evidence = "none"
            return status()
        }
        val remaining = expectedFrames - framesPlayed
        val insideNearEnd = expectedFrames > 0 && framesPlayed > 0 && remaining <= NEAR_END_FRAMES
        if (!insideNearEnd) {
            evidence = "none"
            return status()
        }
        state = "drained"
        evidence = "native_drain"
        return status()
    }

    @Synchronized
    fun acknowledgeCommand(generationAtAck: Long): Map<String, Any?> {
        if (generationAtAck != generation || state != "armed") return status()
        evidence = "command_ack"
        return status()
    }

    @Synchronized
    fun noteFlush(): Map<String, Any?> {
        if (state == "armed" || state == "drained") state = "flushed"
        evidence = "none"
        generation += 1
        return status()
    }

    @Synchronized
    fun cancel(): Map<String, Any?> {
        generation += 1
        state = "cancelled"
        evidence = "none"
        restartBlocked = true
        return status()
    }

    @Synchronized
    fun resetForNewSession(): Map<String, Any?> {
        generation += 1
        state = "idle"
        evidence = "none"
        framesPlayed = 0
        lastSeq = -1
        expectedFrames = 0
        restartBlocked = false
        return status()
    }

    @Synchronized
    fun status(): Map<String, Any?> = mapOf(
        "generation" to generation,
        "state" to state,
        "evidence" to evidence,
        "framesPlayed" to framesPlayed,
        "lastSeq" to lastSeq,
        "restartBlocked" to restartBlocked,
    )

    companion object {
        const val NEAR_END_FRAMES = 32
    }
}
