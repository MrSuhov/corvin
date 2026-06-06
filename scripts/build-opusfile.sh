#!/bin/bash
set -euo pipefail

# Build libogg, libopus, and libopusfile as static universal libraries for macOS
# and arm64 for iOS, similar to how whisper.cpp is vendored.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$PROJECT_DIR/vendor"
BUILD_DIR="$VENDOR_DIR/opus-build"

OGG_VERSION="1.3.5"
OPUS_VERSION="1.5.2"
OPUSFILE_VERSION="0.12"

OGG_URL="https://downloads.xiph.org/releases/ogg/libogg-${OGG_VERSION}.tar.gz"
OPUS_URL="https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz"
OPUSFILE_URL="https://downloads.xiph.org/releases/opus/opusfile-${OPUSFILE_VERSION}.tar.gz"

PLATFORM="${1:-macos}"  # macos or ios

echo "=== Building OGG/Opus/Opusfile ($PLATFORM) ==="

mkdir -p "$BUILD_DIR/src"
cd "$BUILD_DIR/src"

# Download sources if not cached
for pkg in "libogg-${OGG_VERSION}" "opus-${OPUS_VERSION}" "opusfile-${OPUSFILE_VERSION}"; do
    if [ ! -d "$pkg" ]; then
        case "$pkg" in
            libogg*) url="$OGG_URL" ;;
            opus-*)  url="$OPUS_URL" ;;
            opusfile*) url="$OPUSFILE_URL" ;;
        esac
        echo "Downloading $pkg..."
        curl -sL "$url" | tar xz
    fi
done

build_lib() {
    local src_dir="$1"
    local arch="$2"
    local prefix="$BUILD_DIR/$PLATFORM-$arch"

    mkdir -p "$prefix"
    cd "$BUILD_DIR/src/$src_dir"

    local host=""
    local cflags="-O2"
    local sdk_path=""

    if [ "$PLATFORM" = "ios" ]; then
        sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
        cflags="$cflags -isysroot $sdk_path -arch $arch -mios-version-min=15.0"
        host="--host=aarch64-apple-darwin"
    else
        sdk_path=$(xcrun --sdk macosx --show-sdk-path)
        cflags="$cflags -isysroot $sdk_path -arch $arch -mmacosx-version-min=11.0"
        if [ "$arch" = "arm64" ]; then
            host="--host=aarch64-apple-darwin"
        else
            host="--host=x86_64-apple-darwin"
        fi
    fi

    # Add ogg headers for opus/opusfile builds
    local extra_flags=""
    if [ "$src_dir" != "libogg-${OGG_VERSION}" ]; then
        extra_flags="--with-ogg=$prefix"
        cflags="$cflags -I$prefix/include"
    fi

    # opusfile needs opus too — set DEPS_CFLAGS/DEPS_LIBS to bypass pkg-config
    local deps_cflags=""
    local deps_libs=""
    if [[ "$src_dir" == opusfile* ]]; then
        extra_flags="$extra_flags --disable-http --disable-examples"
        cflags="$cflags -I$prefix/include"
        deps_cflags="-I$prefix/include/opus -I$prefix/include"
        deps_libs="-L$prefix/lib -lopus -logg"
    fi

    make clean 2>/dev/null || true
    CFLAGS="$cflags" LDFLAGS="-L$prefix/lib" \
        DEPS_CFLAGS="$deps_cflags" DEPS_LIBS="$deps_libs" \
        ./configure $host --prefix="$prefix" \
        --enable-static --disable-shared --disable-doc \
        $extra_flags \
        > /dev/null 2>&1
    make -j$(sysctl -n hw.ncpu) > /dev/null 2>&1
    make install > /dev/null 2>&1
    cd "$BUILD_DIR/src"
}

if [ "$PLATFORM" = "ios" ]; then
    ARCHS="arm64"
else
    ARCHS="arm64 x86_64"
fi

for arch in $ARCHS; do
    echo "Building libogg ($arch)..."
    build_lib "libogg-${OGG_VERSION}" "$arch"
    echo "Building libopus ($arch)..."
    build_lib "opus-${OPUS_VERSION}" "$arch"
    echo "Building libopusfile ($arch)..."
    build_lib "opusfile-${OPUSFILE_VERSION}" "$arch"
done

# Create universal binaries (macOS only)
OUTPUT_DIR="$BUILD_DIR/$PLATFORM-universal"
mkdir -p "$OUTPUT_DIR/lib" "$OUTPUT_DIR/include"

if [ "$PLATFORM" = "macos" ]; then
    for lib in libogg libopus libopusfile; do
        lipo -create \
            "$BUILD_DIR/$PLATFORM-arm64/lib/${lib}.a" \
            "$BUILD_DIR/$PLATFORM-x86_64/lib/${lib}.a" \
            -output "$OUTPUT_DIR/lib/${lib}.a"
    done
    cp -R "$BUILD_DIR/$PLATFORM-arm64/include/"* "$OUTPUT_DIR/include/"
else
    for lib in libogg libopus libopusfile; do
        cp "$BUILD_DIR/$PLATFORM-arm64/lib/${lib}.a" "$OUTPUT_DIR/lib/"
    done
    cp -R "$BUILD_DIR/$PLATFORM-arm64/include/"* "$OUTPUT_DIR/include/"
fi

echo ""
echo "=== Done ==="
echo "Output: $OUTPUT_DIR"
ls -la "$OUTPUT_DIR/lib/"
