import AVFoundation
import Foundation

/// Group A: the identity of one continuous render lifetime of the plugin's player node. Every operation that can end
/// it or begin a new one (node stop/reset, play() on a node that is not playing, engine start/stop/reset, engine
/// configuration change, interruption, route change, media services loss/reset) ADVANCES the generation BEFORE the
/// operation runs. A render anchor read while the generation still equals the one read when a buffer was scheduled
/// (checked before AND after the read) therefore comes from the render lifetime that buffer was scheduled on; one
/// from a restarted timeline cannot, however close its timing looks. Lock-protected; never touches the node.
final class RenderLifetimeFence {
  private let lock = NSLock()
  private var generation = 0
  var current: Int { lock.lock(); defer { lock.unlock() }; return generation }
  func advance() { lock.lock(); generation += 1; lock.unlock() }
  /// Runs `body` under the fence lock only if the generation is still `expected`; an advance waits for it.
  /// `body` must not advance this fence or wait on anything that does.
  func whileCurrent(_ expected: Int, _ body: () -> Void) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard generation == expected else { return false }
    body()
    return true
  }
}

/// Farewell scheduling on the plugin's own player node (24 kHz mono PCM16). Never touches the node from a
/// completion handler (IOS-2). A retired playback lifetime refuses to schedule or start the node.
final class PluginFarewellPlayer: FarewellPlayer {
  private weak var engine: AVAudioEngine?
  private weak var node: AVAudioPlayerNode?
  private let format: AVAudioFormat
  private let lifetime: RetiringPlaybackLifetime
  private let fence: RenderLifetimeFence

  init(engine: AVAudioEngine, node: AVAudioPlayerNode, format: AVAudioFormat, lifetime: RetiringPlaybackLifetime,
       fence: RenderLifetimeFence = RenderLifetimeFence()) {
    self.engine = engine
    self.node = node
    self.format = format
    self.lifetime = lifetime
    self.fence = fence
  }

  func renderGeneration() -> Int { fence.current }
  func whileRenderGeneration(_ generation: Int, _ body: () -> Void) -> Bool { fence.whileCurrent(generation, body) }

  var sampleRate: Double { format.sampleRate }

  /// The node only while it is still attached to a live engine: AVFAudio raises an uncatchable exception
  /// for render-time reads or scheduling on a detached node.
  private var attachedNode: AVAudioPlayerNode? {
    guard !lifetime.isRetired, let node, node.engine != nil else { return nil }
    return node
  }

  func currentSampleTime() -> Int64? {
    guard let node = attachedNode, let nodeTime = node.lastRenderTime,
          let playerTime = node.playerTime(forNodeTime: nodeTime) else { return nil }
    return playerTime.sampleTime
  }

  func renderAnchor() -> (sampleTime: Int64, hostTime: UInt64)? {
    guard let node = attachedNode, let nodeTime = node.lastRenderTime,
          nodeTime.isHostTimeValid, nodeTime.isSampleTimeValid,
          let playerTime = node.playerTime(forNodeTime: nodeTime), playerTime.isSampleTimeValid else { return nil }
    return (playerTime.sampleTime, nodeTime.hostTime)
  }

  let hostTicksPerSecond: Double = {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return 1e9 * Double(timebase.denom) / Double(timebase.numer)
  }()

  func hostNow() -> UInt64 { mach_absolute_time() }

  /// Conservative bound, in player frames, on how far the graph can have rendered ahead of a render anchor's host time
  /// (review r11): the player node's documented maximum downstream pipeline latency (`outputPresentationLatency`),
  /// the output node's presentation latency, two ACTUAL I/O buffers, plus the largest slice the player's audio unit may
  /// render at once (`maximumFramesToRender`, counted as player frames, which over-estimates if it is at hardware rate).
  /// Returns nil when the slice limit is unavailable: the barrier then fails closed.
  func renderAheadFrames() -> Int64? {
    guard let node = attachedNode else { return nil }
    let slice = Int64(node.auAudioUnit.maximumFramesToRender)
    guard slice > 0 else { return nil }
    let downstream = max(0, node.outputPresentationLatency)
    let output = max(0, engine?.outputNode.presentationLatency ?? 0)
    #if os(iOS)
    let io = AVAudioSession.sharedInstance().ioBufferDuration
    #else
    let io = 0.02
    #endif
    return Int64(((downstream + output + 2 * io) * format.sampleRate).rounded(.up)) + slice
  }

  func presentationLatencyFrames() -> Int64 {
    guard let engine else { return 0 }
    return Int64((engine.outputNode.presentationLatency * format.sampleRate).rounded(.up))
  }

  func schedule(pcm16: Data, atSampleTime: Int64, onPlayedBack: @escaping (UInt64) -> Void) -> Bool {
    guard let node = attachedNode else { return false }
    let frames = AVAudioFrameCount(pcm16.count / MemoryLayout<Int16>.size)
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return false }
    buffer.frameLength = frames
    let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    guard let destination = list[0].mData else { return false }
    pcm16.copyBytes(to: destination.assumingMemoryBound(to: UInt8.self), count: pcm16.count)
    list[0].mDataByteSize = UInt32(pcm16.count)
    let when = AVAudioTime(sampleTime: atSampleTime, atRate: format.sampleRate)
    let scheduled: Void? = lifetime.boundary {
      node.scheduleBuffer(buffer, at: when, options: [], completionCallbackType: .dataPlayedBack) { _ in
        onPlayedBack(mach_absolute_time())   // lock-free; NO node calls here (IOS-2 deadlock with stop())
      }
    }
    return scheduled != nil
  }

  func ensurePlaying() {
    guard let node = attachedNode, let engine, engine.isRunning else { return }
    if !node.isPlaying {
      fence.advance()                      // play() on a stopped node begins a new render lifetime
      _ = lifetime.boundary { node.play() }
    }
  }

  func stop() {
    fence.advance()
    if let node, node.engine != nil { node.stop() }
  }
}

/// Lets a lifetime's stop closure reach the barrier built after it. WEAK (review 1a798d2c MEDIUM-4): the barrier
/// owns its player, the player owns the lifetime and the lifetime owns this closure, so a strong reference here
/// would keep every session's player, barrier and lifetime alive forever. The plugin's `farewellBarrier` owns it.
final class FarewellBarrierBox {
  weak var barrier: FarewellPlaybackBarrier?
}
