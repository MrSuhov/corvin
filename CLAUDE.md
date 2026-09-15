# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build

### macOS (DMG)

```bash
./scripts/build-dmg.sh
```

Builds whisper.cpp universal libs, compiles via SPM, bundles the `ggml-small.bin` model from `~/Library/Application Support/Corvin/Models/`, creates .app bundle with ad-hoc signing, and packages into DMG. The model must be downloaded via the app before building.

### iOS

```bash
make vendor-ios    # Build whisper.cpp for iOS arm64
make project       # Generate Xcode project via XcodeGen
# Open Corvin.xcodeproj, select CorviniOS scheme, build & run on device
```

### Build scripts

- `scripts/build-whisper-macos.sh` — whisper.cpp universal (arm64 + x86_64) for macOS
- `scripts/build-whisper-ios.sh` — whisper.cpp arm64 for iOS
- `scripts/build-dmg.sh` — full macOS DMG build pipeline (includes bundled small model and the
  `corvin-diarize` helper in `Contents/Helpers`)
- `scripts/publish-models-manifest.sh` — regenerate and publish `models.json` (whisper models plus
  the `diarization` section, pinned to `DIARIZATION_REVISION` in `generate-models-manifest.py`)

## Architecture

Corvin is a multiplatform speech-to-text app using whisper.cpp.

### macOS
Menubar app. User holds fn key to record, releases to transcribe, text auto-inserted at cursor.

### iOS
Keyboard Extension (KeyboardKit) + host app. Push-To-Talk via mic button tap or long press any key (≥0.5s). Host app runs whisper.cpp transcription, keyboard extension communicates via localhost socket IPC.

### State Machine Flow

`idle → recording → transcribing → inserting → done → idle`

SessionState enum drives the UI. On macOS the transitions of the hotkey flow
live in `DictationCoordinator`, not in AppDelegate.

### Dictation pipeline (macOS)

```
AudioCaptureService.onSamples ─► SpeechRecognizer ─► TranscriptEvent ─► TranscriptPipeline ─► sinks
```

- `SpeechRecognizer` (`Shared/Core/Dictation/`) — one per session. `WhisperBatchRecognizer`
  (whole recording on release), `WhisperStreamingRecognizer` (re-transcribes a sliding
  window ~1/s, commits words two runs agree on — `HypothesisBuffer`, LocalAgreement-2).
- Events: `.volatile` (never inserted), `.committed` (stable, typed live in realtime mode),
  `.finished` (whole utterance after processors, emitted by the coordinator).
- Sinks: `TextInsertionSink` (paste on release, or `IncrementalTextInserter` typing committed
  chunks via Unicode key events — no clipboard), `ClipboardSink`, `HistorySink`. A future
  assistant is another sink reacting to `.finished`.
- `TranscriptProcessor` transforms the finished utterance. One with `modifiesText` disables
  realtime insertion — typed text cannot be taken back.
- Setting: `DictationSettings.realtimeKey` (`realtimeDictation`), toggle in General settings.

### File transcription (macOS)

```
FileTranscriptionQueue ─► AudioFileDecoder ─► [roles] DiarizationClient ─► corvin-diarize (process)
                                           └─► TranscriptionEngine.transcribeTimed (prompt, word timestamps)
                        ─► SpeakerTranscriptBuilder + RolesFormatter ─► TranscriptSaver ─► TranscriptRegistry
```

- Transcription settings pane: plain jobs write `<name>.txt`; "Dialog recognition" (macOS 14+)
  writes `<name>_roles.txt` as `[HH:MM:SS] Speaker N:` paragraphs. Mode and dictionary are fixed per
  job when queued; `stopAndRestart` cancels one job and re-queues it with current settings.
- Diarization is FluidAudio (CoreML) in `Helpers/Diarizer`, a separate macOS 14 package run as a
  process: Corvin targets 11 and cannot import it, and FluidAudio's macOS 14 BNNS crash stays in the
  helper. It loads models only from disk (`ModelHub.offlineMode`, no download path).
  Dev runs without a bundle: `CORVIN_DIARIZE_PATH=Helpers/Diarizer/.build/release/corvin-diarize`.
- `DiarizationModelStore` installs the 21-file model set (sha256 each, atomic swap, fingerprint for
  updates) from the manifest's `diarization` section, falling back to a compiled-in entry.
  `DiarizationClient.helperAPI` must match the entry's `helperAPI`.
- `SpeakerTranscriptBuilder` (pure, tuned on real meetings): max-overlap attribution, turn
  boundaries snapped to sentence ends (±1 s), short runs absorbed, runs split at whisper's
  leading-dash turn markers. Token timestamps are enough; DTW gave nothing and needs flash
  attention off.
- `TranscriptRegistry` (`transcripts.json`) lists transcribed files; a source whose size or mtime
  differs from transcription time is flagged. `VocabularyStore` (`vocabularies.json`) holds named
  term lists; `TranscriptionEngine.fitPrompt` keeps the leading terms that fit 200 tokens, passed
  as `initial_prompt` with `carry_initial_prompt` (chunks are decoded independently).

### Directory Structure

