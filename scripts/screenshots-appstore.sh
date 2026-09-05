#!/bin/bash
# Capture App Store screenshots for iPhone (6.9") and iPad (13") in the simulator.
#
#   ./scripts/screenshots-appstore.sh
#   ./scripts/screenshots-appstore.sh iphone     # one size only
#
# Output: build/screenshots/<iphone|ipad>/0N-<screen>.png at the exact pixel
# sizes App Store Connect requires (1320x2868 and 2064x2752).
#
# Why the simulator and not the device: the background keep-alive puts a
# Picture-in-Picture window on top of every frame, so device captures carry a
# stray video overlay. Turning the background mode off for a photo shoot is
# fiddly and easy to forget. The simulator has no PiP at all.
#
# The simulator's Metal device cannot host the model (see TranscriptionEngine),
# so transcription itself does not run here — but every screen renders, which is
# all screenshots need.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

BUNDLE_ID="com.corvinvoice.ios"
APP_GROUP="group.com.corvinvoice.app"
RUNTIME=$(xcrun simctl list runtimes --json | python3 -c "
import json,sys
rs=[r for r in json.load(sys.stdin)['runtimes'] if r['isAvailable'] and 'iOS' in r['name']]
if not rs: sys.exit('no iOS simulator runtime installed')
print(sorted(rs, key=lambda r: r['version'])[-1]['identifier'])
")
DERIVED="${SCREENSHOT_DERIVED_DATA:-$PROJECT_ROOT/build/screenshots/DerivedData}"
OUT_ROOT="$PROJECT_ROOT/build/screenshots"
MODEL_SRC="$HOME/Library/Application Support/Corvin/Models/ggml-small.bin"

# App Store Connect requires a 6.9" iPhone set, and a 13" iPad set for any app
# that ships TARGETED_DEVICE_FAMILY 1,2.
declare -a SPECS=(
  "iphone|Corvin-Shots-iPhone|com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"
  "ipad|Corvin-Shots-iPad|com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"
)

WANT="${1:-all}"

# App Store listing locales. The bundle only ever has one es.lproj; es-ES is the
# storefront the Spanish listing uses.
LANGS="ru en es"

# Plain functions rather than associative arrays: macOS ships bash 3.2, where
# `declare -A` does not exist and `[ru]=` is parsed as an arithmetic index.
asc_locale() { case "$1" in ru) echo "ru";; en) echo "en-US";; es) echo "es-ES";; esac; }
sys_locale() { case "$1" in ru) echo "ru_RU";; en) echo "en_US";; es) echo "es_ES";; esac; }
# The first system keyboard has to match the language, so the single globe tap in
# the keyboard test still lands on Corvin.
sys_keyboard() {
    case "$1" in
        ru) echo "ru_RU@sw=Russian;hw=Automatic";;
        en) echo "en_US@sw=QWERTY;hw=Automatic";;
        es) echo "es_ES@sw=QWERTY-Spanish;hw=Automatic";;
    esac
}
# Corvin's own enabled input locales, capture language first.
kb_languages() { case "$1" in ru) echo "ru,en";; en) echo "en,ru";; es) echo "es,en";; esac; }

# Booting a simulator, a cold build and two test runs each take minutes. Without
# timestamps the script looks hung.
step() { echo "  [$(date +%H:%M:%S)] $*"; }

source "$PROJECT_ROOT/signing.env"
xcodegen generate > /dev/null

