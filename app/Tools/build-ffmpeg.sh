#!/bin/sh
# One-time reproducible FFmpeg/ffprobe build for PodCraft macOS Apple Silicon.
# Only official unmodified FFmpeg source, LGPL 2.1+, static libav* libraries.
# Never run this from build-app.sh: release packaging uses Vendor prebuilt tools.
set -eu
umask 022

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=8.0.1
ARCHIVE="ffmpeg-$VERSION.tar.xz"
SOURCE_URL="https://ffmpeg.org/releases/$ARCHIVE"
SIGNATURE_URL="$SOURCE_URL.asc"
KEY_URL="https://ffmpeg.org/ffmpeg-devel.asc"
RELEASE_KEY=FCF986EA15E6E293A5644F10B4322F04D67658D8
# Published independently by OmniOS' ffmpeg source mirror and cross-checked
# against the official HTTPS release archive. This pins all future rebuilds.
SOURCE_SHA256=05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41
SOURCE_CACHE="$ROOT/Vendor/ffmpeg-source"
OUTPUT="$ROOT/Vendor/ffmpeg-arm64"

fail() { echo "error: $*" >&2; exit 1; }
if [ "$(uname -m)" != arm64 ]; then
    fail "FFmpeg packaging requires a native macOS arm64 build host"
fi
command -v xcrun >/dev/null || fail "Xcode command-line tools are unavailable"
command -v curl >/dev/null || fail "curl is unavailable"
command -v shasum >/dev/null || fail "shasum is unavailable"
command -v codesign >/dev/null || fail "codesign is unavailable"
command -v otool >/dev/null || fail "otool is unavailable"
CC=$(xcrun --find clang)
SDK=$(xcrun --sdk macosx --show-sdk-path)
# FFmpeg separately compiles small *host* utilities with the host compiler,
# without its target --sysroot flags. Modern Xcode clang cannot locate even
# <ctype.h> for these probes unless SDKROOT is explicitly exported.
export SDKROOT="$SDK"
mkdir -p "$SOURCE_CACHE" "$ROOT/.build"

download() {
    dest=$1
    url=$2
    if [ ! -s "$dest" ]; then
        echo "Downloading official source artifact: $url"
        curl --proto '=https' --tlsv1.2 -fL --retry 3 --connect-timeout 20 \
            --max-time 240 --output "$dest.tmp" "$url"
        mv "$dest.tmp" "$dest"
    fi
}
download "$SOURCE_CACHE/$ARCHIVE" "$SOURCE_URL"
download "$SOURCE_CACHE/$ARCHIVE.asc" "$SIGNATURE_URL"
download "$SOURCE_CACHE/ffmpeg-devel.asc" "$KEY_URL"
actual=$(shasum -a 256 "$SOURCE_CACHE/$ARCHIVE" | awk '{print $1}')
[ "$actual" = "$SOURCE_SHA256" ] ||
    fail "upstream tarball SHA-256 mismatch; refusing to build (got $actual)"
echo "SOURCE VERIFIED: $ARCHIVE SHA256=$actual"

