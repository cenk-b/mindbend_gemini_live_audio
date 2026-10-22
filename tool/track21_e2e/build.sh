#!/bin/bash
# Builds the two E2E barrier CLIs from the plugin's own barrier sources into $1 (default: ./out).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PLUGIN="$HERE/../.."
OUT="${1:-$HERE/out}"; mkdir -p "$OUT"
KH="/Applications/Android Studio.app/Contents/plugins/Kotlin/kotlinc"
bash "$KH/bin/kotlinc" "$PLUGIN/android/src/main/kotlin/com/cognistence/mindbend_gemini_live_audio/FarewellPlaybackBarrier.kt" \
  "$HERE/BarrierCli.kt" -include-runtime -d "$OUT/barrier-cli.jar" 2>&1 | grep -v "^warning" || true
xcrun swiftc -O -o "$OUT/barrier-cli-swift" \
  "$PLUGIN/ios/Classes/FarewellPlaybackBarrier.swift" "$PLUGIN/ios/Classes/PluginFarewellPlayer.swift" \
  "$PLUGIN/ios/Classes/RetiringPlaybackLifetime.swift" "$HERE/main.swift"
shasum -a 256 "$PLUGIN/android/src/main/kotlin/com/cognistence/mindbend_gemini_live_audio/FarewellPlaybackBarrier.kt" \
  "$PLUGIN/ios/Classes/FarewellPlaybackBarrier.swift" "$PLUGIN/ios/Classes/PluginFarewellPlayer.swift" \
  "$PLUGIN/ios/Classes/RetiringPlaybackLifetime.swift"
ls -la "$OUT"
