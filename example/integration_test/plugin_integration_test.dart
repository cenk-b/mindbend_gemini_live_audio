import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mindbend_gemini_live_audio/mindbend_gemini_live_audio.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('plugin instantiates', (WidgetTester tester) async {
    final plugin = MindbendGeminiLiveAudio();
    expect(plugin, isNotNull);
  });
}
