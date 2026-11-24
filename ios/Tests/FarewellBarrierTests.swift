// Host-run tests for the plugin's farewell barrier (ported from the Track 21 lab, 28 cases).
// Unit cases use a deterministic FakePlayer. The A-cases run the plugin's REAL PluginFarewellPlayer adapter
// on a real, silent AVAudioEngine on the macOS host: real `.dataPlayedBack`, not iOS device proof.
// Run with ios/Tests/run_host_barrier_tests.sh (copies Classes/ sources into a scratch SwiftPM package).
import AVFoundation
import XCTest
@testable import FarewellBarrier

/// Deterministic player that reproduces the AVAudioPlayerNode semantics measured in the spikes:
/// a `.dataPlayedBack` handler runs when the position passes buffer end + latency, AND ALSO (at the
/// current position) when stop() flushes a buffer that has not played; after stop() the node is not
/// rendering (no render anchor). Host clock: 1 tick per frame, offset by `hostBase` (a restart changes it).
final class FakePlayer: FarewellPlayer {
  var sampleRate: Double = 24_000
  var hostTicksPerSecond: Double { sampleRate }
  var pos: Int64? = 0 { didSet { if let pos { lastPos = pos } } }
  /// The host clock follows the timeline's last rendered position (frozen anchors model render stalls).
  private(set) var lastPos: Int64 = 0
  func hostNow() -> UInt64 { host(lastPos) }
  var renderAhead: Int64? = 0
  func renderAheadFrames() -> Int64? { renderAhead }
  var hostBase: UInt64 = 10_000_000
  var latency: Int64 = 528
  var scheduled: [(start: Int64, end: Int64, cb: (UInt64) -> Void, fired: Bool)] = []
  var legacy: [Data] = []
  var stops = 0
  var naturallyPlayed: Set<Int> = []        // ground truth: buffer indices whose end + latency was really reached
  var flushed: Set<Int> = []                // buffers removed by stop() before they played to their end
  /// Render-lifetime generation: advanced BEFORE every stop/restart/pause/resume, as the plugin's fence does.
  var generation = 0
  /// Runs inside renderAnchor() (models a restart racing the barrier's anchor read).
  var onAnchorRead: (() -> Void)?
  func renderGeneration() -> Int { generation }
  /// Runs just before the barrier's atomic drained check (models a stop/restart racing the emission).
  var onEmitCheck: (() -> Void)?
  /// Runs right after a buffer is accepted by schedule() (models rendering overtaking a late submission).
  var onSchedule: ((Int64) -> Void)?
  func whileRenderGeneration(_ g: Int, _ body: () -> Void) -> Bool {
    onEmitCheck?()
    guard g == generation else { return false }
    body(); return true
  }
  /// Flush handlers held back by stopDeferringCallbacks() (models late delivery after a restart).
  var deferred: [(UInt64) -> Void] = []
  func host(_ p: Int64) -> UInt64 { UInt64(Int64(hostBase) + p) }
  func currentSampleTime() -> Int64? { pos }
  /// When set, the render clock is frozen at this anchor (rendering stalled) while the host clock moves on.
  var frozenAnchor: (sampleTime: Int64, hostTime: UInt64)?
  /// When true, the node reports a playhead but no valid render timestamp pair (host time invalid).
  var anchorUnavailable = false
  func renderAnchor() -> (sampleTime: Int64, hostTime: UInt64)? {
    onAnchorRead?()
    if anchorUnavailable { return nil }
    return frozenAnchor ?? pos.map { ($0, host($0)) }
  }
  func presentationLatencyFrames() -> Int64 { latency }
  func schedule(pcm16: Data, atSampleTime: Int64, onPlayedBack: @escaping (UInt64) -> Void) -> Bool {
    scheduled.append((atSampleTime, atSampleTime + Int64(pcm16.count / 2), onPlayedBack, false))
    onSchedule?(atSampleTime)
    return true
  }
  func scheduleLegacy(pcm16: Data) { legacy.append(pcm16) }
  /// Models AVAudioPlayerNode.pause(): playerTime is nil while the timeline stays parked; play() resumes there.
  var parkedAt: Int64?
  func pause() { generation += 1; parkedAt = pos; pos = nil }
  func ensurePlaying() { if pos == nil, let p = parkedAt { generation += 1; pos = p; parkedAt = nil } }
  /// stop() whose flush handlers are delivered later (see fireDeferred()).
  func stopDeferringCallbacks() {
    generation += 1; stops += 1
    for i in scheduled.indices where !scheduled[i].fired { scheduled[i].fired = true; flushed.insert(i); deferred.append(scheduled[i].cb) }
    pos = nil
  }
  func fireDeferred() { let h = host(pos ?? 0); let d = deferred; deferred = []; d.forEach { $0(h) } }
  func stop() {
    generation += 1
    stops += 1
    let h = host(pos ?? 0)
    for i in scheduled.indices where !scheduled[i].fired {
      scheduled[i].fired = true; flushed.insert(i); scheduled[i].cb(h)
    }
    pos = nil                               // a stopped node has no render time
  }
  /// play() after stop(): a NEW player timeline that starts at 0, `gapFrames` of host time after the stop.
  func restart(stoppedAt: Int64, gapFrames: Int64) {
    generation += 1
    hostBase = UInt64(Int64(hostBase) + stoppedAt + gapFrames)
    pos = 0
  }
  /// Advance the timeline and fire handlers of buffers whose end + latency has been reached.
  func advance(to p: Int64) {
    // Ground truth first: a retry on the barrier queue may read the new position as soon as it is set.
    for i in scheduled.indices where !flushed.contains(i) && p >= scheduled[i].end + latency { naturallyPlayed.insert(i) }
    pos = p
    for i in scheduled.indices where !flushed.contains(i) && p >= scheduled[i].end + latency && !scheduled[i].fired {
      scheduled[i].fired = true; scheduled[i].cb(host(p))
    }
  }
}

final class FarewellBarrierUnitTests: XCTestCase {
  var player: FakePlayer!
  var events: [FarewellBarrierEvent] = []
  var barrier: FarewellPlaybackBarrier!
  let q = DispatchQueue(label: "t")
  var clock: Int64 = 1_700_000_000_000

  override func setUp() {
    player = FakePlayer(); events = []
    // minimumTimelineFrames 0: these cases start the fake timeline at 0; the young-timeline guard has its own cases.
    barrier = FarewellPlaybackBarrier(player: player, leadFrames: 2400, minimumTimelineFrames: 0,
                                      nowMs: { [unowned self] in self.clock }, queue: q) { [unowned self] in self.events.append($0) }
  }
  func pcm(_ frames: Int) -> Data { Data(count: frames * 2) }
  /// The plugin accounts legacy audio in the barrier, then schedules it itself (append semantics).
  func pushLegacy(_ data: Data) { barrier.noteLegacyScheduled(frames: Int64(data.count / 2)); player.scheduleLegacy(pcm16: data) }
  func flush() { q.sync {} ; q.sync {} }
  func playTurn(_ chunks: [Int], id: String = "fw_T", gen: Int = 11) {
    barrier.begin(turnId: id, nativeGeneration: gen)
    for (i, n) in chunks.enumerated() { XCTAssertTrue(barrier.push(turnId: id, seq: i, pcm16: pcm(n))) }
    barrier.end(turnId: id, totalChunks: chunks.count, totalFrames: Int64(chunks.reduce(0, +)))
  }

  func testI1_drainsOnlyAfterFinalBufferPositionPassesEndPlusLatency() {
    playTurn([240, 480, 120])            // starts at 2400 (lead); ends at 3240
    player.advance(to: 3240 + 527); flush()
    XCTAssertTrue(events.isEmpty, "one frame short of end+latency: not drained")
    clock = 1_700_000_001_234
    player.advance(to: 3240 + 528); flush()
    XCTAssertEqual(events, [.drained(turnId: "fw_T", nativeGeneration: 11, drainedAtEpochMs: 1_700_000_001_234, framesPlayed: 840, lastSeq: 2, evidence: "ios_dataPlayedBack+position")])
    XCTAssertEqual(player.scheduled.map { $0.start }, [2400, 2640, 3120], "explicit contiguous sample times")
  }

  func testI2_stopFlushInvokesPlayedBackButIsRejected() {
    playTurn([24_000])                   // 1 s farewell
    player.advance(to: 9_000)            // part-way
    player.stop(); settle()              // AVAudioPlayerNode runs the .dataPlayedBack handler on flush
    XCTAssertEqual(events.count, 1)
    guard case .unverified(_, _, let reason) = events[0] else { return XCTFail("expected unverified") }
    // Group A: stop() advances the render-lifetime generation before it flushes, so the flush is judged stale-lifetime.
    XCTAssertEqual(reason, "render_lifetime_changed", "stopped node: fail closed")
  }

