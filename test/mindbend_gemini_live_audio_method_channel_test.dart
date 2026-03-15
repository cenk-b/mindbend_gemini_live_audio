import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mindbend_gemini_live_audio/mindbend_gemini_live_audio_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = MethodChannelMindbendGeminiLiveAudio();
  const methodChannel = MethodChannel('mindbend_gemini_live_audio/methods');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (MethodCall methodCall) async {
          switch (methodCall.method) {
            case 'startSession':
              return <String, Object?>{
                'aecActive': true,
                'nsActive': true,
                'agcActive': true,
                'transportMode': 'native_aec',
                'captureSampleRateHz': 16000,
                'playbackSampleRateHz': 24000,
              };
            case 'pushPlaybackPcm':
              expect(methodCall.arguments, isA<Uint8List>());
              return null;
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
  });

  test('startSession maps native result', () async {
    final result = await platform.startSession();

    expect(result.transportMode, 'native_aec');
    expect(result.aecActive, true);
  });
}
