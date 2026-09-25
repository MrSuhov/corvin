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
- `scripts/build-transcribe-macos.sh` — transcribe.cpp (GigaAM) as one universal
  `libtranscribe.dylib`, pinned to `TRANSCRIBE_REF`; fails if anything but `_transcribe_*` is exported
- `scripts/build-transcribe-ios.sh` — the same as `TranscribeCpp.xcframework` (device + simulator)
- `scripts/build-dmg.sh` — full macOS DMG build pipeline (includes bundled small model and the
  `corvin-diarize` helper in `Contents/Helpers`)
- `scripts/publish-models-manifest.sh` — regenerate and publish `models.json` (whisper models plus
  the `diarization` section, one entry per `DIARIZATION_ENTRIES` item in `generate-models-manifest.py`,
  each pinned to a revision)
- `scripts/generate-status-bar-icons.swift` — the menubar raven, beak closed (idle), open
  (recording), and closed with the eye twice as wide (transcribing), 24×18 pt template PNGs into
  `macOS/Resources`; its outline is measured off a canonical raven profile, and the neck ends in
  feathers inside the frame — cut by the frame it read as a square. The update badge is a green view over the button, not part of the icon — a template
  image is one colour, and a coloured icon would lose the state tints and light/dark adaptation

### Releasing (macOS)

```bash
scripts/publish-release.sh 1.5.1 notes.md   # from a clean main in sync with origin
```

Bumps `MARKETING_VERSION`, builds and checks the notarized DMG, runs `release-appcast.sh`, uploads
the DMG and deltas, checks that every URL in the new feed item answers with the size the feed
states, and only then commits and pushes `appcast.xml` — Sparkle reads it from `main`
(`SUFeedURL`), so an earlier push would send clients to files not uploaded yet. Last, it creates
the `v<version>` release with the notes and the DMG, marked Latest. The notes also become the
release commit's body; `COMMIT_TRAILER` is appended to the commit only.

`UpdaterService` drives Sparkle itself (no Sparkle UI: an accessory app's windows open behind
everything). A scheduled probe — 15 s after launch, every 24 h, on wake — is silent and shows only
the green badge on the menubar icon when a version is found. A check the **user** asked for always
answers, in an alert: up to date, the version found (with Update / Later), or why the check failed;
while it runs the menu item reads "Checking for updates…". Without that answer the menu item is
indistinguishable from a dead button.

Two kinds of GitHub release: `downloads` is Sparkle's bucket (`generate_appcast` takes one URL
prefix, so every DMG and delta sits under that tag, listed by name — GitHub has no other order for
a release's files), and one `v<version>` release per version for people, listed newest first.
`dist/` must keep every released DMG: deltas are computed against them.

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

- Files tab: plain jobs write `<name>.txt`; "By speaker" (macOS 14+) writes `<name>_roles.txt` as
  `[HH:MM:SS] Speaker N:` paragraphs. Mode, model and dictionary are fixed per job when queued;
  `cancel` stops one job (a pending one never starts), and a different mode is a new run.
- Diarization is NVIDIA Nemotron 3 Diarization (8-speaker streaming Sortformer, `offline` preset,
  30 s context) through FluidAudio's CoreML port (`Nemotron3Diarizer`) in `Helpers/Diarizer`, a
  separate macOS 14 package run as a process: Corvin targets 11 and cannot import it, and FluidAudio's
  macOS 14 BNNS crash stays in the helper. It loads models only from disk (`Nemotron3Models.load`,
  `ModelHub.offlineMode`, no download path). The first run after an install compiles the model for
  the Neural Engine (~45 s once); after that two minutes of audio take under a second.
  Dev runs without a bundle: `CORVIN_DIARIZE_PATH=Helpers/Diarizer/.build/release/corvin-diarize`.
- `DiarizationModelStore` installs the model set (sha256 each, atomic swap, fingerprint for
  updates) from the manifest's `diarization` section, falling back to a compiled-in entry.
  `DiarizationClient.helperAPI` must match the entry's `helperAPI`: 1 was pyannote (still published
  for 1.5.0–1.5.2), 2 is Nemotron (1.5.3+). The `installed.json` marker records the set's
  `helperAPI` and top-level names; a set of another layout reads as not installed, so the pane
  offers the download.
