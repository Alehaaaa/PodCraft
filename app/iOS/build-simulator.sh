#!/bin/bash
# A Debug build of PodCraft for the iPhone Simulator (no signing).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

xcodebuild \
  -project PodCraftPhone.xcodeproj \
  -scheme PodCraftPhone \
  -configuration Debug \
  -destination "${SIMULATOR_DESTINATION:-generic/platform=iOS Simulator}" \
  -derivedDataPath "$SCRIPT_DIR/.build" \
  CODE_SIGNING_ALLOWED=NO \
  build

echo "Simulator app ready: $SCRIPT_DIR/.build/Build/Products/Debug-iphonesimulator/PodCraft.app"
