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

class FarewellDrainStatus {
  const FarewellDrainStatus({
    required this.generation,
    required this.state,
    required this.evidence,
    required this.framesPlayed,
    required this.lastSeq,
    required this.restartBlocked,
    this.teardown = 'not_requested',
  });

  final int generation;
  final String state;
  final String evidence;
  final int framesPlayed;
  final int lastSeq;
  final bool restartBlocked;

  /// Native calls returned or failed; never acoustic silence or data quiescence.
  final String teardown;

  bool get isNativeDrain => evidence == 'native_drain';

  factory FarewellDrainStatus.fromMap(Map<Object?, Object?> raw) {
    int asInt(Object? value) => value is int ? value : (value is num ? value.toInt() : 0);
    return FarewellDrainStatus(
      generation: asInt(raw['generation']),
      state: raw['state'] is String ? raw['state'] as String : 'idle',
      evidence: raw['evidence'] is String ? raw['evidence'] as String : 'none',
      framesPlayed: asInt(raw['framesPlayed']),
      lastSeq: asInt(raw['lastSeq']),
      restartBlocked: raw['restartBlocked'] == true,
      teardown: raw['teardown'] is String ? raw['teardown'] as String : 'not_requested',
    );
  }
}

/// What the installed native plugin can prove about farewell playback.
///
/// `api >= 2` with `attributedDrain` means the native side owns a per-track
/// playback barrier and reports typed `farewell_drained` / `farewell_unverified`
/// events. An older plugin reports `api == 0` and must never be treated as able
/// to prove a farewell played.
class FarewellPlaybackCapabilities {
  const FarewellPlaybackCapabilities({
    required this.api,
    required this.attributedDrain,
    this.platform,
    this.evidence,
  });

  static const FarewellPlaybackCapabilities none =
      FarewellPlaybackCapabilities(api: 0, attributedDrain: false);

  final int api;
  final bool attributedDrain;
  final String? platform;
  final String? evidence;

  bool get supportsAttributedDrain => api >= 2 && attributedDrain;

  factory FarewellPlaybackCapabilities.fromMap(Map<Object?, Object?> raw) {
    final api = raw['api'];
    return FarewellPlaybackCapabilities(
      api: api is int ? api : (api is num ? api.toInt() : 0),
      attributedDrain: raw['attributedDrain'] == true,
      platform: raw['platform'] is String ? raw['platform'] as String : null,
      evidence: raw['evidence'] is String ? raw['evidence'] as String : null,
    );
  }
}

/// Typed native farewell outcome, parsed from the plugin event stream.
sealed class FarewellPlaybackEvent {
  const FarewellPlaybackEvent(this.turnId, this.nativeGeneration);

  final String turnId;
  final int nativeGeneration;

  /// Null for every event that is not a well-formed farewell outcome.
  static FarewellPlaybackEvent? tryParse(GeminiLiveAudioEvent event) {
    final data = event.data;
    final turnId = data['turnId'];
    final generation = data['nativeGeneration'];
    if (turnId is! String || turnId.isEmpty || generation is! int) return null;
    if (event.type == 'farewell_drained') {
      final drainedAt = data['drainedAtEpochMs'];
      final frames = data['framesPlayed'];
      final lastSeq = data['lastSeq'];
      final evidence = data['evidence'];
      if (drainedAt is! int || frames is! int || lastSeq is! int ||
          evidence is! String || evidence.isEmpty) {
        return null;
      }
      return FarewellPlaybackDrained(
        turnId,
        generation,
        drainedAtEpochMs: drainedAt,
        framesPlayed: frames,
        lastSeq: lastSeq,
        evidence: evidence,
      );
    }
    if (event.type == 'farewell_unverified') {
      final reason = data['reason'];
      return FarewellPlaybackUnverified(
        turnId,
        generation,
        reason is String && reason.isNotEmpty ? reason : 'unverified',
      );
    }
    return null;
  }
}

/// The native barrier observed the farewell's final frame presented by the
/// installed player/track. [drainedAtEpochMs] is captured once, natively.
class FarewellPlaybackDrained extends FarewellPlaybackEvent {
  const FarewellPlaybackDrained(
    super.turnId,
    super.nativeGeneration, {
    required this.drainedAtEpochMs,
    required this.framesPlayed,
    required this.lastSeq,
    required this.evidence,
  });

  final int drainedAtEpochMs;
  final int framesPlayed;
  final int lastSeq;

  /// `android_timestamp` or `ios_dataPlayedBack+position`.
  final String evidence;
}

class FarewellPlaybackUnverified extends FarewellPlaybackEvent {
  const FarewellPlaybackUnverified(super.turnId, super.nativeGeneration, this.reason);

  final String reason;
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

  Future<FarewellDrainStatus> beginFarewellDrain({required int expectedFrames}) {
    return MindbendGeminiLiveAudioPlatform.instance.beginFarewellDrain(
      expectedFrames: expectedFrames,
    );
  }

  Future<FarewellDrainStatus> cancelFarewellDrain() {
    return MindbendGeminiLiveAudioPlatform.instance.cancelFarewellDrain();
  }

  Future<FarewellDrainStatus> noteFarewellAnchor({
    required int seq,
    required int framesPlayed,
    required int generation,
    required bool nativeDrained,
  }) {
    return MindbendGeminiLiveAudioPlatform.instance.noteFarewellAnchor(
      seq: seq,
      framesPlayed: framesPlayed,
      generation: generation,
      nativeDrained: nativeDrained,
    );
  }

  Future<FarewellDrainStatus> farewellDrainStatus() {
    return MindbendGeminiLiveAudioPlatform.instance.farewellDrainStatus();
  }

  Future<void> setDebugOptions(GeminiLiveAudioDebugOptions options) {
    return MindbendGeminiLiveAudioPlatform.instance.setDebugOptions(options);
  }

  /// Never throws: an older native plugin reports [FarewellPlaybackCapabilities.none].
  Future<FarewellPlaybackCapabilities> farewellCapabilities() {
    return MindbendGeminiLiveAudioPlatform.instance.farewellCapabilities();
  }

  /// Opens one attributed farewell turn on the current playback track.
  Future<bool> beginFarewell({required String turnId, required int nativeGeneration}) {
    return MindbendGeminiLiveAudioPlatform.instance.beginFarewell(
      turnId: turnId,
      nativeGeneration: nativeGeneration,
    );
  }

  /// Queues one farewell chunk behind earlier audio. A native rejection fails
  /// the turn and arrives as [FarewellPlaybackUnverified].
  Future<bool> pushFarewell({required String turnId, required int seq, required Uint8List pcm}) {
    return MindbendGeminiLiveAudioPlatform.instance.pushFarewell(turnId: turnId, seq: seq, pcm: pcm);
  }

  Future<bool> endFarewell({required String turnId, required int totalChunks, required int totalFrames}) {
    return MindbendGeminiLiveAudioPlatform.instance.endFarewell(
      turnId: turnId,
      totalChunks: totalChunks,
      totalFrames: totalFrames,
    );
  }

  Future<void> cancelFarewell({required String turnId, required String reason}) {
    return MindbendGeminiLiveAudioPlatform.instance.cancelFarewell(turnId: turnId, reason: reason);
  }

  Stream<Uint8List> get capturedAudio16kStream =>
      MindbendGeminiLiveAudioPlatform.instance.capturedAudio16kStream;

  Stream<GeminiLiveAudioEvent> get eventStream =>
      MindbendGeminiLiveAudioPlatform.instance.eventStream;
}
