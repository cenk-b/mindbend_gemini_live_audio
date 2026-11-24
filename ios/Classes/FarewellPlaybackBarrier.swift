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
//
// Group A playback-lifetime continuity (16 Nov 2026). Measured on an iOS 26.5 simulator with the plugin's real
// voice-processing graph: `.dataPlayedBack` runs on the render thread up to one render quantum BEFORE the
// reconstructed presentation point, so (b) at the callback instant alone rejected ~20% of genuinely played short
// farewells by a few ms (e.g. pos=42729 < 42785). And a render anchor can be momentarily missing when the barrier
// judges a callback. Neither may be "fixed" by trusting the callback or the clock, and a retried anchor may come from
// ANOTHER render lifetime (stop/restart, Group A review AMEND + adversarial I29). A callback is therefore verified
// only by a render anchor A1 taken at or after it, read while the render-lifetime generation (RenderLifetimeFence:
// advanced BEFORE every stop/reset/restart of the node or engine) still equals the one the WHOLE turn was bound to at
// begin (also re-checked at every push and, atomically, at the drained emission, where one more anchor must still lie
// on the turn's timeline), such that ALL of:
//   (c) the callback-instant position projected BACKWARD from A1 is at most `earlyCallbackSlackFrames` short of the
//       buffer's end + latency. A stop()/restart restarts the player timeline at 0 after the callback, which projects
//       the callback to <= 0, and slack < leadFrames/2 <= that bound, so a flush callback can never pass (c);
//   (d) A1 lies on the SAME continuous render timeline as the buffer's scheduling anchor A0 AND as the turn anchor
//       read at begin (every scheduling anchor is checked against it too), read only once that timeline is
//       >= 960 frames old, so any restart (announced or not) shifts the line by >= 960 frames, more than
//       the tolerance can ever reach (it is evaluated only within 60 s of A0, i.e. <= 384 frames). An UNANNOUNCED
//       render stall that resumes the same timeline discards no audio; it is tolerated only up to that bound: |(A1.sample - A0.sample) - rate * (A1.host - A0.host)| <= 96 frames + 200 ppm of the elapsed
//       time (sample and host time of one anchor come from the same render timestamp; measured to ~1 frame);
//   (e) A1's own position has reached end + latency: the timeline that rendered the buffer was continuously
//       observed past its last frame.
// A missing anchor, an anchor older than the callback, or (c)/(d)-satisfying anchor not yet past (e) are retried
// for a bounded time, re-reading and re-checking (c), (d) and (e) every time; nothing is ever projected forward or
// accepted from elapsed time or from the callback alone. Bound exhausted = fail closed.
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
  /// Group A: identity of the current continuous render lifetime. Advanced BEFORE any stop/reset/restart/pause of the
  /// node or engine, so an anchor read while it is unchanged belongs to the same render lifetime.
  func renderGeneration() -> Int
  /// Runs `body` only while the render-lifetime generation still equals `generation`, atomically with respect to any
  /// advance (an advance waits for `body`). Returns false, without running `body`, when it has changed.
  func whileRenderGeneration(_ generation: Int, _ body: () -> Void) -> Bool
  /// Output presentation latency expressed in player frames.
  func presentationLatencyFrames() -> Int64
  /// Group A (review r10): the current host time, in the same units as render-anchor host times.
  func hostNow() -> UInt64
  /// Group A (review r10/r11): a conservative bound, in player frames, on how far rendering can run ahead of a render
  /// anchor's host time (documented pipeline latencies, I/O buffers and the maximum render slice); nil when it cannot be
  /// established, in which case nothing is scheduled (fail closed).
  func renderAheadFrames() -> Int64?
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
  static let anchorRetryLimit = 40
  /// (c): how far before end + latency the callback-instant position may be (one render quantum of jitter).
  /// Must stay below leadFrames / 2 so a restarted timeline can never satisfy (c).
  static let earlyCallbackSlackFrames: Int64 = 960
  /// (d): maximum deviation of a later anchor from the affine sample/host line of the anchor taken at scheduling:
  /// a fixed part (4 ms at 24 kHz; one anchor pair is measured to ~1 frame) plus 200 ppm of the elapsed time for
  /// sample-clock vs host-clock drift over a long farewell. Defence in depth behind the render-lifetime generation.
  static let continuityToleranceFrames: Double = 96
  static let continuityDriftPerFrame: Double = 0.0002
  /// (d) is only evaluated within this window after the scheduling anchor (60 s at 24 kHz), so the tolerance never
  /// exceeds 96 + 288 = 384 frames, strictly below the >= 960-frame shift of any restart (minimumTimelineFrames).
  /// Beyond it the barrier fails closed rather than widen the tolerance (review r3 F1).
  static let continuityWindowFrames: Double = 1_440_000
  typealias Emit = (FarewellBarrierEvent) -> Void

  private struct Turn {
    let id: String
    let generation: Int
    var nextStart: Int64
    var expectedSeq = 0
    var scheduledFrames: Int64 = 0
    var endFrames: [Int: Int64] = [:]   // seq -> exact end frame on the player timeline
    /// seq -> render anchor (A0) read immediately before that buffer was scheduled, and the render-lifetime generation
    /// it was read in: the buffer's render-timeline reference.
    var scheduleAnchors: [Int: (sampleTime: Int64, hostTime: UInt64, generation: Int)] = [:]
    var verified: Set<Int> = []
    var finalSeq: Int?                    // known after end()
    var declaredFrames: Int64?
    var terminal = false
    /// Group A: the render lifetime the WHOLE turn is bound to (read at begin, once the playhead is known). Any change
    /// before the drained emission fails the turn, even between chunks or after the audio has played.
    var renderGeneration = 0
    /// Group A: render anchor read at begin (timeline >= minimumTimelineFrames old). Every scheduling anchor, every
    /// judging anchor and the anchor read at the drained emission must lie on ITS continuous timeline, so the whole
    /// turn is one render lifetime even across an unannounced restart between chunks or before END (review r4).
    var turnAnchor: (sampleTime: Int64, hostTime: UInt64) = (0, 0)
    /// Group A (review r7): the barrier-wide seal count at begin; any non-blocking invalidation since then seals it.
    var sealAtBegin = 0
  }
  /// Group A (review r7): synchronous seals for the non-blocking cancel / invalidate paths. Checked inside the atomic
  /// drained emission. Never held while waiting on the barrier queue.
  private let sealLock = NSLock()
  private var sealCount = 0
  private var sealedTurnIds: Set<String> = []

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
  /// Group A: a buffer is scheduled only once its render timeline is at least this old (default 40 ms). Any restart
  /// after that shifts the timeline's sample/host line by at least this much, more than the continuity tolerance, so
  /// (d) alone rejects even a restart that no code path announced. Tests of other behaviour may pass 0.
  private let minimumTimelineFrames: Int64
  init(player: FarewellPlayer, leadFrames: Int64 = 2400, playheadWaitMs: Int = 1000, minimumTimelineFrames: Int64 = 960, nowMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
              queue: DispatchQueue = DispatchQueue(label: "farewell.barrier"), emit: @escaping Emit) {
    self.player = player
    precondition(FarewellPlaybackBarrier.earlyCallbackSlackFrames < leadFrames / 2,
                 "a restarted timeline must never satisfy the early-callback slack")
    precondition(minimumTimelineFrames == 0 || FarewellPlaybackBarrier.continuityToleranceFrames
                   + FarewellPlaybackBarrier.continuityDriftPerFrame * FarewellPlaybackBarrier.continuityWindowFrames
                   < Double(minimumTimelineFrames) / 2,
                 "the continuity tolerance must stay below the offset shift of any restart")
    self.leadFrames = leadFrames
    self.playheadWaitMs = playheadWaitMs
    self.minimumTimelineFrames = minimumTimelineFrames
    self.nowMs = nowMs
    self.queue = queue
    self.emit = emit
  }

  // All entry points hop onto the barrier queue; tests can call `sync` variants.
  func begin(turnId: String, nativeGeneration: Int) { queue.sync { self._begin(turnId, nativeGeneration) } }
  @discardableResult func push(turnId: String, seq: Int, pcm16: Data) -> Bool { queue.sync { self._push(turnId, seq, pcm16) } }
  func end(turnId: String, totalChunks: Int, totalFrames: Int64) { queue.sync { self._end(turnId, totalChunks, totalFrames) } }
  /// Never blocks the caller: the platform cancel path must not wait behind a BEGIN warm-up on this queue.
  /// Group A (review r7): the turn is SEALED synchronously first, so once this returns no `drained` can be emitted
  /// for it, even by a final check already running; the queued cancel then reports its reason.
  func cancel(turnId: String, reason: String) {
    sealLock.lock(); sealedTurnIds.insert(turnId); sealLock.unlock()
    queue.async { self._cancel(turnId, reason) }
  }
  /// Platform invalidation: route change, interruption, media services reset, engine configuration change.
  func invalidate(reason: String) { queue.sync { self._invalidate(reason, stopPlayer: true) } }
  /// Invalidation from a thread that must not wait (the independent playback-teardown path). The epoch is
  /// bumped before any later callback can be judged, because callbacks are judged on this same queue.
  func invalidateAsync(reason: String) {
    sealLock.lock(); sealCount += 1; sealLock.unlock()      // review r7: no drain after this returns
    queue.async { self._invalidate(reason, stopPlayer: false) }
  }
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
    // Group A (review r6): the playhead the start frame is derived from and the turn anchor are ONE render-anchor read,
    // inside one unchanged render-lifetime generation, on a timeline >= minimumTimelineFrames old. The turn begins at
    // that read: no turn state is derived from any earlier read, so a restart before it is simply before the turn.
    // Bounded wait (same bound as before) for an anchor that is old enough.
    var waitedMs = 0
    var beginGeneration = player.renderGeneration()
    var anchor = player.renderAnchor()
    func usable(_ a: (sampleTime: Int64, hostTime: UInt64)?) -> Bool {
      guard let a else { return false }
      return a.sampleTime >= minimumTimelineFrames && player.renderGeneration() == beginGeneration
    }
    while !usable(anchor) && waitedMs < playheadWaitMs {
      usleep(2_000); waitedMs += 2
      beginGeneration = player.renderGeneration()
      anchor = player.renderAnchor()
    }
    guard let beginAnchor = anchor else {
      var t = Turn(id: id, generation: gen, nextStart: 0)
      turn = t
      fail(&t, "playhead_unavailable")
      return
    }
    guard player.renderGeneration() == beginGeneration else {
      var t = Turn(id: id, generation: gen, nextStart: 0)
      turn = t
      fail(&t, "render_lifetime_changed_at_begin")
      return
    }
    guard beginAnchor.sampleTime >= minimumTimelineFrames else {
      var t = Turn(id: id, generation: gen, nextStart: 0)
      turn = t
      fail(&t, "render_timeline_too_young")
      return
    }
    let p = beginAnchor.sampleTime
    if unanchoredLegacyFrames > 0 {          // QA-IOS-2: legacy queued while the playhead was unknown
      legacyEndEstimate = max(legacyEndEstimate, p) + unanchoredLegacyFrames
      unanchoredLegacyFrames = 0
    }
    let start = max(p, legacyEndEstimate) + leadFrames
    turn = Turn(id: id, generation: gen, nextStart: start)
    turn?.renderGeneration = beginGeneration
    turn?.turnAnchor = beginAnchor
    sealLock.lock(); turn?.sealAtBegin = sealCount; sealLock.unlock()
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
    // Group A (d) + review r8 F2: ONE render-anchor read, inside one unchanged render-lifetime generation, is both this
    // buffer's timeline reference AND the playhead its start frame is derived from (no earlier, staler read). Read on
    // the barrier queue, never in a handler (IOS-2).
    let generationBefore = player.renderGeneration()
    guard generationBefore == t.renderGeneration else { fail(&t, "render_lifetime_changed"); return false }
    guard let scheduleAnchor = player.renderAnchor() else {
      // QA-IOS-1: never schedule against an unknown playhead (paused node: playerTime nil, timeline parked high).
      fail(&t, player.currentSampleTime() == nil ? "playhead_unavailable_at_schedule" : "render_anchor_unavailable_at_schedule")
      return false
    }
    guard player.renderGeneration() == generationBefore else {
      fail(&t, "render_lifetime_changed_at_schedule"); return false
    }
    guard scheduleAnchor.sampleTime >= minimumTimelineFrames else {
      fail(&t, "render_timeline_too_young"); return false
    }
    if let broken = discontinuity(scheduleAnchor, from: t.turnAnchor) { fail(&t, broken); return false }
    let pos = scheduleAnchor.sampleTime
    // Review r10: a conservative UPPER bound on the render position right now (a stale anchor is projected forward
    // by the elapsed host time; renderAhead covers the render pipeline). Every start frame stays beyond it.
    guard let renderedUpperBound = upperRenderBound(scheduleAnchor) else {
      fail(&t, "render_ahead_bound_unavailable"); return false
    }
    // IOS-3: after an underrun the playhead may have overtaken nextStart. A buffer scheduled in the past would
    // have an end frame at or behind the playhead, so even a stop() flush callback would satisfy the position
    // check. Re-anchor ahead of the playhead (an audible gap, never a false drain).
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
    if start < renderedUpperBound + leadFrames / 2 {
      start = renderedUpperBound + leadFrames
      log.append("underrun_reanchor seq=\(seq) \(t.nextStart)->\(start)")
    }
    let endFrame = start + frames
    t.endFrames[seq] = endFrame
    t.scheduleAnchors[seq] = (scheduleAnchor.sampleTime, scheduleAnchor.hostTime, generationBefore)
    t.nextStart = endFrame
    t.expectedSeq += 1
    t.scheduledFrames += frames
    turn = t
    let capturedEpoch = epoch
    let scheduled = player.schedule(pcm16: pcm, atSampleTime: start) { [weak self] hostAtCallback in
      self?.queue.async { self?._playedBack(epoch: capturedEpoch, turnId: id, seq: seq, host: hostAtCallback) }
    }
    guard scheduled else { fail(&t, "player_unavailable"); return false }
    // Review r8 F2 / r9 F1 / r10 F1: the submission must be PROVEN timely. From a render anchor read after submission,
    // in the same render lifetime, the conservative upper bound on the render position (stale anchor projected forward
    // by elapsed host time, plus the render-ahead bound) must still be at least leadFrames/4 short of the start frame.
    // A missing anchor is retried briefly (bounded, ~10 ms); no proof = fail closed.
    var after = player.renderAnchor()
    var tries = 0
    while after == nil && tries < 5 { usleep(2_000); tries += 1; after = player.renderAnchor() }
    guard let submitted = after, player.renderGeneration() == generationBefore,
          submitted.hostTime >= scheduleAnchor.hostTime else {
      fail(&t, "submission_unverified"); return false
    }
    guard let submittedUpperBound = upperRenderBound(submitted) else {
      fail(&t, "render_ahead_bound_unavailable"); return false
    }
    guard submittedUpperBound + leadFrames / 4 <= start else {
      fail(&t, "scheduled_behind_playhead(start=\(start) pos=\(submittedUpperBound))"); return false
    }
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
    guard let endFrame = t.endFrames[seq], let a0 = t.scheduleAnchors[seq] else { staleCallbacks += 1; return }
    // Verification is monotonic: a duplicate or re-delivered handler of an already verified buffer is stale.
    guard !t.verified.contains(seq) else { staleCallbacks += 1; return }
    let required = endFrame + player.presentationLatencyFrames()
    let canRetry = attempt < FarewellPlaybackBarrier.anchorRetryLimit
    func retry() {
      queue.asyncAfter(deadline: .now() + .milliseconds(FarewellPlaybackBarrier.anchorRetryIntervalMs)) { [weak self] in
        self?._playedBack(epoch: captured, turnId: turnId, seq: seq, host: hostAtCallback, attempt: attempt + 1)
      }
    }
    // `.dataPlayedBack` also fires when stop() flushes the buffer: judge the position AT the callback instant
    // (IOS-1), reconstructed from a render anchor read here, off the handler (IOS-2). No anchor = not rendering (yet).
    // Group A: a momentarily missing anchor is retried; whatever anchor is finally used must still pass (c)+(d)+(e),
    // and must be read in the render lifetime the buffer was scheduled in. Generation read BEFORE and AFTER the anchor:
    // a restart advances it before the new timeline exists, so an anchor of a new lifetime always fails here, whatever
    // its timing (also a flush handler delivered late, after the restart).
    guard player.renderGeneration() == a0.generation else { fail(&t, "render_lifetime_changed"); return }
    let anchor = player.renderAnchor()
    guard player.renderGeneration() == a0.generation else { fail(&t, "render_lifetime_changed"); return }
    guard let a = anchor else {
      if canRetry { retry() } else { fail(&t, "played_back_without_position") }
      return
    }
    let dtSec = (Double(hostAtCallback) - Double(a.hostTime)) / player.hostTicksPerSecond
    // Review 1a798d2c HIGH-2: projecting FORWARD from an older anchor assumes rendering continued, so a stalled
    // render clock would "advance" with wall time and verify audio that never played. Only project BACKWARD
    // from an anchor taken at or after the callback (that can only under-count). Wait briefly for one.
    if dtSec > 0 {
      if canRetry { retry() } else { fail(&t, "render_anchor_stale") }
      return
    }
    let pos = a.sampleTime + Int64((dtSec * player.sampleRate).rounded(.down))
    // (c) A flush/stop callback, judged on its own or on a restarted timeline, lands far short of the end.
    guard pos >= required - FarewellPlaybackBarrier.earlyCallbackSlackFrames else {
      fail(&t, "played_back_before_end_frame(pos=\(pos) < \(required))"); return
    }
    // (d) The anchor must come from the render lifetime that the buffer was scheduled on (no stop/restart, reset or
    // stall beyond the bound in between): sample and host time advanced together. Continuity with the turn anchor is
    // enforced at every push and, for the drain itself, by the anchor read at the emission.
    if let broken = discontinuity(a, from: (a0.sampleTime, a0.hostTime)) {
      fail(&t, broken); return
    }
    // (e) The continuous timeline itself has to be seen past the buffer's last frame + latency.
    guard a.sampleTime >= required else {
      if canRetry { retry() } else { fail(&t, "played_back_before_end_frame(pos=\(a.sampleTime) < \(required))") }
      return
    }
    t.verified.insert(seq)
    turn = t
    maybeDrained()
  }

  /// Review r10: conservative upper bound on the player position being rendered NOW, from one render anchor.
  private func upperRenderBound(_ a: (sampleTime: Int64, hostTime: UInt64)) -> Int64? {
    guard let ahead = player.renderAheadFrames(), ahead >= 0 else { return nil }
    let now = player.hostNow()
    let elapsedTicks = now > a.hostTime ? Double(now - a.hostTime) : 0
    let elapsedFrames = Int64((elapsedTicks / player.hostTicksPerSecond * player.sampleRate).rounded(.up))
    return a.sampleTime + elapsedFrames + ahead
  }

  /// (d) for one anchor against a reference anchor of the same turn: nil when continuous, else the fail reason.
  private func discontinuity(_ a: (sampleTime: Int64, hostTime: UInt64),
                             from ref: (sampleTime: Int64, hostTime: UInt64)) -> String? {
    let elapsedFrames = (Double(a.hostTime) - Double(ref.hostTime)) / player.hostTicksPerSecond * player.sampleRate
    guard elapsedFrames <= FarewellPlaybackBarrier.continuityWindowFrames else { return "render_continuity_window_exceeded" }
    let deviation = Double(a.sampleTime - ref.sampleTime) - elapsedFrames
    let tolerance = FarewellPlaybackBarrier.continuityToleranceFrames
      + FarewellPlaybackBarrier.continuityDriftPerFrame * max(0, elapsedFrames)
    guard a.hostTime >= ref.hostTime, abs(deviation) <= tolerance else {
      return "render_discontinuity(deviation=\(Int64(deviation.rounded())))"
    }
    return nil
  }

  private func maybeDrained(epoch captured: Int? = nil, attempt: Int = 0) {
    guard var t = turn, !t.terminal, let last = t.finalSeq, let frames = t.declaredFrames else { return }
    if let captured, captured != epoch { return }            // a queued final check of an older turn/epoch
    guard (0...last).allSatisfy({ t.verified.contains($0) }) else { return }
    // Group A: the whole turn stayed in ONE render lifetime up to the emission. Checked and emitted atomically against
    // fence advances, and a final anchor read at the emission must still lie on the turn's timeline (review r4).
    enum Final { case emitted, noAnchor, broken(String), sealed }
    var final = Final.noAnchor
    let inLifetime = player.whileRenderGeneration(t.renderGeneration) {
      guard let a = player.renderAnchor() else { final = .noAnchor; return }
      if let broken = discontinuity(a, from: t.turnAnchor) { final = .broken(broken); return }
      // Atomic against a concurrent cancel / invalidate (review r7): sealed = never drained; its queued job reports it.
      sealLock.lock(); defer { sealLock.unlock() }
      guard sealCount == t.sealAtBegin, !sealedTurnIds.contains(t.id) else { final = .sealed; return }
      var drained = t
      drained.terminal = true
      turn = drained
      let at = nowMs()   // captured ONCE, at the verified boundary
      log.append("drained \(drained.id) at=\(at)")
      emit(.drained(turnId: drained.id, nativeGeneration: drained.generation, drainedAtEpochMs: at, framesPlayed: frames,
                    lastSeq: last, evidence: "ios_dataPlayedBack+position"))
      final = .emitted
    }
    guard inLifetime else { fail(&t, "render_lifetime_changed"); return }
    switch final {
    case .emitted, .sealed: return
    case .broken(let reason): fail(&t, reason)
    case .noAnchor:
      guard attempt < FarewellPlaybackBarrier.anchorRetryLimit else { fail(&t, "final_render_anchor_unavailable"); return }
      let e = epoch
      queue.asyncAfter(deadline: .now() + .milliseconds(FarewellPlaybackBarrier.anchorRetryIntervalMs)) { [weak self] in
        self?.maybeDrained(epoch: e, attempt: attempt + 1)
      }
    }
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
