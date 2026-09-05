# Releasing Corvin (macOS) with Sparkle auto-updates

Corvin ships via **Developer ID + notarization** (not the App Store). Auto-updates
use [Sparkle](https://sparkle-project.org) with EdDSA-signed updates and binary
deltas, hosted on **GitHub Releases**.

## One-time setup

0. **Local signing config.** Account identifiers are kept out of the repo. Copy
   `signing.env.example` to `signing.env` (gitignored) and fill in your Apple Team
   ID, Developer ID signing identity, and (for App Store/TestFlight) the App Store
   Connect key/issuer/app ids. `scripts/build-dmg.sh` and
   `scripts/deploy-testflight.sh` source it automatically; before running
   `xcodegen`/`make project` manually, run `source signing.env` so
   `${DEVELOPMENT_TEAM}` in `project.yml` expands.

1. **Generate EdDSA keys** (private key goes into your login Keychain, never the repo):
   ```bash
   # from the Sparkle tools tarball: https://github.com/sparkle-project/Sparkle/releases
   ./bin/generate_keys
   ```
   Copy the printed **public** key into [`macOS/Resources/Info.plist`](../macOS/Resources/Info.plist)
   under `SUPublicEDKey`, replacing `REPLACE_WITH_PUBLIC_ED_KEY`.

   > Back up the private key: `./bin/generate_keys -x private-key-backup.txt` and
   > store it somewhere safe. Losing it means you can no longer ship updates that
   > existing installs will accept.

2. **Create the fixed download release on GitHub.** Make one release tagged
   `downloads` — every version's `Corvin.dmg` and `*.delta` files are uploaded
   here so the download URL prefix stays constant. The `SUFeedURL` in Info.plist
   points at `appcast.xml` served from the repo via `raw.githubusercontent.com`.

3. **Get the Sparkle tools** (`generate_appcast`, `sign_update`) from the same
   tarball. Either add their `bin/` to `PATH` or pass `SPARKLE_BIN=...` to the
   appcast script.

## Per-release steps

1. **Bump the version** in [`project.yml`](../project.yml) (`MARKETING_VERSION`
   and `CURRENT_PROJECT_VERSION`). The DMG build reads these via `$(...)` in
   Info.plist — confirm the built app's version is correct.

2. **Build, sign, notarize the DMG:**
   ```bash
   ./scripts/build-dmg.sh
   ```
   This builds the universal binary, embeds + signs `Sparkle.framework`, signs
   and notarizes the DMG. Output: `build/Corvin.dmg`.

3. **Smoke-test the notarized DMG** on a clean account: install, hold the fn key,
   record, confirm text insertion, and open the menubar → "Проверить обновления…".

4. **Collect into the dist dir.** Keep a directory with *every* released DMG (old
   versions are needed for delta generation):
   ```bash
   mkdir -p dist
   cp build/Corvin.dmg "dist/Corvin-<version>.dmg"
   ```

5. **Generate the appcast (+ deltas):**
   ```bash
   ./scripts/release-appcast.sh dist
   ```
   This signs each archive with your EdDSA key, writes `appcast.xml` + `*.delta`
   into `dist/`, and copies `appcast.xml` to the repo root.

6. **Publish:**
   - Upload `dist/Corvin-<version>.dmg` and any new `dist/*.delta` files to the
     GitHub release tagged `downloads`.
   - Commit & push the updated `appcast.xml` to `main`.

   Existing installs poll `SUFeedURL` (daily by default), see the new entry,
   download the delta (small) or full DMG, verify the EdDSA signature, and update.

## Notes

- The repo `MrSuhov/corvin` must be **public** for `raw.githubusercontent.com`
  and release download URLs to be reachable without auth.
- Delta updates keep downloads small even though the bundled `ggml-small.bin`
  (~466 MB) makes the full DMG large.
- URLs are hardcoded in [`Info.plist`](../macOS/Resources/Info.plist) (`SUFeedURL`)
  and [`scripts/release-appcast.sh`](../scripts/release-appcast.sh)
  (`DOWNLOAD_PREFIX`). Update both if the repo or hosting changes.

## Model catalogue (independent of app releases)

The list of downloadable models is served from
`https://hyperstack.ru/corvin/models.json`, so it can change without shipping an
app update. Both iOS and macOS read it at launch and fall back to the compiled-in
`WhisperModel.all` when the manifest is unreachable or its `schemaVersion` is
newer than the client understands.

To add, remove or re-point a model:

1. Edit `WhisperModel.all` in [`Shared/Core/ModelManager.swift`](../Shared/Core/ModelManager.swift).
   It stays the source of truth for *which* models exist and how they are
   described — and doubles as the offline fallback, so it may lag behind the
   published manifest but should not contradict it.
2. Publish:
   ```bash
   ./scripts/publish-models-manifest.sh          # generate, upload, verify
   ./scripts/publish-models-manifest.sh --dry-run
   ```

The generator reads sha256 and exact byte sizes from Hugging Face's LFS metadata,
so integrity data is never maintained by hand. Every download is verified against
that hash before it is moved into the models directory; a mismatch deletes the
file and surfaces `ModelError.checksumMismatch`.

Clients compare the manifest's sha256 against a record of what they installed
(`Models/installed-models.json`) and offer an **Update** button when they differ.
Nothing is re-downloaded automatically — these files run to gigabytes. Models
installed before this bookkeeping existed are adopted as current when their
on-disk size matches the manifest exactly, which avoids re-hashing gigabytes on
first launch.

Newly appearing model ids raise a badge on the Models tab (iOS) or a banner in the
model window (macOS), cleared as soon as the list is opened. On a fresh install
the first catalogue is adopted silently, so a new user is not told that all 15
models are "new".

Serving is a static `handle_path /corvin/*` block in the Caddyfile on `reactor`
(`/var/www/corvin`), placed ahead of the catch-all proxy.

## App Store screenshots (iOS)

```bash
./scripts/screenshots-appstore.sh            # both sizes
./scripts/screenshots-appstore.sh iphone     # one size
```

Output lands in `build/screenshots/{iphone,ipad}/` at the exact pixel sizes App
Store Connect requires — 1320x2868 for the 6.9" iPhone set and 2064x2752 for the
13" iPad set, which is mandatory while `TARGETED_DEVICE_FAMILY` stays `1,2`.

Captures run in the **simulator**, not on a device: the background keep-alive
puts a Picture-in-Picture window on top of every frame, so device captures come
out with a stray video overlay. The simulator has no PiP, and no usable Metal
device either — transcription cannot run there, but every screen renders, which
is all a screenshot needs.

The script seeds a realistic state before capturing (the `small` model installed
and active, five history entries from
`scripts/seed-screenshot-history.py`, onboarding marked done, and Corvin enabled
as a keyboard) and reboots the simulator so `cfprefsd` re-reads the seeded
preferences.

Two things to check by eye before uploading:

- `01-keyboard.png` must show Corvin's layout — the blue microphone key and the
  `RU` locale key beside `123`. The switch away from the system keyboard is a
  timed wait, because the extension's keys belong to another process and cannot
  be waited on.
- **Do not upload the iPhone `05-record.png`.** It carries "PiP не
  поддерживается", which is true of the simulator and only of the simulator. The
  iPad copy of that screen is clean.
