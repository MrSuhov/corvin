#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WHISPER_DIR="$PROJECT_DIR/vendor/whisper.cpp"

echo "=== Building whisper.cpp universal libraries (arm64 + x86_64) ==="

# ggml-blas unconditionally builds against Accelerate's ILP64 BLAS by defining
# ACCELERATE_NEW_LAPACK + ACCELERATE_LAPACK_ILP64. Those headers rename the
# entry points to cblas_sgemm$NEWLAPACK$ILP64 and friends, which only exist in
# Accelerate from macOS 13.3 onwards. Against a 11.0 deployment target the link
# still succeeds — the symbols bind lazily — and the app then aborts the first
# time it actually multiplies a matrix:
#
#   Termination Reason: DYLD, [0x4] Symbol missing
#   Symbol not found: _cblas_sgemm$NEWLAPACK$ILP64
#
# which lands in whisper_encode_internal during model warm-up, i.e. at launch.
# Dropping the two defines falls back to the classic 32-bit-int BLAS interface
# that has always been there. ILP64 exists for matrices with more than 2^31
# elements per dimension; whisper is orders of magnitude below that.
#
# vendor/ is gitignored, so this has to be re-applied on every checkout rather
# than committed as a patch to the vendored tree.
patch_ggml_blas_for_old_macos() {
    local cmakelists="$WHISPER_DIR/ggml/src/ggml-blas/CMakeLists.txt"
    [ -f "$cmakelists" ] || return 0
    if grep -q "ACCELERATE_NEW_LAPACK" "$cmakelists"; then
        /usr/bin/sed -i '' \
            -e '/add_compile_definitions(ACCELERATE_NEW_LAPACK)/d' \
            -e '/add_compile_definitions(ACCELERATE_LAPACK_ILP64)/d' \
            "$cmakelists"
        echo "  patched ggml-blas: dropped ILP64 Accelerate defines (macOS 11/12 compatibility)"
    fi
}
patch_ggml_blas_for_old_macos

build_whisper_arch() {
    local arch=$1
    local extra_flags=""
    local metal_flags="-DWHISPER_METAL=OFF -DGGML_METAL=OFF"

    if [ "$arch" = "x86_64" ]; then
        extra_flags="-DCMAKE_C_FLAGS=-march=x86-64 -DCMAKE_CXX_FLAGS=-march=x86-64"
    else
        metal_flags="-DGGML_METAL=ON"
    fi

    rm -rf "$WHISPER_DIR/build-$arch"
    mkdir -p "$WHISPER_DIR/build-$arch"
    cd "$WHISPER_DIR/build-$arch"
    cmake .. \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
        -DCMAKE_BUILD_TYPE=Release \
        $metal_flags \
        -DGGML_BLAS=ON \
        -DWHISPER_BUILD_EXAMPLES=OFF \
        -DWHISPER_BUILD_TESTS=OFF \
        -DBUILD_SHARED_LIBS=OFF \
        -DGGML_NATIVE=OFF \
        $extra_flags \
        > /dev/null 2>&1
    make -j"$(sysctl -n hw.ncpu)" > /dev/null 2>&1
    echo "  $arch done"
}

build_whisper_arch arm64
build_whisper_arch x86_64

# Create universal libs with lipo
echo "Creating universal libraries..."

rm -rf "$WHISPER_DIR/build-universal"
mkdir -p "$WHISPER_DIR/build-universal"

for lib in libwhisper libggml libggml-base libggml-cpu; do
    if [ "$lib" = "libwhisper" ]; then
        arm64_path="$WHISPER_DIR/build-arm64/src/${lib}.a"
        x86_path="$WHISPER_DIR/build-x86_64/src/${lib}.a"
    else
        arm64_path="$WHISPER_DIR/build-arm64/ggml/src/${lib}.a"
        x86_path="$WHISPER_DIR/build-x86_64/ggml/src/${lib}.a"
    fi
    lipo -create "$arm64_path" "$x86_path" -output "$WHISPER_DIR/build-universal/${lib}.a"
done

# ggml-blas
lipo -create \
    "$WHISPER_DIR/build-arm64/ggml/src/ggml-blas/libggml-blas.a" \
    "$WHISPER_DIR/build-x86_64/ggml/src/ggml-blas/libggml-blas.a" \
    -output "$WHISPER_DIR/build-universal/libggml-blas.a"

# ggml-metal: arm64 real + x86_64 dummy
METAL_TMPDIR=$(mktemp -d)
echo "" > "$METAL_TMPDIR/empty.c"
clang -c -arch x86_64 -mmacosx-version-min=11.0 "$METAL_TMPDIR/empty.c" -o "$METAL_TMPDIR/empty.o" 2>/dev/null
ar rcs "$METAL_TMPDIR/libggml-metal-x86.a" "$METAL_TMPDIR/empty.o" 2>/dev/null
lipo -create \
    "$WHISPER_DIR/build-arm64/ggml/src/ggml-metal/libggml-metal.a" \
    "$METAL_TMPDIR/libggml-metal-x86.a" \
    -output "$WHISPER_DIR/build-universal/libggml-metal.a"
rm -rf "$METAL_TMPDIR"

echo "  Universal libs ready at $WHISPER_DIR/build-universal/"
