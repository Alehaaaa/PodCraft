#!/bin/sh
# Validate the standalone arm64 LGPL FFmpeg tools independently of PodCraft.
# Usage: Tools/verify-ffmpeg.sh [directory containing ffmpeg and ffprobe]
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN_DIR=${1:-"$ROOT/Vendor/ffmpeg-arm64/bin"}

for name in ffmpeg ffprobe; do
    tool="$BIN_DIR/$name"
    if [ ! -x "$tool" ]; then
        echo "error: missing executable $tool; run Tools/build-ffmpeg.sh first" >&2
        exit 1
    fi

    # A universal build is deliberately not accepted: the reproducible package
    # only contains one Apple Silicon slice with a known minimum macOS version.
    archs=$(lipo -archs "$tool")
    if [ "$archs" != "arm64" ]; then
        echo "error: $tool is not arm64-only (architectures: $archs)" >&2
        exit 1
    fi

    # There must be no runtime dependency on Homebrew, MacPorts, or a framework
    # copied from the build machine. Static libav* code lives in the executables.
    if ! otool -L "$tool" | awk 'NR > 1 {
        dep=$1
        if (dep !~ /^\/usr\/lib\// && dep !~ /^\/System\/Library\//) {
            print "error: non-system dependency: " dep > "/dev/stderr"
            bad=1
        }
    } END { exit bad ? 1 : 0 }'; then
        echo "error: nonportable dynamic dependencies in $tool" >&2
        exit 1
    fi

    if ! "$tool" -version 2>&1 | grep -q '^ffmpeg version 8.0.1\|^ffprobe version 8.0.1'; then
        echo "error: unexpected FFmpeg version for $tool" >&2
        exit 1
    fi
    if ! "$tool" -buildconf 2>&1 | grep -q -- '--disable-autodetect'; then
        echo "error: missing --disable-autodetect in $tool" >&2
        exit 1
    fi
    if ! "$tool" -buildconf 2>&1 | grep -q -- '--disable-shared'; then
        echo "error: missing --disable-shared in $tool" >&2
        exit 1
    fi
    if ! "$tool" -buildconf 2>&1 | grep -q -- '--enable-static'; then
        echo "error: missing --enable-static in $tool" >&2
        exit 1
    fi
    if "$tool" -buildconf 2>&1 | grep -E -q -- '--enable-(gpl|nonfree|version3)( |$)'; then
        echo "error: forbidden GPL/nonfree/version3 build option found in $tool" >&2
        exit 1
    fi
    # ffmpeg -L wraps the words "GNU Lesser General Public" and "License"
    # across separate lines; check the stable phrase rather than one line.
    if ! "$tool" -L 2>&1 | grep -q 'Lesser General Public'; then
        echo "error: tool does not declare the LGPL license: $tool" >&2
        exit 1
    fi
    codesign --verify --strict "$tool"
    echo "VERIFIED: $tool (arm64 static libav, LGPL, signed, system dylibs only)"
done

# On prebuilt vendor artifacts, compare exact final signed binary digests.
if [ "$BIN_DIR" = "$ROOT/Vendor/ffmpeg-arm64/bin" ]; then
    (cd "$ROOT/Vendor/ffmpeg-arm64" && shasum -a 256 -c SHA256SUMS)
    archive="$ROOT/Vendor/ffmpeg-arm64/licenses/ffmpeg-8.0.1.tar.xz"
    sha=$(shasum -a 256 "$archive" | awk '{print $1}')
    if [ "$sha" != 05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41 ]; then
        echo "error: bundled LGPL corresponding source does not match upstream pinned SHA256" >&2
        exit 1
    fi
fi

echo "FFMPEG BUNDLE TOOLS VERIFIED"
