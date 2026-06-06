#!/bin/bash
# Test IPC transcription pipeline
# Usage: ./scripts/test-ipc.sh [host:port]
#
# Tests:
# 1. Ping server
# 2. Send synthetic audio → POST /transcribe → poll /result
# 3. Read server logs
#
# Works with both simulator (localhost) and device (if port-forwarded)

set -euo pipefail

HOST="${1:-localhost:12345}"
BASE="http://$HOST"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; }
info() { echo -e "${YELLOW}→ $1${NC}"; }

# 1. Ping
info "Pinging $BASE/ping..."
PING=$(curl -s -m 5 "$BASE/ping" 2>/dev/null || echo "FAIL")
if echo "$PING" | grep -q '"ok"'; then
    pass "Server is alive"
else
    fail "Server not responding: $PING"
    exit 1
fi

# 2. Generate test audio (3 seconds of 16kHz mono silence + tiny noise)
info "Generating 3s test audio (16kHz mono Int16 PCM)..."
AUDIO_FILE=$(mktemp /tmp/corvin-test-XXXX.raw)
# 3 seconds * 16000 samples/s * 2 bytes = 96000 bytes
python3 -c "
import struct, random, sys
samples = 16000 * 3  # 3 seconds at 16kHz
data = b''
for i in range(samples):
    # Low-amplitude noise to avoid being detected as silence
    sample = random.randint(-100, 100)
    data += struct.pack('<h', sample)
sys.stdout.buffer.write(data)
" > "$AUDIO_FILE"

AUDIO_SIZE=$(wc -c < "$AUDIO_FILE" | tr -d ' ')
info "Audio file: $AUDIO_FILE ($AUDIO_SIZE bytes)"

# 3. POST /transcribe
info "Sending audio to $BASE/transcribe..."
SUBMIT=$(curl -s -m 10 -X POST \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@$AUDIO_FILE" \
    "$BASE/transcribe" 2>/dev/null || echo "FAIL")

REQUEST_ID=$(echo "$SUBMIT" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")

if [ -z "$REQUEST_ID" ]; then
    fail "POST /transcribe failed: $SUBMIT"
    rm -f "$AUDIO_FILE"
    exit 1
fi
pass "Submitted, id=$REQUEST_ID"

# 4. Poll for result
info "Polling for result..."
MAX_POLLS=60
POLL_INTERVAL=1
for i in $(seq 1 $MAX_POLLS); do
    sleep $POLL_INTERVAL
    RESULT=$(curl -s -m 5 "$BASE/result?id=$REQUEST_ID" 2>/dev/null || echo '{"status":"poll_error"}')
    STATUS=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null || echo "parse_error")

    case "$STATUS" in
        done)
            TEXT=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('text',''))" 2>/dev/null)
            LANG=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('language',''))" 2>/dev/null)
            pass "Transcription done after $i polls"
            echo "  Text: '$TEXT'"
            echo "  Language: $LANG"
            break
            ;;
        error)
            ERR=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('error',''))" 2>/dev/null)
            fail "Server error after $i polls: $ERR"
            break
            ;;
        processing)
            echo "  poll #$i: processing..."
            ;;
        *)
            echo "  poll #$i: $STATUS"
            ;;
    esac

    if [ "$i" -eq "$MAX_POLLS" ]; then
        fail "Timed out after $MAX_POLLS polls"
    fi
done

# 5. Show logs
echo ""
info "Server logs:"
curl -s -m 5 "$BASE/log" 2>/dev/null | tail -20

# Cleanup
rm -f "$AUDIO_FILE"
