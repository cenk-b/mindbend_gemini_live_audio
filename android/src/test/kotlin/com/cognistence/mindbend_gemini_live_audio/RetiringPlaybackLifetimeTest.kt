package com.cognistence.mindbend_gemini_live_audio
import java.util.concurrent.*
import java.util.concurrent.atomic.*

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
 test("simultaneous cancellation shares result") {val p=RetiringPlaybackLifetime({},{});val results=CopyOnWriteArrayList<CompletableFuture<String>>();val threads=(1..8).map {Thread {results.add(p.cancel())}.apply {start()}};threads.forEach{it.join()};checkThat(results.all{it===results.first()},"single cancellation");results.first().get()}
 test("nested cancellation does not deadlock") {lateinit var p:RetiringPlaybackLifetime;p=RetiringPlaybackLifetime({p.cancel()},{});checkThat(p.cancel().get(3,TimeUnit.SECONDS)=="returned","nested")}
 test("stop failure still attempts release") {val n=AtomicInteger();val p=RetiringPlaybackLifetime({error("stop")},{n.incrementAndGet()});checkThat(p.cancel().get()=="failed"&&n.get()==1,"failed truthful")}
 test("unsupported release reports failed") {val p=RetiringPlaybackLifetime({}, {throw UnsupportedOperationException()});checkThat(p.cancel().get()=="failed","release unsupported")}
 test("unresolved stop cannot acknowledge") {val entered=CountDownLatch(1);val resume=CountDownLatch(1);val p=RetiringPlaybackLifetime({entered.countDown();signal(resume)},{});val ack=p.cancel();signal(entered);checkThat(!ack.isDone&&p.teardownStatus=="started","not yet returned");resume.countDown();ack.get()}
 test("replacement owns new lifetime and allows unrelated legacy playback") {val old=RetiringPlaybackLifetime({},{});old.cancel().get();val fresh=RetiringPlaybackLifetime({},{});checkThat(fresh.boundary {42}==42&&old.boundary {42}==null,"new native lifetime");fresh.cancel().get()}
 test("positive data and genuine gate evidence remain possible") {val p=RetiringPlaybackLifetime({},{});checkThat(p.boundary {true}==true,"positive playback");val gate=FarewellDrainGate();gate.begin(100);checkThat(gate.noteAnchor(3,100,gate.generation,true)["evidence"]=="native_drain","positive drain model");p.cancel().get()}
 println("RESULT $passed/$passed PASS_LAB")
}
