#!/bin/bash
# Build, install, and launch CorviniOS on connected iPhone
# Usage: ./scripts/deploy-ios.sh [--skip-build]
set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="com.corvin.ios"
DEVICE_ID="00008130-001069A40E31001C"
BUILD_DIR="/tmp/CorvinBuild"
SCHEME="CorviniOS"

SKIP_BUILD=false
for arg in "$@"; do
    case $arg in
        --skip-build) SKIP_BUILD=true ;;
    esac
done

# Ensure xcodegen project is up to date
echo "=== Generating Xcode project ==="
cd "$PROJECT_ROOT"
xcodegen generate 2>&1 | tail -1

if [ "$SKIP_BUILD" = false ]; then
    echo "=== Building $SCHEME ==="
    xcodebuild -scheme "$SCHEME" \
        -configuration Debug \
        -destination "id=$DEVICE_ID" \
        -derivedDataPath "$BUILD_DIR" \
        -allowProvisioningUpdates \
        build 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | grep -v "appintentsnl"

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo "Build failed"
        exit 1
    fi
else
    echo "=== Skipping build ==="
fi

APP_PATH="$BUILD_DIR/Build/Products/Debug-iphoneos/CorviniOS.app"
if [ ! -d "$APP_PATH" ]; then
    echo "App not found at $APP_PATH"
    exit 1
fi

echo "=== Installing on device ==="
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" 2>&1

echo "=== Launching ==="
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" 2>&1

echo "=== Done ==="
