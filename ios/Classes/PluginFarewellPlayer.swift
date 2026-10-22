import AVFoundation
import Foundation

/// Farewell scheduling on the plugin's own player node (24 kHz mono PCM16). Never touches the node from a
/// completion handler (IOS-2). A retired playback lifetime refuses to schedule or start the node.
final class PluginFarewellPlayer: FarewellPlayer {
  private weak var engine: AVAudioEngine?
  private weak var node: AVAudioPlayerNode?
  private let format: AVAudioFormat
  private let lifetime: RetiringPlaybackLifetime

  init(engine: AVAudioEngine, node: AVAudioPlayerNode, format: AVAudioFormat, lifetime: RetiringPlaybackLifetime) {
    self.engine = engine
    self.node = node
    self.format = format
    self.lifetime = lifetime
  }

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
    if !node.isPlaying { _ = lifetime.boundary { node.play() } }
  }

  func stop() { if let node, node.engine != nil { node.stop() } }
}

/// Lets a lifetime's stop closure reach the barrier built after it. WEAK (review 1a798d2c MEDIUM-4): the barrier
/// owns its player, the player owns the lifetime and the lifetime owns this closure, so a strong reference here
/// would keep every session's player, barrier and lifetime alive forever. The plugin's `farewellBarrier` owns it.
final class FarewellBarrierBox {
  weak var barrier: FarewellPlaybackBarrier?
}
