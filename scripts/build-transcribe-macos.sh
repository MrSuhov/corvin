#!/bin/bash
set -euo pipefail

# Builds transcribe.cpp (GigaAM and other non-whisper models) as one universal
# libtranscribe.dylib for macOS 11+: arm64 with Metal, x86_64 on the CPU.
#
# Why a dylib and not static libs like whisper.cpp: transcribe.cpp carries its
# own, patched ggml. Two static ggml copies in one binary collide on every
# ggml_* symbol — or worse, silently bind one library's calls to the other's
# code. Here ggml is linked *inside* the dylib and only `_transcribe_*` is
# exported, so the app's whisper.cpp and this ggml never see each other.
#
# vendor/ is gitignored: the source is cloned at TRANSCRIBE_REF if missing.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$PROJECT_DIR/vendor/transcribe.cpp"
OUT="$SRC/build-universal"
TRANSCRIBE_REPO="https://github.com/handy-computer/transcribe.cpp"
TRANSCRIBE_REF="v0.2.4"  # 4807edaf210d0d7e8a6f7fb2a44b65966a2797f0

if [ ! -d "$SRC/.git" ]; then
    echo "=== Cloning transcribe.cpp $TRANSCRIBE_REF ==="
    git clone -q "$TRANSCRIBE_REPO" "$SRC"
fi
git -C "$SRC" fetch -q --tags
git -C "$SRC" checkout -q "$TRANSCRIBE_REF"

echo "=== Building transcribe.cpp $TRANSCRIBE_REF (arm64 + x86_64) ==="

build_arch() {
    local arch=$1
    local flags=(-DTRANSCRIBE_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON)
    if [ "$arch" = "x86_64" ]; then
        # Same floor as whisper.cpp's x86_64 slice: plain x86-64, no AVX
        # assumptions, so it runs on every Intel Mac macOS 11 supports.
        flags=(-DTRANSCRIBE_METAL=OFF -DTRANSCRIBE_X86_CONSERVATIVE=ON)
    fi
    rm -rf "$SRC/build-$arch"
    cmake -S "$SRC" -B "$SRC/build-$arch" -G "Unix Makefiles" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
        -DTRANSCRIBE_BUILD_SHARED=OFF \
        -DTRANSCRIBE_BUILD_TESTS=OFF \
        -DTRANSCRIBE_BUILD_EXAMPLES=OFF \
        -DTRANSCRIBE_INSTALL=OFF \
        -DGGML_CCACHE=OFF \
        "${flags[@]}" > /dev/null
    cmake --build "$SRC/build-$arch" -j"$(sysctl -n hw.ncpu)" > /dev/null

    # Every static archive of the build, force-loaded: the dylib must carry
    # all of ggml, since nothing outside can provide it.
    local archives=()
    while IFS= read -r a; do archives+=(-Wl,-force_load,"$a"); done \
        < <(find "$SRC/build-$arch" -name '*.a' -not -path '*/examples/*' | sort)

    local exports="$SRC/build-$arch/exports.txt"
    echo "_transcribe_*" > "$exports"

    clang++ -dynamiclib -arch "$arch" -mmacosx-version-min=11.0 \
        -o "$SRC/build-$arch/libtranscribe.dylib" \
        -install_name @rpath/libtranscribe.dylib \
        "${archives[@]}" \
        -Wl,-exported_symbols_list,"$exports" -Wl,-dead_strip \
        -framework Accelerate -framework Foundation -framework Metal -framework MetalKit \
        -lc++ -lz
    echo "  $arch done"
}

build_arch arm64
build_arch x86_64

rm -rf "$OUT"
mkdir -p "$OUT/include"
lipo -create "$SRC/build-arm64/libtranscribe.dylib" "$SRC/build-x86_64/libtranscribe.dylib" \
    -output "$OUT/libtranscribe.dylib"
cp "$SRC"/include/*.h "$OUT/include/"

# The whole point of the dylib: nothing of ggml may be visible outside it.
leaked=$(for a in arm64 x86_64; do nm -gU "$SRC/build-$a/libtranscribe.dylib"; done \
    | awk 'NF == 3 {print $3}' | grep -v '^_transcribe_' | sort -u || true)
if [ -n "$leaked" ]; then
    echo "ERROR: libtranscribe.dylib exports more than _transcribe_*:" >&2
    echo "$leaked" | head -20 >&2
    exit 1
fi

echo "  $(lipo -info "$OUT/libtranscribe.dylib")"
echo "  exports: $(nm -gU "$SRC/build-arm64/libtranscribe.dylib" | grep -c ' _transcribe_') transcribe_* symbols, no ggml"
echo "  Ready at $OUT/"
