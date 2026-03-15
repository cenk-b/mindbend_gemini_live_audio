import 'package:flutter_test/flutter_test.dart';
import 'package:mindbend_gemini_live_audio/mindbend_gemini_live_audio.dart';

void main() {
  test('start result maps defaults safely', () {
    final result = GeminiLiveAudioStartResult.fromMap(
      const <String, Object?>{},
    );

    expect(result.transportMode, 'legacy_half_duplex');
    expect(result.captureSampleRateHz, 16000);
    expect(result.playbackSampleRateHz, 24000);
    expect(result.aecActive, false);
  });
}