```
Shared/Core/         — SessionState, SessionManager, TranscriptionEngine, ModelManager, HistoryStore
Shared/Networking/   — IPC protocol (LocalIPCProtocol), TranscriptionModels
Shared/UI/           — ProPaywallView (cross-platform)
Shared/Resources/    — Localizable.strings/.stringsdict, InfoPlist.strings, AppShortcuts.strings (en, ru, es)
macOS/App/           — AppDelegate, CorvinApp (@main macOS)
macOS/Services/      — HotkeyService, AudioCaptureService, AccessibilityService
macOS/UI/            — StatusBarController, FloatingIndicator, Settings, History, Onboarding, ModelManager views
iOS/App/             — CorviniOSApp (@main iOS), iOSAppState
iOS/Services/        — IPCServer (NWListener), TranscriptionService, AudioCaptureService
iOS/UI/              — MainView, Settings, History, Onboarding, ModelManager views
iOS/Intents/         — StartRecordingIntent (App Intents for Shortcuts/Siri)
CorvinKeyboard/     — KeyboardViewController (KeyboardKit), PTTController, AudioRecorder, IPCClient, CustomActionHandler
Helpers/Diarizer/    — corvin-diarize: FluidAudio speaker diarization helper (separate package, macOS 14)
Sources/CWhisper/    — C bridge to whisper.cpp
vendor/whisper.cpp/  — Vendored whisper.cpp
```

### iOS IPC

- **Protocol**: TCP over localhost:12345 via Network.framework
- **Message format**: 4-byte UInt32 big-endian length prefix + JSON body (IPCPacket)
- **Flow**: Keyboard extension records audio → sends via socket → iOS app transcribes → returns text → extension inserts via textDocumentProxy

### Data Storage

- macOS models: `~/Library/Application Support/Corvin/Models/` (bundled models auto-copied from app Resources on first launch)
- iOS models: App Group shared container (`group.com.corvin.shared`)
- macOS diarization models: `~/Library/Application Support/Corvin/Models/diarization/` (`installed.json` marker)
- macOS file transcription: `Corvin/transcripts.json` (transcribed files), `Corvin/vocabularies.json` (term dictionaries)
- History: Core Data SQLite (programmatic model)
- Settings: UserDefaults (iOS uses App Group suite)

### C Bridge

whisper.cpp vendored at `vendor/whisper.cpp`. CWhisper SPM target in `Sources/CWhisper/` provides Swift-accessible C bindings. Static libraries linked from vendor build output.

### Project Configuration

- `Package.swift` — SPM manifest for macOS command-line build (defaultLocalization: "en")
- `project.yml` — XcodeGen config generating Corvin.xcodeproj with 7 targets (CWhisper_macOS, CWhisper_iOS, CorvinShared_macOS, CorvinShared_iOS, Corvin, CorviniOS, CorvinKeyboard)

## Localization

Three languages: English, Russian, Spanish. Catalogues live in
`Shared/Resources/<lang>.lproj/` for both apps, and in
`CorvinKeyboard/Resources/<lang>.lproj/` for the keyboard extension — an app
extension is a separate bundle, so inside it `Bundle.main` is the appex and it
cannot read the host app's strings.

The idiom is `"some.key".localized`, never `Text("literal")`. SwiftUI's
automatic lookup goes to `Bundle.main` and takes no bundle argument, which is
incompatible with the in-app language picker: `LocalizedBundle` swaps the bundle
at runtime and `String.localized` resolves against it. Use `.localized(with:)`
for anything with a format argument — it passes the chosen locale, without which
`.stringsdict` plurals do not expand and `%f` uses a POSIX decimal point.

One `.id(localization.currentLanguage)` at the iOS root in
`iOS/App/SpeachyiOSApp.swift` is the entire refresh mechanism; individual views
need no awareness of localization. macOS applies the same idea per window.

Text kept in view-model state (`errorMessage` and similar) uses
`LocalizedMessage`, which stores a key and resolves at render time — a resolved
string would freeze in the language it was created in.

App Intents, Siri phrases and the system permission dialogs follow the **system**
language and cannot see the swapped bundle. That is correct for system surfaces.

```bash
make lint-l10n     # fails on drift; also runs in CI on every push
make l10n-report   # per-language coverage
```

The linter checks key parity, per-key format-specifier parity, plural
completeness, and that no new user-facing literal is hardcoded. Adding a
language is a new `.lproj` plus one case in `AppLanguage`.

## Git

Remote `origin` → https://github.com/MrSuhov/corvin (auth via `gh` over HTTPS).

```bash
git push origin main
```

## Key Constraints

- macOS deployment target: 11.0 (Big Sur)
- iOS deployment target: 16.0
- macOS: Universal binary arm64 (Metal GPU) + x86_64 (Accelerate BLAS)
- iOS: arm64 only (Metal GPU)
- Requires microphone permission on both platforms
- macOS requires accessibility permission for text insertion
- iOS keyboard extension requires Full Access for microphone and network
- External dependency: KeyboardKit (iOS keyboard extension only)
- No test suite currently exists
- Local only: recognition, diarization, dictionaries and transcripts never leave the device; the
  network is used only to download model files