  func testI3_cancelBumpsEpochSoFlushedCallbacksAreStale() {
    playTurn([24_000])
    player.advance(to: 9_000)
    barrier.cancel(turnId: "fw_T", reason: "user_stop"); flush()
    XCTAssertEqual(events, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: "user_stop")])
    XCTAssertGreaterThanOrEqual(barrier.staleCallbacks, 1, "the flush callback arrived after the epoch bump and was ignored")
  }

  func testI4_routeChangeInterruptionResetInvalidateMidTurn() {
    for reason in ["route_changed", "interrupted", "media_services_reset", "engine_configuration_change"] {
      setUp(); playTurn([4800]); player.advance(to: 3000)
      barrier.invalidate(reason: reason); flush()
      player.advance(to: 100_000); flush()
      XCTAssertEqual(events, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: reason)], reason)
    }
  }

  func testI5_bufferReplacementByNewTurnNeverDrainsTheOldOne() {
    barrier.begin(turnId: "fw_A", nativeGeneration: 11)
    barrier.push(turnId: "fw_A", seq: 0, pcm16: pcm(4800))
    barrier.begin(turnId: "fw_B", nativeGeneration: 12); flush()
    XCTAssertEqual(events.first, .unverified(turnId: "fw_A", nativeGeneration: 11, reason: "replaced"))
    barrier.push(turnId: "fw_A", seq: 1, pcm16: pcm(480))   // stale producer
    XCTAssertFalse(events.contains { if case .drained(let t, _, _, _, _, _) = $0 { return t == "fw_A" }; return false })
  }

  func testI6_sequenceAndTotalsValidation() {
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)
    XCTAssertTrue(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    XCTAssertFalse(barrier.push(turnId: "fw_T", seq: 2, pcm16: pcm(480)))
    XCTAssertEqual(events, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: "missing_seq")])
    setUp(); barrier.begin(turnId: "fw_T", nativeGeneration: 11); barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480))
    barrier.end(turnId: "fw_T", totalChunks: 1, totalFrames: 481)
    XCTAssertEqual(events, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: "end_totals_mismatch")])
    setUp(); barrier.begin(turnId: "fw_T", nativeGeneration: 11)
    barrier.end(turnId: "fw_T", totalChunks: 0, totalFrames: 0)
    XCTAssertEqual(events, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: "end_totals_mismatch")], "zero-chunk farewell never drains")
  }

  func testI7_finalCallbackBeforeEndStillRequiresEnd() {
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)
    barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480))
    player.advance(to: 100_000); flush()
    XCTAssertTrue(events.isEmpty, "no END yet: not final")
    barrier.end(turnId: "fw_T", totalChunks: 1, totalFrames: 480); flush()
    guard case .drained = events.first else { return XCTFail("expected drained after END") }
  }

  func testI8_noPositionEvidenceIsUnverified() {
    playTurn([480])
    player.pos = nil                                   // node not rendering when the barrier judges it
    player.scheduled[0].fired = true; player.scheduled[0].cb(player.host(5000)); settle()
    XCTAssertEqual(events, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: "played_back_without_position")],
                   "a missing anchor is retried for a bounded time only, then fails closed")
  }

  func testI23_cancelArrivingBeforeItsBeginStillCancelsTheTurn() {
    // Review 1a798d2c HIGH-1 (iOS analogue): farewellBegin hops through the session queue, farewellCancel does
    // not, so the cancel can reach the barrier first. It must still win.
    barrier.cancel(turnId: "fw_T", reason: "cancelled")
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)
    _ = barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480))
    barrier.end(turnId: "fw_T", totalChunks: 1, totalFrames: 480)
    player.advance(to: 100_000); flush()
    XCTAssertEqual(events, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: "cancelled")])
    events = []
    playTurn([480], id: "fw_U")
    player.advance(to: 200_000); flush()
    guard case .drained(let id, _, _, _, _, _) = events.first else { return XCTFail("expected drained, got \(events)") }
    XCTAssertEqual(id, "fw_U")
  }

  /// Lets queued anchor retries run (the barrier retries for up to ~200 ms, then fails closed).
  func settle() { for _ in 0..<100 { RunLoop.current.run(until: Date().addingTimeInterval(0.005)); flush() } }
  func isDrained(_ e: FarewellBarrierEvent) -> Bool { if case .drained = e { return true }; return false }
  func unverifiedReason() -> String? {
    guard events.count == 1, case .unverified(_, _, let r) = events[0] else { return nil }
    return r
  }

  // MARK: Group A playback-lifetime continuity (16 Nov 2026)

  func testI26_transientMissingAnchorRecoversOnTheSameContinuousTimeline() {
    playTurn([480])                        // 2400 ..< 2880, required 3408
    player.pos = nil                       // anchor momentarily missing when the barrier judges the callback
    player.scheduled[0].fired = true
    player.scheduled[0].cb(player.host(3500))
    flush()
    XCTAssertTrue(events.isEmpty, "a missing anchor never asserts completion by itself")
    player.pos = 3600                      // same timeline (host(p) = base + p): continuity holds
    settle()
    XCTAssertEqual(events, [.drained(turnId: "fw_T", nativeGeneration: 11, drainedAtEpochMs: clock, framesPlayed: 480,
                                     lastSeq: 0, evidence: "ios_dataPlayedBack+position")])
  }

  func testI27_permanentlyMissingAnchorFailsClosedAfterBoundedRetry() {
    playTurn([480])
    player.pos = nil
    player.scheduled[0].fired = true
    player.scheduled[0].cb(player.host(9000))
    settle()
    XCTAssertEqual(events, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: "played_back_without_position")])
  }

  func testI28_callbackSlightlyBeforeEndDrainsOnlyOnceTheContinuousTimelinePassesTheEnd() {
    // Measured on the iOS 26.5 simulator: .dataPlayedBack ran ~56 frames before the reconstructed end + latency.
    playTurn([480])                        // required 3408
    player.pos = 3408 - 56
    player.scheduled[0].fired = true
    player.scheduled[0].cb(player.host(3408 - 56))
    flush()
    XCTAssertTrue(events.isEmpty, "not yet: the timeline has not been seen past end + latency")
    player.pos = 3408 - 1; flush(); RunLoop.current.run(until: Date().addingTimeInterval(0.02)); flush()
    XCTAssertTrue(events.isEmpty, "one frame short is still not proof")
    player.pos = 3408
    settle()
    guard events.count == 1, isDrained(events[0]) else { return XCTFail("expected drained, got \(events)") }
  }

  func testI28b_earlyCallbackWhoseTimelineNeverReachesTheEndFailsClosed() {
    playTurn([480])
    player.frozenAnchor = (3408 - 56, player.host(3408 - 56))   // rendering stalls just short of the end
    player.scheduled[0].fired = true
    player.scheduled[0].cb(player.host(3408 - 56))
    settle()
    XCTAssertEqual(unverifiedReason(), "played_back_before_end_frame(pos=3352 < 3408)")
  }

  func testI29_stopRestartDuringMissingAnchorMustNeverMintDrain() {
    // Adversarial (Group A lab, review AMEND): a stop() flush callback, then an anchor from another render
    // lifetime whose host/sample mapping makes the callback instant look past the end.
    playTurn([480])
    player.pos = 1000
    player.stop()                          // flush callback at host(1000); no anchor afterwards
    flush()
    player.hostBase -= 5000                // a different host/sample mapping
    player.pos = 6000                      // maps to the SAME host instant as the callback
    settle()
    XCTAssertFalse(events.contains(where: isDrained), "a restarted render lifetime can never verify a flush")
    XCTAssertEqual(unverifiedReason(), "render_lifetime_changed", "\(events)")
  }

  func testI29b_unannouncedRemapDuringMissingAnchorIsADiscontinuity() {
    // The same adversarial mapping with NO announced lifetime change: timing continuity (d) must still reject it.
    playTurn([480])
    player.pos = 1000
    let hostAtFlush = player.host(1000)
    player.pos = nil                       // not rendering BEFORE the handler is judged (no race with the queue)
    player.scheduled[0].fired = true; player.scheduled[0].cb(hostAtFlush); flush()
    player.hostBase -= 5000
    player.pos = 6000
    settle()
    XCTAssertFalse(events.contains(where: isDrained))
    XCTAssertTrue(unverifiedReason()?.hasPrefix("render_discontinuity") == true, "\(events)")
  }

  func testI30_cancelDuringMissingAnchorRetryNeverDrains() {
    playTurn([480])
    player.pos = nil
    player.scheduled[0].fired = true
    player.scheduled[0].cb(player.host(9000))
    flush()
    barrier.cancel(turnId: "fw_T", reason: "user_done")
    player.pos = 9100
    settle()
    XCTAssertEqual(events, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: "user_done")])
  }

  func testI31_realStopThenRestartedTimelineNeverVerifiesTheFlushedBuffer() {
    // The physical case: stop() flushes 20 ms before the end, play() starts a new timeline at 0 right after,
    // and that new timeline runs far past the old end frame before the anchor is read.
    playTurn([4800])                       // 2400 ..< 7200, required 7728
    player.advance(to: 7728 - 480)
    player.stop()
    player.restart(stoppedAt: 7728 - 480, gapFrames: 24)
    player.advance(to: 20_000)
    settle()
    XCTAssertFalse(events.contains(where: isDrained), "\(events)")
    XCTAssertEqual(unverifiedReason(), "render_lifetime_changed", "\(events)")
  }

  func testI38_lateFlushHandlerAfterRestartOnAYoungTimelineNeverDrains() {
    // Review r1 F1: A0 at sample 0; flushed at sample 100 before playback; a new empty timeline starts 24 frames later
    // and reaches 3500 BEFORE the flush handler is delivered; handler host time == the later anchor's host time.
    playTurn([480])                        // required 3408
    player.advance(to: 100)
    player.stopDeferringCallbacks()
    player.restart(stoppedAt: 100, gapFrames: 24)
    player.advance(to: 3500)
    player.fireDeferred()
    settle()
    XCTAssertFalse(events.contains(where: isDrained), "\(events)")
    XCTAssertEqual(unverifiedReason(), "render_lifetime_changed")
    XCTAssertEqual(player.naturallyPlayed, [], "ground truth: nothing played")
  }

  func testI39_announcedShortPauseDuringTheTurnNeverDrains() {
    // Review r1 F2: pause at 1000, resume 400 frames of host time later, then the timeline passes the end.
    playTurn([480])
    player.advance(to: 1000)
    player.pause()
    player.hostBase += 400
    player.ensurePlaying()
    player.advance(to: 3408 + 10)
    settle()
    XCTAssertFalse(events.contains(where: isDrained), "\(events)")
    XCTAssertEqual(unverifiedReason(), "render_lifetime_changed")
  }

  func testI40_unannouncedEightMillisecondShiftIsADiscontinuity() {
    playTurn([480])
    player.hostBase += 200                 // 8.3 ms that no code path announced: > 96-frame tolerance
    player.advance(to: 3408 + 10)
    settle()
    XCTAssertTrue(unverifiedReason()?.hasPrefix("render_discontinuity") == true, "\(events)")
  }

  func testI41_lifetimeChangeDuringTheJudgingAnchorReadFailsClosed() {
    playTurn([480])
    player.onAnchorRead = { [unowned self] in self.player.generation += 1 }   // restart races the read
    player.advance(to: 3408 + 10)
    settle()
    XCTAssertEqual(unverifiedReason(), "render_lifetime_changed")
  }

  func testI42_lifetimeChangeDuringTheSchedulingAnchorReadFailsClosed() {
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)
    player.onAnchorRead = { [unowned self] in self.player.generation += 1 }
    XCTAssertFalse(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    XCTAssertEqual(unverifiedReason(), "render_lifetime_changed_at_schedule")
    XCTAssertTrue(player.scheduled.isEmpty)
  }

  func testI32_unannouncedStallBetweenScheduleAndJudgementIsADiscontinuity() {
    playTurn([480])                        // anchor at scheduling: (0, host(0))
    player.hostBase += 2400                // rendering stalled 100 ms of host time without any announced change
    player.advance(to: 3408 + 10)          // the buffer's callback fires on the resumed timeline
    settle()
    XCTAssertTrue(unverifiedReason()?.hasPrefix("render_discontinuity") == true, "\(events)")
  }

  func testI33_continuityToleratesRenderJitterWithinBound() {
    playTurn([480])
    player.hostBase += 60                  // < 96-frame tolerance: render quantisation / clock drift
    player.advance(to: 3408 + 10)
    settle()
    guard events.count == 1, isDrained(events[0]) else { return XCTFail("expected drained, got \(events)") }
  }

  func testI34_noRenderAnchorAtSchedulingFailsClosed() {
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)
    player.anchorUnavailable = true        // playhead known, render timestamp pair not valid
    XCTAssertFalse(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    XCTAssertEqual(events, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: "render_anchor_unavailable_at_schedule")])
    XCTAssertTrue(player.scheduled.isEmpty)
  }

  func testI35_callbackFarBeforeTheEndIsRejectedImmediatelyEvenIfTheTimelineLaterPassesIt() {
    playTurn([480])                        // required 3408; slack 960
    player.pos = 3408 - 961
    player.scheduled[0].fired = true
    player.scheduled[0].cb(player.host(3408 - 961))
    player.pos = 50_000                    // continuous timeline far past the end
    settle()
    XCTAssertEqual(unverifiedReason(), "played_back_before_end_frame(pos=2447 < 3408)")
  }

  func testI37_duplicateCallbackOfAVerifiedBufferCannotUnverifyIt() {
    playTurn([480, 480])                   // seq 0: 2400..2880, seq 1: 2880..3360
    player.advance(to: 2880 + 528)         // seq 0 verified on the continuous timeline
    flush()
    player.hostBase += 10_000              // later discontinuity; a re-delivered seq 0 handler must be ignored
    player.scheduled[0].cb(player.host(2880 + 528)); settle()
    XCTAssertTrue(events.isEmpty, "\(events)")
    XCTAssertGreaterThanOrEqual(barrier.staleCallbacks, 1)
  }

  func testI43_pauseBetweenChunksFailsTheWholeTurn() {
    // Review r2 F2: chunk 0 verified, then an announced pause/resume, then chunk 1 is pushed and plays.
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)
    XCTAssertTrue(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    player.advance(to: 2880 + 528); flush()
    player.pause(); player.ensurePlaying()
    XCTAssertFalse(barrier.push(turnId: "fw_T", seq: 1, pcm16: pcm(480)))
    barrier.end(turnId: "fw_T", totalChunks: 2, totalFrames: 960)
    player.advance(to: 20_000); settle()
    XCTAssertEqual(unverifiedReason(), "render_lifetime_changed")
  }

  func testI44_stopAfterTheAudioPlayedButBeforeEndNeverDrains() {
    // Review r2 F2: the sole chunk is verified, the player is stopped, THEN END arrives.
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)
    XCTAssertTrue(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    player.advance(to: 2880 + 528); flush()
    player.stop(); flush()
    barrier.end(turnId: "fw_T", totalChunks: 1, totalFrames: 480); settle()
    XCTAssertEqual(unverifiedReason(), "render_lifetime_changed")
  }

  func testI45_lifetimeChangeRacingTheDrainedEmissionFailsClosed() {
    playTurn([480])
    player.onEmitCheck = { [unowned self] in self.player.generation += 1 }
    player.advance(to: 3408); settle()
    XCTAssertEqual(unverifiedReason(), "render_lifetime_changed")
  }

  func testI46_unannouncedRestartOfAYoungTimelineCannotEvenSchedule() {
    // Review r2 F1 model with the production young-timeline guard: the scheduling anchor would be 10 frames old.
    let p = FakePlayer(); p.pos = 10
    var evs: [FarewellBarrierEvent] = []
    let b = FarewellPlaybackBarrier(player: p, leadFrames: 2400, nowMs: { 1 }, queue: q) { evs.append($0) }
    b.begin(turnId: "fw_T", nativeGeneration: 11)
    XCTAssertFalse(b.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    XCTAssertEqual(evs, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: "render_timeline_too_young")])
  }

  func testI47_unannouncedRestartAfterAMatureScheduleIsADiscontinuity() {
    // Review r2 F1 model: the system flushes and restarts the timeline WITHOUT any fence advance; the flush handler
    // arrives late, on the new timeline, after it ran past the old end frame. The 960-frame-old schedule anchor makes
    // the restart's offset shift >= 960 frames, beyond the 96-frame tolerance.
    let p = FakePlayer(); p.pos = 960
    var evs: [FarewellBarrierEvent] = []
    let b = FarewellPlaybackBarrier(player: p, leadFrames: 2400, nowMs: { 1 }, queue: q) { evs.append($0) }
    b.begin(turnId: "fw_T", nativeGeneration: 11)
    XCTAssertTrue(b.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))     // 3360 ..< 3840, required 4368
    b.end(turnId: "fw_T", totalChunks: 1, totalFrames: 480)
    p.advance(to: 1000)
    let cb = p.scheduled[0].cb; p.scheduled[0].fired = true; p.flushed.insert(0)   // unannounced flush, handler held
    p.hostBase = UInt64(Int64(p.hostBase) + 1000 + 24); p.pos = 0                 // unannounced restart: generation unchanged
    p.advance(to: 6000)
    cb(p.host(6000))
    for _ in 0..<100 { RunLoop.current.run(until: Date().addingTimeInterval(0.005)); q.sync {} }
    XCTAssertFalse(evs.contains { if case .drained = $0 { return true }; return false }, "\(evs)")
    guard evs.count == 1, case .unverified(_, _, let r) = evs[0] else { return XCTFail("\(evs)") }
    XCTAssertTrue(r.hasPrefix("render_discontinuity"), r)
  }

  func testI48_aTimelineExactlyOldEnoughStillDrains() {
    let p = FakePlayer(); p.pos = 960
    var evs: [FarewellBarrierEvent] = []
    let b = FarewellPlaybackBarrier(player: p, leadFrames: 2400, nowMs: { 1 }, queue: q) { evs.append($0) }
    b.begin(turnId: "fw_T", nativeGeneration: 11)
    XCTAssertTrue(b.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    b.end(turnId: "fw_T", totalChunks: 1, totalFrames: 480)
    p.advance(to: 4368); q.sync {}; q.sync {}
    guard case .drained? = evs.first else { return XCTFail("\(evs)") }
  }

  func testI49_unannouncedRestartAfterALongIntervalCannotHideInTheDriftAllowance() {
    // Review r3 F1: a 5,000,000-frame buffer at A0=960; unannounced flush at 1000, restart 24 frames later, the late
    // handler arrives once the NEW timeline reached 5,005,000. Deviation 1024 < the old unbounded drift allowance.
    let p = FakePlayer(); p.pos = 960
    var evs: [FarewellBarrierEvent] = []
    let b = FarewellPlaybackBarrier(player: p, leadFrames: 2400, nowMs: { 1 }, queue: q) { evs.append($0) }
    b.begin(turnId: "fw_T", nativeGeneration: 11)
    XCTAssertTrue(b.push(turnId: "fw_T", seq: 0, pcm16: Data(count: 2 * 5_000_000)))
    b.end(turnId: "fw_T", totalChunks: 1, totalFrames: 5_000_000)
    p.advance(to: 1000)
    let cb = p.scheduled[0].cb; p.scheduled[0].fired = true; p.flushed.insert(0)
    p.hostBase = UInt64(Int64(p.hostBase) + 1000 + 24); p.pos = 0       // unannounced restart
    p.advance(to: 5_005_000)
    cb(p.host(5_005_000))
    for _ in 0..<100 { RunLoop.current.run(until: Date().addingTimeInterval(0.005)); q.sync {} }
    XCTAssertFalse(evs.contains { if case .drained = $0 { return true }; return false }, "\(evs)")
    guard evs.count == 1, case .unverified(_, _, let r) = evs[0] else { return XCTFail("\(evs)") }
    XCTAssertEqual(r, "render_continuity_window_exceeded")
  }

  func testI50_aLongButUninterruptedFarewellWithinTheWindowStillDrains() {
    let p = FakePlayer(); p.pos = 960
    var evs: [FarewellBarrierEvent] = []
    let b = FarewellPlaybackBarrier(player: p, leadFrames: 2400, nowMs: { 1 }, queue: q) { evs.append($0) }
    b.begin(turnId: "fw_T", nativeGeneration: 11)
    XCTAssertTrue(b.push(turnId: "fw_T", seq: 0, pcm16: Data(count: 2 * 1_200_000)))   // 50 s
    b.end(turnId: "fw_T", totalChunks: 1, totalFrames: 1_200_000)
    p.hostBase += 200                      // 200 frames over 50 s (~167 ppm): inside 96 frames + 200 ppm
    p.advance(to: 3360 + 1_200_000 + 528); q.sync {}; q.sync {}
    guard case .drained? = evs.first else { return XCTFail("\(evs)") }
  }

  func testI51_unannouncedShortStallOfTheSameTimelineIsToleratedOnlyWithinTheBound() {
    // Review r3 F2 (declined, documented): a stall that resumes the SAME timeline discards no audio. Within 96 frames
    // it is jitter; beyond it the barrier fails closed.
    playTurn([480]); player.hostBase += 40; player.advance(to: 3408); settle()
    guard events.count == 1, isDrained(events[0]) else { return XCTFail("40-frame stall: \(events)") }
    setUp()
    playTurn([480]); player.hostBase += 120; player.advance(to: 3408); settle()
    XCTAssertTrue(unverifiedReason()?.hasPrefix("render_discontinuity") == true, "120-frame stall: \(events)")
  }

  /// Unannounced (no generation advance) stop + restart of the fake timeline: a new timeline at 0, `gap` frames later.
  func unannouncedRestart(_ p: FakePlayer, gap: Int64 = 24) {
    let at = p.pos ?? 0
    for i in p.scheduled.indices where !p.scheduled[i].fired { p.flushed.insert(i) }
    p.hostBase = UInt64(Int64(p.hostBase) + at + gap); p.pos = 0
  }

  func testI52_unannouncedRestartBetweenChunksFailsTheTurn() {
    // Review r4 F1: chunk 0 plays and verifies; unannounced restart; the new timeline reaches 960; chunk 1 is pushed.
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)
    XCTAssertTrue(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(240)))
    player.advance(to: 2640 + 528); flush()
    unannouncedRestart(player)
    player.advance(to: 960)
    XCTAssertFalse(barrier.push(turnId: "fw_T", seq: 1, pcm16: pcm(240)))
    XCTAssertTrue(unverifiedReason()?.hasPrefix("render_discontinuity") == true, "\(events)")
  }

  func testI53_unannouncedRestartAfterVerificationButBeforeEndNeverDrains() {
    // Review r4 F2: the sole chunk plays and verifies, an unannounced restart follows, then END arrives.
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)
    XCTAssertTrue(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(240)))
    player.advance(to: 2640 + 528); flush()
    unannouncedRestart(player)
    player.advance(to: 5000)
    barrier.end(turnId: "fw_T", totalChunks: 1, totalFrames: 240); settle()
    XCTAssertFalse(events.contains(where: isDrained), "\(events)")
    XCTAssertTrue(unverifiedReason()?.hasPrefix("render_discontinuity") == true, "\(events)")
  }

  func testI54_unannouncedRestartBeforeTheFirstPushFailsTheTurn() {
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)
    player.advance(to: 500)
    unannouncedRestart(player)
    player.advance(to: 960)
    XCTAssertFalse(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(240)))
    XCTAssertTrue(unverifiedReason()?.hasPrefix("render_discontinuity") == true, "\(events)")
  }

  func testI55_finalAnchorMissingAtEndIsRetriedThenDrainsOnTheSameTimeline() {
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)
    XCTAssertTrue(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(240)))
    player.advance(to: 2640 + 528); flush()
    player.anchorUnavailable = true
    barrier.end(turnId: "fw_T", totalChunks: 1, totalFrames: 240); flush()
    XCTAssertTrue(events.isEmpty, "no final anchor yet: not drained")
    player.anchorUnavailable = false; player.advance(to: 4000)
    settle()
    guard events.count == 1, isDrained(events[0]) else { return XCTFail("\(events)") }
  }

  func testI56_finalAnchorPermanentlyMissingFailsClosed() {
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)
    XCTAssertTrue(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(240)))
    player.advance(to: 2640 + 528); flush()
    player.anchorUnavailable = true
    barrier.end(turnId: "fw_T", totalChunks: 1, totalFrames: 240); settle()
    XCTAssertEqual(unverifiedReason(), "final_render_anchor_unavailable")
  }

  func testI57_aQueuedFinalCheckNeverFinalisesALaterTurn() {
    barrier.begin(turnId: "fw_A", nativeGeneration: 11)
    XCTAssertTrue(barrier.push(turnId: "fw_A", seq: 0, pcm16: pcm(240)))
    player.advance(to: 2640 + 528); flush()
    player.anchorUnavailable = true
    barrier.end(turnId: "fw_A", totalChunks: 1, totalFrames: 240); flush()     // final check queued for retry
    player.anchorUnavailable = false
    barrier.begin(turnId: "fw_B", nativeGeneration: 12)                         // replaces A
    settle()
    XCTAssertEqual(events.first, .unverified(turnId: "fw_A", nativeGeneration: 11, reason: "replaced"))
    XCTAssertFalse(events.contains { if case .drained(let id, _, _, _, _, _) = $0 { return id == "fw_B" }; return false })
  }

  func testI58_beginTimingOutOnAYoungPlayheadFailsClosed() {
    // Review r5 F1 probe 1: the bounded wait times out at sample 10.
    let p = FakePlayer(); p.pos = 10
    var evs: [FarewellBarrierEvent] = []
    let b = FarewellPlaybackBarrier(player: p, leadFrames: 2400, playheadWaitMs: 4, nowMs: { 1 }, queue: q) { evs.append($0) }
    b.begin(turnId: "fw_T", nativeGeneration: 11)
    XCTAssertEqual(evs, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: "render_timeline_too_young")])
    XCTAssertFalse(b.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    XCTAssertTrue(p.scheduled.isEmpty)
  }

  func testI59_aYoungReplacementTimelineAtTheBeginReadFailsClosed() {
    // Review r5 F1 probe 2: an unannounced restart right before begin's anchor read leaves a young (10-frame) timeline.
    let p = FakePlayer(); p.pos = 960
    var evs: [FarewellBarrierEvent] = []
    let b = FarewellPlaybackBarrier(player: p, leadFrames: 2400, nowMs: { 1 }, queue: q) { evs.append($0) }
    var once = true
    p.onAnchorRead = { if once { once = false; p.hostBase = UInt64(Int64(p.hostBase) + 960 + 24); p.pos = 10 } }
    b.begin(turnId: "fw_T", nativeGeneration: 11)
    XCTAssertEqual(evs, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: "render_timeline_too_young")])
  }

  func testI60_theTurnIsBoundToTheTimelineOfItsSingleBeginRead() {
    // Review r6 F1: an unannounced restart lands just before begin's anchor read and the replacement timeline is
    // already mature (2000). begin derives the start frame from THAT anchor, never from an earlier read, so every frame
    // of the turn is scheduled on, judged on and emitted from the one timeline the turn began on.
    let p = FakePlayer(); p.pos = 960
    var evs: [FarewellBarrierEvent] = []
    let b = FarewellPlaybackBarrier(player: p, leadFrames: 2400, nowMs: { 1 }, queue: q) { evs.append($0) }
    var once = true
    p.onAnchorRead = { if once { once = false; p.hostBase = UInt64(Int64(p.hostBase) + 960 + 24 - 2000); p.pos = 2000 } }
    b.begin(turnId: "fw_T", nativeGeneration: 11)
    XCTAssertTrue(b.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    XCTAssertEqual(p.scheduled[0].start, 2000 + 2400, "start derived from the begin anchor's own timeline")
    b.end(turnId: "fw_T", totalChunks: 1, totalFrames: 480)
    p.advance(to: 4400 + 480 + 528); q.sync {}; q.sync {}
    guard case .drained? = evs.first else { return XCTFail("\(evs)") }
    XCTAssertEqual(p.naturallyPlayed, [0])
  }

  func testI61_cancelReturningWhileTheFinalCheckRunsNeverDrains() {
    // Review r7 F1: cancel() is called (and returns) at the entry of the final drained check.
    playTurn([480])
    var cancelReturned = false
    player.onEmitCheck = { [unowned self] in
      if !cancelReturned { self.barrier.cancel(turnId: "fw_T", reason: "user_done"); cancelReturned = true }
    }
    player.advance(to: 3408); settle()
    XCTAssertTrue(cancelReturned)
    XCTAssertEqual(events, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: "user_done")])
  }

  func testI62_asyncInvalidationReturningWhileTheFinalCheckRunsNeverDrains() {
    playTurn([480])
    var invalidated = false
    player.onEmitCheck = { [unowned self] in
      if !invalidated { self.barrier.invalidateAsync(reason: "session_stopped"); invalidated = true }
    }
    player.advance(to: 3408); settle()
    XCTAssertEqual(events, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: "session_stopped")])
  }

  func testI63_aSealFromAnEarlierTurnDoesNotBlockALaterTurn() {
    barrier.invalidateAsync(reason: "route_changed"); flush()          // before the turn: no live turn
    barrier.cancel(turnId: "fw_old", reason: "user_done"); flush()
    playTurn([480], id: "fw_new")
    player.advance(to: 3408); settle()
    guard events.count == 1, isDrained(events[0]) else { return XCTFail("\(events)") }
  }

  func testI64_aBufferSubmittedBehindThePlayheadFailsClosed() {
    // Review r8 F2: the barrier thread is delayed between the scheduling read and the submission; rendering has
    // already passed the start frame when the buffer reaches the node.
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)
    player.onSchedule = { [unowned self] start in self.player.pos = start + 10 }
    XCTAssertFalse(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    XCTAssertEqual(unverifiedReason(), "scheduled_behind_playhead(start=2400 pos=2410)")
    player.onSchedule = nil
    player.advance(to: 10_000); settle()
    XCTAssertEqual(events.count, 1, "no later drain")
  }

  func testI65_noAnchorAfterSubmissionFailsClosed() {
    // Review r9 F1: submission delayed past the start AND no render anchor right after it.
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)
    player.onSchedule = { [unowned self] start in self.player.pos = start + 100; self.player.anchorUnavailable = true }
    XCTAssertFalse(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    XCTAssertEqual(unverifiedReason(), "submission_unverified")
    player.onSchedule = nil; player.anchorUnavailable = false
    player.scheduled[0].fired = true; player.scheduled[0].cb(player.host(2400 + 480 + 528))
    player.advance(to: 10_000); settle()
    XCTAssertEqual(events.count, 1, "no later drain: \(events)")
  }

  func testI66_submissionInsideTheRenderQuantumMarginFailsClosed() {
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)
    player.onSchedule = { [unowned self] start in self.player.pos = start - 100 }   // < leadFrames/4 short of start
    XCTAssertFalse(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    XCTAssertEqual(unverifiedReason(), "scheduled_behind_playhead(start=2400 pos=2300)")
  }

  func testI67_aStaleAnchorAfterSubmissionCannotCertifyALateSubmission() {
    // Review r10 F1: submission happened at 2500 (> start 2400) but lastRenderTime still says 1800.
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)
    player.onSchedule = { [unowned self] start in
      self.player.pos = start + 100
      self.player.frozenAnchor = (start - 600, self.player.host(start - 600))
    }
    XCTAssertFalse(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    XCTAssertEqual(unverifiedReason(), "scheduled_behind_playhead(start=2400 pos=2500)")
  }

  func testI68_renderAheadIsAddedToTheBoundAndReanchorsTheStart() {
    player.renderAhead = 1500                 // e.g. 40 ms latency + two 11 ms I/O buffers at 24 kHz
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)   // start 2400 < 0 + 1500 + 1200: re-anchored
    XCTAssertTrue(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    XCTAssertEqual(player.scheduled[0].start, 1500 + 2400)
    barrier.end(turnId: "fw_T", totalChunks: 1, totalFrames: 480)
    player.advance(to: 3900 + 480 + 528); settle()
    guard events.count == 1, isDrained(events[0]) else { return XCTFail("\(events)") }
  }

  func testI69_renderCommittedBeyondTheAllowanceCannotCertifyASubmission() {
    // Review r11 F1 model: anchor at 0, the graph has committed rendering 3000 frames ahead of it. With an allowance
    // that covers the committed extent the late submission is rejected.
    player.renderAhead = 3000
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)
    player.onSchedule = { [unowned self] _ in self.player.renderAhead = 6000 }   // the graph committed even further
    XCTAssertFalse(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    XCTAssertTrue(unverifiedReason()?.hasPrefix("scheduled_behind_playhead") == true, "\(events)")
  }

  func testI70_unavailableRenderAheadBoundFailsClosed() {
    player.renderAhead = nil
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)
    XCTAssertFalse(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    XCTAssertEqual(unverifiedReason(), "render_ahead_bound_unavailable")
    XCTAssertTrue(player.scheduled.isEmpty)
  }

  func testI36_staleSameTimelineCallbackAfterDrainIsIgnored() {
    playTurn([480]); player.advance(to: 3408); settle()
    XCTAssertEqual(events.count, 1)
    player.scheduled[0].cb(player.host(3408)); settle()
    XCTAssertEqual(events.count, 1, "terminal turn: later callbacks are stale")
  }

  func testI25_manyLaterCancelsNeverEvictAnEarlierOne() {
    barrier.cancel(turnId: "fw_T", reason: "cancelled")
    for i in 0..<40 { barrier.cancel(turnId: "fw_other_\(i)", reason: "cancelled") }
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)
    XCTAssertFalse(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    XCTAssertEqual(events, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: "cancelled")])
  }

  func testI21_staleRenderAnchorIsNeverExtrapolatedIntoADrain() {
    // Review 1a798d2c HIGH-2: rendering stopped at frame 3000; a discard callback arrives 200 ms of host time
    // later. Projecting forward from the frozen anchor would claim frame 7800 >= 7200 + 528. It must not drain.
    playTurn([4800])                       // 2400 ..< 7200
    player.frozenAnchor = (3000, player.host(3000))
    player.scheduled[0].fired = true
    player.scheduled[0].cb(player.host(3000) + 4800); settle()
    XCTAssertEqual(events, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: "render_anchor_stale")])
  }

  func testI24_aShortStallJustBeforeTheEndIsNotProjectedPast() {
    // Review round 2: frozen at 6960 (240 frames short of 7200), a callback 32 ms later must not project to
    // 7728 and drain.
    playTurn([4800])
    player.frozenAnchor = (6960, player.host(6960))
    player.scheduled[0].fired = true
    player.scheduled[0].cb(player.host(6960) + 768); settle()
    XCTAssertEqual(events, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: "render_anchor_stale")])
  }

  func testI22_anOlderAnchorWaitsForRenderingToCatchUpAndThenDrains() {
    playTurn([4800])
    player.frozenAnchor = (7200 + 528 - 240, player.host(7200 + 528 - 240))
    player.scheduled[0].fired = true
    player.scheduled[0].cb(player.host(7200 + 528)); flush()
    XCTAssertTrue(events.isEmpty, "judged only once an anchor at or after the callback exists")
    player.frozenAnchor = nil
    player.pos = 7200 + 528 + 240           // rendering continued past the callback instant
    settle()
    guard case .drained = events.first else { return XCTFail("expected drained, got \(events)") }
  }

  func testI11_positionIsTheOneCapturedAtCallbackTimeNotLater() {
    // Callback fires (flush) while the position is short of the end; by the time the barrier queue runs,
    // the timeline has moved past the end. The barrier must judge the CAPTURED position.
    playTurn([4800])
    player.pos = 3000
    let cb = player.scheduled[0].cb
    player.scheduled[0].fired = true
    q.suspend()
    cb(player.host(3000))          // AVFoundation thread fired at the instant pos=3000
    player.pos = 500_000           // timeline advanced before the hop ran (anchor is now far later)
    q.resume(); flush()
    guard case .unverified(_, _, let reason) = events.first else { return XCTFail("expected unverified") }
    XCTAssertTrue(reason.hasPrefix("played_back_before_end_frame"), reason)
  }

  func testI12_flushCallbackJudgedAfterTimelineRestartIsRejected() {
    // stop() flushed the buffer at pos 3000, then something restarted the node and its timeline (new host
    // base, position back near 0 and then beyond the old end) before the hop ran: extrapolating the anchor
    // back to the callback instant lands BEFORE the end frame, so it is rejected (no later-state acceptance).
    playTurn([4800])
    player.pos = 3000
    let hostAtFlush = player.host(3000)
    q.suspend()
    player.scheduled[0].fired = true; player.scheduled[0].cb(hostAtFlush)
    player.hostBase = hostAtFlush + 100; player.pos = 9000   // restarted 100 ticks later, now at 9000
    q.resume(); flush()
    guard case .unverified(_, _, let reason) = events.first else { return XCTFail("expected unverified, got \(events)") }
    XCTAssertTrue(reason.hasPrefix("played_back_before_end_frame"), reason)
  }

  func testI14_underrunNeverSchedulesABufferBehindThePlayhead() {
    // IOS-3: the producer stalls past the lead; the playhead overtakes nextStart. Scheduling the next buffer at
    // the stale nextStart would put its end frame BEHIND the playhead, so a stop() flush callback would pass
    // the position check. The barrier must re-anchor the start ahead of the playhead.
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)
    XCTAssertTrue(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))   // 2400..2880
    player.advance(to: 20_000); flush()                                     // seq 0 played; long stall
    XCTAssertTrue(barrier.push(turnId: "fw_T", seq: 1, pcm16: pcm(480)))
    XCTAssertGreaterThanOrEqual(player.scheduled[1].start, 20_000 + 2400, "re-anchored ahead of the playhead")
    barrier.end(turnId: "fw_T", totalChunks: 2, totalFrames: 960)
    // Flush callback for seq 1 observed with the pre-stop anchor (the race seen in the I13 fuzz).
    let cb = player.scheduled[1].cb; player.scheduled[1].fired = true
    cb(player.host(20_100)); settle()
    guard case .unverified(_, _, let reason) = events.first else { return XCTFail("expected unverified, got \(events)") }
    // The anchor predates the callback, so it is never projected forward: fails closed either way.
    XCTAssertTrue(reason.hasPrefix("played_back_before_end_frame") || reason == "render_anchor_stale", reason)
  }

  func testI15_nilPlayheadAtScheduleFailsClosed_pausedTimeline() {
    // QA-IOS-1 (Grok R1): underrun advances the timeline, pause() makes playerTime nil while the timeline stays
    // parked high; a push must NOT schedule at the stale nextStart (that buffer would play "in the past" on
    // resume and its .dataPlayedBack would pass the position check).
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)       // start 2400
    player.advance(to: 18_688)                                 // underrun: nothing queued, timeline moves on
    player.pause()
    XCTAssertFalse(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    barrier.end(turnId: "fw_T", totalChunks: 1, totalFrames: 480)
    player.ensurePlaying(); player.advance(to: 40_000); flush()
    // Group A: pause() is an announced render-lifetime change in this fake, so the generation check fails it first.
    XCTAssertEqual(events, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: "render_lifetime_changed")])
    XCTAssertTrue(player.scheduled.isEmpty, "nothing scheduled against an unknown playhead")
  }

  func testI15b_unannouncedNilPlayheadAtScheduleFailsClosed() {
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)
    player.pos = nil                                           // not rendering, nothing announced
    XCTAssertFalse(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    XCTAssertEqual(events, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: "playhead_unavailable_at_schedule")])
    XCTAssertTrue(player.scheduled.isEmpty)
  }

  func testI16_beginOnAPausedParkedTimelineAnchorsAfterResume() {
    player.pos = 30_000; player.pause()
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)        // ensurePlaying resumes at the parked frame
    XCTAssertTrue(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    XCTAssertEqual(player.scheduled[0].start, 30_000 + 2400, "anchored on the resumed timeline, not on 0")
  }

  func testI17_beginWithoutAnyPlayheadFailsClosedAfterBoundedWait() {
    let p = FakePlayer(); p.pos = nil
    var evs: [FarewellBarrierEvent] = []
    let b = FarewellPlaybackBarrier(player: p, leadFrames: 2400, playheadWaitMs: 20, nowMs: { 1 }, queue: q) { evs.append($0) }
    b.begin(turnId: "fw_T", nativeGeneration: 11)
    XCTAssertFalse(b.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    XCTAssertEqual(evs, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: "playhead_unavailable")])
  }

  func testI18_legacyQueuedWhilePlayheadNilIsNotCountedFromZero() {
    // QA-IOS-2 (Grok R2): legacy frames queued while playerTime is nil (paused, parked at 100000) were added to 0;
    // max(playhead, 48000) dropped them and the farewell was anchored INSIDE the queued legacy audio.
    player.pos = 100_000; player.pause()
    pushLegacy(pcm(48_000))                    // 2 s queued while the playhead is unknown
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)       // resumes at the parked 100000
    XCTAssertTrue(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    XCTAssertGreaterThanOrEqual(player.scheduled[0].start, 100_000 + 48_000 + 2400, "after the queued legacy audio")
  }

  func testI19_legacyQueuedAfterBeginWhilePausedIsFoldedAtTheFirstPush() {
    // QA-IOS-3 (Grok R3): begin anchors at 8960+2400; then pause, 2 s of legacy queued with a nil playhead, resume.
    // The first farewell buffer must be scheduled after that legacy span, not at the start chosen before it existed.
    // Group A: an ANNOUNCED pause/resume during the turn now fails it (I19b); the fold is exercised with the playhead
    // momentarily unknown inside the same render lifetime.
    player.pos = 8960
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)                        // start 11360
    player.pos = nil                                                           // playhead unknown, same lifetime
    pushLegacy(pcm(48_000))
    player.pos = 8960
    XCTAssertTrue(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    XCTAssertGreaterThanOrEqual(player.scheduled[0].start, 8960 + 48_000 + 2400, "after the queued legacy audio")
  }

  func testI19b_announcedPauseAfterBeginFailsTheTurnBeforeAnythingIsScheduled() {
    player.pos = 8960
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)
    player.pause()
    pushLegacy(pcm(48_000))
    player.ensurePlaying()
    XCTAssertFalse(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    XCTAssertEqual(events, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: "render_lifetime_changed")])
    XCTAssertTrue(player.scheduled.isEmpty)
  }

  func testI20_legacyAfterTheFirstFarewellBufferFailsTheTurn() {
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)
    XCTAssertTrue(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    pushLegacy(pcm(2400))
    XCTAssertEqual(events, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: "legacy_interleaved")])
  }

  func testI9_callbackAfterResetOrAfterDrainIsIgnored() {
    playTurn([480]); player.advance(to: 100_000); flush()
    XCTAssertEqual(events.count, 1)
    player.scheduled[0].cb(player.host(200_000)); flush()  // duplicate/late native callback
    XCTAssertEqual(events.count, 1)
    XCTAssertGreaterThanOrEqual(barrier.staleCallbacks, 1)
  }

  func testI10_farewellStartsAfterQueuedLegacyAudio() {
    player.pos = 1000
    pushLegacy(pcm(24_000))       // 1 s of ordinary conversation audio queued
    playTurn([480])
    XCTAssertEqual(player.scheduled[0].start, 1000 + 24_000 + 2400, "never overlaps queued legacy audio")
    XCTAssertEqual(player.legacy.count, 1, "legacy path unchanged")
  }
}

