// Track 21 cross-language E2E: JSON-lines bridge to the PLUGIN's FarewellPlaybackBarrier.swift scheduling on
// the plugin's PluginFarewellPlayer over a REAL AVAudioEngine/AVAudioPlayerNode on the macOS host (silent
// mixer). Real `.dataPlayedBack` callbacks; host audio, not iOS device proof.
import AVFoundation
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let outLock = NSLock()
func out(_ s: String) { outLock.lock(); print(s); fflush(stdout); outLock.unlock() }
func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }

let engine = AVAudioEngine()
let node = AVAudioPlayerNode()
let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
engine.attach(node)
engine.connect(node, to: engine.mainMixerNode, format: format)
engine.mainMixerNode.outputVolume = 0
let lifetime = RetiringPlaybackLifetime(stop: { node.stop() })
let player = PluginFarewellPlayer(engine: engine, node: node, format: format, lifetime: lifetime)
let barrier = FarewellPlaybackBarrier(player: player) { e in
  switch e {
  case let .drained(t, g, at, frames, last, ev):
    out("{\"event\":\"drained\",\"turnId\":\"\(esc(t))\",\"gen\":\(g),\"drainedAtEpochMs\":\(at),\"framesPlayed\":\(frames),\"lastSeq\":\(last),\"evidence\":\"\(ev)\"}")
  case let .unverified(t, g, reason):
    out("{\"event\":\"unverified\",\"turnId\":\"\(esc(t))\",\"gen\":\(g),\"reason\":\"\(esc(reason))\"}")
  }
}
do { try engine.start() } catch { out("{\"event\":\"fatal\",\"reason\":\"engine_start\"}"); exit(1) }
node.play()
out("{\"event\":\"ready\",\"timestamps\":true}")

while let line = readLine() {
  guard let data = line.data(using: .utf8),
        let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
  let t = o["turnId"] as? String ?? ""
  switch o["op"] as? String {
  case "begin": barrier.begin(turnId: t, nativeGeneration: o["gen"] as? Int ?? 0)
  case "push":
    let pcm = Data(base64Encoded: o["b64"] as? String ?? "") ?? Data()
    let ok = barrier.push(turnId: t, seq: o["seq"] as? Int ?? -1, pcm16: pcm)
    out("{\"event\":\"pushed\",\"turnId\":\"\(esc(t))\",\"seq\":\(o["seq"] as? Int ?? -1),\"ok\":\(ok)}")
  case "end": barrier.end(turnId: t, totalChunks: o["n"] as? Int ?? 0, totalFrames: Int64(o["frames"] as? Int ?? 0))
  case "cancel": barrier.cancel(turnId: t, reason: o["reason"] as? String ?? "cancel")
  case "externalStop": node.stop()   // a platform-side stop that does NOT go through the barrier
  case "routeChange": barrier.invalidate(reason: "route_changed")
  case "quit": exit(0)
  default: break
  }
}
exit(0)