for spec in "${SPECS[@]}"; do
    IFS='|' read -r label simname devtype <<< "$spec"
    [ "$WANT" != "all" ] && [ "$WANT" != "$label" ] && continue

    echo "=== $label ==="

    UDID=$(xcrun simctl list devices --json | python3 -c "
import json,sys
for devs in json.load(sys.stdin)['devices'].values():
    for d in devs:
        if d['name']=='$simname': print(d['udid']); break
" | head -1)
    if [ -z "$UDID" ]; then
        echo "  creating simulator $simname"
        UDID=$(xcrun simctl create "$simname" "$devtype" "$RUNTIME")
    fi
    echo "  simulator $UDID"

    step "booting simulator"
    xcrun simctl boot "$UDID" 2>/dev/null || true
    xcrun simctl bootstatus "$UDID" -b > /dev/null

    step "building (first run compiles whisper + KeyboardKit; later runs are incremental)"
    xcodebuild build -project Corvin.xcodeproj -scheme CorviniOS -configuration Debug \
        -destination "id=$UDID" -derivedDataPath "$DERIVED" > /dev/null

    APP="$DERIVED/Build/Products/Debug-iphonesimulator/CorviniOS.app"
    step "installing"
    xcrun simctl install "$UDID" "$APP"

    # The app group container is only created once the app has run, and the
    # seeding below writes into it.
    xcrun simctl launch "$UDID" "$BUNDLE_ID" > /dev/null
    sleep 8
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true

    GRP=$(python3 - "$UDID" "$APP_GROUP" <<'PY'
import plistlib, sys, pathlib
root = pathlib.Path.home()/"Library/Developer/CoreSimulator/Devices"/sys.argv[1]/"data/Containers/Shared/AppGroup"
for d in root.iterdir():
    meta = d/".com.apple.mobile_container_manager.metadata.plist"
    if meta.exists():
        with open(meta,'rb') as f:
            if plistlib.load(f).get("MCMMetadataIdentifier") == sys.argv[2]:
                print(d); break
PY
)
    [ -z "$GRP" ] && { echo "  ERROR: app group container not found"; exit 1; }

    # The keyboard extension is a separate bundle with preferences of its own,
    # and KeyboardKit remembers there which layout was last used. Nothing in the
    # app group overrides that, so without seeding it the English and Spanish
    # captures come out showing a Cyrillic keyboard.
    KBPREFS=$(python3 - "$UDID" "$BUNDLE_ID.keyboard" <<'KBPY'
import plistlib, sys, pathlib
root = pathlib.Path.home()/"Library/Developer/CoreSimulator/Devices"/sys.argv[1]/"data/Containers/Data/PluginKitPlugin"
for d in sorted(root.iterdir()) if root.exists() else []:
    meta = d/".com.apple.mobile_container_manager.metadata.plist"
    if meta.exists():
        with open(meta, "rb") as f:
            if plistlib.load(f).get("MCMMetadataIdentifier") == sys.argv[2]:
                print(d/"Library/Preferences"/(sys.argv[2] + ".plist")); break
KBPY
)
    [ -z "$KBPREFS" ] && echo "  warning: keyboard extension container not found — its layout will be whatever it last used"

  # UILANG, not LANG: that name is already an exported environment variable,
  # and reassigning it here would hand every child process an invalid locale.
  for UILANG in $LANGS; do
    step "=== language: $UILANG ==="
    step "seeding state"
    if [ -f "$MODEL_SRC" ]; then
        mkdir -p "$GRP/Models"
        [ -f "$GRP/Models/ggml-small.bin" ] || cp "$MODEL_SRC" "$GRP/Models/"
    else
        echo "  warning: $MODEL_SRC missing — the model row will show as not installed"
    fi

    PREFS="$GRP/Library/Preferences/$APP_GROUP.plist"
    /usr/libexec/PlistBuddy -c "Add :onboardingCompleted bool true" "$PREFS" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :onboardingCompleted true" "$PREFS"
    /usr/libexec/PlistBuddy -c "Add :activeModelId string small" "$PREFS" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :activeModelId small" "$PREFS"

    python3 "$PROJECT_ROOT/scripts/seed-screenshot-history.py" "$GRP/Corvin.sqlite" "$UILANG"

    # Enable Corvin as a keyboard so the keyboard itself can be photographed.
    # iOS keeps at least one system keyboard, so Corvin goes second and the
    # capture reaches it with a single tap of the globe key.
    GLOBALS="$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Library/Preferences/.GlobalPreferences.plist"
    /usr/libexec/PlistBuddy -c "Delete :AppleKeyboards" "$GLOBALS" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :AppleKeyboards array" "$GLOBALS"
    /usr/libexec/PlistBuddy -c "Add :AppleKeyboards:0 string 'ru_RU@sw=Russian;hw=Automatic'" "$GLOBALS"
    /usr/libexec/PlistBuddy -c "Add :AppleKeyboards:1 string 'com.corvinvoice.ios.keyboard'" "$GLOBALS"
    /usr/libexec/PlistBuddy -c "Add :AppleKeyboardsExpanded integer 1" "$GLOBALS" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :AppleKeyboardsExpanded 1" "$GLOBALS"
    /usr/libexec/PlistBuddy -c "Set :AppleKeyboards:0 $(sys_keyboard "$UILANG")" "$GLOBALS"

    # Corvin's own layout: the set offered behind the language key, and the one
    # currently showing.
    /usr/libexec/PlistBuddy -c "Add :keyboardLanguages string $(kb_languages "$UILANG")" "$PREFS" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :keyboardLanguages $(kb_languages "$UILANG")" "$PREFS"
    if [ -n "$KBPREFS" ]; then
        mkdir -p "$(dirname "$KBPREFS")"
        KBKEY="com.keyboardkit.settings.keyboard.localeIdentifier"
        /usr/libexec/PlistBuddy -c "Add :$KBKEY string $(sys_locale "$UILANG")" "$KBPREFS" 2>/dev/null \
            || /usr/libexec/PlistBuddy -c "Set :$KBKEY $(sys_locale "$UILANG")" "$KBPREFS"
    fi

    # The app's own language, read by LocalizationManager.
    /usr/libexec/PlistBuddy -c "Add :appLanguage string $UILANG" "$PREFS" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :appLanguage $UILANG" "$PREFS"
    # And the simulator's, because the status bar, the system keyboard behind the
    # globe tap and every DateFormatter date in the history list follow it.
    /usr/libexec/PlistBuddy -c "Set :AppleLanguages:0 $UILANG" "$GLOBALS" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :AppleLanguages array" "$GLOBALS"
    /usr/libexec/PlistBuddy -c "Set :AppleLanguages:0 $UILANG" "$GLOBALS" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :AppleLocale $(sys_locale "$UILANG")" "$GLOBALS" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :AppleLocale string $(sys_locale "$UILANG")" "$GLOBALS"

    # cfprefsd caches preference domains for the lifetime of the boot, so the
    # edits above are only picked up after a restart.
    step "rebooting simulator so the seeded prefs are read"
    xcrun simctl shutdown "$UDID"
    xcrun simctl boot "$UDID"
    xcrun simctl bootstatus "$UDID" -b > /dev/null

    step "capturing (runs the UI test)"
    RESULT="$OUT_ROOT/$label.xcresult"
    rm -rf "$RESULT"
    xcodebuild test -project Corvin.xcodeproj -scheme CorviniOS -configuration Debug \
        -destination "id=$UDID" -derivedDataPath "$DERIVED" \
        -only-testing:CorvinUITests/AppStoreScreenshotTests \
        -resultBundlePath "$RESULT" > /dev/null

    DEST="$OUT_ROOT/$(asc_locale "$UILANG")/$label"
    rm -rf "$DEST"; mkdir -p "$DEST"
    xcrun xcresulttool export attachments --path "$RESULT" --output-path "$DEST" > /dev/null
    python3 - "$DEST" <<'PY'
import json, pathlib, re, sys
d = pathlib.Path(sys.argv[1])
manifest = d/"manifest.json"
for test in json.load(open(manifest)):
    for a in test.get("attachments", []):
        # exported names carry an index and a uuid: "01-record_0_<uuid>.png"
        clean = re.sub(r"_\d+_[0-9A-F-]{36}", "", a["suggestedHumanReadableName"])
        (d/a["exportedFileName"]).rename(d/clean)
manifest.unlink()
PY
    rm -rf "$RESULT"
    echo "  -> $DEST"
    ls "$DEST"
  done
    sips -g pixelWidth -g pixelHeight "$DEST"/02-models.png | tail -2
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
done

echo "=== Done ==="
