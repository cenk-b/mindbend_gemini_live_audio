#!/bin/bash
# Runs ios/Tests/FarewellBarrierTests.swift on the macOS host against the plugin's own barrier, adapter
# and lifetime sources. Classes/ files are COPIED (not edited) into a scratch SwiftPM package; their
# SHA-256 is printed so the run is bound to the exact plugin bytes.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CLASSES="$HERE/../Classes"
WORK="${1:-$(mktemp -d)}"
mkdir -p "$WORK/Sources/FarewellBarrier" "$WORK/Tests/FarewellBarrierTests"
for f in FarewellPlaybackBarrier.swift PluginFarewellPlayer.swift RetiringPlaybackLifetime.swift; do
  cp "$CLASSES/$f" "$WORK/Sources/FarewellBarrier/$f"
  shasum -a 256 "$CLASSES/$f"
done
cp "$HERE/FarewellBarrierTests.swift" "$WORK/Tests/FarewellBarrierTests/"
cat > "$WORK/Package.swift" <<'PKG'
// swift-tools-version:5.9
import PackageDescription
let package = Package(
  name: "FarewellBarrier",
  platforms: [.macOS(.v13)],
  targets: [
    .target(name: "FarewellBarrier"),
    .testTarget(name: "FarewellBarrierTests", dependencies: ["FarewellBarrier"]),
  ]
)
PKG
cd "$WORK" && swift test 2>&1