/// Seeded randomized stress of the iOS barrier against FakePlayer. SAFETY is checked against the fake's ground
/// truth at emission: a drain is legal only when the timeline truly passed the last buffer's end + latency and
/// nothing disturbed the turn. LIVENESS: an undisturbed turn drains. FUZZ_SEEDS env (default 5000).
final class FarewellBarrierFuzzTests: XCTestCase {
  struct SplitMix { var s: UInt64; mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) } }

  func testI13_seededInterleavingsNeverDrainEarlyOrTwice() {
    let seeds = Int(ProcessInfo.processInfo.environment["FUZZ_SEEDS"] ?? "") ?? 5000
    let base = Int(ProcessInfo.processInfo.environment["FUZZ_BASE"] ?? "") ?? 0
    var drained = 0, unverified = 0
    var keepAlive: [FarewellPlaybackBarrier] = []
    for seed in base..<(base + seeds) {
      var r = SplitMix(s: UInt64(seed))
      let player = FakePlayer()
      // Production young-timeline guard. Most seeds start on a mature timeline; 1 in 4 starts young (review r5).
      player.pos = r.int(4) == 0 ? Int64(r.int(1200)) : 5000
      let q = DispatchQueue(label: "fz")
      var events: [FarewellBarrierEvent] = []
      var disturbed = false
      var lastEndTruth: Int64 = -1
      var ops: [String] = []
      var logRef: () -> [String] = { [] }
      var generationAtBegin = -1
      var unannouncedRestartInTurn = false
      let barrier = FarewellPlaybackBarrier(player: player, leadFrames: 2400, playheadWaitMs: 2, nowMs: { 1 }, queue: q) { e in
        if case .drained = e {
          // Review r2 F2: the whole turn ran in ONE render lifetime (no stop/pause/restart at any point of it).
          XCTAssertEqual(player.generation, generationAtBegin, "seed=\(seed) drained across a render-lifetime change ops=\(ops)")
          // Review r4: nor across an UNANNOUNCED restart at any point of the turn (between chunks, before END).
          XCTAssertFalse(unannouncedRestartInTurn, "seed=\(seed) drained across an unannounced restart ops=\(ops)")
          // Ground truth: EVERY farewell buffer really played past its end + latency (a stop/cancel AFTER that
          // does not un-play it; END may legitimately arrive later than the audio).
          XCTAssertEqual(player.naturallyPlayed, Set(player.scheduled.indices),
                         "seed=\(seed) drained although a buffer did not play to its end ops=\(ops) log=\(logRef())")
          XCTAssertTrue(lastEndTruth >= 0, "seed=\(seed)")
        }
        events.append(e)
      }
      logRef = { barrier.log }
      func settle() { q.sync {}; q.sync {} }
      /// Lets bounded anchor retries finish before the outcome is judged.
      func drainRetries() { for _ in 0..<60 { usleep(5_000); q.sync {} } }
      func legacy(_ d: Data) { barrier.noteLegacyScheduled(frames: Int64(d.count / 2)); player.scheduleLegacy(pcm16: d) }
      if r.int(2) == 0 { legacy(Data(count: 2 * (1 + r.int(4800)))); ops.append("legacy") }
      if (player.pos ?? 0) < 960 { disturbed = true; ops.append("young_start") }   // must fail closed at begin
      barrier.begin(turnId: "fw_T", nativeGeneration: 1)
      generationAtBegin = player.generation
      let n = 1 + r.int(5)
      var seq = 0, frames: Int64 = 0, ended = false
      for _ in 0..<(n + 2 + r.int(12)) {
        let choices = ["advance", "advance", "advance", "advance", "advance", "advance", "stop", "cancel", "invalidate", "dup", "wrong_end", "late_cb", "no_render", "legacy_mid",
                       "restart", "remap", "early_cb", "anchor_gap", "late_flush", "short_pause", "drift", "sys_restart", "sys_restart_long", "sys_restart_any"]
        let op = seq < n && r.int(3) == 0 ? "push" : (seq == n && !ended && r.int(3) == 0 ? "end" : choices[r.int(choices.count)])
        ops.append(op)
        switch op {
        case "push":
          let f = 1 + r.int(1200)
          if barrier.push(turnId: "fw_T", seq: seq, pcm16: Data(count: 2 * f)) { frames += Int64(f); lastEndTruth = player.scheduled.last!.end } else { disturbed = true }
          seq += 1
        case "end": ended = true; barrier.end(turnId: "fw_T", totalChunks: n, totalFrames: frames)
        case "wrong_end": if seq == n && !ended { ended = true; disturbed = true; barrier.end(turnId: "fw_T", totalChunks: n, totalFrames: frames + 1) }
        case "advance": if let p = player.pos { player.advance(to: p + Int64(r.int(3000))) }
        case "stop": if player.pos != nil { disturbed = true; player.stop() }   // external stop flushes, handlers fire
        case "cancel": disturbed = true; barrier.cancel(turnId: "fw_T", reason: "barge_in")
        case "invalidate": disturbed = true; barrier.invalidate(reason: "route_changed")
        case "dup": if seq > 0 { disturbed = true; barrier.push(turnId: "fw_T", seq: seq - 1, pcm16: Data(count: 2)) }
        // Duplicate re-delivery of an ALREADY-fired handler. (An early first firing is what stop() does; that is
        // covered by "stop" and must fail closed.)
        case "late_cb": if let done = player.scheduled.first(where: { $0.fired }) { done.cb(player.host(player.pos ?? 0)) }
        case "no_render": if player.pos != nil, player.scheduled.contains(where: { !$0.fired }) { disturbed = true; player.pos = nil }
        // QA-IOS-3: legacy before the first farewell buffer is folded in; after it, the turn must fail.
        case "legacy_mid": if seq > 0 { disturbed = true }; legacy(Data(count: 2 * (1 + r.int(2400))))
        // Group A: stop() flush followed by play() on a new timeline that then runs on.
        case "restart": if let p = player.pos { disturbed = true; player.stop(); player.restart(stoppedAt: p, gapFrames: Int64(r.int(200))); player.advance(to: Int64(r.int(30_000))) }
        // Adversarial: an arbitrary new host/sample mapping (another render lifetime), position anywhere.
        case "remap": disturbed = true; if player.scheduled.contains(where: { !$0.fired }) { player.stop() }
                      player.hostBase = UInt64(max(1, Int64(player.hostBase) + Int64(r.int(20_000)) - 10_000)); player.pos = Int64(r.int(40_000))
        // A real handler that runs up to one render quantum early, on the continuing timeline.
        case "early_cb": if let p = player.pos, let i = player.scheduled.indices.first(where: { !player.scheduled[$0].fired }),
                            p >= player.scheduled[i].end + player.latency - 900 {
                           player.scheduled[i].fired = true; player.scheduled[i].cb(player.host(p)) }
        // The anchor is momentarily missing while rendering continues.
        case "anchor_gap": player.anchorUnavailable.toggle()
        // Review r1 F1: stop() whose flush handlers arrive only after a restart has run past the old end frames.
        case "late_flush": if let p = player.pos { disturbed = true; player.stopDeferringCallbacks()
                             player.restart(stoppedAt: p, gapFrames: Int64(r.int(64))); player.advance(to: Int64(r.int(30_000))); player.fireDeferred() }
        // Review r1 F2: an announced pause/resume of any length (generation advances).
        case "short_pause": if player.pos != nil { disturbed = true; player.pause(); player.hostBase += UInt64(r.int(600)); player.ensurePlaying() }
        // Unannounced render jitter well inside the tolerance: must not stop a genuine drain.
        case "drift": player.hostBase += UInt64(r.int(40))
        // Review r2 F1: the SYSTEM flushes and restarts the timeline with NO fence advance; handlers arrive late.
        // Review r4: unannounced restart at ANY point (between chunks, after the last callback, before END).
        case "sys_restart_any": if let p = player.pos {
                              disturbed = true; unannouncedRestartInTurn = true
                              for i in player.scheduled.indices where !player.scheduled[i].fired { player.flushed.insert(i) }
                              player.hostBase = UInt64(Int64(player.hostBase) + p + Int64(r.int(64))); player.pos = 0
                              player.advance(to: Int64(r.int(30_000))) }
        // Review r3 F1: same, but the late handler arrives after a LONG time on the new timeline.
        case "sys_restart_long": if let p = player.pos, player.scheduled.contains(where: { !$0.fired }) {
                              disturbed = true; unannouncedRestartInTurn = true
                              var held: [(UInt64) -> Void] = []
                              for i in player.scheduled.indices where !player.scheduled[i].fired {
                                player.scheduled[i].fired = true; player.flushed.insert(i); held.append(player.scheduled[i].cb) }
                              player.hostBase = UInt64(Int64(player.hostBase) + p + Int64(r.int(64))); player.pos = 0
                              player.advance(to: 1_000_000 + Int64(r.int(9_000_000)))
                              let h = player.host(player.pos ?? 0); held.forEach { $0(h) } }
        case "sys_restart": if let p = player.pos, player.scheduled.contains(where: { !$0.fired }) {
                              disturbed = true; unannouncedRestartInTurn = true
                              var held: [(UInt64) -> Void] = []
                              for i in player.scheduled.indices where !player.scheduled[i].fired {
                                player.scheduled[i].fired = true; player.flushed.insert(i); held.append(player.scheduled[i].cb) }
                              player.hostBase = UInt64(Int64(player.hostBase) + p + Int64(r.int(64))); player.pos = 0
                              player.advance(to: Int64(r.int(30_000)))
                              let h = player.host(player.pos ?? 0); held.forEach { $0(h) } }
        default: break
        }
        settle()
      }
      if !disturbed {
        player.anchorUnavailable = false     // a momentary gap is not a disturbance; it ends before completion
        while seq < n { let f = 1 + r.int(1200); if barrier.push(turnId: "fw_T", seq: seq, pcm16: Data(count: 2 * f)) { frames += Int64(f); lastEndTruth = player.scheduled.last!.end }; seq += 1 }
        if !ended { ended = true; barrier.end(turnId: "fw_T", totalChunks: n, totalFrames: frames) }
        player.advance(to: (player.pos ?? 0) + 1_000_000)
      }
      settle()
      if events.isEmpty && !disturbed { drainRetries() }
      // Pending bounded retries of disturbed seeds keep running: their late emissions are still checked above.
      keepAlive.append(barrier)
      let why = "seed=\(seed) ops=\(ops) events=\(events) log=\(barrier.log)"
      XCTAssertLessThanOrEqual(events.count, 1, why)
      switch events.first {
      case .drained(_, _, _, let fp, let last, _)?: drained += 1; XCTAssertEqual(fp, frames, why); XCTAssertEqual(last, n - 1, why)
      case .unverified?: unverified += 1; XCTAssertTrue(disturbed, "undisturbed turn must drain: \(why)")
      case nil: XCTAssertTrue(disturbed, "undisturbed turn must reach a terminal event: \(why)")
      }
    }
    usleep(600_000)                         // every late retry has finished and been safety-checked
    print("I13 seeds=\(base)..\(base + seeds - 1) drained=\(drained) unverified=\(unverified)")
    // Coverage floors (Group A: the restart/late_flush/short_pause ops disturb more seeds, so the positive floor is 1/30).
    // Coverage floor, not a safety property: young starts (1 in 4) and the many disturbance ops leave ~2.5-3% of seeds
    // draining; require at least 1/50 so a regression that stops genuine drains is still caught.
    if seeds >= 1000 { XCTAssertGreaterThan(drained, seeds / 50); XCTAssertGreaterThan(unverified, seeds / 20) }
  }
}

