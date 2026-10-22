// iOS farewell playback barrier. Ported from the Track 21 farewell-barrier lab (six external QA rounds).
// Plugin changes: legacy audio is only ACCOUNTED here (the plugin schedules it), schedule() can refuse a
// retired player, a stopped/reset player timeline resets the legacy estimate, and the cancel path can
// invalidate without blocking the platform thread.
//
// Proves that the FINAL buffer of ONE farewell turn reached AVAudioPlayerNode's `.dataPlayedBack`
// boundary. Empirically (evidence/platform_spikes/FINDINGS.md) a `.dataPlayedBack` handler ALSO runs
// when `stop()` flushes an unplayed buffer, so the callback alone is not proof. This barrier
// therefore accepts a buffer only when, inside its callback:
//   (a) the playback epoch captured at scheduling is still current (no cancel/reset/route/interruption),
//   (b) the player's sample position AT CALLBACK TIME >= that buffer's exact end frame + output presentation
//       latency (exact because farewell buffers are scheduled at explicit player-timeline sample times).
// Finding IOS-2: reading node state (lastRenderTime/playerTime) INSIDE the handler deadlocks against a
// concurrent AVAudioPlayerNode.stop() (both take the node's recursive mutex; stop waits on the handler).
// The handler therefore captures only the lock-free host time; the barrier queue later reads one
// (sampleTime, hostTime) render anchor and extrapolates the position back to the callback instant. A
// stopped / not-rendering node yields no anchor (fail closed); a restarted timeline extrapolates to a
// position before the end frame (fail closed).
// The turn is drained only when every sequence number up to the declared final one passed (a)+(b).
import Foundation

enum FarewellBarrierEvent: Equatable {
  case drained(turnId: String, nativeGeneration: Int, drainedAtEpochMs: Int64, framesPlayed: Int64, lastSeq: Int, evidence: String)
  case unverified(turnId: String, nativeGeneration: Int, reason: String)
}

/// Thin seam over AVAudioPlayerNode so the barrier logic is testable without audio hardware.
protocol FarewellPlayer: AnyObject {
  var sampleRate: Double { get }
  /// Player-timeline position in frames, or nil when the node is not rendering. Never called from a handler.
  func currentSampleTime() -> Int64?
  /// One render anchor: player sample time and the host time of that same render cycle (nil if not rendering).
  func renderAnchor() -> (sampleTime: Int64, hostTime: UInt64)?
  var hostTicksPerSecond: Double { get }
  /// Output presentation latency expressed in player frames.
  func presentationLatencyFrames() -> Int64
  /// Schedule mono PCM16 at an explicit player sample time. `onPlayedBack` is the `.dataPlayedBack` handler and
  /// receives the host time captured SYNCHRONOUSLY inside the platform callback. Implementations must not touch
  /// the node from the handler (IOS-2). Returns false when the player can no longer schedule (retired).
  func schedule(pcm16: Data, atSampleTime: Int64, onPlayedBack: @escaping (UInt64) -> Void) -> Bool
  func ensurePlaying()
  func stop()
}

final class FarewellPlaybackBarrier {
  /// A played-back callback is judged only from a render anchor taken AT OR AFTER it. While the anchor is
  /// older, the judgement is retried this often, at most this many times (~100 ms), then fails closed.
  static let anchorRetryIntervalMs = 5
  static let anchorRetryLimit = 20
  typealias Emit = (FarewellBarrierEvent) -> Void

  private struct Turn {
    let id: String
    let generation: Int
    var nextStart: Int64
    var expectedSeq = 0
    var scheduledFrames: Int64 = 0
    var endFrames: [Int: Int64] = [:]   // seq -> exact end frame on the player timeline
    var verified: Set<Int> = []
    var finalSeq: Int?                    // known after end()
    var declaredFrames: Int64?
    var terminal = false
  }

  private let player: FarewellPlayer
  private let nowMs: () -> Int64
  private let emit: Emit
  private let queue: DispatchQueue
  private let leadFrames: Int64
  private var epoch = 0
  private var turn: Turn?
  private var legacyEndEstimate: Int64 = 0
  private var unanchoredLegacyFrames: Int64 = 0
  private(set) var staleCallbacks = 0
  private(set) var log: [String] = []

