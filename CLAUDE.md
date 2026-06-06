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
- `scripts/build-dmg.sh` — full macOS DMG build pipeline (includes bundled small model)

## Architecture

Corvin is a multiplatform speech-to-text app using whisper.cpp.

### macOS
Menubar app. User holds fn key to record, releases to transcribe, text auto-inserted at cursor.

### iOS
Keyboard Extension (KeyboardKit) + host app. Push-To-Talk via mic button tap or long press any key (≥0.5s). Host app runs whisper.cpp transcription, keyboard extension communicates via localhost socket IPC.

### State Machine Flow

`idle → recording → transcribing → inserting → done → idle`

SessionState enum drives all UI and service coordination.

### Directory Structure

```
Shared/Core/         — SessionState, SessionManager, TranscriptionEngine, ModelManager, HistoryStore
Shared/Networking/   — IPC protocol (LocalIPCProtocol), TranscriptionModels
Shared/UI/           — ProPaywallView (cross-platform)
Shared/Resources/    — Localizable.strings (en, ru)
macOS/App/           — AppDelegate, CorvinApp (@main macOS)
macOS/Services/      — HotkeyService, AudioCaptureService, AccessibilityService
macOS/UI/            — StatusBarController, FloatingIndicator, Settings, History, Onboarding, ModelManager views
iOS/App/             — CorviniOSApp (@main iOS), iOSAppState
iOS/Services/        — IPCServer (NWListener), TranscriptionService, AudioCaptureService
iOS/UI/              — MainView, Settings, History, Onboarding, ModelManager views
iOS/Intents/         — StartRecordingIntent (App Intents for Shortcuts/Siri)
CorvinKeyboard/     — KeyboardViewController (KeyboardKit), PTTController, AudioRecorder, IPCClient, CustomActionHandler
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
- History: Core Data SQLite (programmatic model)
- Settings: UserDefaults (iOS uses App Group suite)

### C Bridge

whisper.cpp vendored at `vendor/whisper.cpp`. CWhisper SPM target in `Sources/CWhisper/` provides Swift-accessible C bindings. Static libraries linked from vendor build output.

### Project Configuration

- `Package.swift` — SPM manifest for macOS command-line build (defaultLocalization: "en")
- `project.yml` — XcodeGen config generating Corvin.xcodeproj with 7 targets (CWhisper_macOS, CWhisper_iOS, CorvinShared_macOS, CorvinShared_iOS, Corvin, CorviniOS, CorvinKeyboard)

## Git

Remote `origin` → https://github.com/MrSuhov/corvin (auth via `gh` over HTTPS).

```bash
git push origin main
```

## Key Constraints

- macOS deployment target: 11.0 (Big Sur)
- iOS deployment target: 15.0
- macOS: Universal binary arm64 (Metal GPU) + x86_64 (Accelerate BLAS)
- iOS: arm64 only (Metal GPU)
- Requires microphone permission on both platforms
- macOS requires accessibility permission for text insertion
- iOS keyboard extension requires Full Access for microphone and network
- External dependency: KeyboardKit (iOS keyboard extension only)
- No test suite currently exists
