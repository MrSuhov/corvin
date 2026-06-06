#!/bin/bash
set -euo pipefail

# Generates/updates appcast.xml (with binary deltas) from a directory of released
# DMGs, then copies it to the repo root for committing.
#
# Hosting model (GitHub Releases): all version DMGs and their *.delta files live
# under ONE fixed release tag ("downloads") so the download URL prefix is stable.
# appcast.xml is committed to the repo and served via raw.githubusercontent.com
# (that raw URL is SUFeedURL in Info.plist).
#
# Usage:  scripts/release-appcast.sh [dist_dir]
# dist_dir defaults to ./dist and must contain EVERY released DMG (Sparkle needs
# the previous versions present to compute deltas).

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${1:-$PROJECT_DIR/dist}"
DOWNLOAD_PREFIX="https://github.com/MrSuhov/corvin/releases/download/downloads/"

# Locate generate_appcast (ships with the Sparkle tools tarball, not the SPM
# xcframework). Set SPARKLE_BIN, put it in PATH, or install via Homebrew cask.
GEN=""
if [ -n "${SPARKLE_BIN:-}" ] && [ -x "$SPARKLE_BIN/generate_appcast" ]; then
    GEN="$SPARKLE_BIN/generate_appcast"
elif command -v generate_appcast >/dev/null 2>&1; then
    GEN="$(command -v generate_appcast)"
else
    GEN=$(/usr/bin/find "$PROJECT_DIR/.build" /opt/homebrew/Caskroom/sparkle 2>/dev/null -type f -name generate_appcast | head -1)
fi
if [ -z "$GEN" ]; then
    echo "ERROR: generate_appcast not found."
    echo "  Get the Sparkle tools from https://github.com/sparkle-project/Sparkle/releases"
    echo "  (download Sparkle-<ver>.tar.xz, the tools are in bin/), then either add"
    echo "  that bin/ to PATH or run with:  SPARKLE_BIN=/path/to/bin $0"
    exit 1
fi

if [ ! -d "$DIST_DIR" ]; then
    echo "ERROR: dist dir not found: $DIST_DIR"
    echo "  Put every released Corvin.dmg there (keep old ones for delta generation)."
    exit 1
fi

echo "Using: $GEN"
echo "Dist:  $DIST_DIR"
# generate_appcast signs each archive with the EdDSA private key from your Keychain
# (created by generate_keys) and writes appcast.xml + *.delta into DIST_DIR.
"$GEN" --download-url-prefix "$DOWNLOAD_PREFIX" "$DIST_DIR"

cp "$DIST_DIR/appcast.xml" "$PROJECT_DIR/appcast.xml"
echo ""
echo "=== Done ==="
echo "  - appcast.xml copied to repo root — commit & push it."
echo "  - Upload the new Corvin.dmg AND any generated *.delta files from"
echo "    $DIST_DIR to the GitHub release tagged 'downloads'."