/// Real AVAudioEngine + AVAudioPlayerNode on the host's default output device, SILENT
/// (zero samples, mixer volume 0). This is real `.dataPlayedBack` behaviour, but it is host audio,
/// not iOS device proof.
/// Mirrors the plugin's playback graph: Int16 24 kHz mono player node into the main mixer (silent here).
final class RealPluginPlayback {
  let engine = AVAudioEngine()
  let node = AVAudioPlayerNode()
  let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
  let lifetime: RetiringPlaybackLifetime
  let adapter: PluginFarewellPlayer
  var onPlatformInvalidation: ((String) -> Void)?
  private var observer: NSObjectProtocol?
  init() throws {
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
    engine.mainMixerNode.outputVolume = 0
    let node = self.node
    lifetime = RetiringPlaybackLifetime(stop: { node.stop() })
    adapter = PluginFarewellPlayer(engine: engine, node: node, format: format, lifetime: lifetime)
    observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
      self?.onPlatformInvalidation?("engine_configuration_change")
    }
    try engine.start()
  }
  deinit { observer.map(NotificationCenter.default.removeObserver) }
  func stop() { node.stop() }
  func ensurePlaying() { adapter.ensurePlaying() }
  func scheduleLegacy(_ data: Data) {
    let frames = AVAudioFrameCount(data.count / 2)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    data.copyBytes(to: list[0].mData!.assumingMemoryBound(to: UInt8.self), count: data.count)
    node.scheduleBuffer(buffer, completionHandler: nil)
  }
  func simulateEngineStop() { engine.stop() }
}

