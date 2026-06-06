#!/bin/bash
# Test IPC with real microphone audio
# Usage: ./scripts/test-ipc-mic.sh [seconds] [host:port]
#
# Records from Mac microphone, sends to IPC server, shows transcription result.

set -euo pipefail

DURATION="${1:-3}"
HOST="${2:-localhost:12345}"
BASE="http://$HOST"
AUDIO_FILE=$(mktemp /tmp/corvin-mic-XXXX.raw)

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; }
info() { echo -e "${YELLOW}→ $1${NC}"; }

# Check server
PING=$(curl -s -m 3 "$BASE/ping" 2>/dev/null || echo "FAIL")
if ! echo "$PING" | grep -q '"ok"'; then
    fail "Server not responding at $BASE"
    exit 1
fi
pass "Server alive"

# Record audio
info "Recording ${DURATION}s from microphone... Speak now!"
ffmpeg -f avfoundation -i ":0" -t "$DURATION" -ar 16000 -ac 1 -f s16le -acodec pcm_s16le "$AUDIO_FILE" -y -loglevel error 2>&1

AUDIO_SIZE=$(wc -c < "$AUDIO_FILE" | tr -d ' ')
AUDIO_DUR=$(echo "scale=2; $AUDIO_SIZE / 32000" | bc)
info "Recorded: $AUDIO_SIZE bytes (${AUDIO_DUR}s)"

if [ "$AUDIO_SIZE" -lt 16000 ]; then
    fail "Audio too short ($AUDIO_SIZE bytes)"
    rm -f "$AUDIO_FILE"
    exit 1
fi

# Submit
info "Sending to server..."
SUBMIT=$(curl -s -m 10 -X POST \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@$AUDIO_FILE" \
    "$BASE/transcribe")

REQUEST_ID=$(echo "$SUBMIT" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
if [ -z "$REQUEST_ID" ]; then
    fail "Submit failed: $SUBMIT"
    rm -f "$AUDIO_FILE"
    exit 1
fi
pass "Submitted (id=${REQUEST_ID:0:8}...)"

# Poll
info "Waiting for transcription..."
for i in $(seq 1 120); do
    sleep 1
    RESULT=$(curl -s -m 5 "$BASE/result?id=$REQUEST_ID" 2>/dev/null || echo '{"status":"error"}')
    STATUS=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null || echo "?")

    case "$STATUS" in
        done)
            TEXT=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('text',''))" 2>/dev/null)
            LANG=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('language',''))" 2>/dev/null)
            echo ""
            pass "Transcription (${i}s, lang=$LANG):"
            echo -e "  ${GREEN}$TEXT${NC}"
            break
            ;;
        error)
            ERR=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('error',''))" 2>/dev/null)
            fail "Error: $ERR"
            break
            ;;
        processing)
            printf "."
            ;;
    esac

    if [ "$i" -eq 120 ]; then
        echo ""
        fail "Timed out"
    fi
done

rm -f "$AUDIO_FILE"