# FFmpeg publishes this key fingerprint on https://ffmpeg.org/download.html.
# If GnuPG is installed, also verify the detached upstream signature in an
# isolated, temporary keyring, without changing the user's personal keyring.
# FFmpeg generates unquoted shell build metadata from --prefix; keep the
# configure/compile directory free of spaces (the PodCraft checkout may live
# under "Craft Anything"). Only the finished staged artifact lives in Vendor.
WORK=$(mktemp -d /tmp/podcraft-ffmpeg-build.XXXXXX)
cleanup() {
    # Preserve configure's exact failed compiler/linker probe for diagnosis.
    if [ -f "$WORK/src/ffmpeg-$VERSION/ffbuild/config.log" ]; then
        cp "$WORK/src/ffmpeg-$VERSION/ffbuild/config.log" "$ROOT/.build/ffmpeg-static-config.log"
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM
if command -v gpg >/dev/null 2>&1; then
    mkdir "$WORK/gnupg"
    chmod 700 "$WORK/gnupg"
    gpg --batch --homedir "$WORK/gnupg" --import "$SOURCE_CACHE/ffmpeg-devel.asc" >/dev/null 2>&1
    if ! gpg --batch --homedir "$WORK/gnupg" --with-colons --fingerprint |
        grep -q "^fpr:::::::::$RELEASE_KEY:"; then
        fail "the downloaded FFmpeg release public key fingerprint is not the published key"
    fi
    gpg --batch --homedir "$WORK/gnupg" --verify \
        "$SOURCE_CACHE/$ARCHIVE.asc" "$SOURCE_CACHE/$ARCHIVE"
    echo "OFFICIAL RELEASE PGP SIGNATURE VERIFIED"
else
    echo "NOTICE: gpg not installed; verified pinned upstream SHA256 only."
    echo "        Install GnuPG and rerun to additionally check FFmpeg's detached release signature."
fi

mkdir "$WORK/src"
tar -xf "$SOURCE_CACHE/$ARCHIVE" -C "$WORK/src"
cd "$WORK/src/ffmpeg-$VERSION"

# Restrict the codec/format graph to files yt-dlp actually hands ffmpeg:
# progressive H.264/AAC MP4 => M4A AAC, DASH H.264+AAC merging, HLS and common
# podcast audio containers. TLS uses Apple's built-in SecureTransport system
# frameworks; no Homebrew codecs, bundled TLS, libx264 or other GPL code.
# Preserve ARM64 assembly optimizations and FFmpeg's built-in AAC encoder.
# Keep full configure invocation in the source archive's generated config files.
./configure \
    --prefix="$WORK/install" \
    --cc="$CC" \
    --arch=arm64 --target-os=darwin \
    --sysroot="$SDK" \
    --extra-cflags="-arch arm64 -mmacosx-version-min=26.0" \
    --extra-ldflags="-arch arm64 -mmacosx-version-min=26.0" \
    --disable-autodetect \
    --disable-shared --enable-static \
    --disable-gpl --disable-nonfree --disable-version3 \
    --disable-debug --disable-doc --enable-securetransport \
    --disable-ffplay --disable-avdevice \
    --disable-programs --enable-ffmpeg --enable-ffprobe \
    --disable-everything \
    --enable-protocol=file,pipe,data,subfile,concat,http,https,httpproxy,tcp,tls,crypto \
    --enable-demuxer=mov,aac,mp3,matroska,ogg,wav,flac,mpegts,hls,concat \
    --enable-muxer=mp4,mov,ipod,adts,matroska,mp3,null,wav \
    --enable-decoder=aac,alac,flac,mp3,opus,vorbis,pcm_s16le,h264,ac3,eac3 \
    --enable-encoder=aac,pcm_s16le \
    --enable-parser=aac,ac3,h264,mpegaudio,opus \
    --enable-bsf=aac_adtstoasc,h264_mp4toannexb,extract_extradata \
    --enable-filter=aresample,anull,abuffer,abuffersink,aformat,atrim,asetpts,volume,format,scale,buffer,buffersink

# Save configuration before deleting temporary build products. The tools are
# source-built once, at low priority, not on the interactive app release path.
cp ffbuild/config.sh "$WORK/configure-command.sh"
cp config.h "$WORK/config.h"
echo "Compiling independent LGPL tools; this is NOT a PodCraft release build."
nice -n 15 make -j "${FFMPEG_BUILD_JOBS:-2}"
make install
for name in ffmpeg ffprobe; do
    [ -x "$WORK/install/bin/$name" ] || fail "missing compiled tool: $name"
done

STAGE=$(mktemp -d "$ROOT/Vendor/.ffmpeg-arm64-stage.XXXXXX")
cleanup_stage() { rm -rf "$STAGE"; }
trap 'cleanup_stage; cleanup' EXIT HUP INT TERM
mkdir -p "$STAGE/bin" "$STAGE/licenses"
cp "$WORK/install/bin/ffmpeg" "$WORK/install/bin/ffprobe" "$STAGE/bin/"
cp COPYING.LGPLv2.1 COPYING.LGPLv3 LICENSE.md "$STAGE/licenses/"
cp "$WORK/configure-command.sh" "$WORK/config.h" "$STAGE/licenses/"
cp "$SOURCE_CACHE/$ARCHIVE" "$STAGE/licenses/$ARCHIVE"
cat > "$STAGE/licenses/SOURCE-OFFER.txt" <<EOF
FFmpeg $VERSION — LGPLv2.1-or-later, independent command-line utilities.

PodCraft distributes ffmpeg and ffprobe as separate helper processes, not as
libraries linked into its own executable. FFmpeg is licensed by its authors
under the GNU Lesser General Public License, version 2.1 or later.

Exact corresponding unmodified source is INCLUDED with these notices as
$ARCHIVE. You can also obtain it directly from FFmpeg upstream:
  $SOURCE_URL
  SHA-256: $SOURCE_SHA256
  Detached signature: $SIGNATURE_URL
  Official release key: $KEY_URL
  Key fingerprint: $RELEASE_KEY

To inspect, modify, and rebuild these executable tools, use the separately
distributed, human-readable Tools/build-ffmpeg.sh script included with this
notice. The exact FFmpeg configure invocation is in configure-command.sh.
No third-party proprietary, GPL, or nonfree libraries were enabled.
This build uses only macOS system libraries at runtime.

The exact source archive is distributed alongside this document, offline,
with its checksum, detached signature, and reproducible build instructions.
FFmpeg copyright and license details: LICENSE.md, COPYING.LGPLv2.1,
COPYING.LGPLv3. These apply to FFmpeg, not PodCraft's own application code.
EOF
cp "$ROOT/Tools/build-ffmpeg.sh" "$STAGE/licenses/build-ffmpeg.sh"
cp "$SOURCE_CACHE/$ARCHIVE.asc" "$STAGE/licenses/"
cp "$SOURCE_CACHE/ffmpeg-devel.asc" "$STAGE/licenses/"

for tool in "$STAGE/bin/ffmpeg" "$STAGE/bin/ffprobe"; do
    codesign --force --sign - "$tool"
done
("$ROOT/Tools/verify-ffmpeg.sh" "$STAGE/bin")
(cd "$STAGE" && shasum -a 256 bin/ffmpeg bin/ffprobe licenses/$ARCHIVE > SHA256SUMS)

# Atomically publish the reusable, checked binaries. Keep the preceding
# prebuilt as a local rollback until the next successful build.
BACKUP="$ROOT/Vendor/.ffmpeg-arm64-previous"
if [ -e "$BACKUP" ]; then rm -rf "$BACKUP"; fi
if [ -e "$OUTPUT" ]; then mv "$OUTPUT" "$BACKUP"; fi
if ! mv "$STAGE" "$OUTPUT"; then
    if [ -e "$BACKUP" ]; then mv "$BACKUP" "$OUTPUT"; fi
    fail "could not promote verified FFmpeg tools"
fi
trap cleanup EXIT HUP INT TERM
echo "STATIC LGPL FFMPEG READY: $OUTPUT/bin/{ffmpeg,ffprobe}"
"$ROOT/Tools/verify-ffmpeg.sh"
