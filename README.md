# mindbend_gemini_live_audio

Native full-duplex Gemini Live audio transport for Mindbend.

This plugin owns Gemini Live voice-session capture and playback in one native
audio path on iOS and Android. It is used only for Gemini Live voice chat and
is isolated from the app's legacy Botpress voice flow and meditation playback.

## Scope

- iOS: native audio session + playback/capture path with voice-processing
- Android: native `AudioRecord`/`AudioTrack` path with hardware AEC when
  available
- Dart API for starting/stopping sessions, pushing playback PCM, and receiving
  captured mic PCM

## Package status

This package is private and intended to be consumed as a Git dependency by the
Mindbend FlutterFlow app.