  private let playheadWaitMs: Int
  init(player: FarewellPlayer, leadFrames: Int64 = 2400, playheadWaitMs: Int = 1000, nowMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
              queue: DispatchQueue = DispatchQueue(label: "farewell.barrier"), emit: @escaping Emit) {
    self.player = player
    self.leadFrames = leadFrames
    self.playheadWaitMs = playheadWaitMs
    self.nowMs = nowMs
    self.queue = queue
    self.emit = emit
  }

  // All entry points hop onto the barrier queue; tests can call `sync` variants.
  func begin(turnId: String, nativeGeneration: Int) { queue.sync { self._begin(turnId, nativeGeneration) } }
  @discardableResult func push(turnId: String, seq: Int, pcm16: Data) -> Bool { queue.sync { self._push(turnId, seq, pcm16) } }
  func end(turnId: String, totalChunks: Int, totalFrames: Int64) { queue.sync { self._end(turnId, totalChunks, totalFrames) } }
  /// Never blocks the caller: the platform cancel path must not wait behind a BEGIN warm-up on this queue.
  func cancel(turnId: String, reason: String) { queue.async { self._cancel(turnId, reason) } }
  /// Platform invalidation: route change, interruption, media services reset, engine configuration change.
  func invalidate(reason: String) { queue.sync { self._invalidate(reason, stopPlayer: true) } }
  /// Invalidation from a thread that must not wait (the independent playback-teardown path). The epoch is
  /// bumped before any later callback can be judged, because callbacks are judged on this same queue.
  func invalidateAsync(reason: String) { queue.async { self._invalidate(reason, stopPlayer: false) } }
  /// The plugin stopped/reset the player: its timeline restarts, so the queued-legacy estimate is void.
  func noteTimelineReset(reason: String) {
    queue.sync {
      self._invalidate(reason, stopPlayer: false)
      self.legacyEndEstimate = 0
      self.unanchoredLegacyFrames = 0
    }
  }
  /// True while a farewell turn can still drain or fail.
  var hasLiveTurn: Bool { queue.sync { turn.map { !$0.terminal } ?? false } }
  /// Ordinary (non-farewell) audio that the plugin is about to schedule with append semantics. Only the
  /// accounting happens here; scheduling stays in the plugin.
  func noteLegacyScheduled(frames: Int64) {
    queue.sync {
      // QA-IOS-3: once a farewell buffer is scheduled, legacy audio would land beside/among the farewell on the
      // player timeline; the farewell's end frame could no longer be trusted.
      if var t = turn, !t.terminal, t.expectedSeq > 0 { fail(&t, "legacy_interleaved") }
      // QA-IOS-2: never count from 0. While the playhead is unknown (paused, parked timeline) the frames are held
      // as UNANCHORED and folded in on the next known playhead: they play after whatever is queued, from there.
      if let pos = player.currentSampleTime() {
        legacyEndEstimate = max(legacyEndEstimate, pos) + unanchoredLegacyFrames + frames
        unanchoredLegacyFrames = 0
      } else {
        unanchoredLegacyFrames += frames
      }
    }
  }

