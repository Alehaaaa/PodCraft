#!/bin/sh
# Builds PodCraft for iPhone.
#   sh build-ios.sh          Simulator build
#   sh build-ios.sh device   unsigned build for a real iPhone (compile check)
#   sh build-ios.sh ipa      a release: iOS/dist/PodCraft.ipa plus PodCraft-release.json (version, build, size).
#                            The Mac app bundles it on its next build (sh build-app.sh) and hosts it as an
#                            AltStore / LiveContainer source, so the iPhone app's Check for Updates finds it.
#                            Signed for your iPhone when Xcode is signed in to your Apple ID (Settings →
#                            Accounts; DEVELOPMENT_TEAM overrides the team); otherwise unsigned, which
#                            LiveContainer, SideStore and AltStore sign themselves as they install it.
#                            PODCRAFT_UNSIGNED=1 skips signing (GitHub Actions); PODCRAFT_BUILD sets the build number.
# Every release gets a newer build number (date and time), so phones can tell it's an update.
# Nothing is deleted: each .ipa is staged in a fresh temporary folder and moved into dist/.
set -e
cd "$(dirname "$0")"
TEAM="${DEVELOPMENT_TEAM:-L4947CL6Q2}"
# The version lives in iOS/VERSION, so releases (and the GitHub workflow) read it from one place.
VERSION="${PODCRAFT_IOS_VERSION:-$(cat VERSION 2>/dev/null || echo 1.1)}"
BUILD="${PODCRAFT_BUILD:-$(date -u +%Y%m%d%H%M)}"
case "$1" in
  ipa)
    mkdir -p dist
    STAGE="$(mktemp -d "${TMPDIR:-/tmp}/podcraft-ipa.XXXXXX")"
    SIGNED=false
    if [ -z "$PODCRAFT_UNSIGNED" ] && xcodebuild -project PodCraftPhone.xcodeproj -scheme PodCraftPhone -configuration Release \
         -destination 'generic/platform=iOS' -derivedDataPath build -archivePath "$STAGE/PodCraft.xcarchive" \
         -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic \
         MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" archive \
       && xcodebuild -exportArchive -archivePath "$STAGE/PodCraft.xcarchive" -exportPath "$STAGE/export" \
         -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates; then
      mv -f "$STAGE"/export/*.ipa "$STAGE/PodCraft.ipa"
      SIGNED=true
    else
      [ -z "$PODCRAFT_UNSIGNED" ] && echo "Signing isn't set up in Xcode (Settings → Accounts), so building an unsigned .ipa instead."
      xcodebuild -project PodCraftPhone.xcodeproj -scheme PodCraftPhone -configuration Release \
        -destination 'generic/platform=iOS' -derivedDataPath build -archivePath "$STAGE/PodCraft-unsigned.xcarchive" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
        MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" archive
      mkdir -p "$STAGE/Payload"
      cp -R "$STAGE/PodCraft-unsigned.xcarchive/Products/Applications/PodCraft.app" "$STAGE/Payload/"
      (cd "$STAGE" && /usr/bin/zip -qry PodCraft.ipa Payload)
    fi
    SIZE="$(wc -c < "$STAGE/PodCraft.ipa" | tr -d ' ')"
    DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat > "$STAGE/PodCraft-release.json" <<JSON
{"version": "$VERSION", "build": "$BUILD", "date": "$DATE", "size": $SIZE, "minOSVersion": "26.0", "signed": $SIGNED, "bundleIdentifier": "app.podcraft.ios"}
JSON
    mv -f "$STAGE/PodCraft.ipa" dist/PodCraft.ipa
    mv -f "$STAGE/PodCraft-release.json" dist/PodCraft-release.json
    echo "Built $(pwd)/dist/PodCraft.ipa — version $VERSION ($BUILD), $( [ "$SIGNED" = true ] && echo signed || echo 'unsigned: LiveContainer/SideStore sign it as they install')"
    ;;
  device)
    xcodebuild -project PodCraftPhone.xcodeproj -scheme PodCraftPhone -configuration Release \
      -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
    echo "Built build/Build/Products/Release-iphoneos/PodCraft.app"
    ;;
  *)
    xcodebuild -project PodCraftPhone.xcodeproj -scheme PodCraftPhone -configuration Debug \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
    echo "Built build/Build/Products/Debug-iphonesimulator/PodCraft.app"
    ;;
esac
