import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mindbend_gemini_live_audio/mindbend_gemini_live_audio.dart';
import 'package:mindbend_gemini_live_audio/mindbend_gemini_live_audio_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('mindbend_gemini_live_audio/methods');
  final platform = MethodChannelMindbendGeminiLiveAudio();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('an older native plugin reports no attributed farewell capability', () async {
    messenger.setMockMethodCallHandler(channel, null); // MissingPluginException
    final caps = await platform.farewellCapabilities();
    expect(caps.api, 0);
    expect(caps.supportsAttributedDrain, isFalse);
  });

  test('a platform error never advertises the capability', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'boom');
    });
    expect((await platform.farewellCapabilities()).supportsAttributedDrain, isFalse);
  });

  test('api 2 with attributed drain is the only supported shape', () async {
    var reply = <String, Object?>{'api': 2, 'attributedDrain': true, 'platform': 'android', 'evidence': 'android_timestamp'};
    messenger.setMockMethodCallHandler(channel, (call) async => reply);
    expect((await platform.farewellCapabilities()).supportsAttributedDrain, isTrue);
    reply = <String, Object?>{'api': 2, 'attributedDrain': false};
    expect((await platform.farewellCapabilities()).supportsAttributedDrain, isFalse);
    reply = <String, Object?>{'api': 1, 'attributedDrain': true};
    expect((await platform.farewellCapabilities()).supportsAttributedDrain, isFalse);
  });

  test('begin, push, end and cancel carry the exact turn arguments', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'farewellBegin':
          return <String, Object?>{'accepted': true};
        case 'farewellPush':
        case 'farewellEnd':
        case 'farewellCancel':
          return true;
      }
      return null;
    });
    expect(await platform.beginFarewell(turnId: 'fw_1', nativeGeneration: 7), isTrue);
    expect(await platform.pushFarewell(turnId: 'fw_1', seq: 0, pcm: Uint8List.fromList(<int>[1, 2, 3, 4])), isTrue);
    expect(await platform.endFarewell(turnId: 'fw_1', totalChunks: 1, totalFrames: 2), isTrue);
    await platform.cancelFarewell(turnId: 'fw_1', reason: 'barge_in');
    expect(calls.map((c) => c.method), <String>['farewellBegin', 'farewellPush', 'farewellEnd', 'farewellCancel']);
    expect(calls[0].arguments, <String, Object?>{'turnId': 'fw_1', 'nativeGeneration': 7});
    final push = calls[1].arguments as Map<Object?, Object?>;
    expect(push['seq'], 0);
    expect(push['pcm'], Uint8List.fromList(<int>[1, 2, 3, 4]));
    expect(calls[2].arguments, <String, Object?>{'turnId': 'fw_1', 'totalChunks': 1, 'totalFrames': 2});
    expect(calls[3].arguments, <String, Object?>{'turnId': 'fw_1', 'reason': 'barge_in'});
  });

  test('a native begin refusal is reported as not accepted', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => <String, Object?>{'accepted': false, 'reason': 'no_playback'});
    expect(await platform.beginFarewell(turnId: 'fw_1', nativeGeneration: 1), isFalse);
  });

  group('typed farewell events', () {
    GeminiLiveAudioEvent raw(Map<String, Object?> m) => GeminiLiveAudioEvent.fromRaw(m);

    test('a complete drained event parses with its platform evidence', () {
      final event = FarewellPlaybackEvent.tryParse(raw(<String, Object?>{
        'type': 'farewell_drained', 'platform': 'ios', 'atMs': 5,
        'turnId': 'fw_1', 'nativeGeneration': 3, 'drainedAtEpochMs': 1700000000000,
        'framesPlayed': 9600, 'lastSeq': 3, 'evidence': 'ios_dataPlayedBack+position',
      }));
      expect(event, isA<FarewellPlaybackDrained>());
      final drained = event! as FarewellPlaybackDrained;
      expect(drained.turnId, 'fw_1');
      expect(drained.nativeGeneration, 3);
      expect(drained.framesPlayed, 9600);
      expect(drained.lastSeq, 3);
      expect(drained.evidence, 'ios_dataPlayedBack+position');
    });

    test('a drained event missing any field is not a drain', () {
      for (final missing in <String>['turnId', 'nativeGeneration', 'drainedAtEpochMs', 'framesPlayed', 'lastSeq', 'evidence']) {
        final m = <String, Object?>{
          'type': 'farewell_drained', 'turnId': 'fw_1', 'nativeGeneration': 3, 'drainedAtEpochMs': 1,
          'framesPlayed': 2, 'lastSeq': 0, 'evidence': 'android_timestamp',
        }..remove(missing);
        expect(FarewellPlaybackEvent.tryParse(raw(m)), isNull, reason: missing);
      }
    });

    test('unverified events keep their reason; unrelated events are ignored', () {
      final event = FarewellPlaybackEvent.tryParse(raw(<String, Object?>{
        'type': 'farewell_unverified', 'turnId': 'fw_1', 'nativeGeneration': 3, 'reason': 'route_changed',
      }));
      expect((event! as FarewellPlaybackUnverified).reason, 'route_changed');
      expect(FarewellPlaybackEvent.tryParse(raw(<String, Object?>{'type': 'playback_started', 'turnId': 'fw_1', 'nativeGeneration': 3})), isNull);
      expect(FarewellPlaybackEvent.tryParse(GeminiLiveAudioEvent.fromRaw('farewell_drained')), isNull);
    });
  });
}