final class FarewellBarrierAVFoundationTests: XCTestCase {
  /// The plugin owns its engine for the whole session; the tests keep it alive the same way.
  var keepAlive: [RealPluginPlayback] = []
  func make() throws -> (RealPluginPlayback, FarewellPlaybackBarrier, () -> [FarewellBarrierEvent]) {
    let player = try RealPluginPlayback()
    keepAlive.append(player)
    let lock = NSLock(); var evs: [FarewellBarrierEvent] = []
    let barrier = FarewellPlaybackBarrier(player: player.adapter) { e in lock.lock(); evs.append(e); lock.unlock() }
    player.onPlatformInvalidation = { reason in barrier.invalidate(reason: reason) }
    if !player.node.isPlaying { player.node.play() }
    return (player, barrier, { lock.lock(); defer { lock.unlock() }; return evs })
  }
  func wait(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
  func pcm(_ frames: Int) -> Data { Data(count: frames * 2) }

  func testP4_aStoppedSessionReleasesItsLifetimeBarrierAndPlayer() throws {
    // Review 1a798d2c MEDIUM-4: the plugin's session graph (lifetime -> stop closure -> box -> barrier -> player
    // -> lifetime) must not be a retain cycle once the plugin drops its references.
    weak var weakLifetime: RetiringPlaybackLifetime?
    weak var weakBarrier: FarewellPlaybackBarrier?
    let engine = AVAudioEngine()
    let node = AVAudioPlayerNode()
    engine.attach(node)
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    do {
      let box = FarewellBarrierBox()
      let lifetime = RetiringPlaybackLifetime(stop: { box.barrier?.invalidateAsync(reason: "playback_retired"); node.stop() })
      var barrier: FarewellPlaybackBarrier? = FarewellPlaybackBarrier(
        player: PluginFarewellPlayer(engine: engine, node: node, format: format, lifetime: lifetime), emit: { _ in })
      box.barrier = barrier
      weakLifetime = lifetime
      weakBarrier = barrier
      let stopped = expectation(description: "stopped")
      lifetime.cancel { _ in stopped.fulfill() }
      wait(for: [stopped], timeout: 3)
      barrier = nil
    }
    wait(0.2)
    XCTAssertNil(weakBarrier, "barrier leaked")
    XCTAssertNil(weakLifetime, "lifetime leaked")
  }

  func testA1_realDataPlayedBackDrainsTheFarewell() throws {
    let (_, b, events) = try make()
    let t0 = Int64(Date().timeIntervalSince1970 * 1000)
    b.begin(turnId: "fw_R", nativeGeneration: 1)
    for i in 0..<4 { XCTAssertTrue(b.push(turnId: "fw_R", seq: i, pcm16: pcm(2400))) }   // 4 x 100 ms
    b.end(turnId: "fw_R", totalChunks: 4, totalFrames: 9600)
    wait(1.5)
    guard case .drained(let id, _, let at, let frames, let last, _) = events().first else { return XCTFail("not drained: \(events()) log=\(b.log)") }
    XCTAssertEqual(id, "fw_R"); XCTAssertEqual(frames, 9600); XCTAssertEqual(last, 3)
    XCTAssertGreaterThanOrEqual(at - t0, 400, "drained no earlier than the audio duration (100 ms lead + 400 ms audio)")
  }

  func testA2_realStopMidFarewellIsUnverifiedEvenThoughPlayedBackFires() throws {
    let (p, b, events) = try make()
    b.begin(turnId: "fw_S", nativeGeneration: 1)
    XCTAssertTrue(b.push(turnId: "fw_S", seq: 0, pcm16: pcm(48_000)))   // 2 s
    b.end(turnId: "fw_S", totalChunks: 1, totalFrames: 48_000)
    wait(0.4)
    p.stop()          // external stop (NOT through the barrier): AVFoundation runs the handler
    // Group A: a missing anchor is retried for up to ~200 ms before failing closed; poll (bounded) for the outcome.
    for _ in 0..<40 where events().isEmpty { wait(0.05) }
    guard case .unverified(_, _, let reason) = events().first else { return XCTFail("expected unverified, got \(events())") }
    XCTAssertTrue(reason.hasPrefix("played_back_before_end_frame") || reason == "played_back_without_position", reason)
  }

  func testA3_realEngineTeardownMidFarewellIsUnverified() throws {
    let (p, b, events) = try make()
    b.begin(turnId: "fw_E", nativeGeneration: 1)
    XCTAssertTrue(b.push(turnId: "fw_E", seq: 0, pcm16: pcm(48_000)))
    b.end(turnId: "fw_E", totalChunks: 1, totalFrames: 48_000)
    wait(0.3)
    p.simulateEngineStop()
    wait(0.8)
    XCTAssertFalse(events().contains { if case .drained = $0 { return true }; return false }, "\(events())")
  }

  func testA5_cancelFromAWorkerThreadWithPendingBuffersNeverDeadlocks() throws {
    // Regression for IOS-2 (stop() vs node reads inside the handler). Mirrors the CLI/plugin threading:
    // barrier calls arrive on a non-main worker thread while buffers are queued.
    let (_, b, events) = try make()
    for round in 0..<5 {
      let id = "fw_D\(round)"
      let done = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        b.begin(turnId: id, nativeGeneration: round)
        _ = b.push(turnId: id, seq: 0, pcm16: Data(count: 4800)); _ = b.push(turnId: id, seq: 1, pcm16: Data(count: 4800))
        Thread.sleep(forTimeInterval: 0.15)
        b.cancel(turnId: id, reason: "transport_lost")
        done.signal()
      }
      XCTAssertEqual(done.wait(timeout: .now() + 3), .success, "round \(round): cancel deadlocked")
    }
    wait(0.3)
    XCTAssertEqual(events().filter { if case .unverified(_, _, "transport_lost") = $0 { return true }; return false }.count, 5)
  }