  private func _begin(_ id: String, _ gen: Int) {
    if var t = turn, !t.terminal {
      // Buffer replacement: a new farewell supersedes the old one; the old one can never drain.
      t.terminal = true; turn = t
      epoch += 1
      stopPlayerAndResetTimeline()
      emit(.unverified(turnId: t.id, nativeGeneration: t.generation, reason: "replaced"))
    }
    epoch += 1
    player.ensurePlaying()
    // QA-IOS-1: the start frame must be derived from a KNOWN playhead. A nil read right after play() is engine
    // warm-up; wait for it (bounded). Still nil means the node is not rendering (paused, stopped, no engine):
    // substituting 0 would schedule against a timeline that may be parked far ahead.
    var pos = player.currentSampleTime()
    var waitedMs = 0
    while pos == nil && waitedMs < playheadWaitMs { usleep(2_000); waitedMs += 2; pos = player.currentSampleTime() }
    guard let p = pos else {
      var t = Turn(id: id, generation: gen, nextStart: 0)
      turn = t
      fail(&t, "playhead_unavailable")
      return
    }
    if unanchoredLegacyFrames > 0 {          // QA-IOS-2: legacy queued while the playhead was unknown
      legacyEndEstimate = max(legacyEndEstimate, p) + unanchoredLegacyFrames
      unanchoredLegacyFrames = 0
    }
    let start = max(p, legacyEndEstimate) + leadFrames
    turn = Turn(id: id, generation: gen, nextStart: start)
    if let i = cancelledBeforeBegin.firstIndex(where: { $0.id == id }) {
      let reason = cancelledBeforeBegin.remove(at: i).reason
      var t = turn!
      fail(&t, reason)
      return
    }
    log.append("begin \(id) start=\(start)" + (waitedMs > 0 ? " waitedMs=\(waitedMs)" : ""))
  }

  private func _push(_ id: String, _ seq: Int, _ pcm: Data) -> Bool {
    guard var t = turn, t.id == id, !t.terminal else { return false }
    guard t.finalSeq == nil else { fail(&t, "push_after_end"); return false }
    guard seq == t.expectedSeq else { fail(&t, seq < t.expectedSeq ? "duplicate_seq" : "missing_seq"); return false }
    guard !pcm.isEmpty, pcm.count % 2 == 0 else { fail(&t, "bad_pcm"); return false }
    let frames = Int64(pcm.count / 2)
    // IOS-3: after an underrun the playhead may have overtaken nextStart. A buffer scheduled in the past would
    // have an end frame at or behind the playhead, so even a stop() flush callback would satisfy the position
    // check. Re-anchor ahead of the playhead (an audible gap, never a false drain). The position is read here
    // on the barrier queue, never inside a handler (IOS-2).
    // QA-IOS-1: never schedule against an unknown playhead (paused node: playerTime nil, timeline parked high).
    guard let pos = player.currentSampleTime() else { fail(&t, "playhead_unavailable_at_schedule"); return false }
    if t.expectedSeq == 0 {
      // QA-IOS-3: legacy may have been queued AFTER begin (possibly while the playhead was nil). Fold that backlog
      // onto the playhead now and start the farewell after all of it.
      if unanchoredLegacyFrames > 0 {
        legacyEndEstimate = max(legacyEndEstimate, pos) + unanchoredLegacyFrames
        unanchoredLegacyFrames = 0
      }
      let afterLegacy = max(pos, legacyEndEstimate) + leadFrames
      if afterLegacy > t.nextStart { log.append("legacy_reanchor \(t.nextStart)->\(afterLegacy)"); t.nextStart = afterLegacy }
    }
    var start = t.nextStart
    if start < pos + leadFrames / 2 {
      start = pos + leadFrames
      log.append("underrun_reanchor seq=\(seq) \(t.nextStart)->\(start)")
    }
    let endFrame = start + frames
    t.endFrames[seq] = endFrame
    t.nextStart = endFrame
    t.expectedSeq += 1
    t.scheduledFrames += frames
    turn = t
    let capturedEpoch = epoch
    let scheduled = player.schedule(pcm16: pcm, atSampleTime: start) { [weak self] hostAtCallback in
      self?.queue.async { self?._playedBack(epoch: capturedEpoch, turnId: id, seq: seq, host: hostAtCallback) }
    }
    guard scheduled else { fail(&t, "player_unavailable"); return false }
    return true
  }

  private func _end(_ id: String, _ totalChunks: Int, _ totalFrames: Int64) {
    guard var t = turn, t.id == id, !t.terminal else { return }
    if totalChunks <= 0 || totalChunks != t.expectedSeq || totalFrames != t.scheduledFrames {
      fail(&t, "end_totals_mismatch"); return
    }
    t.finalSeq = totalChunks - 1
    t.declaredFrames = totalFrames
    turn = t
    maybeDrained()
  }

