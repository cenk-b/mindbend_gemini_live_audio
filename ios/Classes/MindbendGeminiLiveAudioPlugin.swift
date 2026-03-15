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
  private var captureSinkMissingLogged = false

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
        instance?.emitEvent("debug:ios_capture_sink_attached")
      },
      onCancel: { [weak instance] in
        instance?.captureEventSink = nil
      }
    )
    let eventHandler = ClosureStreamHandler(
      onListen: { [weak instance] sink in
        instance?.eventSink = sink
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
        options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
      )
      try audioSession.setPreferredIOBufferDuration(0.01)
      try audioSession.setActive(true, options: [])

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

      // Request ~30ms input buffers at the hardware sample rate (typically 48kHz).
      // AVAudioEngine treats this as a hint and may deliver larger chunks.
      let requestedTapFrames = AVAudioFrameCount(
        max(1, Int((inputFormat.sampleRate * 0.03).rounded()))
      )
      inputNode.installTap(onBus: 0, bufferSize: requestedTapFrames, format: inputFormat) { [weak self] buffer, _ in
        self?.handleCapturedBuffer(buffer)
      }

      audioEngine.prepare()
      try audioEngine.start()
      player.play()

      engine = audioEngine
      playerNode = player
      captureConverter = converter
      captureTargetFormat = targetCaptureFormat
      playbackFormat = outputPlaybackFormat
      isSessionRunning = true
      playbackDidStart = false
      captureChunkCount = 0
      captureSinkMissingLogged = false
      emitEvent(
        "debug:ios_session_started input_sr=\(Int(inputFormat.sampleRate)) " +
          "input_ch=\(inputFormat.channelCount) tap=\(requestedTapFrames)"
      )

      return startResult(
        aecActive: true,
        transportMode: "native_aec",
        errorCode: nil
      )
    } catch {
      stopSessionLocked(restoreAudioSession: true)
      emitEvent("error:ios_start_failed")
      return startResult(
        aecActive: false,
        transportMode: "legacy_half_duplex",
        errorCode: "ios_start_failed"
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

  private func handleCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
    guard isSessionRunning,
          let converter = captureConverter,
          let targetFormat = captureTargetFormat
    else {
      return
    }

    if captureChunkCount == 0 {
      emitEvent(
        "debug:ios_capture_buffer_first sr=\(Int(buffer.format.sampleRate)) " +
          "frames=\(buffer.frameLength)"
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
      emitEvent("error:ios_capture_convert_failed")
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

    if !playbackDidStart {
      playbackDidStart = true
      emitEvent("playback_started")
    }
    if !player.isPlaying {
      player.play()
    }
    player.scheduleBuffer(pcmBuffer, completionHandler: nil)
  }

  private func flushPlaybackLocked() {
    guard isSessionRunning, let player = playerNode else {
      return
    }
    player.stop()
    player.reset()
    player.play()
    playbackDidStart = false
    emitEvent("interrupted")
    emitEvent("playback_stopped")
  }

  private func markPlaybackCompleteLocked() {
    // Native playback completion is inferred from chunk idle timing in Dart.
    // This method intentionally does not flush or stop queued audio.
  }

  private func stopSessionLocked(restoreAudioSession: Bool) {
    if let inputNode = engine?.inputNode {
      inputNode.removeTap(onBus: 0)
    }
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
    isSessionRunning = false

    if restoreAudioSession {
      do {
        if let previousCategory, let previousMode {
          try audioSession.setCategory(previousCategory, mode: previousMode, options: previousOptions)
        }
        try audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
      } catch {
        emitEvent("error:ios_restore_session_failed")
      }
    }
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
          self.emitEvent("debug:ios_capture_sink_missing")
        }
        return
      }
      sink(FlutterStandardTypedData(bytes: data))
    }
  }

  private func emitEvent(_ event: String) {
    DispatchQueue.main.async { [weak self] in
      guard let self, let sink = self.eventSink else { return }
      sink(event)
    }
  }
}
