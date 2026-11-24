import AVFoundation
import Flutter
import UIKit
import XCTest


@testable import mindbend_gemini_live_audio

// This demonstrates a simple unit test of the Swift portion of this plugin's implementation.
//
// See https://developer.apple.com/documentation/xctest for more information about using XCTest.

class RunnerTests: XCTestCase {

  func testGetPlatformVersion() {
    let plugin = MindbendGeminiLiveAudioPlugin()

    let call = FlutterMethodCall(methodName: "getPlatformVersion", arguments: [])

    let resultExpectation = expectation(description: "result block must be called.")
    plugin.handle(call) { result in
      XCTAssertEqual(result as! String, "iOS " + UIDevice.current.systemVersion)
      resultExpectation.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  func testFarewellDrainAckIsNotNativeDrain() {
    var gate = FarewellDrainGate()
    let begun = gate.begin(expectedFrames: 100)
    XCTAssertEqual(begun["state"] as? String, "armed")
    let ack = gate.acknowledgeCommand(generationAtAck: gate.generation)
    XCTAssertEqual(ack["evidence"] as? String, "command_ack")
    XCTAssertNotEqual(ack["evidence"] as? String, "native_drain")
    let early = gate.noteAnchor(seq: 1, played: 10, generationAtAnchor: gate.generation, nativeDrained: true)
    XCTAssertEqual(early["evidence"] as? String, "none")
    let drained = gate.noteAnchor(seq: 2, played: 80, generationAtAnchor: gate.generation, nativeDrained: true)
    XCTAssertEqual(drained["evidence"] as? String, "native_drain")
    _ = gate.noteFlush()
    XCTAssertEqual(gate.evidence, "none")
    XCTAssertEqual(gate.restartBlocked, false)
    _ = gate.cancel()
    XCTAssertEqual(gate.restartBlocked, true)
    let stale = gate.noteAnchor(seq: 3, played: 80, generationAtAnchor: (begun["generation"] as? Int) ?? 0, nativeDrained: true)
    XCTAssertNotEqual(stale["evidence"] as? String, "native_drain")
  }

}

/// Group A (16 Nov 2026): on-device / simulator proof of the iOS attributed farewell through the REAL plugin: it is
/// registered exactly as in an app (a fake registrar and binary messenger stand in for the Flutter engine), method
/// calls go through `handle(_:result:)`, and outcomes are decoded from the real event-channel envelopes. Real
/// session, voice-processing I/O, AVAudioPlayerNode, barrier and PluginFarewellPlayer. Native only: runs through
/// `xcodebuild test` without a Dart VM. Silent PCM. The failing iPhone case was a short farewell in a fresh session.
final class FarewellPluginDeviceTests: XCTestCase {
  private final class Messenger: NSObject, FlutterBinaryMessenger {
    private let codec = FlutterStandardMethodCodec.sharedInstance()
    private var handlers: [String: FlutterBinaryMessageHandler] = [:]
    private let lock = NSLock()
    private var events: [[String: Any]] = []
    func send(onChannel channel: String, message: Data?) {
      guard channel == "mindbend_gemini_live_audio/events", let message,
            let payload = codec.decodeEnvelope(message) as? [String: Any] else { return }
      lock.lock(); events.append(payload); lock.unlock()
    }
    func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply? = nil) {
      send(onChannel: channel, message: message); callback?(nil)
    }
    func setMessageHandlerOnChannel(_ channel: String,
                                    binaryMessageHandler handler: FlutterBinaryMessageHandler? = nil) -> FlutterBinaryMessengerConnection {
      handlers[channel] = handler; return 1
    }
    func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
    /// What Dart's `receiveBroadcastStream().listen` sends.
    func listen(_ channel: String) {
      handlers[channel]?(codec.encode(FlutterMethodCall(methodName: "listen", arguments: nil))) { _ in }
    }
    func snapshot() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return events }
  }
  private final class Textures: NSObject, FlutterTextureRegistry {
    func register(_ texture: FlutterTexture) -> Int64 { 0 }
    func textureFrameAvailable(_ textureId: Int64) {}
    func unregisterTexture(_ textureId: Int64) {}
  }
  private final class Registrar: NSObject, FlutterPluginRegistrar {
    let bus = Messenger()
    private let tex = Textures()
    var published: NSObject?
    var delegate: (NSObject & FlutterPlugin)?
    var viewController: UIViewController? { nil }
    func messenger() -> FlutterBinaryMessenger { bus }
    func textures() -> FlutterTextureRegistry { tex }
    func register(_ factory: FlutterPlatformViewFactory, withId factoryId: String) {}
    func register(_ factory: FlutterPlatformViewFactory, withId factoryId: String,
                  gestureRecognizersBlockingPolicy: FlutterPlatformViewGestureRecognizersBlockingPolicy) {}
    func publish(_ value: NSObject) { published = value }
    func addMethodCallDelegate(_ delegate: FlutterPlugin, channel: FlutterMethodChannel) {
      self.delegate = delegate as? (NSObject & FlutterPlugin)
    }
    func addApplicationDelegate(_ delegate: FlutterPlugin) {}
    func addSceneDelegate(_ delegate: FlutterSceneLifeCycleDelegate) {}
    func lookupKey(forAsset asset: String) -> String { asset }
    func lookupKey(forAsset asset: String, fromPackage package: String) -> String { asset }
  }