- `SpeakerTranscriptBuilder` (pure, tuned on real meetings): max-overlap attribution, turn
  boundaries snapped to sentence ends (±1 s), short runs absorbed, runs split at whisper's
  leading-dash turn markers. Token timestamps are enough; DTW gave nothing and needs flash
  attention off.
- `TranscriptRegistry` (`transcripts.json`) lists transcribed files; a source whose size or mtime
  differs from transcription time is flagged. `VocabularyStore` (`vocabularies.json`) holds named
  term lists; `TranscriptionEngine.fitPrompt` keeps the leading terms that fit 200 tokens, passed
  as `initial_prompt` with `carry_initial_prompt` (chunks are decoded independently).

### Call recording (macOS 13+)

```
MicSource (AVAudioEngine + voice processing) ─┐  16 kHz mono + host time
ProcessTapSource (14.2+, Core Audio tap)      ─┼─► CallTimelineWriter ─► PCM CAF parts (L = me, R = app)
  or ScreenCaptureSource (13–14.1)            ─┘        Stop ─► merge ─► AAC .m4a ─► FileTranscriptionQueue (.call)
.call job: decodeChannels ─► SpeechSegmenter.spans ─► CompactedAudio (speech only + time map)
           ─► transcribeTimed(L′), transcribeTimed(R′) ─► place words back ─► [diarize R]
           ─► EchoFilter ─► CallTranscriptBuilder.turns ─► header + [HH:MM:SS] Me: / Other:
```

- Menubar "Record Call ▸ <app>" (`AudioAppCatalog`: helpers by bundle-ID prefix, WebKit GPU process by
  name) and a floating pill (`CallIndicatorView`). `CallRecorder` is separate from `SessionState` on
  purpose: a non-idle session parks the file queue and blocks dictation for the whole call.
- Two independent streams aligned by host time (`TimelineCursor`, 20 ms tolerance, silence for gaps):
  voice processing cannot live inside an aggregate device with the tap, and ScreenCaptureKit is a
  separate stream anyway.
- Recorded in parts (`<base>.partN.caf`, length from `CallSettings.chunkMinutes`, default 5): each
  finished part is a closed file, so an interruption costs at most the part in flight. Stop merges
  the parts into one AAC file (`CallRecorder.merge`); parts left in
  `Application Support/Corvin/Recordings` at launch are grouped by name, merged and queued.
  PCM rather than AAC while recording because only PCM CAF survives a crash.
- Roles come from channels ("Me" / "Other"); diarization only splits the other side in group calls.
  `EchoFilter` drops mic phrases also heard on the app channel (speakers without headphones).
- **The shape and the times of a transcript come from the audio, not from whisper.**
  `SpeechSegmenter` (20 ms frames, RMS, threshold clamped both ways) finds each channel's speech; the
  recording pads a quiet channel with silence instead of closing the gap, so a sample position *is*
  call time. Two stretches of one side are one reply when less than `joinPause` (3 s) apart and the
  other side said nothing in between — a flat pause threshold would shred a monologue instead, which
  is how "one block stamped [00:00:00]" happened in the first place. A reply past 40 s is cut at a
  silence between its spans.
- `CompactedAudio` hands whisper the speech alone and maps word times back. Whisper invents text on
  silence and its token times drift by up to ~2 s, so words are only used to decide *which* reply
  they belong to, with the boundary nudged to the widest gap between words near it. The 0.4 s
  separators also fix where `splitAtSilence` cuts its 25 s chunks — always in a separator, so no word
  is split and drift cannot accumulate past one chunk.
- `TranscriptionOptions.suppressNonSpeech` (calls only) turns on `suppress_nst`, drops segments whose
  `no_speech_prob` is over 0.9 and those that merely describe a sound ("[Аплодисменты]", a ring tone
  as "ДИНАМИЧНАЯ МУЗЫКА") — each would otherwise become a turn with a timestamp. Without
  `suppress_nst` whisper files a poor far end away as "*звонок*" and the speech in it is lost.
- `TranscriptionOptions.beamSearch` (calls only): beam 5 instead of greedy. On a poor far end greedy
  decoding locked onto one invented sentence and repeated it for a whole chunk; beam search on the
  same audio recovered the words, for 20–50% more time. Dictation stays greedy.
