#!/bin/bash
# Run iOS UI tests in background
# Simulator window can be minimized while tests run

set -e

SCHEME="CorviniOS"
SIMULATOR="iPhone 17 Pro"
PROJECT="Corvin.xcodeproj"
LOG_FILE="test-results.log"

echo "=== Corvin iOS UI Tests ==="
echo "Simulator: $SIMULATOR"
echo "Log file: $LOG_FILE"
echo ""

# Check if simulator is booted
if ! xcrun simctl list devices booted | grep -q "$SIMULATOR"; then
    echo "Booting simulator..."
    xcrun simctl boot "$SIMULATOR" 2>/dev/null || true
    sleep 3
fi

echo "Building and running tests..."
echo "You can minimize the simulator window and continue working."
echo ""

# Run tests in background, output to log file
xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,name=$SIMULATOR" \
    -resultBundlePath "test-results.xcresult" \
    2>&1 | tee "$LOG_FILE" &

TEST_PID=$!

echo "Test process started (PID: $TEST_PID)"
echo "Monitor progress: tail -f $LOG_FILE"
echo "Stop tests: kill $TEST_PID"
echo ""

# Wait for tests to complete
wait $TEST_PID
EXIT_CODE=$?

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo "✅ Tests PASSED"
else
    echo "❌ Tests FAILED (exit code: $EXIT_CODE)"
fi

# Print summary
echo ""
echo "=== Test Summary ==="
grep -E "(Test Case|passed|failed|error:)" "$LOG_FILE" | tail -20

exit $EXIT_CODE