  private var registrar: Registrar!
  private var plugin: MindbendGeminiLiveAudioPlugin!

  override func setUp() {
    super.setUp()
    registrar = Registrar()
    MindbendGeminiLiveAudioPlugin.register(with: registrar)
    plugin = registrar.published as? MindbendGeminiLiveAudioPlugin
    XCTAssertNotNil(plugin)
    registrar.bus.listen("mindbend_gemini_live_audio/events")
  }
  override func tearDown() {
    _ = call("stopSession")
    plugin = nil; registrar = nil
    super.tearDown()
  }

  @discardableResult
  private func call(_ method: String, _ args: Any? = nil) -> Any? {
    var out: Any?
    let done = expectation(description: method)
    plugin.handle(FlutterMethodCall(methodName: method, arguments: args)) { out = $0; done.fulfill() }
    wait(for: [done], timeout: 10)
    return out
  }
  private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
  private func pcm(_ frames: Int) -> FlutterStandardTypedData { FlutterStandardTypedData(bytes: Data(count: frames * 2)) }
  /// The farewell_drained / farewell_unverified payload for one turn, or nil on timeout.
  private func outcome(_ turnId: String, timeout: Double = 6) -> [String: Any]? {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
      if let e = registrar.bus.snapshot().first(where: {
        ($0["type"] as? String)?.hasPrefix("farewell_") == true && $0["turnId"] as? String == turnId
      }) { return e }
      spin(0.02)
    }
    return nil
  }
  private func begin(_ id: String, frames: Int) {
    XCTAssertEqual((call("farewellBegin", ["turnId": id, "nativeGeneration": 7]) as? [String: Any])?["accepted"] as? Bool, true)
    XCTAssertEqual(call("farewellPush", ["turnId": id, "seq": 0, "pcm": pcm(frames)]) as? Bool, true)
    XCTAssertEqual(call("farewellEnd", ["turnId": id, "totalChunks": 1, "totalFrames": frames]) as? Bool, true)
  }
  private func startNative() throws {
    let start = call("startSession") as? [String: Any]
    guard start?["transportMode"] as? String == "native_aec" else {
      throw XCTSkip("no native AEC session on this device: \(String(describing: start))")
    }
  }

  func testFreshSessionShortFarewellDrainsEveryTime() throws {
    var results: [String] = []
    for cycle in 0..<6 {
      try startNative()
      call("pushPlaybackPcm", pcm(4800))   // the session has spoken before its farewell, as in a real Ending
      spin(1.5)
      let fresh = "fw_fresh_\(cycle)"
      begin(fresh, frames: 4800)           // 200 ms
      let first = outcome(fresh)
      spin(0.3)
      let again = "fw_same_\(cycle)"
      begin(again, frames: 4800)
      let second = outcome(again)
      results.append("cycle=\(cycle) fresh=\(String(describing: first)) sameSession=\(String(describing: second))")
      XCTAssertEqual(first?["type"] as? String, "farewell_drained", results.last!)
      XCTAssertEqual(second?["type"] as? String, "farewell_drained", results.last!)
      call("stopSession")
      spin(0.5)
    }
    print("GROUPA_DEVICE fresh-session results:\n" + results.joined(separator: "\n"))
  }

  func testStopSessionMidFarewellIsNeverADrain() throws {
    try startNative()
    call("pushPlaybackPcm", pcm(4800)); spin(1.0)
    begin("fw_stop", frames: 48_000)       // 2 s
    spin(0.4)
    call("stopSession")
    spin(1.0)
    let e = outcome("fw_stop", timeout: 1)
    XCTAssertNotEqual(e?["type"] as? String, "farewell_drained", "\(String(describing: e))")
  }

  func testFlushDuringFarewellIsNeverADrain() throws {
    try startNative()
    call("pushPlaybackPcm", pcm(4800)); spin(1.0)
    begin("fw_flush", frames: 48_000)
    spin(0.3)
    call("flushPlayback")                  // barge-in: player stop/reset and a new timeline at once
    let e = outcome("fw_flush")
    XCTAssertEqual(e?["type"] as? String, "farewell_unverified", "\(String(describing: e))")
    spin(2.5)                              // the restarted timeline runs far past the old end frame
    XCTAssertFalse(registrar.bus.snapshot().contains {
      $0["type"] as? String == "farewell_drained" && $0["turnId"] as? String == "fw_flush"
    })
  }

  func testCancelAcknowledgedBeforeTheBarrierExistsStillCancelsAQueuedBegin() throws {
    // Review r8 F1: startSession and farewellBegin are queued; farewellCancel arrives (and is acknowledged) while the
    // session has not installed its barrier yet. The begin that runs after must still be cancelled, never drained.
    let started = expectation(description: "start"), begun = expectation(description: "begin")
    var start: [String: Any]?
    plugin.handle(FlutterMethodCall(methodName: "startSession", arguments: nil)) { start = $0 as? [String: Any]; started.fulfill() }
    plugin.handle(FlutterMethodCall(methodName: "farewellBegin", arguments: ["turnId": "fw_early", "nativeGeneration": 7])) { _ in begun.fulfill() }
    XCTAssertEqual(call("farewellCancel", ["turnId": "fw_early", "reason": "user_done"]) as? Bool, true)
    wait(for: [started, begun], timeout: 10)
    guard start?["transportMode"] as? String == "native_aec" else { throw XCTSkip("no native AEC session") }
    _ = call("farewellPush", ["turnId": "fw_early", "seq": 0, "pcm": pcm(4800)])
    _ = call("farewellEnd", ["turnId": "fw_early", "totalChunks": 1, "totalFrames": 4800])
    spin(2.0)
    XCTAssertFalse(registrar.bus.snapshot().contains {
      $0["type"] as? String == "farewell_drained" && $0["turnId"] as? String == "fw_early"
    }, "\(registrar.bus.snapshot().filter { ($0["type"] as? String)?.hasPrefix("farewell") == true })")
    let e = outcome("fw_early", timeout: 1)
    XCTAssertEqual(e?["reason"] as? String, "user_done", "\(String(describing: e))")
  }

  func testCancelDuringFarewellIsNeverADrain() throws {
    try startNative()
    call("pushPlaybackPcm", pcm(4800)); spin(1.0)
    begin("fw_cancel", frames: 24_000)
    spin(0.2)
    call("farewellCancel", ["turnId": "fw_cancel", "reason": "user_done"])
    let e = outcome("fw_cancel")
    XCTAssertEqual(e?["type"] as? String, "farewell_unverified")
    XCTAssertEqual(e?["reason"] as? String, "user_done")
    spin(1.5)
    XCTAssertFalse(registrar.bus.snapshot().contains { $0["type"] as? String == "farewell_drained" })
  }
}
