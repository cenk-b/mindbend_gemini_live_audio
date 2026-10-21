// On-device acceptance of the attributed farewell API through the REAL MethodChannel, the REAL native plugin
// (session start, AudioTrack / AVAudioPlayerNode, barrier, poller) and the REAL event channel. Silent PCM.
// Run: flutter test integration_test/attributed_farewell_test.dart -d <device>
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mindbend_gemini_live_audio/mindbend_gemini_live_audio.dart';

Uint8List _pcm(int frames) => Uint8List(frames * 2);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final plugin = MindbendGeminiLiveAudio();
  final events = <FarewellPlaybackEvent>[];
  final raw = <GeminiLiveAudioEvent>[];
  StreamSubscription<GeminiLiveAudioEvent>? sub;
  GeminiLiveAudioStartResult? start;
  var gen = 100;

  Future<FarewellPlaybackEvent> outcome(String turnId, {Duration timeout = const Duration(seconds: 12)}) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      for (final e in events) {
        if (e.turnId == turnId) return e;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw TimeoutException('no farewell outcome for $turnId; events=${raw.map((e) => '${e.type}:${e.data}').toList()}');
  }

  setUpAll(() async {
    sub = plugin.eventStream.listen((e) {
      raw.add(e);
      final parsed = FarewellPlaybackEvent.tryParse(e);
      if (parsed != null) events.add(parsed);
    });
    start = await plugin.startSession();
    // ignore: avoid_print
    print('T21_NATIVE start=${start!.toMap()}');
  });

  tearDownAll(() async {
    await plugin.stopSession();
    await sub?.cancel();
  });

  testWidgets('capability: the installed native plugin reports API 2 attributed drain', (tester) async {
    final caps = await plugin.farewellCapabilities();
    expect(caps.supportsAttributedDrain, isTrue);
    expect(caps.evidence, anyOf('android_timestamp', 'ios_dataPlayedBack+position'));
  });

  bool nativeSession() {
    if (start!.isNativeAec) return true;
    // ignore: avoid_print
    print('T21_NATIVE NOT_RUN: this device has no native AEC session (${start!.errorCode}); the plugin keeps '
        'legacy half-duplex and the attributed playback path cannot run here.');
    markTestSkipped('no native AEC session on this device: ${start!.errorCode}');
    return false;
  }

  testWidgets('without a native session every farewell call fails closed', (tester) async {
    if (start!.isNativeAec) {
      markTestSkipped('native session available');
      return;
    }
    expect(await plugin.beginFarewell(turnId: 'fw_none', nativeGeneration: 1), isFalse);
    expect(await plugin.pushFarewell(turnId: 'fw_none', seq: 0, pcm: _pcm(10)), isFalse);
    expect(await plugin.endFarewell(turnId: 'fw_none', totalChunks: 1, totalFrames: 10), isFalse);
    await plugin.cancelFarewell(turnId: 'fw_none', reason: 'x');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(events.where((e) => e.turnId == 'fw_none'), isEmpty);
  });

  testWidgets('positive: legacy then a 400 ms farewell drains with platform evidence', (tester) async {
    if (!nativeSession()) return;
    await plugin.pushPlaybackPcm(_pcm(4800)); // 200 ms of ordinary audio ahead of the farewell
    final id = 'fw_pos_${gen++}';
    expect(await plugin.beginFarewell(turnId: id, nativeGeneration: gen), isTrue);
    for (var i = 0; i < 4; i++) {
      expect(await plugin.pushFarewell(turnId: id, seq: i, pcm: _pcm(2400)), isTrue);
    }
    final t0 = DateTime.now().millisecondsSinceEpoch;
    expect(await plugin.endFarewell(turnId: id, totalChunks: 4, totalFrames: 9600), isTrue);
    final e = await outcome(id);
    expect(e, isA<FarewellPlaybackDrained>(), reason: (e is FarewellPlaybackUnverified) ? e.reason : '');
    final d = e as FarewellPlaybackDrained;
    expect(d.nativeGeneration, gen);
    expect(d.framesPlayed, 9600);
    expect(d.lastSeq, 3);
    expect(d.evidence, anyOf('android_timestamp', 'ios_dataPlayedBack+position'));
    expect(d.drainedAtEpochMs, greaterThanOrEqualTo(t0 - 600), reason: 'not before the audio could have played');
    // ignore: avoid_print
    print('T21_NATIVE drained ${d.turnId} at=${d.drainedAtEpochMs} evidence=${d.evidence} endToDrainMs=${d.drainedAtEpochMs - t0}');
  });

  testWidgets('negative: a barge-in flush during the farewell is never a drain', (tester) async {
    if (!nativeSession()) return;
    final id = 'fw_flush_${gen++}';
    expect(await plugin.beginFarewell(turnId: id, nativeGeneration: gen), isTrue);
    expect(await plugin.pushFarewell(turnId: id, seq: 0, pcm: _pcm(48000)), isTrue); // 2 s
    expect(await plugin.endFarewell(turnId: id, totalChunks: 1, totalFrames: 48000), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await plugin.flushPlayback();
    final e = await outcome(id);
    expect(e, isA<FarewellPlaybackUnverified>());
    // ignore: avoid_print
    print('T21_NATIVE flush -> ${(e as FarewellPlaybackUnverified).reason}');
  });

  testWidgets('negative: cancel during the farewell is never a drain', (tester) async {
    if (!nativeSession()) return;
    final id = 'fw_cancel_${gen++}';
    expect(await plugin.beginFarewell(turnId: id, nativeGeneration: gen), isTrue);
    expect(await plugin.pushFarewell(turnId: id, seq: 0, pcm: _pcm(48000)), isTrue);
    expect(await plugin.endFarewell(turnId: id, totalChunks: 1, totalFrames: 48000), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await plugin.cancelFarewell(turnId: id, reason: 'user_done');
    final e = await outcome(id);
    expect(e, isA<FarewellPlaybackUnverified>());
    expect((e as FarewellPlaybackUnverified).reason, 'user_done');
  });

  testWidgets('negative: END totals that disagree with what was pushed fail closed', (tester) async {
    if (!nativeSession()) return;
    final id = 'fw_totals_${gen++}';
    expect(await plugin.beginFarewell(turnId: id, nativeGeneration: gen), isTrue);
    expect(await plugin.pushFarewell(turnId: id, seq: 0, pcm: _pcm(2400)), isTrue);
    expect(await plugin.endFarewell(turnId: id, totalChunks: 1, totalFrames: 2401), isTrue);
    final e = await outcome(id);
    expect((e as FarewellPlaybackUnverified).reason, 'end_totals_mismatch');
  });

  testWidgets('negative: a caller-supplied drain flag still cannot mint native evidence', (tester) async {
    final status = await plugin.noteFarewellAnchor(seq: 0, framesPlayed: 10, generation: 1, nativeDrained: true);
    expect(status.isNativeDrain, isFalse);
  });

  testWidgets('negative: stopping the session mid-farewell is never a drain; restart drains again', (tester) async {
    if (!nativeSession()) return;
    final id = 'fw_stop_${gen++}';
    expect(await plugin.beginFarewell(turnId: id, nativeGeneration: gen), isTrue);
    expect(await plugin.pushFarewell(turnId: id, seq: 0, pcm: _pcm(48000)), isTrue);
    expect(await plugin.endFarewell(turnId: id, totalChunks: 1, totalFrames: 48000), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final sinkBefore = events.length;
    await plugin.stopSession();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(events.skip(sinkBefore).whereType<FarewellPlaybackDrained>().where((e) => e.turnId == id), isEmpty);
    // The event stream is recreated after stop; re-subscribe, restart, and prove a fresh lifetime still drains.
    await sub?.cancel();
    sub = plugin.eventStream.listen((e) {
      raw.add(e);
      final parsed = FarewellPlaybackEvent.tryParse(e);
      if (parsed != null) events.add(parsed);
    });
    start = await plugin.startSession();
    expect(start!.isNativeAec, isTrue);
    // As in a real Ending, the farewell comes after the restarted session has settled and spoken. A farewell that
    // is live while iOS reconfigures the engine at startup is (correctly) invalidated by engine_configuration_change.
    await plugin.pushPlaybackPcm(_pcm(4800));
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final id2 = 'fw_restart_${gen++}';
    expect(await plugin.beginFarewell(turnId: id2, nativeGeneration: gen), isTrue);
    expect(await plugin.pushFarewell(turnId: id2, seq: 0, pcm: _pcm(4800)), isTrue);
    expect(await plugin.endFarewell(turnId: id2, totalChunks: 1, totalFrames: 4800), isTrue);
    final restarted = await outcome(id2);
    // ignore: avoid_print
    print('T21_NATIVE restart -> ${restarted is FarewellPlaybackUnverified ? restarted.reason : 'drained'}');
    expect(restarted, isA<FarewellPlaybackDrained>());
  });
}
