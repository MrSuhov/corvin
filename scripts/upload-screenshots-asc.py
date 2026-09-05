#!/usr/bin/env python3
"""Replace the App Store screenshot sets of the current iOS version.

    ./scripts/upload-screenshots-asc.py                 # every locale found
    ./scripts/upload-screenshots-asc.py es-ES           # one locale
    ./scripts/upload-screenshots-asc.py --dry-run

Reads `build/screenshots/<locale>/<iphone|ipad>/NN-name.png`, exactly the layout
`screenshots-appstore.sh` writes, and uploads each directory into the matching
screenshot set, in filename order. A set is emptied first: App Store Connect
appends rather than replaces, so uploading twice would otherwise leave the old
captures behind alongside the new ones.

Needs `source signing.env` for ASC_KEY_ID / ASC_ISSUER_ID and the matching
`~/private_keys/AuthKey_<kid>.p8`.
"""

import hashlib
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request

try:
    import jwt
except ImportError:
    sys.exit("PyJWT missing: pip3 install pyjwt")

BASE = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "com.corvinvoice.ios"
ROOT = pathlib.Path(__file__).resolve().parent.parent
SHOTS = ROOT / "build" / "screenshots"

# Directory name -> the display type App Store Connect files it under. The sizes
# these correspond to are the ones screenshots-appstore.sh captures: 1320x2868
# and 2064x2752.
DISPLAY_TYPES = {
    "iphone": "APP_IPHONE_67",
    "ipad": "APP_IPAD_PRO_3GEN_129",
}


def _key():
    kid = os.environ["ASC_KEY_ID"]
    path = pathlib.Path.home() / "private_keys" / f"AuthKey_{kid}.p8"
    return kid, path.read_text()


def token():
    kid, key = _key()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900,
         "aud": "appstoreconnect-v1"},
        key, algorithm="ES256", headers={"kid": kid, "typ": "JWT"},
    )


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        BASE + path, data=data, method=method,
        headers={"Authorization": "Bearer " + token(),
                 "Content-Type": "application/json"},
    )
    try:
        raw = urllib.request.urlopen(req).read()
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{method} {path} -> {e.code}: {e.read().decode()[:2000]}")
    return json.loads(raw) if raw else {}


def upload(operation, blob):
    """Run one of the `uploadOperations` the reservation came back with.

    These go to a storage host rather than to the API, and carry their own
    headers — including the authorization — so the API token must not be added.
    """
    chunk = blob[operation["offset"]:operation["offset"] + operation["length"]]
    req = urllib.request.Request(operation["url"], data=chunk,
                                 method=operation["method"])
    for header in operation["requestHeaders"]:
        req.add_header(header["name"], header["value"])
    urllib.request.urlopen(req).read()


def version_id():
    apps = call("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}")["data"]
    if not apps:
        sys.exit(f"no app with bundle id {BUNDLE_ID}")
    versions = call(
        "GET",
        f"/v1/apps/{apps[0]['id']}/appStoreVersions"
        "?filter[platform]=IOS&filter[appStoreState]=PREPARE_FOR_SUBMISSION",
    )["data"]
    if not versions:
        sys.exit("no iOS version in PREPARE_FOR_SUBMISSION")
    v = versions[0]
    print(f"version {v['attributes']['versionString']} ({v['id']})")
    return v["id"]


def screenshot_set(localization_id, display_type, dry_run):
    sets = call("GET", f"/v1/appStoreVersionLocalizations/{localization_id}"
                       "/appScreenshotSets")["data"]
    for s in sets:
        if s["attributes"]["screenshotDisplayType"] == display_type:
            return s["id"], False
    if dry_run:
        return None, True
    created = call("POST", "/v1/appScreenshotSets", {
        "data": {
            "type": "appScreenshotSets",
            "attributes": {"screenshotDisplayType": display_type},
            "relationships": {"appStoreVersionLocalization": {
                "data": {"type": "appStoreVersionLocalizations",
                         "id": localization_id}}},
        }
    })["data"]
    return created["id"], True


def put_set(set_id, files, dry_run):
    existing = call("GET", f"/v1/appScreenshotSets/{set_id}/appScreenshots")["data"]
    if existing:
        print(f"    removing {len(existing)} existing")
        if not dry_run:
            for s in existing:
                call("DELETE", f"/v1/appScreenshots/{s['id']}")

    uploaded = []
    for f in files:
        blob = f.read_bytes()
        print(f"    {f.name} ({len(blob) // 1024} KB)")
        if dry_run:
            continue
        reservation = call("POST", "/v1/appScreenshots", {
            "data": {
                "type": "appScreenshots",
                "attributes": {"fileSize": len(blob), "fileName": f.name},
                "relationships": {"appScreenshotSet": {
                    "data": {"type": "appScreenshotSets", "id": set_id}}},
            }
        })["data"]
        for operation in reservation["attributes"]["uploadOperations"]:
            upload(operation, blob)
        call("PATCH", f"/v1/appScreenshots/{reservation['id']}", {
            "data": {
                "type": "appScreenshots",
                "id": reservation["id"],
                "attributes": {"uploaded": True,
                               "sourceFileChecksum": hashlib.md5(blob).hexdigest()},
            }
        })
        uploaded.append(reservation["id"])

    # Upload order is not display order; say it explicitly.
    if uploaded and not dry_run:
        call("PATCH", f"/v1/appScreenshotSets/{set_id}/relationships/appScreenshots",
             {"data": [{"type": "appScreenshots", "id": i} for i in uploaded]})


def main():
    args = [a for a in sys.argv[1:] if a != "--dry-run"]
    dry_run = "--dry-run" in sys.argv[1:]
    wanted = set(args) or None

    if not SHOTS.is_dir():
        sys.exit(f"{SHOTS} missing — run scripts/screenshots-appstore.sh first")

    vid = version_id()
    localizations = {
        l["attributes"]["locale"]: l["id"]
        for l in call("GET", f"/v1/appStoreVersions/{vid}"
                             "/appStoreVersionLocalizations")["data"]
    }

    unknown = (wanted or set()) - set(localizations)
    if unknown:
        sys.exit("no such localization: " + ", ".join(sorted(unknown))
                 + ". Have: " + ", ".join(sorted(localizations)))

    for locale_dir in sorted(SHOTS.iterdir()):
        locale = locale_dir.name
        if not locale_dir.is_dir() or locale not in localizations:
            continue
        if wanted and locale not in wanted:
            continue
        print(f"  {locale}")
        for device, display_type in DISPLAY_TYPES.items():
            files = sorted((locale_dir / device).glob("*.png")) \
                if (locale_dir / device).is_dir() else []
            if not files:
                print(f"    {device}: nothing captured, left untouched")
                continue
            set_id, created = screenshot_set(
                localizations[locale], display_type, dry_run)
            print(f"    {device} -> {display_type}"
                  + (" (would create)" if created and dry_run
                     else " (created)" if created else ""))
            if set_id is None:
                for f in files:
                    print(f"    {f.name}")
                continue
            put_set(set_id, files, dry_run)


if __name__ == "__main__":
    main()