  private func _playedBack(epoch captured: Int, turnId: String, seq: Int, host hostAtCallback: UInt64,
                           attempt: Int = 0) {
    guard captured == epoch, var t = turn, t.id == turnId, !t.terminal else { staleCallbacks += 1; return }
    guard let endFrame = t.endFrames[seq] else { staleCallbacks += 1; return }
    // `.dataPlayedBack` also fires when stop() flushes the buffer: judge the position AT the callback instant
    // (IOS-1), reconstructed from a render anchor read here, off the handler (IOS-2). No anchor = not rendering.
    guard let a = player.renderAnchor() else { fail(&t, "played_back_without_position"); return }
    let dtSec = (Double(hostAtCallback) - Double(a.hostTime)) / player.hostTicksPerSecond
    // Review 1a798d2c HIGH-2: projecting FORWARD from an older anchor assumes rendering continued, so a stalled
    // render clock would "advance" with wall time and verify audio that never played. Only project BACKWARD
    // from an anchor taken at or after the callback (that can only under-count). Wait briefly for one.
    if dtSec > 0 {
      guard attempt < FarewellPlaybackBarrier.anchorRetryLimit else {
        fail(&t, "render_anchor_stale"); return
      }
      queue.asyncAfter(deadline: .now() + .milliseconds(FarewellPlaybackBarrier.anchorRetryIntervalMs)) { [weak self] in
        self?._playedBack(epoch: captured, turnId: turnId, seq: seq, host: hostAtCallback, attempt: attempt + 1)
      }
      return
    }
    let pos = a.sampleTime + Int64((dtSec * player.sampleRate).rounded(.down))
    let required = endFrame + player.presentationLatencyFrames()
    guard pos >= required else {
      fail(&t, "played_back_before_end_frame(pos=\(pos) < \(required))"); return
    }
    t.verified.insert(seq)
    turn = t
    maybeDrained()
  }

  private func maybeDrained() {
    guard var t = turn, !t.terminal, let last = t.finalSeq, let frames = t.declaredFrames else { return }
    guard (0...last).allSatisfy({ t.verified.contains($0) }) else { return }
    t.terminal = true
    turn = t
    let at = nowMs()   // captured ONCE, at the verified boundary
    log.append("drained \(t.id) at=\(at)")
    emit(.drained(turnId: t.id, nativeGeneration: t.generation, drainedAtEpochMs: at, framesPlayed: frames, lastSeq: last,
                  evidence: "ios_dataPlayedBack+position"))
  }

  /// Turns cancelled before their BEGIN reached this queue (review 1a798d2c HIGH-1: farewellBegin hops through
  /// the plugin's session queue, farewellCancel does not).
  private var cancelledBeforeBegin: [(id: String, reason: String)] = []

  private func _cancel(_ id: String, _ reason: String) {
    guard turn?.id == id else {
      // Not evicted (review round 2): an evicted entry would re-open the cancel. The barrier lives for one
      // playback lifetime and the app cancels only turns it began, so this stays small.
      cancelledBeforeBegin.removeAll { $0.id == id }
      cancelledBeforeBegin.append((id, reason))
      return
    }
    _invalidate(reason, stopPlayer: true)
  }

  private func _invalidate(_ reason: String, stopPlayer: Bool) {
    guard var t = turn, !t.terminal else { epoch += 1; return }
    epoch += 1                       // every in-flight callback is now stale, BEFORE stopping
    if stopPlayer { stopPlayerAndResetTimeline() }  // stop() runs the flushed buffers' handlers: ignored
    fail(&t, reason)
  }

  /// stop() empties the node and restarts its timeline, so the queued-legacy estimate no longer applies.
  private func stopPlayerAndResetTimeline() {
    player.stop()
    legacyEndEstimate = 0
    unanchoredLegacyFrames = 0
  }

  private func fail(_ t: inout Turn, _ reason: String) {
    guard !t.terminal else { return }
    t.terminal = true
    turn = t
    epoch += 1
    log.append("unverified \(t.id) \(reason)")
    emit(.unverified(turnId: t.id, nativeGeneration: t.generation, reason: reason))
  }

  /// For tests: run a block on the barrier queue after pending callbacks.
  func sync<T>(_ f: () -> T) -> T { queue.sync(execute: f) }
}