  func testA6_realPauseAfterUnderrunThenPushNeverDrains() throws {
    // QA-IOS-1 regression on real AVFoundation (ports qa/grok_r1/probes/av_pause_then_push.swift).
    let (p, b, events) = try make()
    b.begin(turnId: "fw_P", nativeGeneration: 1)
    wait(0.8)                                   // underrun: timeline advances with nothing queued
    p.node.pause()                              // external pause (not through the barrier)
    _ = b.push(turnId: "fw_P", seq: 0, pcm16: pcm(480))
    b.end(turnId: "fw_P", totalChunks: 1, totalFrames: 480)
    p.node.play()
    wait(1.0)
    XCTAssertFalse(events().contains { if case .drained = $0 { return true }; return false }, "\(events()) log=\(b.log)")
  }

  func testA7_realLegacyQueuedWhilePausedDelaysTheFarewell() throws {
    // QA-IOS-2 regression on real AVFoundation (after qa/grok_r2/probes/ios_r2_attacks.swift legacy case).
    let (p, b, events) = try make()
    b.noteLegacyScheduled(frames: 4800); p.scheduleLegacy(pcm(4800)); p.ensurePlaying()
    wait(0.6)                                    // timeline advances well past 0
    p.node.pause()                               // playhead nil, timeline parked
    b.noteLegacyScheduled(frames: 48_000); p.scheduleLegacy(pcm(48_000))             // 2 s of conversation audio queued while paused
    let t0 = Date()
    b.begin(turnId: "fw_L", nativeGeneration: 1)
    XCTAssertTrue(b.push(turnId: "fw_L", seq: 0, pcm16: pcm(480)))
    b.end(turnId: "fw_L", totalChunks: 1, totalFrames: 480)
    var drainedAfter: Double?
    for _ in 0..<35 { wait(0.1); if drainedAfter == nil, events().contains(where: { if case .drained = $0 { return true }; return false }) { drainedAfter = Date().timeIntervalSince(t0) } }
    if let d = drainedAfter { XCTAssertGreaterThanOrEqual(d, 1.9, "farewell drained \(d)s after begin, inside 2 s of queued legacy audio; log=\(b.log)") }
    else { XCTFail("expected a drain after the legacy audio: \(events()) log=\(b.log)") }
  }

