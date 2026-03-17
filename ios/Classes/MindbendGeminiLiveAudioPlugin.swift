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

public final class MindbendGeminiLiveAudioPlugin: NSObject, FlutterPlugin {
  private let sessionQueue = DispatchQueue(label: "com.cognistence.mindbend_gemini_live_audio.session")
  private let audioSession = AVAudioSession.sharedInstance()

  private var captureStreamHandler: ClosureStreamHandler?
  private var eventStreamHandler: ClosureStreamHandler?
  private var captureEventSink: FlutterEventSink?
  private var eventSink: FlutterEventSink?

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
  private var captureSinkMissingLogged = false
  private var captureFirstBufferLogged = false
  private var captureFirstChunkDelivered = false
  private var observersRegistered = false
  private var captureStallProbeWorkItems: [DispatchWorkItem] = []
  private var playbackProbeWorkItems: [DispatchWorkItem] = []
  private var sessionStartedAtMs: Int?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = MindbendGeminiLiveAudioPlugin()

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
        instance?.captureEventSink = sink
        instance?.captureSinkMissingLogged = false
        instance?.emitEvent("capture_sink_attached")
      },
      onCancel: { [weak instance] in
        instance?.captureEventSink = nil
      }
    )
    let eventHandler = ClosureStreamHandler(
      onListen: { [weak instance] sink in
        instance?.eventSink = sink
        instance?.emitEvent("event_sink_attached")
      },
      onCancel: { [weak instance] in
        instance?.eventSink = nil
      }
    )

    instance.captureStreamHandler = captureHandler
    instance.eventStreamHandler = eventHandler
    captureChannel.setStreamHandler(captureHandler)
    eventChannel.setStreamHandler(eventHandler)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startSession":
      sessionQueue.async { [weak self] in
        guard let self else { return }
        let payload = self.startSessionLocked()
        DispatchQueue.main.async {
          result(payload)
        }
      }
    case "stopSession":
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

  private func startSessionLocked() -> [String: Any] {
    if isSessionRunning {
      return startResult(
        aecActive: true,
        transportMode: "native_aec",
        errorCode: nil
      )
    }

    do {
      previousCategory = audioSession.category
      previousMode = audioSession.mode
      previousOptions = audioSession.categoryOptions

      try audioSession.setCategory(
        .playAndRecord,
        mode: .voiceChat,
        options: [.allowBluetooth, .defaultToSpeaker]
      )
      try audioSession.setPreferredIOBufferDuration(0.01)
      try audioSession.setActive(true, options: [])
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
      stopSessionLocked(restoreAudioSession: true)
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
        self.emitSessionSnapshotLocked(
          "playback_stall_probe",
          self.playbackProgressDetailsLocked(probeLabel: label)
        )
      }
      playbackProbeWorkItems.append(workItem)
      sessionQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
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
        try audioSession.setActive(true, options: [])
        audioEngine.prepare()
        if !audioEngine.isRunning {
          try audioEngine.start()
        }
        if !player.isPlaying {
          player.play()
        }
      } catch {
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
    guard isSessionRunning else { return }
    do {
      try audioSession.setCategory(
        .playAndRecord,
        mode: .voiceChat,
        options: [.allowBluetooth, .defaultToSpeaker]
      )
      try audioSession.setPreferredIOBufferDuration(0.01)
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
      self?.emitEvent("media_services_lost")
    }
  }

  @objc private func handleMediaServicesWereReset(_ notification: Notification) {
    sessionQueue.async { [weak self] in
      guard let self else { return }
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

    playbackChunkCount += 1
    playbackBytesScheduled += bytes.count
    pendingPlaybackBufferCount += 1
    let shouldEmitEnqueueSnapshot =
      playbackChunkCount == 1 ||
      playbackChunkCount <= 4 ||
      playbackChunkCount % 16 == 0
    let pcmStats = shouldEmitEnqueueSnapshot ? pcm16StatsLocked(bytes) : [:]
    player.scheduleBuffer(pcmBuffer) { [weak self] in
      guard let self else { return }
      self.sessionQueue.async {
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
    if !player.isPlaying {
      player.play()
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
    guard isSessionRunning, let player = playerNode else {
      return
    }
    player.stop()
    player.reset()
    player.play()
    playbackDidStart = false
    pendingPlaybackBufferCount = 0
    mixerBufferCount = 0
    mixerFirstBufferLogged = false
    lastMixerNonZeroRatio = nil
    lastMixerRmsNormalized = nil
    lastMixerPeakNormalized = nil
    lastMixerBufferAtMs = nil
    cancelPlaybackProbesLocked()
    emitEvent("interrupted", ["route": currentRouteDescriptionLocked()])
    emitEvent("playback_stopped", ["route": currentRouteDescriptionLocked()])
  }

  private func markPlaybackCompleteLocked() {
    // Native playback completion is inferred from chunk idle timing in Dart.
    // This method intentionally does not flush or stop queued audio.
  }

  private func stopSessionLocked(restoreAudioSession: Bool) {
    if let inputNode = engine?.inputNode {
      inputNode.removeTap(onBus: 0)
    }
    engine?.mainMixerNode.removeTap(onBus: 0)
    playerNode?.stop()
    playerNode?.reset()
    engine?.stop()
    engine?.reset()

    playerNode = nil
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
    isSessionRunning = false
    captureFirstBufferLogged = false
    captureFirstChunkDelivered = false
    cancelCaptureStallProbesLocked()
    cancelPlaybackProbesLocked()
    sessionStartedAtMs = nil

    if restoreAudioSession {
      do {
        if let previousCategory, let previousMode {
          try audioSession.setCategory(previousCategory, mode: previousMode, options: previousOptions)
        }
        try audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
      } catch {
        emitEvent("error", ["code": "ios_restore_session_failed"])
      }
    }

    unregisterAudioSessionObserversLocked()
  }

  private func emitCapturedAudio(_ data: Data) {
    // Avoid capturing a stale sink closure across async hops. During
    // hot-restart/dispose, EventChannel callbacks can be deleted while queued
    // blocks are still pending, which can abort the Dart VM.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard let sink = self.captureEventSink else {
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
    DispatchQueue.main.async { [weak self] in
      guard let self, let sink = self.eventSink else { return }
      sink(payload)
    }
  }
}
