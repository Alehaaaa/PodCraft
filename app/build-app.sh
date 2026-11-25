#!/bin/sh
# Builds PodCraft and packages it as a Mac app using its Icon Composer source.
set -e
cd "$(dirname "$0")"

# Always publish the finished bundle at this path, including when invoked by Cargo.
APP="$(pwd)/PodCraft.app"
# This path contains independently built, static LGPL-only Apple Silicon tools.
# A release never invokes the lengthy FFmpeg source build implicitly.
FFMPEG_VENDOR="$(pwd)/Vendor/ffmpeg-arm64"
FFMPEG_HELPERS="$FFMPEG_VENDOR/bin"
FFMPEG_LICENSES="$FFMPEG_VENDOR/licenses"
PREVIOUS_APP="$(pwd)/.build/PodCraft.previous.app"
# Ad-hoc signing is suitable for local builds. For external distribution set
# PODCRAFT_CODESIGN_IDENTITY to an installed Developer ID Application identity
# and notarize the resulting app using Apple's notarytool before distribution.
SIGN_IDENTITY="${PODCRAFT_CODESIGN_IDENTITY:--}"
sign_for_release() {
  if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --sign - "$1"
  else
    codesign --force --options runtime --sign "$SIGN_IDENTITY" "$1"
  fi
}

# Fail before spending time compiling PodCraft, rather than publishing an app
# whose YouTube extraction works only in an interactive Homebrew shell.
if [ ! -f "$FFMPEG_VENDOR/SHA256SUMS" ] || [ ! -d "$FFMPEG_LICENSES" ]; then
  echo "error: missing static LGPL FFmpeg bundle at $FFMPEG_VENDOR" >&2
  echo "       run Tools/build-ffmpeg.sh once, then retry the release" >&2
  exit 1
fi
(cd "$FFMPEG_VENDOR" && shasum -a 256 -c SHA256SUMS)
"$(pwd)/Tools/verify-ffmpeg.sh" "$FFMPEG_HELPERS"
swift build -c release

# Icon Composer owns the adaptive shape, glass treatment, and macOS 27 rendering.
# The app is packaged manually (rather than by Xcode), so render the Composer
# document once and create the compatibility ICNS from that canonical output.
ICON_COMPOSER_TOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
ICON_DOCUMENT="Resources/PodCraft.icon"
COMPOSED_ICON=".build/PodCraft-composed-1024.png"

if [ ! -x "$ICON_COMPOSER_TOOL" ]; then
  echo "error: Icon Composer's ictool was not found. Install Xcode with Icon Composer." >&2
  exit 1
fi

if [ ! -d "$ICON_DOCUMENT" ]; then
  echo "error: missing Icon Composer document: $ICON_DOCUMENT" >&2
  exit 1
fi

# Assemble and sign the complete app before replacing the previous working copy.
# This also refreshes the bundle directory's timestamp for Finder/Launch Services.
STAGE_DIR="$(mktemp -d "$(pwd)/.build/PodCraft-stage.XXXXXX")"
STAGED_APP="$STAGE_DIR/PodCraft.app"
BACKUP_APP="$STAGE_DIR/PodCraft.previous.app"
cleanup() {
  if [ -d "$BACKUP_APP" ] && [ ! -e "$APP" ]; then
    mv "$BACKUP_APP" "$APP"
  fi
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources" "$STAGED_APP/Contents/Helpers"
cp .build/release/PodCraft "$STAGED_APP/Contents/MacOS/PodCraft"
cp Info.plist "$STAGED_APP/Contents/Info.plist"
cp Resources/logo.png "$STAGED_APP/Contents/Resources/logo.png"
cp "$FFMPEG_HELPERS/ffmpeg" "$FFMPEG_HELPERS/ffprobe" "$STAGED_APP/Contents/Helpers/"
mkdir -p "$STAGED_APP/Contents/Resources/ThirdParty/FFmpeg"
cp -R "$FFMPEG_LICENSES/." "$STAGED_APP/Contents/Resources/ThirdParty/FFmpeg/"
# The latest iPhone build (sh iOS/build-ios.sh ipa), which the Mac hosts as an AltStore / LiveContainer source.
if [ -f iOS/dist/PodCraft.ipa ] && [ -f iOS/dist/PodCraft-release.json ]; then
  mkdir -p "$STAGED_APP/Contents/Resources/iPhone"
  cp iOS/dist/PodCraft.ipa iOS/dist/PodCraft-release.json "$STAGED_APP/Contents/Resources/iPhone/"
fi

# Sign the nested tools first. Signing only the outer app is insufficient for
# Finder-launched child processes, and --deep signing can conceal stale helpers.
for tool in ffmpeg ffprobe; do
  cmp "$FFMPEG_HELPERS/$tool" "$STAGED_APP/Contents/Helpers/$tool"
  sign_for_release "$STAGED_APP/Contents/Helpers/$tool"
  codesign --verify --strict "$STAGED_APP/Contents/Helpers/$tool"
done
"$(pwd)/Tools/verify-ffmpeg.sh" "$STAGED_APP/Contents/Helpers"

"$ICON_COMPOSER_TOOL" "$ICON_DOCUMENT" \
  --export-image \
  --output-file "$COMPOSED_ICON" \
  --platform macOS \
  --rendition Default \
  --width 1024 \
  --height 1024 \
  --scale 1 \
  --design-generation 27 >/dev/null

ICONSET=.build/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$COMPOSED_ICON" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$COMPOSED_ICON" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$STAGED_APP/Contents/Resources/AppIcon.icns"

sign_for_release "$STAGED_APP"
codesign --verify --strict --deep "$STAGED_APP"

if [ -e "$APP" ]; then
  mv "$APP" "$BACKUP_APP"
fi
mv "$STAGED_APP" "$APP"
# Keep the previous signed app as a safe rollback. Only replace an older
# backup after the newly signed app has been verified and installed.
if [ -d "$BACKUP_APP" ]; then
  rm -rf "$PREVIOUS_APP"
  mv "$BACKUP_APP" "$PREVIOUS_APP"
fi
echo "Built and updated $APP"
echo "Previous signed release (if any): $PREVIOUS_APP"
