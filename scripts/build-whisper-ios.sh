#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WHISPER_DIR="$PROJECT_DIR/vendor/whisper.cpp"
LIBS="libwhisper.a libggml.a libggml-base.a libggml-cpu.a libggml-metal.a"

echo "=== Building whisper.cpp for iOS (device + simulator) ==="

# --- Device (arm64) ---
echo "  Building for iOS device (arm64)..."
rm -rf "$WHISPER_DIR/build-ios-device"
mkdir -p "$WHISPER_DIR/build-ios-device"
cd "$WHISPER_DIR/build-ios-device"

cmake .. \
    -G "Unix Makefiles" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_METAL=ON \
    -DGGML_BLAS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_NATIVE=OFF \
    > /dev/null 2>&1

make -j"$(sysctl -n hw.ncpu)" > /dev/null 2>&1

# --- Simulator (arm64) ---
echo "  Building for iOS Simulator (arm64)..."
rm -rf "$WHISPER_DIR/build-ios-sim"
mkdir -p "$WHISPER_DIR/build-ios-sim"
cd "$WHISPER_DIR/build-ios-sim"

cmake .. \
    -G "Unix Makefiles" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_OSX_SYSROOT=iphonesimulator \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_METAL=ON \
    -DGGML_BLAS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_NATIVE=OFF \
    > /dev/null 2>&1

make -j"$(sysctl -n hw.ncpu)" > /dev/null 2>&1

# --- Collect into flat dirs ---
echo "  Collecting libraries..."
DEVICE_OUT="$WHISPER_DIR/build-ios-universal"
SIM_OUT="$WHISPER_DIR/build-ios-sim-universal"
rm -rf "$DEVICE_OUT" "$SIM_OUT"
mkdir -p "$DEVICE_OUT" "$SIM_OUT"

for lib in $LIBS; do
    DEVICE_LIB=$(find "$WHISPER_DIR/build-ios-device" -name "$lib" -print -quit)
    SIM_LIB=$(find "$WHISPER_DIR/build-ios-sim" -name "$lib" -print -quit)
    [ -n "$DEVICE_LIB" ] && cp "$DEVICE_LIB" "$DEVICE_OUT/"
    [ -n "$SIM_LIB" ] && cp "$SIM_LIB" "$SIM_OUT/"
done

echo "  Device libs: $DEVICE_OUT/"
ls -la "$DEVICE_OUT/"*.a 2>/dev/null || true
echo "  Simulator libs: $SIM_OUT/"
ls -la "$SIM_OUT/"*.a 2>/dev/null || true