- The merge is written under `.<name>.partial.m4a` and renamed: `AVAudioFile` picks the container by
  extension and silently writes CAF for one it does not know, which QuickTime refuses as `.m4a` —
  reading it back sniffs content and succeeds, so only a container check catches it.
- Diarization runs on the **original** right channel, not the compacted one: mapping segments back
  would stretch one across the real silence, and the diarizer's 10 s window holds three voices at
  most, which compaction would overfill exactly in a group call.
- The header (`call.transcript.*`) names the app, the start and the length, from `CallIndex` through
  `FileTranscriptionQueue.callInfo`; a call recorded before the index has no header.
- `SpeechSegmenterFieldCheck` (skipped unless `CORVIN_CALL_FILE` is set) prints a real recording's
  spans and replies — thresholds can be calibrated without waiting for whisper.
- Tap permission ("System Audio Recording", `NSAudioCaptureUsageDescription`) has no preflight: a
  denied tap delivers silence, surfaced as a warning. Spike app: `CallSpike` (scratch, not in repo).

### Settings window and Files (macOS)

- Sidebar: **Files, Models, Settings** (`SettingsTab`). Everything that used to be a
  tab of its own — general, language, indicator, layout, cleanup, permissions — is a section of
  `ConsolidatedSettingsView`, reusing the same pane structs (their root `Form` is a `VStack` now).
  The window is resizable (900×600, min 720×460, frame autosaved); the sidebar keeps a fixed width
  and the detail pane stays `.clipped()`, and every picker is capped at 360 pt — a wide picker used
  to shove the sidebar sideways.
