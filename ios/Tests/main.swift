import Foundation
import Dispatch
func require(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
func wait(_ s: DispatchSemaphore) { require(s.wait(timeout: .now()+3) == .success,"latch deadline") }
var passed=0
func test(_ name: String,_ body: () -> Void) { body(); passed += 1; print("PASS \(name)") }
for phase in ["push","end","ensurePlaying"] { test("blocked_\(phase) independent teardown") {
 let entered=DispatchSemaphore(value:0),resume=DispatchSemaphore(value:0),stopped=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0)
 let p=RetiringPlaybackLifetime(stop:{stopped.signal()})
 DispatchQueue.global().async {p.boundary {entered.signal();wait(resume)};p.boundary {fatalError("retired restart")};done.signal()}
 wait(entered);let ack=DispatchSemaphore(value:0);p.cancel {_ in ack.signal()};wait(stopped);wait(ack)
 require(p.isRetired,"irreversible");resume.signal();wait(done)
} }
test("late ensurePlaying gets immediate second stop") {
 let entered=DispatchSemaphore(value:0),resume=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0),ack=DispatchSemaphore(value:0)
 let lock=NSLock();var playing=false;var stops=0
 let p=RetiringPlaybackLifetime(stop:{lock.lock();playing=false;stops += 1;lock.unlock()})
 DispatchQueue.global().async {p.boundary {entered.signal();wait(resume);lock.lock();playing=true;lock.unlock()};done.signal()}
 wait(entered);p.cancel {_ in ack.signal()};wait(ack);resume.signal();wait(done);lock.lock();require(!playing && stops>=2,"late stopped");lock.unlock()
}
test("cancel before begin rejects work") {let p=RetiringPlaybackLifetime(stop:{});p.cancel();require(p.boundary {42}==nil,"no rearm")}
test("unresolved stop never acknowledges") {
 let entered=DispatchSemaphore(value:0),resume=DispatchSemaphore(value:0),ack=DispatchSemaphore(value:0)
 let p=RetiringPlaybackLifetime(stop:{entered.signal();wait(resume)});p.cancel {_ in ack.signal()};wait(entered)
 require(ack.wait(timeout:.now()+0.02) == .timedOut,"premature ack");require(p.teardownStatus=="started","typed status");resume.signal();wait(ack)
}
test("simultaneous and nested cancellation") {
 let ack=DispatchSemaphore(value:0);var p:RetiringPlaybackLifetime!;p=RetiringPlaybackLifetime(stop:{p.cancel()})
 for _ in 0..<8 {DispatchQueue.global().async {p.cancel {_ in ack.signal()}}};for _ in 0..<8 {wait(ack)}
 require(p.teardownStatus=="returned","nested returned")
}
struct Failed:Error {}
test("stop throwing still releases and reports failed") {let ack=DispatchSemaphore(value:0);var released=false;let p=RetiringPlaybackLifetime(stop:{throw Failed()},release:{released=true});p.cancel {status in require(status=="failed"&&released,"truthful");ack.signal()};wait(ack)}
test("unsupported release reports failed") {let ack=DispatchSemaphore(value:0);let p=RetiringPlaybackLifetime(stop:{},release:{throw Failed()});p.cancel {status in require(status=="failed","release");ack.signal()};wait(ack)}
test("new player supports unrelated legacy after retirement") {let old=RetiringPlaybackLifetime(stop:{});old.cancel();let new=RetiringPlaybackLifetime(stop:{});require(old.boundary {42}==nil && new.boundary {42}==42,"new lifetime")}
test("positive playback operations permitted") {let p=RetiringPlaybackLifetime(stop:{});require(p.boundary {true}==true,"positive");p.cancel()}
print("RESULT \(passed)/\(passed) PASS_LAB")
