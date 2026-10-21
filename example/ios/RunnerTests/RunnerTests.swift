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
