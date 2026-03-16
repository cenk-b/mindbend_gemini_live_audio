import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'mindbend_gemini_live_audio.dart';
import 'mindbend_gemini_live_audio_platform_interface.dart';

class MethodChannelMindbendGeminiLiveAudio
    extends MindbendGeminiLiveAudioPlatform {
  @visibleForTesting
  final MethodChannel methodChannel = const MethodChannel(
    'mindbend_gemini_live_audio/methods',
  );

  @visibleForTesting
  final EventChannel capturedAudioChannel = const EventChannel(
    'mindbend_gemini_live_audio/captured_audio',
  );

  @visibleForTesting
  final EventChannel eventChannel = const EventChannel(
    'mindbend_gemini_live_audio/events',
  );

  Stream<Uint8List>? _capturedAudio16kStream;
  Stream<GeminiLiveAudioEvent>? _eventStream;

  @override
  Future<GeminiLiveAudioStartResult> startSession() async {
    final raw = await methodChannel.invokeMethod<Object?>('startSession');
    if (raw is Map) {
      return GeminiLiveAudioStartResult.fromMap(raw);
    }
    return const GeminiLiveAudioStartResult(
      aecActive: false,
      nsActive: false,
      agcActive: false,
      transportMode: 'legacy_half_duplex',
      captureSampleRateHz: 16000,
      playbackSampleRateHz: 24000,
      errorCode: 'invalid_start_result',
    );
  }

  @override
  Future<void> stopSession() async {
    try {
      await methodChannel.invokeMethod<void>('stopSession');
    } finally {
      // EventChannel streams can become stale after native stop/start cycles.
      // Recreate lazily on next access.
      _capturedAudio16kStream = null;
      _eventStream = null;
    }
  }

  @override
  Future<void> pushPlaybackPcm(Uint8List pcm24kMono16) {
    return methodChannel.invokeMethod<void>('pushPlaybackPcm', pcm24kMono16);
  }

  @override
  Future<void> flushPlayback() {
    return methodChannel.invokeMethod<void>('flushPlayback');
  }

  @override
  Future<void> markPlaybackComplete() {
    return methodChannel.invokeMethod<void>('markPlaybackComplete');
  }

  @override
  Future<void> setDebugOptions(GeminiLiveAudioDebugOptions options) {
    return methodChannel.invokeMethod<void>('setDebugOptions', options.toMap());
  }

  @override
  Stream<Uint8List> get capturedAudio16kStream {
    _capturedAudio16kStream ??= capturedAudioChannel
        .receiveBroadcastStream()
        .map<Uint8List>((Object? event) {
          if (event is Uint8List) {
            return event;
          }
          if (event is List<int>) {
            return Uint8List.fromList(event);
          }
          throw StateError(
            'Unexpected captured audio event: ${event.runtimeType}',
          );
        })
        .asBroadcastStream();
    return _capturedAudio16kStream!;
  }

  @override
  Stream<GeminiLiveAudioEvent> get eventStream {
    _eventStream ??= eventChannel
        .receiveBroadcastStream()
        .map(GeminiLiveAudioEvent.fromRaw)
        .where((event) => event.type.trim().isNotEmpty)
        .asBroadcastStream();
    return _eventStream!;
  }
}
