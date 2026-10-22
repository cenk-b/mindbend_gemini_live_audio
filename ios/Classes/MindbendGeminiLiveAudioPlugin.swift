import AVFAudio
import Flutter
import UIKit

private final class ClosureStreamHandler: NSObject, FlutterStreamHandler {
  private let onListenBlock: (FlutterEventSink?) -> Void
  private let onCancelBlock: () -> Void

  init(onListen: @escaping (FlutterEventSink?) -> Void, onCancel: @escaping () -> Void) {
    self.onListenBlock = onListen
    self.onCancelBlock = onCancel
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    onListenBlock(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    onCancelBlock()
    return nil
  }
}

struct FarewellDrainGate {
  static let nearEndFrames = 32
  private(set) var generation = 0
  private(set) var state = "idle"
  private(set) var evidence = "none"
  private(set) var framesPlayed = 0
  private(set) var lastSeq = -1
  private(set) var restartBlocked = false
  private var expectedFrames = 0

  mutating func begin(expectedFrames: Int) -> [String: Any] {
    if restartBlocked { return status() }
    generation += 1
    state = "armed"
    evidence = "none"
    framesPlayed = 0
    lastSeq = -1
    restartBlocked = false
    self.expectedFrames = max(0, expectedFrames)
    return status()
  }

  mutating func noteAnchor(seq: Int, played: Int, generationAtAnchor: Int, nativeDrained: Bool) -> [String: Any] {
    if generationAtAnchor != generation || state != "armed" { return status() }
    framesPlayed = max(0, played)
    lastSeq = seq
    if !nativeDrained {
      evidence = "none"
      return status()
    }
    let remaining = expectedFrames - framesPlayed
    let insideNearEnd = expectedFrames > 0 && framesPlayed > 0 && remaining <= FarewellDrainGate.nearEndFrames
    if !insideNearEnd {
      evidence = "none"
      return status()
    }
    state = "drained"
    evidence = "native_drain"
    return status()
  }

  mutating func acknowledgeCommand(generationAtAck: Int) -> [String: Any] {
    if generationAtAck != generation || state != "armed" { return status() }
    evidence = "command_ack"
    return status()
  }

  mutating func noteFlush() -> [String: Any] {
    if state == "armed" || state == "drained" { state = "flushed" }
    evidence = "none"
    generation += 1
    return status()
  }

  mutating func cancel() -> [String: Any] {
    generation += 1
    state = "cancelled"
    evidence = "none"
    restartBlocked = true
    return status()
  }

  mutating func resetForNewSession() -> [String: Any] {
    generation += 1
    state = "idle"
    evidence = "none"
    framesPlayed = 0
    lastSeq = -1
    expectedFrames = 0
    restartBlocked = false
    return status()
  }

  func status() -> [String: Any] {
    [
      "generation": generation,
      "state": state,
      "evidence": evidence,
      "framesPlayed": framesPlayed,
      "lastSeq": lastSeq,
      "restartBlocked": restartBlocked,
    ]
  }
}

public final class MindbendGeminiLiveAudioPlugin: NSObject, FlutterPlugin {
  private let sessionQueue = DispatchQueue(label: "com.cognistence.mindbend_gemini_live_audio.session")
  private var farewellDrain = FarewellDrainGate()
  private let lifetimeLock = NSLock()
  private var controlGeneration = 0
  private func captureControlGeneration() -> Int {
    lifetimeLock.lock(); defer { lifetimeLock.unlock() }; return controlGeneration
  }
  private func invalidatePendingStart() {
    lifetimeLock.lock(); controlGeneration += 1; lifetimeLock.unlock()
  }
  private var _playbackLifetime: RetiringPlaybackLifetime?
  private var playbackLifetime: RetiringPlaybackLifetime? {
    get { lifetimeLock.lock(); defer { lifetimeLock.unlock() }; return _playbackLifetime }
    set { lifetimeLock.lock(); _playbackLifetime = newValue; lifetimeLock.unlock() }
  }
  /// One barrier per playback lifetime. Read from the platform thread by the cancel path.
  private var _farewellBarrier: FarewellPlaybackBarrier?
  private var farewellBarrier: FarewellPlaybackBarrier? {
    get { lifetimeLock.lock(); defer { lifetimeLock.unlock() }; return _farewellBarrier }
    set { lifetimeLock.lock(); _farewellBarrier = newValue; lifetimeLock.unlock() }
  }
  private var engineConfigurationObserver: NSObjectProtocol?
  /// Attributed farewell playback API. 2 = farewellBegin/Push/End/Cancel + typed drain events.
  private static let farewellApiVersion = 2
  private let audioSession = AVAudioSession.sharedInstance()

  private var captureStreamHandler: ClosureStreamHandler?
  private var eventStreamHandler: ClosureStreamHandler?
  private var captureEventSink: FlutterEventSink?
  private var eventSink: FlutterEventSink?
  // Payloads are stamped when queued and delivered only to the subscription they were queued for.
  private let captureDelivery = DeliveryEpochGate()
  private let eventDelivery = DeliveryEpochGate()
  /// Detached from its engine. Checked where queued work executes, not only where calls enter:
  /// work accepted before detach must never touch the shared AVAudioSession afterwards.
  private var retiredFromEngine: Bool { eventDelivery.isDetached }

  /// Every shared-session mutation goes through here, so retirement is rechecked before each one:
  /// a call stalled across a detach cannot be followed by another mutation. (The one native call
  /// already in flight when detach lands can still complete; detach never waits on sessionQueue.)
  private func mutateSharedSession(_ body: () throws -> Void) throws {
    if retiredFromEngine {
      throw NSError(domain: "mindbend_gemini_live_audio", code: -33,
        userInfo: [NSLocalizedDescriptionKey: "Plugin was detached from its engine."])
    }
    try body()
  }

  private var engine: AVAudioEngine?
  private var playerNode: AVAudioPlayerNode?
  private var captureConverter: AVAudioConverter?
  private var captureTargetFormat: AVAudioFormat?
  private var playbackFormat: AVAudioFormat?

  private var previousCategory: AVAudioSession.Category?
  private var previousMode: AVAudioSession.Mode?
  private var previousOptions: AVAudioSession.CategoryOptions = []

  private var isSessionRunning = false
  private var playbackDidStart = false
  private var captureChunkCount = 0
  private var playbackChunkCount = 0
  private var playbackBytesScheduled = 0
  private var playbackCompletionCount = 0
  private var pendingPlaybackBufferCount = 0
  private var mixerBufferCount = 0
  private var mixerFirstBufferLogged = false
  private var lastMixerNonZeroRatio: Double?
  private var lastMixerRmsNormalized: Double?
  private var lastMixerPeakNormalized: Double?
  private var lastMixerBufferAtMs: Int?
  private var playbackStartupConfirmed = false
  private var playbackStartupRecoveryAttempted = false
  private var startupPlaybackReplayBuffers: [Data] = []
  private var startupPlaybackReplayBytes = 0
  private var isReplayingStartupBuffers = false
  private var captureSinkMissingLogged = false
  private var captureFirstBufferLogged = false
  private var captureFirstChunkDelivered = false
  private var observersRegistered = false
  private var captureStallProbeWorkItems: [DispatchWorkItem] = []
  private var playbackProbeWorkItems: [DispatchWorkItem] = []
  private var sessionStartedAtMs: Int?
  private let startupPlaybackReplayMaxBytes = 240_000

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = MindbendGeminiLiveAudioPlugin()
    // Publishing is what makes the engine call detachFromEngine(for:) on this instance.
    registrar.publish(instance)

