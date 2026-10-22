package com.cognistence.mindbend_gemini_live_audio
import java.util.concurrent.*
import java.util.concurrent.atomic.*
import org.junit.Test

/** Review 1a798d2c MEDIUM-6: the lab cases below also run under standard JUnit/Gradle discovery. */
class RetiringPlaybackLifetimeTest {
    @Test fun labCases() = main()
}

private fun checkThat(value: Boolean, message: String) { check(value) { message } }
fun main() {
 var passed = 0
 fun test(name: String, body: () -> Unit) { body(); passed++; println("PASS $name") }
 fun signal(s: CountDownLatch) { checkThat(s.await(3, TimeUnit.SECONDS), "latch deadline") }
 for (phase in listOf("push", "end", "ensurePlaying")) test("blocked_$phase independent teardown and late boundary") {
   val entered=CountDownLatch(1); val resume=CountDownLatch(1); val stopped=CountDownLatch(1); val finished=CountDownLatch(1)
   val restarts=AtomicInteger(0); val releases=AtomicInteger(0)
   val p=RetiringPlaybackLifetime({stopped.countDown()}, {releases.incrementAndGet()})
   p.submit { p.boundary {entered.countDown(); signal(resume)}; p.boundary {restarts.incrementAndGet()}; finished.countDown() }
   signal(entered); val ack=p.cancel(); signal(stopped)
   checkThat(resume.count==1L,"stop must precede data return"); checkThat(ack.get(3,TimeUnit.SECONDS)=="returned","typed native return")
   resume.countDown(); signal(finished); checkThat(restarts.get()==0,"no next native call"); checkThat(releases.get()==1,"release once")
 }
 test("late ensurePlaying return gets immediate second discard") {
   val entered=CountDownLatch(1); val resume=CountDownLatch(1); val done=CountDownLatch(1); val playing=AtomicBoolean(false);val stops=AtomicInteger(0)
   val p=RetiringPlaybackLifetime({playing.set(false);stops.incrementAndGet()}, {})
   p.submit {p.boundary {entered.countDown();signal(resume);playing.set(true)};done.countDown()};signal(entered);p.cancel().get(3,TimeUnit.SECONDS)
   resume.countDown();signal(done);checkThat(!playing.get()&&stops.get()>=2,"late restart discarded")
 }
 test("cancel before begin rejects new work") {val calls=AtomicInteger();val p=RetiringPlaybackLifetime({},{});p.cancel().get();checkThat(p.boundary {calls.incrementAndGet()}==null&&calls.get()==0,"fenced")}
 test("cancel after end waiting drain rejects stale callback") {val p=RetiringPlaybackLifetime({},{});val gate=FarewellDrainGate();gate.begin(40);val old=gate.generation;p.cancel().get();gate.cancel();checkThat(gate.noteAnchor(1,40,old,true)["evidence"]!="native_drain","stale")}
 test("cancel after verified drain irreversibly retires") {val p=RetiringPlaybackLifetime({},{});val gate=FarewellDrainGate();gate.begin(40);checkThat(gate.noteAnchor(1,40,gate.generation,true)["evidence"]=="native_drain","positive");p.cancel().get();gate.cancel();checkThat(gate.begin(40)["restartBlocked"]==true,"rearm forbidden")}
 test("simultaneous cancellation shares result") {val p=RetiringPlaybackLifetime({},{});val results=CopyOnWriteArrayList<TeardownResult>();val threads=(1..8).map {Thread {results.add(p.cancel())}.apply {start()}};threads.forEach{it.join()};checkThat(results.all{it===results.first()},"single cancellation");results.first().get()}
 test("nested cancellation does not deadlock") {lateinit var p:RetiringPlaybackLifetime;p=RetiringPlaybackLifetime({p.cancel()},{});checkThat(p.cancel().get(3,TimeUnit.SECONDS)=="returned","nested")}
 test("stop failure still attempts release") {val n=AtomicInteger();val p=RetiringPlaybackLifetime({error("stop")},{n.incrementAndGet()});checkThat(p.cancel().get()=="failed"&&n.get()==1,"failed truthful")}
 test("unsupported release reports failed") {val p=RetiringPlaybackLifetime({}, {throw UnsupportedOperationException()});checkThat(p.cancel().get()=="failed","release unsupported")}
 test("unresolved stop cannot acknowledge") {val entered=CountDownLatch(1);val resume=CountDownLatch(1);val p=RetiringPlaybackLifetime({entered.countDown();signal(resume)},{});val ack=p.cancel();signal(entered);checkThat(!ack.isDone&&p.teardownStatus=="started","not yet returned");resume.countDown();ack.get()}
 test("replacement owns new lifetime and allows unrelated legacy playback") {val old=RetiringPlaybackLifetime({},{});old.cancel().get();val fresh=RetiringPlaybackLifetime({},{});checkThat(fresh.boundary {42}==42&&old.boundary {42}==null,"new native lifetime");fresh.cancel().get()}
 test("positive data and genuine gate evidence remain possible") {val p=RetiringPlaybackLifetime({},{});checkThat(p.boundary {true}==true,"positive playback");val gate=FarewellDrainGate();gate.begin(100);checkThat(gate.noteAnchor(3,100,gate.generation,true)["evidence"]=="native_drain","positive drain model");p.cancel().get()}
 // UID 505 review of b113d222, P1: CompletableFuture needs API 24, the plugin declares minSdk 23.
 test("teardown result: a callback added before completion runs once with the state") {val r=TeardownResult();val seen=CopyOnWriteArrayList<String>();r.thenAccept {seen.add(it)};checkThat(!r.isDone&&seen.isEmpty(),"pending");r.complete("returned");r.complete("failed");checkThat(seen==listOf("returned")&&r.get()=="returned","completed once")}
 test("teardown result: a callback added after completion runs immediately") {val r=TeardownResult();r.complete("failed");val seen=CopyOnWriteArrayList<String>();r.thenAccept {seen.add(it)};checkThat(seen==listOf("failed"),"immediate")}
 test("teardown result: get times out while teardown has not returned") {val r=TeardownResult();checkThat(try {r.get(50,TimeUnit.MILLISECONDS);false} catch (_: TimeoutException) {true},"timeout");r.complete("returned");checkThat(r.get(1,TimeUnit.SECONDS)=="returned","then returns")}
 test("teardown result: the cancel callback fires on the control thread after native return") {val stopped=CountDownLatch(1);val p=RetiringPlaybackLifetime({stopped.countDown()},{});val got=CountDownLatch(1);val state=AtomicReference<String>();p.cancel().thenAccept {state.set(it);got.countDown()};signal(got);checkThat(stopped.count==0L&&state.get()=="returned","callback after stop")}
 println("RESULT $passed/$passed PASS_LAB")
}
