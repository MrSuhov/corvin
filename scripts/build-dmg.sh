#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/Corvin.app/Contents"
DMG_PATH="$BUILD_DIR/Corvin.dmg"

MODELS_DIR="$HOME/Library/Application Support/Corvin/Models"
SMALL_MODEL="$MODELS_DIR/ggml-small.bin"

echo "=== Corvin DMG Builder ==="

# Step 1: Build whisper.cpp universal static libs
echo "[1/5] Building whisper.cpp universal libraries..."
"$PROJECT_DIR/scripts/build-whisper-macos.sh"

# Step 1b: Build opus/opusfile universal static libs
echo "[1b/5] Building opus/opusfile universal libraries..."
"$PROJECT_DIR/scripts/build-opusfile.sh" macos

# Step 2: Build Corvin universal binary
echo "[2/4] Building Corvin universal binary..."

cd "$PROJECT_DIR"
rm -f "$PROJECT_DIR/.build/apple/Products/Release/Corvin"
swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -E "error:|warning:|Build complete" || true

BINARY="$PROJECT_DIR/.build/apple/Products/Release/Corvin"
if [ ! -f "$BINARY" ]; then
    echo "ERROR: Build failed"
    exit 1
fi

ARCHS=$(lipo -info "$BINARY" 2>&1)
echo "  $ARCHS"

# Step 3: Verify small model exists locally
echo "[3/4] Checking small model..."
if [ ! -f "$SMALL_MODEL" ]; then
    echo "ERROR: ggml-small.bin not found at $SMALL_MODEL"
    echo "Download it first via the app, then re-run this script."
    exit 1
fi
echo "  Found: $(du -h "$SMALL_MODEL" | cut -f1)"

# Step 4: Create .app bundle with bundled model and package DMG
echo "[4/4] Creating Corvin.dmg..."

rm -rf "$BUILD_DIR/Corvin.app"
mkdir -p "$APP_DIR/MacOS" "$APP_DIR/Resources/Models"

cp "$BINARY" "$APP_DIR/MacOS/"
cp "$PROJECT_DIR/macOS/Resources/Info.plist" "$APP_DIR/"

# swift build does not substitute Xcode build-setting placeholders, so the copied
# Info.plist still contains $(MARKETING_VERSION)/$(CURRENT_PROJECT_VERSION). Fill
# them in here. MARKETING_VERSION (human-facing) is read from project.yml; the
# build number is a timestamp so Sparkle's sparkle:version always increases
# monotonically across releases.
MARKETING_VERSION=$(grep 'MARKETING_VERSION:' "$PROJECT_DIR/project.yml" | head -1 | sed 's/.*"\(.*\)".*/\1/')
BUILD_VERSION=$(date +%Y%m%d%H%M)
echo "  Version: $MARKETING_VERSION (build $BUILD_VERSION)"
/usr/bin/sed -i '' \
    -e "s/\$(MARKETING_VERSION)/$MARKETING_VERSION/g" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/$BUILD_VERSION/g" \
    "$APP_DIR/Info.plist"
cp "$PROJECT_DIR/macOS/Resources/AppIcon.icns" "$APP_DIR/Resources/" 2>/dev/null || true
cp "$PROJECT_DIR/macOS/Resources/StatusBarIcon.png" "$APP_DIR/Resources/" 2>/dev/null || true
cp "$PROJECT_DIR/macOS/Resources/StatusBarIcon@2x.png" "$APP_DIR/Resources/" 2>/dev/null || true

# Copy localization resources
for lproj in "$PROJECT_DIR/Shared/Resources/"*.lproj; do
    cp -R "$lproj" "$APP_DIR/Resources/"
done

# Bundle small model
cp "$SMALL_MODEL" "$APP_DIR/Resources/Models/ggml-small.bin"

# Embed Sparkle.framework (auto-update). swift build links against it but does
# not embed it into a .app, so copy it from the SPM binary-artifact cache.
echo "  Embedding Sparkle.framework..."
SPARKLE_FW=$(/usr/bin/find "$PROJECT_DIR/.build" -type d -name "Sparkle.framework" -path "*macos*" 2>/dev/null | head -1)
if [ -z "$SPARKLE_FW" ]; then
    echo "ERROR: Sparkle.framework not found under .build. Run 'swift build' once so SPM fetches it."
    exit 1
fi
mkdir -p "$APP_DIR/Frameworks"
/usr/bin/ditto "$SPARKLE_FW" "$APP_DIR/Frameworks/Sparkle.framework"

# Load local signing config (gitignored). Copy signing.env.example -> signing.env.
[ -f "$PROJECT_DIR/signing.env" ] && source "$PROJECT_DIR/signing.env"
SIGN_IDENTITY="${SIGN_IDENTITY:?Set SIGN_IDENTITY (copy signing.env.example to signing.env)}"
ENTITLEMENTS="$PROJECT_DIR/macOS/Resources/Corvin.entitlements"

echo "  Signing with Developer ID..."
# Sparkle's nested helpers must be signed (innermost first) before the framework,
# the main binary, and finally the outer app bundle.
SP="$APP_DIR/Frameworks/Sparkle.framework"
SPARKLE_VER="$SP/Versions/Current"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$SPARKLE_VER/Autoupdate"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$SPARKLE_VER/Updater.app"
for xpc in "$SPARKLE_VER/XPCServices/"*.xpc; do
    [ -e "$xpc" ] && codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$xpc"
done
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$SP"

codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$BUILD_DIR/Corvin.app/Contents/MacOS/Corvin"
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$BUILD_DIR/Corvin.app"
codesign --verify --deep --strict "$BUILD_DIR/Corvin.app"
echo "  Signature verified."

rm -f "$DMG_PATH"
if command -v create-dmg &>/dev/null; then
    create-dmg \
        --volname "Corvin" \
        --window-size 600 400 \
        --icon-size 128 \
        --icon "Corvin.app" 150 200 \
        --app-drop-link 450 200 \
        "$DMG_PATH" \
        "$BUILD_DIR/Corvin.app" \
        2>&1 | grep -E "created:|Disk image done" || true
else
    hdiutil create -volname "Corvin" -srcfolder "$BUILD_DIR/Corvin.app" \
        -ov -format UDZO "$DMG_PATH" > /dev/null 2>&1
fi

if [ ! -f "$DMG_PATH" ]; then
    echo "ERROR: DMG creation failed"
    exit 1
fi

# Sign the DMG itself
codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH"

# Notarize
echo "[5/5] Notarizing DMG with Apple..."
xcrun notarytool submit "$DMG_PATH" --keychain-profile "AC_PASSWORD" --wait 2>&1

echo "  Stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"

# Cleanup
rm -rf "$BUILD_DIR/Corvin.app"

SIZE=$(du -h "$DMG_PATH" | cut -f1)

echo ""
echo "=== Done ==="
echo "DMG: $DMG_PATH ($SIZE, includes small model)"
echo "Signed: Developer ID + Notarized"
echo "Min macOS: 11.0 (Big Sur)"
echo "Architectures: arm64 + x86_64"