    let methodChannel = FlutterMethodChannel(
      name: "mindbend_gemini_live_audio/methods",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: methodChannel)

    let captureChannel = FlutterEventChannel(
      name: "mindbend_gemini_live_audio/captured_audio",
      binaryMessenger: registrar.messenger()
    )
    let eventChannel = FlutterEventChannel(
      name: "mindbend_gemini_live_audio/events",
      binaryMessenger: registrar.messenger()
    )

    let captureHandler = ClosureStreamHandler(
      onListen: { [weak instance] sink in
        guard let instance, instance.captureDelivery.listen() else { return }
        instance.captureEventSink = sink
        instance.captureSinkMissingLogged = false
        instance.emitEvent("capture_sink_attached")
      },
      onCancel: { [weak instance] in
        instance?.captureDelivery.cancel()
        instance?.captureEventSink = nil
      }
    )
    let eventHandler = ClosureStreamHandler(
      onListen: { [weak instance] sink in
        guard let instance, instance.eventDelivery.listen() else { return }
        instance.eventSink = sink
        instance.emitEvent("event_sink_attached")
      },
      onCancel: { [weak instance] in
        instance?.eventDelivery.cancel()
        instance?.eventSink = nil
      }
    )

    instance.captureStreamHandler = captureHandler
    instance.eventStreamHandler = eventHandler
    captureChannel.setStreamHandler(captureHandler)
    eventChannel.setStreamHandler(eventHandler)
  }

