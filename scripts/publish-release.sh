#!/bin/bash
set -euo pipefail

# Publishes a macOS release: builds the notarized DMG, updates the Sparkle feed,
# uploads the update files and creates the version's GitHub release.
#
# Usage:  scripts/publish-release.sh <version> <notes.md>
#
#   <notes.md>  what changed, for people: the release page and the release
#               commit's body. COMMIT_TRAILER, if set, is appended to the
#               commit message only.
#
# Two kinds of GitHub release, on purpose:
#   downloads   — where Sparkle downloads from. generate_appcast takes a single
#                 URL prefix, so every DMG and delta lives under this one tag.
#                 GitHub lists a release's files by name, never by date.
#   v<version>  — one per version, for people: notes and the DMG. The Releases
#                 page lists these newest first.
#
# Order matters. Sparkle reads appcast.xml from main, so the feed is pushed only
# after every file it points to has been uploaded and answers with the size the
# feed states — no client is ever sent to a file that is not there yet.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="MrSuhov/corvin"
DOWNLOADS="https://github.com/$REPO/releases/download/downloads"

die() { echo "ERROR: $*" >&2; exit 1; }

VERSION="${1:-}"
NOTES="${2:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: $0 <version> <notes.md>"
[ -f "$NOTES" ] || die "no notes file: $NOTES"
NOTES="$(cd "$(dirname "$NOTES")" && pwd)/$(basename "$NOTES")"

cd "$PROJECT_DIR"

# --- Preconditions -----------------------------------------------------------

[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "releases are cut from main"
git diff --quiet && git diff --cached --quiet || die "the working tree has uncommitted changes"
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "main is not in sync with origin/main"
gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1 && die "release v$VERSION already exists"
[ ! -e "dist/Corvin-$VERSION.dmg" ] || die "dist/Corvin-$VERSION.dmg already exists"

# --- Build ---------------------------------------------------------------------

echo "=== Version $VERSION"
sed -i '' -E "s/(MARKETING_VERSION: )\"[^\"]*\"/\1\"$VERSION\"/" project.yml
grep -q "MARKETING_VERSION: \"$VERSION\"" project.yml || die "could not set MARKETING_VERSION in project.yml"

./scripts/build-dmg.sh

MOUNT="$(mktemp -d)"
hdiutil attach build/Corvin.dmg -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MOUNT/Corvin.app/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$MOUNT/Corvin.app/Contents/Info.plist")"
hdiutil detach "$MOUNT" -quiet
[ "$BUILT" = "$VERSION" ] || die "the DMG carries version $BUILT, not $VERSION"
spctl -a -t open --context context:primary-signature build/Corvin.dmg 2>/dev/null \
    || die "build/Corvin.dmg is not notarized"
echo "=== Built $VERSION (build $BUILD), notarized"

# --- Feed ----------------------------------------------------------------------

cp build/Corvin.dmg "dist/Corvin-$VERSION.dmg"
./scripts/release-appcast.sh
grep -q "<sparkle:version>$BUILD</sparkle:version>" appcast.xml || die "appcast.xml has no item for build $BUILD"

# Everything the feed's new item points to.
ENCLOSURES="$(grep -E "$DOWNLOADS/(Corvin-$VERSION\.dmg|Corvin$BUILD-[0-9]+\.delta)\"" appcast.xml)" \
    || die "appcast.xml points to no file of build $BUILD"
FILES=()
while IFS= read -r line; do
    FILES+=("dist/$(sed -E 's#.*url="[^"]*/([^"/]+)".*#\1#' <<<"$line")")
done <<<"$ENCLOSURES"
for file in "${FILES[@]}"; do
    [ -f "$file" ] || die "the feed points to $file, which is not in dist"
done

# --- Upload and verify ---------------------------------------------------------

echo "=== Uploading ${#FILES[@]} file(s) to the downloads release"
gh release upload downloads "${FILES[@]}" --repo "$REPO"

while IFS= read -r line; do
    url="$(sed -E 's/.*url="([^"]+)".*/\1/' <<<"$line")"
    expected="$(sed -E 's/.* length="([0-9]+)".*/\1/' <<<"$line")"
    actual="$(curl -sLI "$url" | grep -i '^content-length' | tail -1 | tr -d '\r' | awk '{print $2}')"
    [ "$actual" = "$expected" ] || die "$url answers with '${actual:-nothing}' bytes, the feed says $expected"
    echo "  ok  $(basename "$url")  $expected bytes"
done <<<"$ENCLOSURES"

# --- Publish -------------------------------------------------------------------

MESSAGE="$(mktemp)"
{
    echo "release: $VERSION (build $BUILD)"
    echo
    cat "$NOTES"
    if [ -n "${COMMIT_TRAILER:-}" ]; then
        echo
        echo "$COMMIT_TRAILER"
    fi
} >"$MESSAGE"
git add project.yml appcast.xml
git commit -q -F "$MESSAGE"
git push -q origin main
echo "=== Feed pushed: clients now see $VERSION"

gh release create "v$VERSION" "dist/Corvin-$VERSION.dmg" --repo "$REPO" \
    --target "$(git rev-parse HEAD)" --title "Corvin $VERSION" --notes-file "$NOTES" --latest
echo "=== Released: https://github.com/$REPO/releases/tag/v$VERSION"
