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
