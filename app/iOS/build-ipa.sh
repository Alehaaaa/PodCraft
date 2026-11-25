#!/bin/bash
# Builds PodCraft for iPhone into dist/PodCraft.ipa, plus dist/PodCraft-release.json (version, build, size).
#
# Unsigned by default: AltStore, SideStore and LiveContainer sign it as they install it. With Xcode signing set up,
# EXPORT_OPTIONS_PLIST=/absolute/path/ExportOptions.plist archives and exports a signed IPA instead
# (ExportOptions.plist here is a starting point; set DEVELOPMENT_TEAM to pick the team).
#
# The version comes from VERSION; the build number is the date and time (UTC), so every build is newer than the
# last. PODCRAFT_BUILD overrides it. The Mac app bundles the latest IPA on its next build and serves it to iPhones.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="${PODCRAFT_BUILD:-$(date -u +%Y%m%d%H%M)}"
MIN_OS="26.0"
VERSIONS=(MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD")

mkdir -p dist
STAGING="$(mktemp -d "$SCRIPT_DIR/dist/.ipa-staging.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
SIGNED=false

if [[ -n "${EXPORT_OPTIONS_PLIST:-}" ]]; then
  if [[ ! -f "$EXPORT_OPTIONS_PLIST" ]]; then
    echo "Export options file not found: $EXPORT_OPTIONS_PLIST" >&2
    exit 2
  fi
  TEAM=()
  [[ -n "${DEVELOPMENT_TEAM:-}" ]] && TEAM=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
  xcodebuild \
    -project PodCraftPhone.xcodeproj \
    -scheme PodCraftPhone \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$SCRIPT_DIR/.build-device" \
    -archivePath "$STAGING/PodCraft.xcarchive" \
    -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic ${TEAM[@]+"${TEAM[@]}"} "${VERSIONS[@]}" \
    archive
  xcodebuild \
    -exportArchive \
    -archivePath "$STAGING/PodCraft.xcarchive" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    -exportPath "$STAGING/export" \
    -allowProvisioningUpdates
  mv -f "$STAGING"/export/*.ipa "$STAGING/PodCraft.ipa"
  SIGNED=true
else
  xcodebuild \
    -project PodCraftPhone.xcodeproj \
    -scheme PodCraftPhone \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$SCRIPT_DIR/.build-device" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    "${VERSIONS[@]}" \
    build

  APP="$SCRIPT_DIR/.build-device/Build/Products/Release-iphoneos/PodCraft.app"
  if [[ ! -d "$APP" ]]; then
    echo "Device build did not produce PodCraft.app" >&2
    exit 1
  fi
  mkdir -p "$STAGING/Payload"
  /usr/bin/ditto "$APP" "$STAGING/Payload/PodCraft.app"
  (cd "$STAGING" && /usr/bin/zip -q -r -y PodCraft.ipa Payload)
fi

# Check the archive before it replaces the last good one.
/usr/bin/unzip -tq "$STAGING/PodCraft.ipa"
for expected in 'Payload/PodCraft.app/PodCraft' 'Payload/PodCraft.app/Info.plist'; do
  # Not grep -q under pipefail: it can exit before unzip finishes and make a present item look missing.
  if ! /usr/bin/unzip -Z1 "$STAGING/PodCraft.ipa" | /usr/bin/grep -Fx "$expected" >/dev/null; then
    echo "IPA is missing $expected" >&2
    exit 1
  fi
done

SIZE="$(wc -c < "$STAGING/PodCraft.ipa" | tr -d ' ')"
cat > "$STAGING/PodCraft-release.json" <<JSON
{"version": "$VERSION", "build": "$BUILD", "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "size": $SIZE, "minOSVersion": "$MIN_OS", "signed": $SIGNED, "bundleIdentifier": "app.podcraft.ios"}
JSON
mv -f "$STAGING/PodCraft.ipa" dist/PodCraft.ipa
mv -f "$STAGING/PodCraft-release.json" dist/PodCraft-release.json
echo "IPA ready: $SCRIPT_DIR/dist/PodCraft.ipa — PodCraft $VERSION ($BUILD), $([[ $SIGNED == true ]] && echo signed || echo unsigned)"
