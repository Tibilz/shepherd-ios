#!/bin/sh
# Generates HerdrApp.xcodeproj. If a local SwiftPM mirror config exists (slow-network workaround),
# it is copied into the project workspace so Xcode resolves the big dependencies locally.
set -e
cd "$(dirname "$0")/.."
xcodegen generate
MIRRORS=Packages/HerdrSSH/.swiftpm/configuration/mirrors.json
if [ -f "$MIRRORS" ]; then
  DEST=HerdrApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration
  mkdir -p "$DEST" && cp "$MIRRORS" "$DEST/mirrors.json"
  echo "Lokale Paket-Mirrors übernommen."
fi
