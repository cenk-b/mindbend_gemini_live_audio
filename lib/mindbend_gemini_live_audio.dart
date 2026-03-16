import 'dart:typed_data';

import 'mindbend_gemini_live_audio_platform_interface.dart';

class GeminiLiveAudioStartResult {
  const GeminiLiveAudioStartResult({
    required this.aecActive,
    required this.nsActive,
    required this.agcActive,
    required this.transportMode,
    required this.captureSampleRateHz,
    required this.playbackSampleRateHz,
    this.errorCode,
  });

  final bool aecActive;
  final bool nsActive;
  final bool agcActive;
  final String transportMode;
  final int captureSampleRateHz;
  final int playbackSampleRateHz;
  final String? errorCode;

  bool get isNativeAec => transportMode == 'native_aec' && aecActive;

  factory GeminiLiveAudioStartResult.fromMap(Map<Object?, Object?> raw) {
    int asInt(Object? value, int fallback) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return fallback;
    }

    bool asBool(Object? value, bool fallback) {
      if (value is bool) return value;
      return fallback;
    }

    String asString(Object? value, String fallback) {
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
      return fallback;
    }

    return GeminiLiveAudioStartResult(
      aecActive: asBool(raw['aecActive'], false),
      nsActive: asBool(raw['nsActive'], false),
      agcActive: asBool(raw['agcActive'], false),
      transportMode: asString(raw['transportMode'], 'legacy_half_duplex'),
      captureSampleRateHz: asInt(raw['captureSampleRateHz'], 16000),
      playbackSampleRateHz: asInt(raw['playbackSampleRateHz'], 24000),
      errorCode: raw['errorCode'] as String?,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'aecActive': aecActive,
    'nsActive': nsActive,
    'agcActive': agcActive,
    'transportMode': transportMode,
    'captureSampleRateHz': captureSampleRateHz,
    'playbackSampleRateHz': playbackSampleRateHz,
    'errorCode': errorCode,
  };
}

class GeminiLiveAudioEvent {
  const GeminiLiveAudioEvent({
    required this.type,
    required this.platform,
    required this.data,
    this.atMs,
  });

  final String type;
  final String platform;
  final int? atMs;
  final Map<String, Object?> data;

  bool get isError => type == 'error';

  String? get code {
    final value = data['code'];
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }
    return null;
  }

  factory GeminiLiveAudioEvent.fromRaw(Object? raw) {
    if (raw is Map) {
      final normalized = raw.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      final typeValue = normalized['type'];
      final platformValue = normalized['platform'];
      final atMsValue = normalized['atMs'];
      final payload = Map<String, Object?>.from(normalized)
        ..remove('type')
        ..remove('platform')
        ..remove('atMs');
      return GeminiLiveAudioEvent(
        type: typeValue is String && typeValue.trim().isNotEmpty
            ? typeValue.trim()
            : 'unknown',
        platform: platformValue is String && platformValue.trim().isNotEmpty
            ? platformValue.trim()
            : 'unknown',
        atMs: atMsValue is int
            ? atMsValue
            : (atMsValue is num ? atMsValue.toInt() : null),
        data: payload,
      );
    }

    final normalized = raw?.toString().trim() ?? '';
    if (normalized.isEmpty) {
      return const GeminiLiveAudioEvent(
        type: 'unknown',
        platform: 'unknown',
        data: <String, Object?>{},
      );
    }

    if (normalized.startsWith('error:')) {
      return GeminiLiveAudioEvent(
        type: 'error',
        platform: 'unknown',
        data: <String, Object?>{
          'code': normalized.substring('error:'.length),
          'legacyEvent': normalized,
        },
      );
    }

    return GeminiLiveAudioEvent(
      type: normalized,
      platform: 'unknown',
      data: <String, Object?>{'legacyEvent': normalized},
    );
  }
}

class GeminiLiveAudioDebugOptions {
  const GeminiLiveAudioDebugOptions({
    this.disableNoiseSuppressor = false,
    this.disableAutomaticGainControl = false,
  });

  final bool disableNoiseSuppressor;
  final bool disableAutomaticGainControl;

  Map<String, Object?> toMap() => <String, Object?>{
    'disableNoiseSuppressor': disableNoiseSuppressor,
    'disableAutomaticGainControl': disableAutomaticGainControl,
  };
}

class MindbendGeminiLiveAudio {
  Future<GeminiLiveAudioStartResult> startSession() {
    return MindbendGeminiLiveAudioPlatform.instance.startSession();
  }

  Future<void> stopSession() {
    return MindbendGeminiLiveAudioPlatform.instance.stopSession();
  }

  Future<void> pushPlaybackPcm(Uint8List pcm24kMono16) {
    return MindbendGeminiLiveAudioPlatform.instance.pushPlaybackPcm(
      pcm24kMono16,
    );
  }

  Future<void> flushPlayback() {
    return MindbendGeminiLiveAudioPlatform.instance.flushPlayback();
  }

  Future<void> markPlaybackComplete() {
    return MindbendGeminiLiveAudioPlatform.instance.markPlaybackComplete();
  }

  Future<void> setDebugOptions(GeminiLiveAudioDebugOptions options) {
    return MindbendGeminiLiveAudioPlatform.instance.setDebugOptions(options);
  }

  Stream<Uint8List> get capturedAudio16kStream =>
      MindbendGeminiLiveAudioPlatform.instance.capturedAudio16kStream;

  Stream<GeminiLiveAudioEvent> get eventStream =>
      MindbendGeminiLiveAudioPlatform.instance.eventStream;
}
