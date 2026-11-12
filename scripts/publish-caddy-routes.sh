#!/bin/bash
# Install Corvin's Caddy routes (/corvin/*, /apps) on the shared server.
#
# The server's Caddy serves four projects, and each one writes only its own
# file, through /usr/local/sbin/caddy-site-install: it validates the whole
# config with the new file before writing it and puts the old one back if the
# reload fails. Corvin's routes live inside the `hyperstack.ru` site, which
# Reactor owns, so ours is /etc/caddy/hyperstack.d/routes/corvin.caddy, imported from
# that block. Rules for every project: /etc/caddy/README.md on the server.
#
# Run it after changing deploy/caddy/corvin.caddy — nothing else installs that
# file, and editing the server copy by hand is lost on the next run.
#
#   ./scripts/publish-caddy-routes.sh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL="$PROJECT_ROOT/deploy/caddy/corvin.caddy"
REMOTE_HOST="reactor"
# Where the file waits for the installer. The installer reads it from here, so
# this path is the one a sudoers line would pin.
REMOTE_SRC="/opt/corvin/deploy/caddy/corvin.caddy"
INSTALLED="/etc/caddy/hyperstack.d/routes/corvin.caddy"
INSTALLER="/usr/local/sbin/caddy-site-install"
# `routes` is the installer's slot for hyperstack.d/routes/<project>.caddy (approved by
# Reactor); without it the installer would write sites/corvin.caddy.
INSTALL_ARGS=(corvin "$REMOTE_SRC" routes)

[ -f "$LOCAL" ] || { echo "ERROR: $LOCAL not found"; exit 1; }

echo "=== Checking the server ==="
# Before the split, Corvin's routes are part of the one big Caddyfile and there
# is nothing to install into. Refuse rather than drop the file somewhere the
# config never reads.
if ! ssh "$REMOTE_HOST" "test -x '$INSTALLER' && test -f '$INSTALLED'"; then
    echo "ERROR: $INSTALLER or $INSTALLED missing on $REMOTE_HOST"
    echo "  The Caddy split has not happened yet; the routes still live in"
    echo "  /etc/caddy/Caddyfile. See /etc/caddy/README.md once it exists."
    exit 1
fi

echo "=== Uploading ==="
ssh "$REMOTE_HOST" "mkdir -p '$(dirname "$REMOTE_SRC")'"
scp "$LOCAL" "$REMOTE_HOST:${REMOTE_SRC}.tmp"
ssh "$REMOTE_HOST" "mv '${REMOTE_SRC}.tmp' '$REMOTE_SRC'"

echo "=== Installing ==="
ssh "$REMOTE_HOST" "sudo -n '$INSTALLER' $(printf "'%s' " "${INSTALL_ARGS[@]}")"

echo "=== Verifying routes ==="
# /apps answers 308 (file_server adds the slash), the rest 200. A 404 or a page
# from the Next.js site means the import is missing or sits below the catch-all.
check() {
    local url="$1" want="$2" got
    got=$(curl -s -o /dev/null -w '%{http_code}' "$url")
    if [ "$got" != "$want" ]; then
        echo "ERROR: $url answered $got, expected $want"
        exit 1
    fi
    echo "  $url → $got"
}
check https://hyperstack.ru/corvin/models.json 200
check https://hyperstack.ru/apps 308
check https://hyperstack.ru/apps/ 200
echo "=== Done ==="
