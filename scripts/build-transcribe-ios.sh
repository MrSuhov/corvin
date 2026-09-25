#!/bin/bash
set -euo pipefail

# Builds transcribe.cpp (GigaAM) for iOS as TranscribeCpp.xcframework: a
# dynamic framework per slice — device arm64 with Metal, simulator arm64 on
# the CPU — with ggml linked inside and only `_transcribe_*` exported, for the
# same reason as on macOS (see build-transcribe-macos.sh): the app also links
# whisper.cpp's static ggml. A framework rather than a bare dylib because the
# App Store rejects loose dylibs in an app bundle.
#
# Only the host app links it; the keyboard extension never runs a model.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$PROJECT_DIR/vendor/transcribe.cpp"
OUT="$SRC/build-ios"
XCFRAMEWORK="$OUT/TranscribeCpp.xcframework"
DEPLOYMENT=16.0

# The same pinned source as macOS: the ref is declared once, there.
TRANSCRIBE_REF=$(grep '^TRANSCRIBE_REF=' "$PROJECT_DIR/scripts/build-transcribe-macos.sh" | cut -d'"' -f2)
if [ ! -d "$SRC/.git" ]; then
    echo "=== Cloning transcribe.cpp $TRANSCRIBE_REF ==="
    git clone -q https://github.com/handy-computer/transcribe.cpp "$SRC"
fi
git -C "$SRC" fetch -q --tags
git -C "$SRC" checkout -q "$TRANSCRIBE_REF"

echo "=== Building transcribe.cpp $TRANSCRIBE_REF for iOS (device + simulator) ==="

# $1 = iphoneos | iphonesimulator
build_slice() {
    local sdk=$1
    local build="$SRC/build-$sdk"
    local metal=ON target="arm64-apple-ios$DEPLOYMENT"
    if [ "$sdk" = "iphonesimulator" ]; then
        # The simulator's Metal device cannot hold a model (see
        # TranscriptionEngine.loadModel); CPU only, as upstream ships it.
        metal=OFF
        target="arm64-apple-ios$DEPLOYMENT-simulator"
    fi
    rm -rf "$build"
    cmake -S "$SRC" -B "$build" -G "Unix Makefiles" \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$sdk" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$DEPLOYMENT \
        -DCMAKE_BUILD_TYPE=Release \
        -DTRANSCRIBE_METAL=$metal \
        -DGGML_METAL_EMBED_LIBRARY=ON \
        -DGGML_NATIVE=OFF \
        -DTRANSCRIBE_BUILD_SHARED=OFF \
        -DTRANSCRIBE_BUILD_TESTS=OFF \
        -DTRANSCRIBE_BUILD_EXAMPLES=OFF \
        -DTRANSCRIBE_INSTALL=OFF \
        -DGGML_CCACHE=OFF > /dev/null
    cmake --build "$build" -j"$(sysctl -n hw.ncpu)" > /dev/null

    local archives=()
    while IFS= read -r a; do archives+=(-Wl,-force_load,"$a"); done \
        < <(find "$build" -name '*.a' -not -path '*/examples/*' | sort)
    echo "_transcribe_*" > "$build/exports.txt"

    local fw="$build/TranscribeCpp.framework"
    rm -rf "$fw" && mkdir -p "$fw"
    xcrun --sdk "$sdk" clang++ -dynamiclib -target "$target" \
        -o "$fw/TranscribeCpp" \
        -install_name @rpath/TranscribeCpp.framework/TranscribeCpp \
        "${archives[@]}" \
        -Wl,-exported_symbols_list,"$build/exports.txt" -Wl,-dead_strip \
        -framework Accelerate -framework Foundation -framework Metal -framework MetalKit \
        -lc++ -lz
    local platform=iPhoneOS
    [ "$sdk" = "iphonesimulator" ] && platform=iPhoneSimulator
    cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>TranscribeCpp</string>
    <key>CFBundleIdentifier</key><string>com.corvinvoice.transcribecpp</string>
    <key>CFBundleName</key><string>TranscribeCpp</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>${TRANSCRIBE_REF#v}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
    <key>MinimumOSVersion</key><string>$DEPLOYMENT</string>
</dict>
</plist>
PLIST

    leaked=$(nm -gU "$fw/TranscribeCpp" | awk 'NF == 3 {print $3}' | grep -v '^_transcribe_' | sort -u || true)
    if [ -n "$leaked" ]; then
        echo "ERROR: $sdk framework exports more than _transcribe_*:" >&2
        echo "$leaked" | head -20 >&2
        exit 1
    fi
    echo "  $sdk done"
}

build_slice iphoneos
build_slice iphonesimulator

rm -rf "$XCFRAMEWORK"
mkdir -p "$OUT"
xcodebuild -create-xcframework \
    -framework "$SRC/build-iphoneos/TranscribeCpp.framework" \
    -framework "$SRC/build-iphonesimulator/TranscribeCpp.framework" \
    -output "$XCFRAMEWORK" > /dev/null
echo "  Ready at $XCFRAMEWORK"