  /// The engine is going away. Retire this instance: refuse new calls and listeners, drop every
  /// queued delivery, invalidate any start in progress and stop its own engine. The shared
  /// AVAudioSession is left alone, since a replacement instance may already own it.
  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    captureDelivery.detach()
    eventDelivery.detach()
    captureEventSink = nil
    eventSink = nil
    invalidatePendingStart()
    farewellBarrier?.invalidateAsync(reason: "engine_detached")
    playbackLifetime?.cancel()
    // Strong capture on purpose: teardown must run even though the engine dropped this instance.
    sessionQueue.async {
      self.stopSessionLocked(restoreAudioSession: false)
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if eventDelivery.isDetached {
      result(FlutterError(code: "plugin_detached", message: "Plugin was detached from its engine.", details: nil))
      return
    }
    switch call.method {
    case "startSession":
      let requestGeneration = captureControlGeneration()
      sessionQueue.async { [weak self] in
        guard let self else { return }
        let payload = self.startSessionLocked(requestGeneration: requestGeneration)
        DispatchQueue.main.async {
          result(payload)
        }
      }
    case "stopSession":
      invalidatePendingStart()
      farewellBarrier?.invalidateAsync(reason: "session_stopped")
      playbackLifetime?.cancel()
      sessionQueue.async { [weak self] in
        self?.stopSessionLocked(restoreAudioSession: true)
        DispatchQueue.main.async {
          result(nil)
        }
      }
    case "pushPlaybackPcm":
      guard let bytes = Self.decodeBytes(call.arguments) else {
        result(
          FlutterError(
            code: "invalid_playback_bytes",
            message: "pushPlaybackPcm expects Uint8List bytes.",
            details: nil
          )
        )
        return
      }
      sessionQueue.async { [weak self] in
        do {
          try self?.pushPlaybackLocked(bytes: bytes)
          DispatchQueue.main.async {
            result(nil)
          }
        } catch {
          DispatchQueue.main.async {
            result(
              FlutterError(
                code: "push_playback_failed",
                message: error.localizedDescription,
                details: nil
              )
            )
          }
        }
      }
    case "flushPlayback":
      sessionQueue.async { [weak self] in
        self?.flushPlaybackLocked()
        DispatchQueue.main.async {
          result(nil)
        }
      }
    case "markPlaybackComplete":
      sessionQueue.async { [weak self] in
        self?.markPlaybackCompleteLocked()
        DispatchQueue.main.async {
          result(nil)
        }
      }
    case "beginFarewellDrain":
      let frames = (call.arguments as? [String: Any])?["expectedFrames"] as? Int ?? 0
      sessionQueue.async { [weak self] in
        guard let self else { return }
        let payload = self.farewellDrain.begin(expectedFrames: frames)
        DispatchQueue.main.async { result(payload) }
      }
    case "cancelFarewellDrain":
      invalidatePendingStart()
      // The platform handler never waits on sessionQueue (which may be parked in schedule/play).
      farewellBarrier?.invalidateAsync(reason: "playback_cancelled")
      let lifetime = playbackLifetime
      lifetime?.cancel { state in
        DispatchQueue.main.async {
          result(["state": "cancelled", "evidence": "none", "restartBlocked": true,
                  "generation": -1, "teardown": state])
        }
      }
      if lifetime == nil {
        result(["state": "cancelled", "evidence": "none", "restartBlocked": true,
                "generation": -1, "teardown": "no_player"])
      }
      sessionQueue.async { [weak self] in _ = self?.farewellDrain.cancel() }
    case "noteFarewellAnchor":
      let args = call.arguments as? [String: Any]
      let seq = args?["seq"] as? Int ?? -1
      let played = args?["framesPlayed"] as? Int ?? 0
      let generation = args?["generation"] as? Int ?? -1
      let nativeDrained = false // channel input is not native drain evidence
      sessionQueue.async { [weak self] in
        guard let self else { return }
        let payload = self.farewellDrain.noteAnchor(
          seq: seq,
          played: played,
          generationAtAnchor: generation,
          nativeDrained: nativeDrained
        )
        DispatchQueue.main.async { result(payload) }
      }
    case "farewellDrainStatus":
      sessionQueue.async { [weak self] in
        guard let self else { return }
        let payload = self.farewellDrain.status()
        DispatchQueue.main.async { result(payload) }
      }
    case "farewellCapabilities":
      result([
        "api": Self.farewellApiVersion,
        "attributedDrain": true,
        "platform": "ios",
        "evidence": "ios_dataPlayedBack+position",
      ])
    case "farewellBegin":
      let args = call.arguments as? [String: Any]
      guard let turnId = args?["turnId"] as? String, !turnId.isEmpty,
            let nativeGeneration = args?["nativeGeneration"] as? Int else {
        result(["accepted": false, "reason": "invalid_arguments"])
        return
      }
      sessionQueue.async { [weak self] in
        guard let self, self.isSessionRunning, let barrier = self.farewellBarrier,
              let lifetime = self.playbackLifetime, !lifetime.isRetired else {
          DispatchQueue.main.async { result(["accepted": false, "reason": "no_playback"]) }
          return
        }
        barrier.begin(turnId: turnId, nativeGeneration: nativeGeneration)
        DispatchQueue.main.async { result(["accepted": true]) }
      }
    case "farewellPush":
      let args = call.arguments as? [String: Any]
      guard let turnId = args?["turnId"] as? String, !turnId.isEmpty,
            let seq = args?["seq"] as? Int,
            let pcm = Self.decodeBytes(args?["pcm"]) else {
        result(false)
        return
      }
      // Same serial queue as legacy audio, so the barrier sees farewell and legacy in scheduling order.
      sessionQueue.async { [weak self] in
        let accepted = self?.farewellBarrier?.push(turnId: turnId, seq: seq, pcm16: pcm) ?? false
        DispatchQueue.main.async { result(accepted) }
      }
    case "farewellEnd":
      let args = call.arguments as? [String: Any]
      guard let turnId = args?["turnId"] as? String, !turnId.isEmpty,
            let totalChunks = args?["totalChunks"] as? Int,
            let totalFrames = (args?["totalFrames"] as? NSNumber)?.int64Value else {
        result(false)
        return
      }
      sessionQueue.async { [weak self] in
        guard let barrier = self?.farewellBarrier else {
          DispatchQueue.main.async { result(false) }
          return
        }
        barrier.end(turnId: turnId, totalChunks: totalChunks, totalFrames: totalFrames)
        DispatchQueue.main.async { result(true) }
      }
    case "farewellCancel":
      let args = call.arguments as? [String: Any]
      if let turnId = args?["turnId"] as? String, !turnId.isEmpty {
        farewellBarrier?.cancel(turnId: turnId, reason: (args?["reason"] as? String) ?? "cancelled")
      }
      result(true)
    case "setDebugOptions":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func decodeBytes(_ arguments: Any?) -> Data? {
    if let typed = arguments as? FlutterStandardTypedData {
      return typed.data
    }
    if let data = arguments as? Data {
      return data
    }
    if let bytes = arguments as? [UInt8] {
      return Data(bytes)
    }
    return nil
  }

  private func startSessionLocked(requestGeneration: Int) -> [String: Any] {
    guard requestGeneration == captureControlGeneration() else {
      return startResult(aecActive: false, transportMode: "legacy_half_duplex", errorCode: "session_start_cancelled")
    }
    if isSessionRunning && playbackLifetime?.isRetired == true {
      stopSessionLocked(restoreAudioSession: false)
    }
    if isSessionRunning {
      return startResult(
        aecActive: true,
        transportMode: "native_aec",
        errorCode: nil
      )
    }

    do {
      _ = farewellDrain.resetForNewSession()
      previousCategory = audioSession.category
      previousMode = audioSession.mode
      previousOptions = audioSession.categoryOptions

      if requestGeneration != captureControlGeneration() || retiredFromEngine {
        throw NSError(domain: "mindbend_gemini_live_audio", code: -32,
          userInfo: [NSLocalizedDescriptionKey: "Session start cancelled before audio session setup."])
      }
      try mutateSharedSession {
        try audioSession.setCategory(
          .playAndRecord,
          mode: .voiceChat,
          options: [.allowBluetooth, .defaultToSpeaker]
        )
      }
      try mutateSharedSession { try audioSession.setPreferredIOBufferDuration(0.01) }
      try mutateSharedSession { try audioSession.setActive(true, options: []) }
      registerAudioSessionObserversLocked()

      let audioEngine = AVAudioEngine()
      let inputNode = audioEngine.inputNode
      try inputNode.setVoiceProcessingEnabled(true)

      let inputFormat = inputNode.outputFormat(forBus: 0)
      guard let targetCaptureFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
      ) else {
        throw NSError(
          domain: "mindbend_gemini_live_audio",
          code: -10,
          userInfo: [NSLocalizedDescriptionKey: "Unable to create capture format."]
        )
      }
      guard let outputPlaybackFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: true
      ) else {
        throw NSError(
          domain: "mindbend_gemini_live_audio",
          code: -11,
          userInfo: [NSLocalizedDescriptionKey: "Unable to create playback format."]
        )
      }
      guard let converter = AVAudioConverter(from: inputFormat, to: targetCaptureFormat) else {
        throw NSError(
          domain: "mindbend_gemini_live_audio",
          code: -12,
          userInfo: [NSLocalizedDescriptionKey: "Unable to create capture converter."]
        )
      }

      let player = AVAudioPlayerNode()
      audioEngine.attach(player)
      audioEngine.connect(player, to: audioEngine.mainMixerNode, format: outputPlaybackFormat)
      audioEngine.mainMixerNode.outputVolume = 1.0
      let mixerFormat = audioEngine.mainMixerNode.outputFormat(forBus: 0)
      audioEngine.mainMixerNode.installTap(
        onBus: 0,
        bufferSize: 1024,
        format: mixerFormat
      ) { [weak self] buffer, _ in
        self?.handleMixerBuffer(buffer)
      }

      // Request ~30ms input buffers at the hardware sample rate (typically 48kHz).
      // AVAudioEngine treats this as a hint and may deliver larger chunks.
      let requestedTapFrames = AVAudioFrameCount(
        max(1, Int((inputFormat.sampleRate * 0.03).rounded()))
      )
      inputNode.installTap(onBus: 0, bufferSize: requestedTapFrames, format: inputFormat) { [weak self] buffer, _ in
        self?.handleCapturedBuffer(buffer)
      }

      engine = audioEngine
      playerNode = player
      let barrierBox = FarewellBarrierBox()
      let lifetime = RetiringPlaybackLifetime(stop: {
        // A retired player can never prove a drain. Async: this runs on the independent control queue.
        barrierBox.barrier?.invalidateAsync(reason: "playback_retired")
        player.stop()
      })
      playbackLifetime = lifetime
      let barrier = FarewellPlaybackBarrier(
        player: PluginFarewellPlayer(engine: audioEngine, node: player, format: outputPlaybackFormat, lifetime: lifetime),
        emit: { [weak self] event in self?.emitFarewellEvent(event) }
      )
      barrierBox.barrier = barrier
      farewellBarrier = barrier
      engineConfigurationObserver = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: nil
      ) { [weak barrier] _ in
        barrier?.invalidateAsync(reason: "engine_configuration_change")
      }
      if requestGeneration != captureControlGeneration() {
        playbackLifetime?.cancel()
        throw NSError(domain: "mindbend_gemini_live_audio", code: -30,
          userInfo: [NSLocalizedDescriptionKey: "Session start cancelled."])
      }
      captureConverter = converter
      captureTargetFormat = targetCaptureFormat
      playbackFormat = outputPlaybackFormat
      sessionStartedAtMs = Int(Date().timeIntervalSince1970 * 1000)

      try ensureEngineRunningLocked(
        audioEngine,
        player: player,
        trigger: "session_start",
        failureCode: "ios_engine_not_running_after_start"
      )
      if requestGeneration != captureControlGeneration() {
        throw NSError(domain: "mindbend_gemini_live_audio", code: -31,
          userInfo: [NSLocalizedDescriptionKey: "Session start cancelled after engine start."])
      }

      isSessionRunning = true
      playbackDidStart = false
      captureChunkCount = 0
      playbackChunkCount = 0
      playbackBytesScheduled = 0
      playbackCompletionCount = 0
      pendingPlaybackBufferCount = 0
      mixerBufferCount = 0
      mixerFirstBufferLogged = false
      lastMixerNonZeroRatio = nil
      lastMixerRmsNormalized = nil
      lastMixerPeakNormalized = nil
      lastMixerBufferAtMs = nil
      playbackStartupConfirmed = false
      playbackStartupRecoveryAttempted = false
      clearStartupPlaybackReplayLocked()
      isReplayingStartupBuffers = false
      captureFirstBufferLogged = false
      captureFirstChunkDelivered = false
      captureSinkMissingLogged = false
      scheduleCaptureStallProbesLocked()
      emitCurrentRouteEventLocked(type: "route_applied", reason: "session_start")
      emitSessionSnapshotLocked(
        "session_ready",
        [
          "inputSampleRateHz": Int(inputFormat.sampleRate),
          "inputChannels": Int(inputFormat.channelCount),
          "tapFrames": Int(requestedTapFrames),
          "captureSampleRateHz": 16_000,
          "playbackSampleRateHz": 24_000,
          "route": currentRouteDescriptionLocked(),
        ]
      )
      emitSessionSnapshotLocked(
        "capture_ready",
        [
          "captureSampleRateHz": 16_000,
          "route": currentRouteDescriptionLocked(),
        ]
      )
      emitSessionSnapshotLocked(
        "playback_ready",
        [
          "playbackSampleRateHz": 24_000,
          "route": currentRouteDescriptionLocked(),
        ]
      )

      return startResult(
        aecActive: true,
        transportMode: "native_aec",
        errorCode: nil
      )
    } catch {
      let failureCode = nativeErrorCode(from: error) ?? "ios_start_failed"
      stopSessionLocked(restoreAudioSession: !eventDelivery.isDetached)
      emitEvent("error", ["code": failureCode])
      return startResult(
        aecActive: false,
        transportMode: "legacy_half_duplex",
        errorCode: failureCode
      )
    }
  }

  private func startResult(aecActive: Bool, transportMode: String, errorCode: String?) -> [String: Any] {
    return [
      "aecActive": aecActive,
      // iOS voice processing enables NS/AGC as part of the same pipeline.
      "nsActive": aecActive,
      "agcActive": aecActive,
      "transportMode": transportMode,
      "captureSampleRateHz": 16_000,
      "playbackSampleRateHz": 24_000,
      "errorCode": errorCode as Any
    ]
  }

  private func registerAudioSessionObserversLocked() {
    guard !observersRegistered else { return }
    let center = NotificationCenter.default
    center.addObserver(
      self,
      selector: #selector(handleAudioSessionInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: audioSession
    )
    center.addObserver(
      self,
      selector: #selector(handleAudioSessionRouteChange(_:)),
      name: AVAudioSession.routeChangeNotification,
      object: audioSession
    )
    center.addObserver(
      self,
      selector: #selector(handleMediaServicesWereLost(_:)),
      name: AVAudioSession.mediaServicesWereLostNotification,
      object: audioSession
    )
    center.addObserver(
      self,
      selector: #selector(handleMediaServicesWereReset(_:)),
      name: AVAudioSession.mediaServicesWereResetNotification,
      object: audioSession
    )
    observersRegistered = true
  }

  private func unregisterAudioSessionObserversLocked() {
    guard observersRegistered else { return }
    NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: audioSession)
    NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: audioSession)
    NotificationCenter.default.removeObserver(self, name: AVAudioSession.mediaServicesWereLostNotification, object: audioSession)
    NotificationCenter.default.removeObserver(self, name: AVAudioSession.mediaServicesWereResetNotification, object: audioSession)
    observersRegistered = false
  }

  private func currentRouteDescriptionLocked() -> String {
    let route = audioSession.currentRoute
    let inputs = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
    let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
    return "inputs=[\(inputs)] outputs=[\(outputs)]"
  }

  private func sessionSnapshotLocked() -> [String: Any?] {
    let availableInputs = (audioSession.availableInputs ?? []).map {
      "\($0.portType.rawValue):\($0.portName)"
    }
    let currentInput = audioSession.currentRoute.inputs.first.map {
      "\($0.portType.rawValue):\($0.portName)"
    }
    let inputNode = engine?.inputNode
    let inputNodeOutputFormat = inputNode?.outputFormat(forBus: 0)
    let inputNodeInputFormat = inputNode?.inputFormat(forBus: 0)
    let nowMs = Int(Date().timeIntervalSince1970 * 1000)

    return [
      "route": currentRouteDescriptionLocked(),
      "audioSessionCategory": audioSession.category.rawValue,
      "audioSessionMode": audioSession.mode.rawValue,
      "audioSessionSampleRateHz": Int(audioSession.sampleRate.rounded()),
      "audioSessionIoBufferMs": Int((audioSession.ioBufferDuration * 1000).rounded()),
      "audioSessionInputLatencyMs": Int((audioSession.inputLatency * 1000).rounded()),
      "audioSessionOutputLatencyMs": Int((audioSession.outputLatency * 1000).rounded()),
      "audioSessionOutputVolume": audioSession.outputVolume,
      "inputAvailable": audioSession.isInputAvailable,
      "preferredInput": audioSession.preferredInput.map {
        "\($0.portType.rawValue):\($0.portName)"
      },
      "currentInput": currentInput,
      "availableInputs": availableInputs,
      "engineRunning": engine?.isRunning ?? false,
      "playerPlaying": playerNode?.isPlaying ?? false,
      "playbackDidStart": playbackDidStart,
      "captureFirstBufferLogged": captureFirstBufferLogged,
      "captureFirstChunkDelivered": captureFirstChunkDelivered,
      "captureChunkCount": captureChunkCount,
      "playbackChunkCount": playbackChunkCount,
      "playbackBytesScheduled": playbackBytesScheduled,
      "playbackCompletionCount": playbackCompletionCount,
      "pendingPlaybackBufferCount": pendingPlaybackBufferCount,
      "mixerBufferCount": mixerBufferCount,
      "mixerFirstBufferLogged": mixerFirstBufferLogged,
      "lastMixerNonZeroRatio": lastMixerNonZeroRatio as Any,
      "lastMixerRmsNormalized": lastMixerRmsNormalized as Any,
      "lastMixerPeakNormalized": lastMixerPeakNormalized as Any,
      "lastMixerBufferAtMs": lastMixerBufferAtMs as Any,
      "sessionStartedAtMs": sessionStartedAtMs as Any,
      "snapshotAtMs": nowMs,
      "elapsedSinceStartMs": sessionStartedAtMs.map { max(0, nowMs - $0) } as Any,
      "inputNodeOutputSampleRateHz": inputNodeOutputFormat.map {
        Int($0.sampleRate.rounded())
      } as Any,
      "inputNodeOutputChannels": inputNodeOutputFormat.map {
        Int($0.channelCount)
      } as Any,
      "inputNodeInputSampleRateHz": inputNodeInputFormat.map {
        Int($0.sampleRate.rounded())
      } as Any,
      "inputNodeInputChannels": inputNodeInputFormat.map {
        Int($0.channelCount)
      } as Any,
    ]
  }

  private func emitSessionSnapshotLocked(
    _ type: String,
    _ details: [String: Any?] = [:]
  ) {
    var payload = sessionSnapshotLocked()
    for (key, value) in details {
      payload[key] = value
    }
    emitEvent(type, payload)
  }

  private func cancelCaptureStallProbesLocked() {
    for workItem in captureStallProbeWorkItems {
      workItem.cancel()
    }
    captureStallProbeWorkItems.removeAll()
  }

  private func cancelPlaybackProbesLocked() {
    for workItem in playbackProbeWorkItems {
      workItem.cancel()
    }
    playbackProbeWorkItems.removeAll()
  }

  private func scheduleCaptureStallProbesLocked() {
    cancelCaptureStallProbesLocked()
    let probes: [(TimeInterval, String)] = [
      (0.35, "350ms"),
      (1.0, "1000ms"),
      (2.2, "2200ms"),
    ]
    for (delay, label) in probes {
      let workItem = DispatchWorkItem { [weak self] in
        guard let self else { return }
        guard self.isSessionRunning, !self.captureFirstBufferLogged else { return }
        self.emitSessionSnapshotLocked(
          "capture_stall_probe",
          [
            "probeLabel": label,
          ]
        )
      }
      captureStallProbeWorkItems.append(workItem)
      sessionQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
  }

  private func playbackProgressDetailsLocked(probeLabel: String? = nil) -> [String: Any?] {
    let playerRenderTime = playerNode?.lastRenderTime
    let playerTime = playerRenderTime.flatMap { renderTime in
      playerNode?.playerTime(forNodeTime: renderTime)
    }
    let outputRenderTime = engine?.outputNode.lastRenderTime
    return [
      "probeLabel": probeLabel,
      "pendingPlaybackBufferCount": pendingPlaybackBufferCount,
      "playbackChunkCount": playbackChunkCount,
      "playbackCompletionCount": playbackCompletionCount,
      "playbackBytesScheduled": playbackBytesScheduled,
      "playerLastRenderHostTime": playerRenderTime?.hostTime as Any,
      "playerLastRenderSampleTime": playerRenderTime?.sampleTime as Any,
      "playerRenderSampleTime": playerTime?.sampleTime as Any,
      "playerRenderTimeSeconds": playerTime.map { Double($0.sampleTime) / $0.sampleRate } as Any,
      "playerRenderSampleRateHz": playerTime.map { Int($0.sampleRate.rounded()) } as Any,
      "outputNodeLastRenderHostTime": outputRenderTime?.hostTime as Any,
      "outputNodeLastRenderSampleTime": outputRenderTime?.sampleTime as Any,
      "mainMixerOutputVolume": engine?.mainMixerNode.outputVolume as Any,
      "playerVolume": playerNode?.volume as Any,
    ]
  }

  private func pcm16StatsLocked(_ data: Data, maxSamples: Int = 4096) -> [String: Any?] {
    let availableSamples = data.count / MemoryLayout<Int16>.size
    let sampleCount = min(availableSamples, maxSamples)
    guard sampleCount > 0 else {
      return [:]
    }

    var nonZeroCount = 0
    var peak = 0
    var sumSquares = 0.0

    data.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
        return
      }
      for index in 0..<sampleCount {
        let offset = index * 2
        let magnitudeSource = Int16(
          bitPattern: UInt16(base[offset]) | (UInt16(base[offset + 1]) << 8)
        )
        let magnitude = magnitudeSource == Int16.min
          ? 32767
          : abs(Int(magnitudeSource))
        if magnitude > 0 {
          nonZeroCount += 1
        }
        if magnitude > peak {
          peak = magnitude
        }
        sumSquares += Double(magnitude * magnitude)
      }
    }

    let rms = sqrt(sumSquares / Double(sampleCount))
    let rmsNormalized = rms / 32767.0
    let peakNormalized = Double(peak) / 32767.0

    return [
      "sampleCount": sampleCount,
      "nonZeroRatio": Double((Double(nonZeroCount) / Double(sampleCount) * 1000).rounded()) / 1000,
      "rmsNormalized": Double((rmsNormalized * 10000).rounded()) / 10000,
      "peakNormalized": Double((peakNormalized * 10000).rounded()) / 10000,
      "rmsDbfs": Double((20.0 * log10(max(rmsNormalized, 0.000001)) * 10).rounded()) / 10,
    ]
  }

  private func pcmBufferStatsLocked(
    _ buffer: AVAudioPCMBuffer,
    maxSamples: Int = 4096
  ) -> [String: Any?] {
    let sampleCount = min(Int(buffer.frameLength), maxSamples)
    guard sampleCount > 0 else {
      return [:]
    }

    var nonZeroCount = 0
    var peak = 0.0
    var sumSquares = 0.0

    switch buffer.format.commonFormat {
    case .pcmFormatFloat32:
      guard let channels = buffer.floatChannelData else { return [:] }
      let channel = channels[0]
      for index in 0..<sampleCount {
        let value = Double(abs(channel[index]))
        if value > 0.0001 {
          nonZeroCount += 1
        }
        if value > peak {
          peak = value
        }
        sumSquares += value * value
      }
    case .pcmFormatInt16:
      guard let channels = buffer.int16ChannelData else { return [:] }
      let channel = channels[0]
      for index in 0..<sampleCount {
        let raw = channel[index]
        let magnitude = Double(raw == Int16.min ? 32767 : abs(Int(raw))) / 32767.0
        if magnitude > 0.0001 {
          nonZeroCount += 1
        }
        if magnitude > peak {
          peak = magnitude
        }
        sumSquares += magnitude * magnitude
      }
    default:
      return [:]
    }

    let rms = sqrt(sumSquares / Double(sampleCount))
    return [
      "sampleCount": sampleCount,
      "nonZeroRatio": Double((Double(nonZeroCount) / Double(sampleCount) * 1000).rounded()) / 1000,
      "rmsNormalized": Double((rms * 10000).rounded()) / 10000,
      "peakNormalized": Double((peak * 10000).rounded()) / 10000,
      "rmsDbfs": Double((20.0 * log10(max(rms, 0.000001)) * 10).rounded()) / 10,
    ]
  }

  private func handleMixerBuffer(_ buffer: AVAudioPCMBuffer) {
    guard isSessionRunning, playbackDidStart else { return }

    let stats = pcmBufferStatsLocked(buffer)
    guard !stats.isEmpty else { return }

    mixerBufferCount += 1
    lastMixerBufferAtMs = Int(Date().timeIntervalSince1970 * 1000)
    if let value = stats["nonZeroRatio"] as? Double {
      lastMixerNonZeroRatio = value
    }
    if let value = stats["rmsNormalized"] as? Double {
      lastMixerRmsNormalized = value
    }
    if let value = stats["peakNormalized"] as? Double {
      lastMixerPeakNormalized = value
    }
    if !playbackStartupConfirmed {
      let nonZeroRatio = (stats["nonZeroRatio"] as? Double) ?? 0
      let rmsNormalized = (stats["rmsNormalized"] as? Double) ?? 0
      if nonZeroRatio > 0.05 || rmsNormalized > 0.002 {
        playbackStartupConfirmed = true
        clearStartupPlaybackReplayLocked()
        emitSessionSnapshotLocked(
          "playback_startup_confirmed",
          [
            "nonZeroRatio": nonZeroRatio,
            "rmsNormalized": rmsNormalized,
          ]
        )
      }
    }

    if !mixerFirstBufferLogged {
      mixerFirstBufferLogged = true
      var details: [String: Any?] = [
        "mixerBufferCount": mixerBufferCount,
        "mixerSampleRateHz": Int(buffer.format.sampleRate.rounded()),
        "mixerChannels": Int(buffer.format.channelCount),
      ]
      for (key, value) in stats {
        details[key] = value
      }
      emitSessionSnapshotLocked(
        "playback_mixer_buffer_first",
        details
      )
    }
  }

  private func clearStartupPlaybackReplayLocked() {
    startupPlaybackReplayBuffers.removeAll(keepingCapacity: false)
    startupPlaybackReplayBytes = 0
  }

  private func cacheStartupPlaybackBufferLocked(_ bytes: Data) {
    guard !playbackStartupConfirmed else { return }
    guard !isReplayingStartupBuffers else { return }
    guard !bytes.isEmpty else { return }

    startupPlaybackReplayBuffers.append(bytes)
    startupPlaybackReplayBytes += bytes.count

    while startupPlaybackReplayBytes > startupPlaybackReplayMaxBytes &&
      !startupPlaybackReplayBuffers.isEmpty {
      startupPlaybackReplayBytes -= startupPlaybackReplayBuffers.removeFirst().count
    }
  }

  private func replayStartupPlaybackBuffersLocked(reason: String) {
    guard !startupPlaybackReplayBuffers.isEmpty else { return }
    let replayBuffers = startupPlaybackReplayBuffers
    let replayBytes = startupPlaybackReplayBytes
    clearStartupPlaybackReplayLocked()
    isReplayingStartupBuffers = true
    defer { isReplayingStartupBuffers = false }

    emitSessionSnapshotLocked(
      "playback_startup_replay",
      [
        "reason": reason,
        "replayBufferCount": replayBuffers.count,
        "replayBytes": replayBytes,
      ]
    )

    for buffer in replayBuffers {
      try? pushPlaybackLocked(bytes: buffer)
    }
  }

  private func schedulePlaybackProbesLocked() {
    cancelPlaybackProbesLocked()
    let probes: [(TimeInterval, String)] = [
      (0.35, "350ms"),
      (1.2, "1200ms"),
      (3.0, "3000ms"),
    ]
    for (delay, label) in probes {
      let workItem = DispatchWorkItem { [weak self] in
        guard let self else { return }
        guard self.isSessionRunning, self.playbackDidStart else { return }
        let details = self.playbackProgressDetailsLocked(probeLabel: label)
        self.emitSessionSnapshotLocked(
          "playback_stall_probe",
          details
        )
        if self.shouldAttemptSilentPlaybackStartupRecoveryLocked(
          probeLabel: label,
          details: details
        ) {
          self.reprimePlaybackLocked(reason: "startup_silent_\(label)", emitInterruption: false)
        }
      }
      playbackProbeWorkItems.append(workItem)
      sessionQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
  }

  private func shouldAttemptSilentPlaybackStartupRecoveryLocked(
    probeLabel: String,
    details: [String: Any?]
  ) -> Bool {
    guard !playbackStartupConfirmed else { return false }
    guard !playbackStartupRecoveryAttempted else { return false }
    guard playbackDidStart else { return false }
    guard probeLabel == "350ms" || probeLabel == "1200ms" else { return false }
    guard playbackChunkCount > 0 else { return false }
    guard playbackCompletionCount == 0 else { return false }
    guard pendingPlaybackBufferCount > 0 else { return false }
    guard mixerFirstBufferLogged else { return false }

    let lastNonZero = lastMixerNonZeroRatio ?? 0
    let lastRms = lastMixerRmsNormalized ?? 0
    if lastNonZero > 0.001 || lastRms > 0.0005 {
      return false
    }

    let playerRenderSampleTime = details["playerRenderSampleTime"] as? NSNumber
    let outputRenderSampleTime = details["outputNodeLastRenderSampleTime"] as? NSNumber
    let renderActive =
      (playerRenderSampleTime?.int64Value ?? 0) > 0 ||
      (outputRenderSampleTime?.int64Value ?? 0) > 0
    guard renderActive else { return false }

    return true
  }

  private func routeSupportDetailsLocked(reason: String) -> [String: Any?] {
    let route = audioSession.currentRoute
    let inputs = route.inputs.map(\.portType.rawValue)
    let outputs = route.outputs.map(\.portType.rawValue)
    let unsupportedOutputs = route.outputs
      .map(\.portType)
      .filter { $0 == .bluetoothA2DP || $0 == .airPlay }
      .map(\.rawValue)
    return [
      "reason": reason,
      "route": currentRouteDescriptionLocked(),
      "hasInput": !route.inputs.isEmpty,
      "inputs": inputs,
      "outputs": outputs,
      "unsupportedOutputs": unsupportedOutputs,
    ]
  }

  private func isUnsupportedNativeVoiceRouteLocked() -> Bool {
    let outputPortTypes = Set(audioSession.currentRoute.outputs.map(\.portType))
    return outputPortTypes.contains(.bluetoothA2DP) || outputPortTypes.contains(.airPlay)
  }

  private func emitCurrentRouteEventLocked(type: String, reason: String) {
    emitSessionSnapshotLocked(
      type,
      [
        "reason": reason,
        "route": currentRouteDescriptionLocked(),
      ]
    )
    if isUnsupportedNativeVoiceRouteLocked() {
      emitEvent("route_unsupported", routeSupportDetailsLocked(reason: reason))
    }
  }

  private func nativeErrorCode(from error: Error) -> String? {
    let nsError = error as NSError
    if let code = nsError.userInfo["errorCode"] as? String, !code.isEmpty {
      return code
    }
    return nil
  }

  private func ensureEngineRunningLocked(
    _ audioEngine: AVAudioEngine,
    player: AVAudioPlayerNode,
    trigger: String,
    failureCode: String
  ) throws {
    let maxAttempts = 3
    var lastThrownError: Error?

    for attempt in 1...maxAttempts {
      do {
        // Rechecked on every attempt: a detach during the retry sleep stops further activation.
        try mutateSharedSession { try audioSession.setActive(true, options: []) }
        audioEngine.prepare()
        if !audioEngine.isRunning {
          try audioEngine.start()
        }
        if let lifetime = playbackLifetime, !lifetime.isRetired, !farewellDrain.restartBlocked {
          _ = lifetime.boundary { player.play() }
        }
      } catch {
        if retiredFromEngine { throw error }
        lastThrownError = error
      }

      emitSessionSnapshotLocked(
        "engine_start_attempt",
        [
          "trigger": trigger,
          "attempt": attempt,
          "engineRunningCheck": audioEngine.isRunning,
        ]
      )

      if audioEngine.isRunning {
        return
      }

      if attempt < maxAttempts {
        Thread.sleep(forTimeInterval: 0.05)
      }
    }

    let error = NSError(
      domain: "mindbend_gemini_live_audio",
      code: -13,
      userInfo: [
        NSLocalizedDescriptionKey: "AVAudioEngine did not enter a running state.",
        "errorCode": failureCode,
        "trigger": trigger,
      ]
    )
    var errorDetails: [String: Any?] = [
      "code": failureCode,
      "trigger": trigger,
      "message": error.localizedDescription,
    ]
    if let lastThrownError {
      errorDetails["underlyingError"] = lastThrownError.localizedDescription
    }
    emitSessionSnapshotLocked("error", errorDetails)
    throw error
  }

  private func recoverAudioSessionLocked(trigger: String) {
    guard isSessionRunning, !retiredFromEngine else { return }
    do {
      try mutateSharedSession {
        try audioSession.setCategory(
          .playAndRecord,
          mode: .voiceChat,
          options: [.allowBluetooth, .defaultToSpeaker]
        )
      }
      try mutateSharedSession { try audioSession.setPreferredIOBufferDuration(0.01) }
      if let audioEngine = engine, let player = playerNode {
        try ensureEngineRunningLocked(
          audioEngine,
          player: player,
          trigger: trigger,
          failureCode: "ios_engine_not_running_after_recover"
        )
      }
      emitCurrentRouteEventLocked(type: "route_applied", reason: trigger)
      emitSessionSnapshotLocked(
        "session_recovered",
        [
          "trigger": trigger,
          "route": currentRouteDescriptionLocked(),
        ]
      )
    } catch {
      let failureCode = nativeErrorCode(from: error) ?? "ios_session_recovery_failed"
      emitEvent(
        "error",
        [
          "code": failureCode,
          "trigger": trigger,
          "message": error.localizedDescription,
        ]
      )
    }
  }

  @objc private func handleAudioSessionInterruption(_ notification: Notification) {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      guard let userInfo = notification.userInfo,
            let rawType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
      else {
        return
      }

      switch type {
      case .began:
        self.farewellBarrier?.invalidate(reason: "interrupted")
        self.emitEvent(
          "interruption_began",
          ["route": self.currentRouteDescriptionLocked()]
        )
      case .ended:
        let rawOptions = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
        self.emitEvent(
          "interruption_ended",
          [
            "shouldResume": options.contains(.shouldResume),
            "route": self.currentRouteDescriptionLocked(),
          ]
        )
        self.recoverAudioSessionLocked(trigger: "interruption_ended")
      @unknown default:
        break
      }
    }
  }

  @objc private func handleAudioSessionRouteChange(_ notification: Notification) {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      let userInfo = notification.userInfo ?? [:]
      let rawReason = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
      let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
      let previousRoute = (userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)
        .map { route in
          let inputs = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
          let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
          return "inputs=[\(inputs)] outputs=[\(outputs)]"
        }
      self.farewellBarrier?.invalidate(reason: "route_changed")
      self.emitEvent(
        "route_changed",
        [
          "reasonCode": Int(rawReason),
          "reason": reason.map { String(describing: $0) } ?? "unknown",
          "route": self.currentRouteDescriptionLocked(),
          "previousRoute": previousRoute as Any,
        ]
      )
      if self.isUnsupportedNativeVoiceRouteLocked() {
        self.emitEvent("route_unsupported", self.routeSupportDetailsLocked(reason: "route_change"))
      }
    }
  }

  @objc private func handleMediaServicesWereLost(_ notification: Notification) {
    sessionQueue.async { [weak self] in
      self?.farewellBarrier?.invalidate(reason: "media_services_lost")
      self?.emitEvent("media_services_lost")
    }
  }

  @objc private func handleMediaServicesWereReset(_ notification: Notification) {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.farewellBarrier?.invalidate(reason: "media_services_reset")
      self.emitEvent("media_services_reset")
      self.recoverAudioSessionLocked(trigger: "media_services_reset")
    }
  }

  private func handleCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
    guard isSessionRunning,
          let converter = captureConverter,
          let targetFormat = captureTargetFormat
    else {
      return
    }

    if !captureFirstBufferLogged {
      captureFirstBufferLogged = true
      cancelCaptureStallProbesLocked()
      emitSessionSnapshotLocked(
        "capture_buffer_first",
        [
          "sampleRateHz": Int(buffer.format.sampleRate),
          "frames": Int(buffer.frameLength),
          "route": currentRouteDescriptionLocked(),
        ]
      )
    }

    let frameRatio = targetFormat.sampleRate / buffer.format.sampleRate
    let outputCapacity = AVAudioFrameCount((Double(buffer.frameLength) * frameRatio).rounded(.up) + 8)
    guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(outputCapacity, 1)) else {
      return
    }

    var inputConsumed = false
    var conversionError: NSError?
    let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
      if inputConsumed {
        outStatus.pointee = .noDataNow
        return nil
      }
      inputConsumed = true
      outStatus.pointee = .haveData
      return buffer
    }

    if status == .error || conversionError != nil || converted.frameLength == 0 {
      emitEvent("error", ["code": "ios_capture_convert_failed"])
      return
    }

    let audioBufferList = UnsafeMutableAudioBufferListPointer(converted.mutableAudioBufferList)
    guard let mData = audioBufferList[0].mData else {
      return
    }
    let data = Data(bytes: mData, count: Int(audioBufferList[0].mDataByteSize))
    guard !data.isEmpty else { return }
    captureChunkCount += 1
    emitCapturedAudio(data)
  }

  private func pushPlaybackLocked(bytes: Data) throws {
    guard isSessionRunning,
          let player = playerNode,
          let format = playbackFormat
    else {
      throw NSError(
        domain: "mindbend_gemini_live_audio",
        code: -20,
        userInfo: [NSLocalizedDescriptionKey: "Session is not running."]
      )
    }
    guard let lifetime = playbackLifetime, !lifetime.isRetired else { return }
    if bytes.isEmpty {
      return
    }

    let frameCount = AVAudioFrameCount(bytes.count / MemoryLayout<Int16>.size)
    guard frameCount > 0,
          let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
    else {
      throw NSError(
        domain: "mindbend_gemini_live_audio",
        code: -21,
        userInfo: [NSLocalizedDescriptionKey: "Unable to allocate playback buffer."]
      )
    }

    pcmBuffer.frameLength = frameCount
    let audioBufferList = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
    guard let mData = audioBufferList[0].mData else {
      throw NSError(
        domain: "mindbend_gemini_live_audio",
        code: -22,
        userInfo: [NSLocalizedDescriptionKey: "Playback buffer has no writable memory."]
      )
    }

    bytes.copyBytes(to: mData.assumingMemoryBound(to: UInt8.self), count: bytes.count)
    audioBufferList[0].mDataByteSize = UInt32(bytes.count)

    // The barrier must know every buffer that lands on this player's timeline ahead of a farewell.
    farewellBarrier?.noteLegacyScheduled(frames: Int64(frameCount))
    playbackChunkCount += 1
    playbackBytesScheduled += bytes.count
    pendingPlaybackBufferCount += 1
    cacheStartupPlaybackBufferLocked(bytes)
    let shouldEmitEnqueueSnapshot =
      playbackChunkCount == 1 ||
      playbackChunkCount <= 4 ||
      playbackChunkCount % 16 == 0
    let pcmStats = shouldEmitEnqueueSnapshot ? pcm16StatsLocked(bytes) : [:]
    let scheduled: Void? = lifetime.boundary { player.scheduleBuffer(pcmBuffer) { [weak self] in
      guard let self else { return }
      self.sessionQueue.async {
        guard !lifetime.isRetired, self.playbackLifetime === lifetime else { return }
        self.pendingPlaybackBufferCount = max(0, self.pendingPlaybackBufferCount - 1)
        self.playbackCompletionCount += 1
        if self.playbackCompletionCount == 1 || self.playbackCompletionCount % 16 == 0 {
          self.emitSessionSnapshotLocked(
            "playback_chunk_completed",
            [
              "completionCount": self.playbackCompletionCount,
              "pendingPlaybackBufferCount": self.pendingPlaybackBufferCount,
            ]
          )
        }
      }
    }
    }
    guard scheduled != nil, !lifetime.isRetired else { return }
    if !player.isPlaying {
      guard lifetime.boundary({ player.play() }) != nil else { return }
    }
    if shouldEmitEnqueueSnapshot {
      var details: [String: Any?] = [
        "bytes": bytes.count,
        "chunkCount": playbackChunkCount,
        "playbackBytesScheduled": playbackBytesScheduled,
        "pendingPlaybackBufferCount": pendingPlaybackBufferCount,
      ]
      for (key, value) in pcmStats {
        details[key] = value
      }
      emitSessionSnapshotLocked(
        "playback_chunk_enqueued",
        details
      )
    }
    if !playbackDidStart {
      playbackDidStart = true
      playbackStartupConfirmed = false
      schedulePlaybackProbesLocked()
      emitEvent(
        "playback_started",
        [
          "bytes": bytes.count,
          "route": currentRouteDescriptionLocked(),
        ]
      )
    }
  }

  private func flushPlaybackLocked() {
    _ = farewellDrain.noteFlush()
    reprimePlaybackLocked(reason: "flush_request", emitInterruption: true)
  }

  private func reprimePlaybackLocked(reason: String, emitInterruption: Bool) {
    guard isSessionRunning, let player = playerNode else {
      return
    }
    if !emitInterruption {
      playbackStartupRecoveryAttempted = true
      emitSessionSnapshotLocked(
        "playback_startup_silent_recovery",
        [
          "reason": reason,
          "pendingPlaybackBufferCount": pendingPlaybackBufferCount,
          "playbackChunkCount": playbackChunkCount,
          "playbackCompletionCount": playbackCompletionCount,
        ]
      )
    }
    player.stop()
    player.reset()
    farewellBarrier?.noteTimelineReset(reason: "playback_reprimed")
    if let lifetime = playbackLifetime, !lifetime.isRetired, !farewellDrain.restartBlocked {
      _ = lifetime.boundary { player.play() }
    }
    playbackDidStart = false
    pendingPlaybackBufferCount = 0
    mixerBufferCount = 0
    mixerFirstBufferLogged = false
    lastMixerNonZeroRatio = nil
    lastMixerRmsNormalized = nil
    lastMixerPeakNormalized = nil
    lastMixerBufferAtMs = nil
    playbackStartupConfirmed = false
    cancelPlaybackProbesLocked()
    if emitInterruption {
      clearStartupPlaybackReplayLocked()
      emitEvent("interrupted", ["route": currentRouteDescriptionLocked()])
      emitEvent("playback_stopped", ["route": currentRouteDescriptionLocked()])
    } else {
      emitSessionSnapshotLocked(
        "playback_reprimed",
        [
          "reason": reason,
        ]
      )
      replayStartupPlaybackBuffersLocked(reason: reason)
    }
  }

  private func markPlaybackCompleteLocked() {
    _ = farewellDrain.acknowledgeCommand(generationAtAck: farewellDrain.generation)
  }

  private func stopSessionLocked(restoreAudioSession: Bool) {
    farewellBarrier?.noteTimelineReset(reason: "session_stopped")
    farewellBarrier = nil
    if let observer = engineConfigurationObserver {
      NotificationCenter.default.removeObserver(observer)
      engineConfigurationObserver = nil
    }
    playbackLifetime?.cancel()
    _ = farewellDrain.cancel()
    if let inputNode = engine?.inputNode {
      inputNode.removeTap(onBus: 0)
    }
    engine?.mainMixerNode.removeTap(onBus: 0)
    playerNode?.stop()
    playerNode?.reset()
    engine?.stop()
    engine?.reset()

    playerNode = nil
    playbackLifetime = nil
    captureConverter = nil
    captureTargetFormat = nil
    playbackFormat = nil
    engine = nil
    playbackDidStart = false
    playbackChunkCount = 0
    playbackBytesScheduled = 0
    playbackCompletionCount = 0
    pendingPlaybackBufferCount = 0
    mixerBufferCount = 0
    mixerFirstBufferLogged = false
    lastMixerNonZeroRatio = nil
    lastMixerRmsNormalized = nil
    lastMixerPeakNormalized = nil
    lastMixerBufferAtMs = nil
    clearStartupPlaybackReplayLocked()
    isReplayingStartupBuffers = false
    isSessionRunning = false
    captureFirstBufferLogged = false
    captureFirstChunkDelivered = false
    cancelCaptureStallProbesLocked()
    cancelPlaybackProbesLocked()
    sessionStartedAtMs = nil

    if restoreAudioSession && !retiredFromEngine {
      do {
        if let previousCategory, let previousMode {
          try mutateSharedSession {
            try audioSession.setCategory(previousCategory, mode: previousMode, options: previousOptions)
          }
        }
        try mutateSharedSession { try audioSession.setActive(false, options: [.notifyOthersOnDeactivation]) }
      } catch {
        if !retiredFromEngine { emitEvent("error", ["code": "ios_restore_session_failed"]) }
      }
    }

    unregisterAudioSessionObserversLocked()
  }

  private func emitFarewellEvent(_ event: FarewellBarrierEvent) {
    switch event {
    case let .drained(turnId, nativeGeneration, drainedAtEpochMs, framesPlayed, lastSeq, evidence):
      emitEvent("farewell_drained", [
        "turnId": turnId,
        "nativeGeneration": nativeGeneration,
        "drainedAtEpochMs": drainedAtEpochMs,
        "framesPlayed": framesPlayed,
        "lastSeq": lastSeq,
        "evidence": evidence,
      ])
    case let .unverified(turnId, nativeGeneration, reason):
      emitEvent("farewell_unverified", [
        "turnId": turnId,
        "nativeGeneration": nativeGeneration,
        "reason": reason,
      ])
    }
  }

  private func emitCapturedAudio(_ data: Data) {
    // Avoid capturing a stale sink closure across async hops. During
    // hot-restart/dispose, EventChannel callbacks can be deleted while queued
    // blocks are still pending, which can abort the Dart VM.
    let stamp = captureDelivery.stamp()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if let stamp, !self.captureDelivery.admits(stamp) { return }
      guard stamp != nil, let sink = self.captureEventSink else {
        if self.captureDelivery.isDetached || self.captureEventSink != nil { return }
        if !self.captureSinkMissingLogged {
          self.captureSinkMissingLogged = true
          self.emitEvent("capture_sink_missing")
        }
        return
      }
      if !self.captureFirstChunkDelivered {
        self.captureFirstChunkDelivered = true
        self.cancelCaptureStallProbesLocked()
        self.emitSessionSnapshotLocked(
          "capture_first_chunk",
          [
            "bytes": data.count,
            "chunksDelivered": self.captureChunkCount,
            "route": self.currentRouteDescriptionLocked(),
          ]
        )
      }
      sink(FlutterStandardTypedData(bytes: data))
    }
  }

  private func emitEvent(_ type: String, _ details: [String: Any?] = [:]) {
    var payload: [String: Any] = [
      "type": type,
      "platform": "ios",
      "atMs": Int(Date().timeIntervalSince1970 * 1000)
    ]
    for (key, value) in details {
      if let value {
        payload[key] = value
      }
    }
    guard let stamp = eventDelivery.stamp() else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.eventDelivery.admits(stamp), let sink = self.eventSink else { return }
      sink(payload)
    }
  }
}

/// Lets a lifetime's stop closure reach the barrier that is created after the lifetime.
