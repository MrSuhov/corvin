#!/bin/bash
# Deploy Corvin to TestFlight (iOS, macOS, or both)
# Usage: ./scripts/deploy-testflight.sh [ios|macos|all]
#
# Requires:
#   - Xcode with signing configured
#   - signing.env filled in (copy from signing.env.example)
#   - App Store Connect API key at ~/private_keys/AuthKey_<ASC_KEY_ID>.p8
#   - xcodegen (brew install xcodegen)
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="/tmp/CorvinTestFlight"

# Load local Apple-account config (gitignored). Exports DEVELOPMENT_TEAM too, so
# the xcodegen invocation below expands ${DEVELOPMENT_TEAM} in project.yml.
[ -f "$PROJECT_ROOT/signing.env" ] && source "$PROJECT_ROOT/signing.env"

# App Store Connect API
API_KEY_ID="${ASC_KEY_ID:?Set ASC_KEY_ID (copy signing.env.example to signing.env)}"
API_ISSUER_ID="${ASC_ISSUER_ID:?Set ASC_ISSUER_ID in signing.env}"
API_KEY_PATH="$HOME/private_keys/AuthKey_${API_KEY_ID}.p8"

PLATFORM="${1:-all}"

# Validate API key
if [ ! -f "$API_KEY_PATH" ]; then
    echo "ERROR: API key not found at $API_KEY_PATH"
    echo "Copy it: mkdir -p ~/private_keys && cp ~/Downloads/AuthKey_${API_KEY_ID}.p8 ~/private_keys/"
    exit 1
fi

# Build number (timestamp-based, always unique). Flows to every target
# via the CURRENT_PROJECT_VERSION build setting passed to xcodebuild below;
# all Info.plist files read $(CURRENT_PROJECT_VERSION).
BUILD_NUMBER=$(date +%Y%m%d%H%M)
echo "=== Build number: $BUILD_NUMBER ==="

archive_and_upload() {
    local scheme="$1"
    local platform="$2"
    local export_plist="$3"
    local destination="$4"

    local archive_path="$BUILD_DIR/${scheme}.xcarchive"
    local export_path="$BUILD_DIR/${scheme}-export"

    # Substitute the team id (kept out of the repo) into a runtime copy of the
    # export options plist.
    local runtime_plist="$BUILD_DIR/$(basename "$export_plist")"
    sed "s/__DEVELOPMENT_TEAM__/${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM in signing.env}/" "$export_plist" > "$runtime_plist"

    echo ""
    echo "=== Archiving $scheme ($platform) ==="
    xcodebuild archive \
        -project "$PROJECT_ROOT/Corvin.xcodeproj" \
        -scheme "$scheme" \
        -configuration Release \
        -destination "$destination" \
        -archivePath "$archive_path" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$API_KEY_PATH" \
        -authenticationKeyID "$API_KEY_ID" \
        -authenticationKeyIssuerID "$API_ISSUER_ID" \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        2>&1 | grep -E "ARCHIVE SUCCEEDED|ARCHIVE FAILED|error:|warning:.*error" || true

    if [ ! -d "$archive_path" ]; then
        echo "ERROR: Archive failed for $scheme"
        exit 1
    fi
    echo "  Archive: $archive_path"

    echo "=== Uploading $scheme to TestFlight ==="
    local export_log
    export_log=$(xcodebuild -exportArchive \
        -archivePath "$archive_path" \
        -exportOptionsPlist "$runtime_plist" \
        -exportPath "$export_path" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$API_KEY_PATH" \
        -authenticationKeyID "$API_KEY_ID" \
        -authenticationKeyIssuerID "$API_ISSUER_ID" \
        2>&1)

    if echo "$export_log" | grep -q "EXPORT SUCCEEDED"; then
        echo "  Upload succeeded"
    else
        echo "$export_log" | grep -E "error:|EXPORT FAILED" || true
        echo "  ERROR: Export/upload failed for $scheme"
        exit 1
    fi
}

# Step 1: Generate Xcode project
echo "=== Generating Xcode project ==="
cd "$PROJECT_ROOT"
xcodegen generate 2>&1 | tail -1

# Step 2: Clean build dir
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Step 3: Archive and upload
if [ "$PLATFORM" = "ios" ] || [ "$PLATFORM" = "all" ]; then
    archive_and_upload \
        "CorviniOS" \
        "iOS" \
        "$PROJECT_ROOT/scripts/ExportOptions-ios.plist" \
        "generic/platform=iOS"
fi

if [ "$PLATFORM" = "macos" ] || [ "$PLATFORM" = "all" ]; then
    archive_and_upload \
        "Corvin" \
        "macOS" \
        "$PROJECT_ROOT/scripts/ExportOptions-macos.plist" \
        "generic/platform=macOS"
fi

echo ""
echo "=== Done ==="
echo "Check TestFlight: https://appstoreconnect.apple.com/apps"
echo "Build: $BUILD_NUMBER"
