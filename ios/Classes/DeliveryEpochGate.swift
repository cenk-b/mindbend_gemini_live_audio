import Foundation

/// Fences queued deliveries to one Dart event sink.
///
/// A payload is stamped with the subscription epoch when it is queued and is delivered
/// only if that subscription is still current and the plugin is still attached to its
/// engine. A cancel, a replacement listen or an engine detach therefore drops every
/// payload queued before it, so bytes from an old subscription or session never reach a
/// new one (hot restart, re-listen).
final class DeliveryEpochGate {
  private let lock = NSLock()
  private var epoch = 0
  private var listening = false
  private var detached = false

  /// A Dart listener attached. False after an engine detach: the listener is refused.
  @discardableResult
  func listen() -> Bool {
    lock.lock(); defer { lock.unlock() }
    if detached { return false }
    epoch += 1
    listening = true
    return true
  }

  /// The Dart listener cancelled. Everything queued for it is dropped.
  func cancel() {
    lock.lock(); defer { lock.unlock() }
    epoch += 1
    listening = false
  }

  /// The plugin was detached from its engine. Irreversible.
  func detach() {
    lock.lock(); defer { lock.unlock() }
    detached = true
    epoch += 1
    listening = false
  }

  var isDetached: Bool {
    lock.lock(); defer { lock.unlock() }
    return detached
  }

  /// Stamp for a payload queued now; nil when nothing may be delivered.
  func stamp() -> Int? {
    lock.lock(); defer { lock.unlock() }
    return listening && !detached ? epoch : nil
  }

  /// True only if the subscription that [stamp] was taken under is still current.
  func admits(_ stamp: Int) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return listening && !detached && stamp == epoch
  }
}
