#!/bin/bash
# Compiles the plugin's barrier/port/lifetime + EmulatorProbe.kt, dexes them, and runs them with app_process on
# the given emulator. Usage: run_emulator_probe.sh <adb serial> [out dir]
set -euo pipefail
SERIAL="${1:?adb serial}"; HERE="$(cd "$(dirname "$0")" && pwd)"; PLUGIN="$HERE/../.."
OUT="${2:-$(mktemp -d)}"; mkdir -p "$OUT"
SDK=~/Library/Android/sdk; AJAR=$SDK/platforms/android-36/android.jar
D8="$(ls -d $SDK/build-tools/* | sort -V | tail -1)/d8"
KH="/Applications/Android Studio.app/Contents/plugins/Kotlin/kotlinc"
FE=$(find ~/.gradle/caches -name 'flutter_embedding_debug-*.jar' | head -1)
K="$PLUGIN/android/src/main/kotlin/com/cognistence/mindbend_gemini_live_audio"
rm -rf "$OUT/classes"; mkdir -p "$OUT/classes"
bash "$KH/bin/kotlinc" "$K/FarewellPlaybackBarrier.kt" "$K/RetiringPlaybackLifetime.kt" "$K/MindbendGeminiLiveAudioPlugin.kt" \
  "$HERE/EmulatorProbe.kt" -cp "$AJAR:$FE" -d "$OUT/classes" 2>&1 | grep -E "error:" && exit 2
# Only the classes the probe needs (the plugin class itself references the Flutter embedding).
(cd "$OUT/classes" && find . -name '*.class' | grep -E "FarewellPlaybackBarrier|FarewellTrack|FarewellBarrierEvent|LifetimeAudioTrackPort|RetiringPlaybackLifetime|FarewellPoller|MindbendGeminiLiveAudioPluginKt|EmulatorProbe|/Rig" > ../keep.txt && jar cf ../probe-classes.jar @../keep.txt)
"$D8" --min-api 26 --lib "$AJAR" --output "$OUT" "$OUT/probe-classes.jar" "$KH/lib/kotlin-stdlib.jar" 2>&1 | grep -vi warning || true
(cd "$OUT" && jar cf probe.jar classes*.dex)
shasum -a 256 "$K/FarewellPlaybackBarrier.kt" "$K/RetiringPlaybackLifetime.kt" "$K/MindbendGeminiLiveAudioPlugin.kt" "$OUT/probe.jar"
adb -s "$SERIAL" push "$OUT/probe.jar" /data/local/tmp/t21-farewell-probe.jar | tail -1
adb -s "$SERIAL" shell "CLASSPATH=/data/local/tmp/t21-farewell-probe.jar app_process /system/bin com.cognistence.mindbend_gemini_live_audio.EmulatorProbeKt"
