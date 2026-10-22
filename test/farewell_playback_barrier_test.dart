import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mindbend_gemini_live_audio/mindbend_gemini_live_audio.dart';
import 'package:mindbend_gemini_live_audio/mindbend_gemini_live_audio_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('mindbend_gemini_live_audio/methods');
  final platform = MethodChannelMindbendGeminiLiveAudio();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('a command acknowledgement is not reported as a native drain', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'noteFarewellAnchor') {
        final args = call.arguments as Map<Object?, Object?>;
        expect(args['nativeDrained'], isFalse);
        return <String, Object?>{
          'generation': args['generation'],
          'state': 'armed',
          'evidence': 'none',
          'framesPlayed': args['framesPlayed'],
          'lastSeq': args['seq'],
          'restartBlocked': false,
        };
      }
      if (call.method == 'markPlaybackComplete') {
        return null;
      }
      return <String, Object?>{
        'generation': 1,
        'state': 'armed',
        'evidence': 'command_ack',
        'framesPlayed': 0,
        'lastSeq': -1,
        'restartBlocked': false,
      };
    });

    final anchor = await platform.noteFarewellAnchor(
      seq: 1,
      framesPlayed: 8,
      generation: 1,
      nativeDrained: false,
    );
    expect(anchor.isNativeDrain, isFalse);
    final audio = MindbendGeminiLiveAudio();
    final begun = await audio.beginFarewellDrain(expectedFrames: 100);
    expect(begun.evidence, 'command_ack');
    expect(begun.isNativeDrain, isFalse);
  });
}