  func testA8_realLegacyQueuedAfterBeginWhilePausedDelaysTheFarewell() throws {
    // QA-IOS-3 regression on real AVFoundation (after qa/grok_r3/probes/ios_r3_av.swift legacy_after_begin).
    let (p, b, events) = try make()
    b.noteLegacyScheduled(frames: 4800); p.scheduleLegacy(pcm(4800)); p.ensurePlaying()
    wait(0.4)
    b.begin(turnId: "fw_A", nativeGeneration: 1)        // playhead known: start chosen now
    p.node.pause()
    b.noteLegacyScheduled(frames: 48_000); p.scheduleLegacy(pcm(48_000))                    // 2 s queued AFTER begin, playhead nil
    p.node.play()
    let t0 = Date()
    // Group A: the external pause/play is an unannounced stall of the turn's timeline. Within the 96-frame bound the
    // farewell is scheduled after the legacy span and drains after it; beyond it the turn fails closed
    // (render_discontinuity), at the push or later. Never a drain inside the legacy span.
    let pushed = b.push(turnId: "fw_A", seq: 0, pcm16: pcm(480))
    b.end(turnId: "fw_A", totalChunks: 1, totalFrames: 480)
    var drainedAfter: Double?
    for _ in 0..<35 { wait(0.1); if drainedAfter == nil, events().contains(where: { if case .drained = $0 { return true }; return false }) { drainedAfter = Date().timeIntervalSince(t0) } }
    if let d = drainedAfter {
      XCTAssertTrue(pushed)
      XCTAssertGreaterThanOrEqual(d, 1.9, "drained \(d)s after the push, inside 2 s of legacy queued after begin; log=\(b.log)")
    } else {
      guard case .unverified(_, _, let reason)? = events().first else { return XCTFail("no outcome: log=\(b.log)") }
      XCTAssertTrue(reason.hasPrefix("render_discontinuity"), "expected a drain after the legacy audio or a fail-closed stall: \(reason)")
    }
  }