- **Files tab** (`FilesView`) is the only place files are handled: calls, transcribed files and
  files still in the queue (`HistoryEntry.merge` over `TranscriptRegistry` + `CallIndex` + the
  queue's jobs — a just-added file has no registry row until its transcript is written). A job's
  status and progress show in its row; there is no separate queue list. Audio dropped on **any**
  tab, "Add Files…", the menubar "Transcribe File…" and Finder's "Open with" all queue at once and
  select the file in Files (`SettingsTabSelection.show(added:)`).
- The card's **Transcription** block — plain / by speaker, model, Transcribe / Stop — is the only
  place the choice is made. A run remembers it (`dialogMode`, `defaultModelID`) for files added
  next; there is no global toggle. A call has no mode choice (its channels give the roles). The card
  also shows "Save as…" (a copy) and "Show in Finder" for the audio and each transcript. Output
  folder and dictionary sit in the bar above the list. Testing a model by voice (`ModelTestView`) is
  in Models, and so is the speaker-diarization model (`DiarizationModelSection`, macOS 14+) — people
  look for models there, not in the Files card that uses it; the call part length is a section of Settings. Dictation texts keep their own menubar
  window ("Dictation history…").
- **Per-job model**: `TranscriptionOptions.modelID` (nil = active model) is loaded for that run only,
  so re-transcribing never moves the model fn dictation uses. A model chosen but not downloaded is
  offered for download first, and only an explicit yes starts it. Because two runs can now want
  different models, the chunk loop **re-acquires the context** on a generation change instead of
  returning a partial transcript as success.
- **`CallIndex`** (`calls.json`) remembers which app each call came from: the file name is localized
  and unparseable, and a registry row only appears once a transcript exists. A `<base>.call.json`
  side-car is written next to the parts, so the app survives `kill -9`.
- **Cleanup** (`CleanupService`, `CleanupPlan`): three independent periods — call audio, transcript
  files, dictation history — all `never` by default, first run 8 s after launch then every 6 h, at
  most once per 12 h. Only files Corvin created are candidates (calls it recorded, transcripts it
  wrote); the user's own audio and anything else in the output folder is never touched, and every
  deletion is logged. `autoCleanupPeriod` keeps its name because iOS reads it through the app group.

### Directory Structure

```
Shared/Core/         — SessionState, SessionManager, TranscriptionEngine, ModelManager, HistoryStore
Shared/Networking/   — IPC protocol (LocalIPCProtocol), TranscriptionModels
Shared/UI/           — ProPaywallView (cross-platform)
Shared/Resources/    — Localizable.strings/.stringsdict, InfoPlist.strings, AppShortcuts.strings (en, ru, es)
macOS/App/           — AppDelegate, CorvinApp (@main macOS: plain AppKit, no SwiftUI `App` — its required
                       Settings scene opened a blank window on ⌘,), MainMenu (⌘, → the real settings)
macOS/Services/      — HotkeyService, AudioCaptureService, AccessibilityService
macOS/UI/            — StatusBarController, FloatingIndicator, Settings, History, Onboarding, ModelManager views
iOS/App/             — CorviniOSApp (@main iOS), iOSAppState
iOS/Services/        — IPCServer (NWListener), TranscriptionService, AudioCaptureService
iOS/UI/              — MainView, Settings, History, Onboarding, ModelManager views
iOS/Intents/         — StartRecordingIntent (App Intents for Shortcuts/Siri)
CorvinKeyboard/     — KeyboardViewController (KeyboardKit), PTTController, AudioRecorder, IPCClient, CustomActionHandler
Helpers/Diarizer/    — corvin-diarize: FluidAudio speaker diarization helper (separate package, macOS 14)
Sources/CWhisper/    — C bridge to whisper.cpp
Sources/CTranscribe/ — C bridge to transcribe.cpp (GigaAM)
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

transcribe.cpp (GigaAM) at `vendor/transcribe.cpp`, bridged by `Sources/CTranscribe/`. It carries a
ggml of its own, so it is **never** linked statically next to whisper.cpp's: two static ggml copies
collide on every `ggml_*` symbol. It ships as a dylib (macOS, `Contents/Frameworks`, dev runs find it
through an rpath into `vendor/` that `build-dmg.sh` deletes) or a framework (iOS host app only) with
ggml inside and only `_transcribe_*` exported. `TranscribeCppFieldCheck` runs whisper and GigaAM in
one process (skipped unless `CORVIN_GIGAAM_MODEL`, `CORVIN_WHISPER_MODEL`, `CORVIN_CLIP` are set).

### Model families

`WhisperModel.family` picks the runtime: `.whisper` (ggml `.bin`, whisper.cpp) or `.gigaam` (GGUF,
`TranscribeCppModel`). `TranscriptionEngine` keeps its public API and holds either a whisper context
or a `TranscribeCppModel` under the same lock and generation counter; the chunk loop branches per
chunk, and chunk length follows the model's limit (GigaAM: 25 s, minus a second).
- GigaAM v3 e2e RNN-T: Russian only (`languages: ["ru"]`, badge on the model row), punctuated,
  numbers as digits. No prompt (`supportsPrompt` — the dictionary is dropped and the Files card says
  so), no streaming (`supportsStreaming` — realtime dictation falls back to insert-on-release, and
  both the recognizer and the insertion mode switch, or nothing would be typed). Words come from token
  rows joined at SentencePiece's `▁` (`TranscribeCppWords`).
- The manifest omits `family` for whisper entries (byte-identical for old clients) and gives other
  families `FAMILY_MIN_APP_VERSION`: an older build would hand a GGUF to whisper.cpp. A family this
  build has no runtime for (`ModelFamily.isSupported`) is dropped from the catalogue.
- Apple Silicon only (`chipRequirement`): the x86_64 slice is a plain-x86-64 CPU build.

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

## CI

GitHub Actions (`.github/workflows/`), on every push to `main`:

- **Lint** — `scripts/check-localization.py`.
- **Deploy iOS to TestFlight** — `fastlane ios testflight_ios` on a clean `macos-26` runner: builds
  all of `vendor/` from scratch (whisper.cpp, opus, transcribe.cpp), archives, uploads. **iOS reaches
  TestFlight by pushing to main**; `scripts/deploy-testflight.sh` is only for uploading without CI.
  A new vendored dependency must be built in that lane (`fastlane/Fastfile`) — the runner has none of
  your local `vendor/`.
- **Deploy macOS to TestFlight** — disabled. macOS ships through `scripts/publish-release.sh`.

`publish-release.sh` pushes the release commit itself, which triggers the iOS upload too.

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
- Unit tests: `swift test` (`Tests/CorvinTests`: pure logic and the call file format; no model,
  no audio devices). iOS has UI tests only (`Tests/UITests`)
- Local only: recognition, diarization, dictionaries and transcripts never leave the device; the
  network is used only to download model files
