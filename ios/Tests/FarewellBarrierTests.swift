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
  var pos: Int64? = 0
  var hostBase: UInt64 = 10_000_000
  var latency: Int64 = 528
  var scheduled: [(start: Int64, end: Int64, cb: (UInt64) -> Void, fired: Bool)] = []
  var legacy: [Data] = []
  var stops = 0
  var naturallyPlayed: Set<Int> = []        // ground truth: buffer indices whose end + latency was really reached
  func host(_ p: Int64) -> UInt64 { UInt64(Int64(hostBase) + p) }
  func currentSampleTime() -> Int64? { pos }
  /// When set, the render clock is frozen at this anchor (rendering stalled) while the host clock moves on.
  var frozenAnchor: (sampleTime: Int64, hostTime: UInt64)?
  func renderAnchor() -> (sampleTime: Int64, hostTime: UInt64)? { frozenAnchor ?? pos.map { ($0, host($0)) } }
  func presentationLatencyFrames() -> Int64 { latency }
  func schedule(pcm16: Data, atSampleTime: Int64, onPlayedBack: @escaping (UInt64) -> Void) -> Bool {
    scheduled.append((atSampleTime, atSampleTime + Int64(pcm16.count / 2), onPlayedBack, false))
    return true
  }
  func scheduleLegacy(pcm16: Data) { legacy.append(pcm16) }
  /// Models AVAudioPlayerNode.pause(): playerTime is nil while the timeline stays parked; play() resumes there.
  var parkedAt: Int64?
  func pause() { parkedAt = pos; pos = nil }
  func ensurePlaying() { if pos == nil, let p = parkedAt { pos = p; parkedAt = nil } }
  func stop() {
    stops += 1
    let h = host(pos ?? 0)
    for i in scheduled.indices where !scheduled[i].fired { scheduled[i].fired = true; scheduled[i].cb(h) }
    pos = nil                               // a stopped node has no render time
  }
  /// Advance the timeline and fire handlers of buffers whose end + latency has been reached.
  func advance(to p: Int64) {
    pos = p
    for i in scheduled.indices where !scheduled[i].fired && p >= scheduled[i].end + latency {
      scheduled[i].fired = true; naturallyPlayed.insert(i); scheduled[i].cb(host(p))
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
    barrier = FarewellPlaybackBarrier(player: player, leadFrames: 2400, nowMs: { [unowned self] in self.clock }, queue: q) { [unowned self] in self.events.append($0) }
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
    player.stop(); flush()               // AVAudioPlayerNode runs the .dataPlayedBack handler on flush
    XCTAssertEqual(events.count, 1)
    guard case .unverified(_, _, let reason) = events[0] else { return XCTFail("expected unverified") }
    XCTAssertEqual(reason, "played_back_without_position", "stopped node: no render anchor, fail closed")
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
    player.scheduled[0].fired = true; player.scheduled[0].cb(player.host(5000)); flush()
    XCTAssertEqual(events, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: "played_back_without_position")])
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

  /// Lets queued anchor retries run (the barrier waits up to ~100 ms for an anchor at or after a callback).
  func settle() { for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.005)); flush() } }

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
    XCTAssertEqual(events, [.unverified(turnId: "fw_T", nativeGeneration: 11, reason: "playhead_unavailable_at_schedule")])
    XCTAssertTrue(player.scheduled.isEmpty, "nothing scheduled against an unknown playhead")
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
    player.pos = 8960
    barrier.begin(turnId: "fw_T", nativeGeneration: 11)                        // start 11360
    player.pause()
    pushLegacy(pcm(48_000))
    player.ensurePlaying()                                                     // external play(): resumes at 8960
    XCTAssertTrue(barrier.push(turnId: "fw_T", seq: 0, pcm16: pcm(480)))
    XCTAssertGreaterThanOrEqual(player.scheduled[0].start, 8960 + 48_000 + 2400, "after the queued legacy audio")
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
    for seed in base..<(base + seeds) {
      var r = SplitMix(s: UInt64(seed))
      let player = FakePlayer()
      let q = DispatchQueue(label: "fz")
      var events: [FarewellBarrierEvent] = []
      var disturbed = false
      var lastEndTruth: Int64 = -1
      var ops: [String] = []
      var logRef: () -> [String] = { [] }
      let barrier = FarewellPlaybackBarrier(player: player, leadFrames: 2400, nowMs: { 1 }, queue: q) { e in
        if case .drained = e {
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
      func legacy(_ d: Data) { barrier.noteLegacyScheduled(frames: Int64(d.count / 2)); player.scheduleLegacy(pcm16: d) }
      if r.int(2) == 0 { legacy(Data(count: 2 * (1 + r.int(4800)))); ops.append("legacy") }
      barrier.begin(turnId: "fw_T", nativeGeneration: 1)
      let n = 1 + r.int(5)
      var seq = 0, frames: Int64 = 0, ended = false
      for _ in 0..<(n + 2 + r.int(12)) {
        let choices = ["advance", "advance", "advance", "advance", "advance", "advance", "stop", "cancel", "invalidate", "dup", "wrong_end", "late_cb", "no_render", "legacy_mid"]
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
        default: break
        }
        settle()
      }
      if !disturbed {
        while seq < n { let f = 1 + r.int(1200); if barrier.push(turnId: "fw_T", seq: seq, pcm16: Data(count: 2 * f)) { frames += Int64(f); lastEndTruth = player.scheduled.last!.end }; seq += 1 }
        if !ended { ended = true; barrier.end(turnId: "fw_T", totalChunks: n, totalFrames: frames) }
        player.advance(to: (player.pos ?? 0) + 1_000_000)
      }
      settle()
      let why = "seed=\(seed) ops=\(ops) events=\(events) log=\(barrier.log)"
      XCTAssertLessThanOrEqual(events.count, 1, why)
      switch events.first {
      case .drained(_, _, _, let fp, let last, _)?: drained += 1; XCTAssertEqual(fp, frames, why); XCTAssertEqual(last, n - 1, why)
      case .unverified?: unverified += 1; XCTAssertTrue(disturbed, "undisturbed turn must drain: \(why)")
      case nil: XCTAssertTrue(disturbed, "undisturbed turn must reach a terminal event: \(why)")
      }
    }
    print("I13 seeds=\(base)..\(base + seeds - 1) drained=\(drained) unverified=\(unverified)")
    if seeds >= 1000 { XCTAssertGreaterThan(drained, seeds / 20); XCTAssertGreaterThan(unverified, seeds / 20) }
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
    wait(0.5)
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
    XCTAssertTrue(b.push(turnId: "fw_A", seq: 0, pcm16: pcm(480)))
    b.end(turnId: "fw_A", totalChunks: 1, totalFrames: 480)
    var drainedAfter: Double?
    for _ in 0..<35 { wait(0.1); if drainedAfter == nil, events().contains(where: { if case .drained = $0 { return true }; return false }) { drainedAfter = Date().timeIntervalSince(t0) } }
    if let d = drainedAfter { XCTAssertGreaterThanOrEqual(d, 1.9, "drained \(d)s after the push, inside 2 s of legacy queued after begin; log=\(b.log)") }
    else { XCTFail("expected a drain after the legacy audio: \(events()) log=\(b.log)") }
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
