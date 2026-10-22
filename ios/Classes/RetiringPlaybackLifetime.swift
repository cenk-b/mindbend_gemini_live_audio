import Foundation

/// One non-reusable native lifetime. The lock protects state only, never a native call.
/// Stop returning is an acknowledgement of the call, not physical silence or data quiescence.
final class RetiringPlaybackLifetime {
  private let lock = NSLock()
  private let control = DispatchQueue(label: "mindbend.playback.control", qos: .userInitiated)
  private let stop: () throws -> Void
  private let release: () throws -> Void
  private var retired = false
  private var status = "not_requested"
  private var callbacks: [(String) -> Void] = []
  init(stop: @escaping () throws -> Void, release: @escaping () throws -> Void = {}) {
    self.stop = stop; self.release = release
  }
  var isRetired: Bool { lock.lock(); defer { lock.unlock() }; return retired }
  var teardownStatus: String { lock.lock(); defer { lock.unlock() }; return status }
  @discardableResult func boundary<T>(_ operation: () throws -> T) rethrows -> T? {
    if isRetired { return nil }
    do {
      let value = try operation()
      if isRetired { try? stop(); return nil }
      return value
    } catch {
      cancel(); throw error
    }
  }
  func cancel(completion: @escaping (String) -> Void = { _ in }) {
    lock.lock()
    if retired {
      let current = status
      if current == "returned" || current == "failed" { lock.unlock(); completion(current); return }
      callbacks.append(completion); lock.unlock(); return
    }
    retired = true; status = "requested"; callbacks.append(completion)
    lock.unlock()
    control.async { [self] in
      lock.lock(); status = "started"; lock.unlock()
      var failed = false
      do { try stop() } catch { failed = true }
      do { try release() } catch { failed = true }
      lock.lock(); status = failed ? "failed" : "returned"
      let result = status; let done = callbacks; callbacks.removeAll(); lock.unlock()
      done.forEach { $0(result) }
    }
  }
}