  func testA4_realCancelThenNewTurnDrainsOnlyTheNewTurn() throws {
    let (_, b, events) = try make()
    b.begin(turnId: "fw_1", nativeGeneration: 1)
    XCTAssertTrue(b.push(turnId: "fw_1", seq: 0, pcm16: pcm(48_000)))
    wait(0.2)
    b.cancel(turnId: "fw_1", reason: "barge_in")
    b.begin(turnId: "fw_2", nativeGeneration: 2)
    XCTAssertTrue(b.push(turnId: "fw_2", seq: 0, pcm16: pcm(2400)))
    b.end(turnId: "fw_2", totalChunks: 1, totalFrames: 2400)
    wait(1.2)
    let evs = events()
    XCTAssertEqual(evs.first, .unverified(turnId: "fw_1", nativeGeneration: 1, reason: "barge_in"))
    XCTAssertTrue(evs.contains { if case .drained(let t, 2, _, 2400, 0, _) = $0 { return t == "fw_2" }; return false }, "\(evs) log=\(b.log)")
    XCTAssertFalse(evs.contains { if case .drained(let t, _, _, _, _, _) = $0 { return t == "fw_1" }; return false })
  }
}

/// Plugin-specific cases: the retirement fence and timeline reset added in the port.
final class FarewellBarrierPluginPortTests: XCTestCase {
  func wait(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
  func pcm(_ frames: Int) -> Data { Data(count: frames * 2) }

  func testP1_retiredLifetimeRefusesToScheduleAndFailsClosed() throws {
    let p = try RealPluginPlayback(); p.node.play()
    var evs: [FarewellBarrierEvent] = []; let lock = NSLock()
    let b = FarewellPlaybackBarrier(player: p.adapter) { e in lock.lock(); evs.append(e); lock.unlock() }
    b.begin(turnId: "fw_X", nativeGeneration: 3)
    let done = DispatchSemaphore(value: 0)
    p.lifetime.cancel { _ in done.signal() }
    XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
    XCTAssertFalse(b.push(turnId: "fw_X", seq: 0, pcm16: pcm(2400)), "a retired player never schedules a farewell")
    wait(0.3)
    lock.lock(); let got = evs; lock.unlock()
    XCTAssertEqual(got.count, 1)
    guard case .unverified("fw_X", 3, let reason) = got.first else { return XCTFail("\(got)") }
    XCTAssertTrue(reason == "player_unavailable" || reason.hasPrefix("playhead_unavailable"), reason)
  }

  func testP2_asyncInvalidateFromTeardownMakesLaterCallbacksStale() throws {
    let p = try RealPluginPlayback(); p.node.play()
    var evs: [FarewellBarrierEvent] = []; let lock = NSLock()
    let b = FarewellPlaybackBarrier(player: p.adapter) { e in lock.lock(); evs.append(e); lock.unlock() }
    b.begin(turnId: "fw_T", nativeGeneration: 4)
    XCTAssertTrue(b.push(turnId: "fw_T", seq: 0, pcm16: pcm(24_000)))
    b.end(turnId: "fw_T", totalChunks: 1, totalFrames: 24_000)
    wait(0.2)
    b.invalidateAsync(reason: "playback_retired")
    p.stop()
    wait(1.5)
    lock.lock(); let got = evs; lock.unlock()
    XCTAssertEqual(got, [.unverified(turnId: "fw_T", nativeGeneration: 4, reason: "playback_retired")])
  }

  func testP3_timelineResetVoidsTheLegacyEstimateSoTheNextFarewellStillDrains() throws {
    let p = try RealPluginPlayback(); p.node.play()
    var evs: [FarewellBarrierEvent] = []; let lock = NSLock()
    let b = FarewellPlaybackBarrier(player: p.adapter) { e in lock.lock(); evs.append(e); lock.unlock() }
    b.noteLegacyScheduled(frames: 240_000); p.scheduleLegacy(pcm(240_000))   // 10 s of queued conversation audio
    wait(0.2)
    p.node.stop(); p.node.reset()                                           // plugin reprime: queue emptied
    b.noteTimelineReset(reason: "playback_reprimed")
    p.node.play()
    let t0 = Date()
    b.begin(turnId: "fw_R", nativeGeneration: 5)
    XCTAssertTrue(b.push(turnId: "fw_R", seq: 0, pcm16: pcm(4800)))
    b.end(turnId: "fw_R", totalChunks: 1, totalFrames: 4800)
    var drainedAfter: Double?
    for _ in 0..<30 { wait(0.1); lock.lock(); let d = evs.contains { if case .drained = $0 { return true }; return false }; lock.unlock(); if d { drainedAfter = Date().timeIntervalSince(t0); break } }
    XCTAssertNotNil(drainedAfter, "the stale 10 s estimate must not park the farewell; log=\(b.log)")
    if let d = drainedAfter { XCTAssertLessThan(d, 2.0) }
  }
}

/// UID 505 review of b113d222, findings 2 and 3: a payload queued for one Dart subscription must never be
/// delivered to a replacement subscription, and nothing may be delivered after the engine detaches.
final class DeliveryEpochGateTests: XCTestCase {
  func testG1_nothingIsStampedWithoutAListener() {
    let gate = DeliveryEpochGate()
    XCTAssertNil(gate.stamp())
    gate.listen()
    XCTAssertNotNil(gate.stamp())
    gate.cancel()
    XCTAssertNil(gate.stamp())
  }

  func testG2_payloadQueuedBeforeCancelAndRelistenIsDropped() {
    let gate = DeliveryEpochGate()
    gate.listen()
    let oldPcm = gate.stamp()!   // old capture callback queues PCM
    gate.cancel()                // queued cancel runs first
    gate.listen()                // then the replacement listen
    XCTAssertFalse(gate.admits(oldPcm), "old subscription's bytes must not reach the new sink")
    let newPcm = gate.stamp()!
    XCTAssertTrue(gate.admits(newPcm))
  }

  func testG3_relistenWithoutCancelStillFencesTheOldSubscription() {
    let gate = DeliveryEpochGate()
    gate.listen()
    let queued = gate.stamp()!
    gate.listen()
    XCTAssertFalse(gate.admits(queued))
  }

  func testG4_detachRefusesListenersAndDropsEverythingQueued() {
    let gate = DeliveryEpochGate()
    gate.listen()
    let queued = gate.stamp()!
    gate.detach()
    XCTAssertTrue(gate.isDetached)
    XCTAssertFalse(gate.admits(queued))
    XCTAssertFalse(gate.listen(), "a detached instance must not accept a new listener")
    XCTAssertNil(gate.stamp())
  }

  func testG5_concurrentStampsAcrossARelistenNeverAdmitTheOldEpoch() {
    let gate = DeliveryEpochGate()
    gate.listen()
    let lock = NSLock()
    var before: [Int] = []
    DispatchQueue.concurrentPerform(iterations: 200) { _ in
      if let s = gate.stamp() { lock.lock(); before.append(s); lock.unlock() }
    }
    gate.cancel()
    gate.listen()
    XCTAssertFalse(before.contains { gate.admits($0) })
  }
}
