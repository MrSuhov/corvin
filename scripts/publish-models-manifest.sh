#!/bin/bash
# Regenerate models.json and publish it to hyperstack.ru.
#
# Run this after changing WhisperModel.all — clients pick the new catalogue up
# without an app release. Nothing here is tied to a version bump or a build.
#
#   ./scripts/publish-models-manifest.sh            # generate, upload, verify
#   ./scripts/publish-models-manifest.sh --dry-run  # generate and verify locally only
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL="$PROJECT_ROOT/build/models.json"
REMOTE_HOST="reactor"
REMOTE_PATH="/var/www/corvin/models.json"
PUBLIC_URL="https://hyperstack.ru/corvin/models.json"

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

echo "=== Generating manifest ==="
"$PROJECT_ROOT/scripts/generate-models-manifest.py" --out "$LOCAL"

# A malformed manifest would push every client onto its fallback catalogue
# silently, so check it here rather than finding out from the logs.
python3 - "$LOCAL" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["schemaVersion"] == 1, f"unexpected schemaVersion {d['schemaVersion']}"
assert d["models"], "manifest has no models"
for m in d["models"]:
    assert len(m["sha256"]) == 64, f"{m['id']}: bad sha256"
    assert m["sizeBytes"] > 0, f"{m['id']}: bad sizeBytes"
    assert m["downloadURL"].startswith("https://"), f"{m['id']}: insecure URL"
print(f"  manifest OK — {len(d['models'])} models")
PY

if [ "$DRY_RUN" = true ]; then
    echo "=== Dry run, not uploading ==="
    exit 0
fi

echo "=== Uploading ==="
# Write to a temp path and move into place so a reader never sees a half file.
scp "$LOCAL" "$REMOTE_HOST:${REMOTE_PATH}.tmp"
ssh "$REMOTE_HOST" "mv '${REMOTE_PATH}.tmp' '$REMOTE_PATH' && chmod 644 '$REMOTE_PATH'"

echo "=== Verifying published copy ==="
REMOTE_SHA=$(curl -fsS "$PUBLIC_URL" | shasum -a 256 | cut -d' ' -f1)
LOCAL_SHA=$(shasum -a 256 < "$LOCAL" | cut -d' ' -f1)
if [ "$REMOTE_SHA" != "$LOCAL_SHA" ]; then
    echo "ERROR: served manifest does not match the file just uploaded"
    echo "  local:  $LOCAL_SHA"
    echo "  remote: $REMOTE_SHA"
    exit 1
fi
echo "  $PUBLIC_URL matches the local manifest"
echo "=== Done ==="
