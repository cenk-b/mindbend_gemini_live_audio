import 'dart:typed_data';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'mindbend_gemini_live_audio.dart';
import 'mindbend_gemini_live_audio_method_channel.dart';

abstract class MindbendGeminiLiveAudioPlatform extends PlatformInterface {
  MindbendGeminiLiveAudioPlatform() : super(token: _token);

  static final Object _token = Object();

  static MindbendGeminiLiveAudioPlatform _instance =
      MethodChannelMindbendGeminiLiveAudio();

  static MindbendGeminiLiveAudioPlatform get instance => _instance;

  static set instance(MindbendGeminiLiveAudioPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<GeminiLiveAudioStartResult> startSession() {
    throw UnimplementedError('startSession() has not been implemented.');
  }

  Future<void> stopSession() {
    throw UnimplementedError('stopSession() has not been implemented.');
  }

  Future<void> pushPlaybackPcm(Uint8List pcm24kMono16) {
    throw UnimplementedError('pushPlaybackPcm() has not been implemented.');
  }

  Future<void> flushPlayback() {
    throw UnimplementedError('flushPlayback() has not been implemented.');
  }

  Future<void> markPlaybackComplete() {
    throw UnimplementedError(
      'markPlaybackComplete() has not been implemented.',
    );
  }

  Future<void> setDebugOptions(GeminiLiveAudioDebugOptions options) {
    throw UnimplementedError('setDebugOptions() has not been implemented.');
  }

  Stream<Uint8List> get capturedAudio16kStream => throw UnimplementedError(
    'capturedAudio16kStream has not been implemented.',
  );

  Stream<GeminiLiveAudioEvent> get eventStream =>
      throw UnimplementedError('eventStream has not been implemented.');
}
