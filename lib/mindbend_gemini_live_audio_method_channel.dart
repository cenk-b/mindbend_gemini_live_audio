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

  Future<FarewellDrainStatus> _status(String method, [Object? arguments]) async {
    final raw = await methodChannel.invokeMethod<Object?>(method, arguments);
    if (raw is Map) return FarewellDrainStatus.fromMap(raw);
    return const FarewellDrainStatus(
      generation: 0,
      state: 'idle',
      evidence: 'none',
      framesPlayed: 0,
      lastSeq: -1,
      restartBlocked: false,
    );
  }

  @override
  Future<FarewellDrainStatus> beginFarewellDrain({required int expectedFrames}) {
    return _status('beginFarewellDrain', <String, Object?>{
      'expectedFrames': expectedFrames,
    });
  }

  @override
  Future<FarewellDrainStatus> cancelFarewellDrain() {
    return _status('cancelFarewellDrain');
  }

  @override
  Future<FarewellDrainStatus> noteFarewellAnchor({
    required int seq,
    required int framesPlayed,
    required int generation,
    required bool nativeDrained,
  }) {
    return _status('noteFarewellAnchor', <String, Object?>{
      'seq': seq,
      'framesPlayed': framesPlayed,
      'generation': generation,
      'nativeDrained': nativeDrained,
    });
  }

  @override
  Future<FarewellDrainStatus> farewellDrainStatus() {
    return _status('farewellDrainStatus');
  }

  @override
  Future<void> setDebugOptions(GeminiLiveAudioDebugOptions options) {
    return methodChannel.invokeMethod<void>('setDebugOptions', options.toMap());
  }

  @override
  Future<FarewellPlaybackCapabilities> farewellCapabilities() async {
    try {
      final raw = await methodChannel.invokeMethod<Object?>('farewellCapabilities');
      if (raw is Map) return FarewellPlaybackCapabilities.fromMap(raw);
    } on MissingPluginException {
      // Older native plugin: no attributed farewell playback.
    } on PlatformException {
      // Treated the same: the capability is never assumed.
    }
    return FarewellPlaybackCapabilities.none;
  }

  @override
  Future<bool> beginFarewell({required String turnId, required int nativeGeneration}) async {
    final raw = await methodChannel.invokeMethod<Object?>('farewellBegin', <String, Object?>{
      'turnId': turnId,
      'nativeGeneration': nativeGeneration,
    });
    return raw is Map && raw['accepted'] == true;
  }

  @override
  Future<bool> pushFarewell({required String turnId, required int seq, required Uint8List pcm}) async {
    final raw = await methodChannel.invokeMethod<Object?>('farewellPush', <String, Object?>{
      'turnId': turnId,
      'seq': seq,
      'pcm': pcm,
    });
    return raw == true;
  }

  @override
  Future<bool> endFarewell({required String turnId, required int totalChunks, required int totalFrames}) async {
    final raw = await methodChannel.invokeMethod<Object?>('farewellEnd', <String, Object?>{
      'turnId': turnId,
      'totalChunks': totalChunks,
      'totalFrames': totalFrames,
    });
    return raw == true;
  }

  @override
  Future<void> cancelFarewell({required String turnId, required String reason}) async {
    await methodChannel.invokeMethod<Object?>('farewellCancel', <String, Object?>{
      'turnId': turnId,
      'reason': reason,
    });
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
