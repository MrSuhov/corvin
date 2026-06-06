# Test Transcription + OGG File Import — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a "Test Transcription" tab to macOS Settings (mic recording + file import) and extend the iOS test feature with OGG file import, enabling users to transcribe Telegram voice messages.

**Architecture:** New `TestTranscriptionView` in macOS Settings with two modes: (1) PTT mic recording (reusing existing `AudioCaptureService` + `TranscriptionEngine`) and (2) OGG/audio file import via `NSOpenPanel`/document picker. OGG Opus decoding via `AVAudioFile` with a fallback to the `libopus`/`libogg` C libraries vendored similarly to whisper.cpp. Both platforms share a new `AudioFileDecoder` utility in `Shared/Core/` that converts any supported audio file to 16kHz Int16 PCM Data — the format `TranscriptionEngine` already expects.

**Tech Stack:** SwiftUI, AVFoundation (`AVAudioFile`, `AVAudioConverter`), UniformTypeIdentifiers, existing whisper.cpp pipeline. For OGG Opus: `libopusfile` + `libopus` + `libogg` vendored as static C libraries with a thin Swift bridge.

---

## Task 1: Add "Test" tab to macOS Settings

**Files:**
- Modify: `macOS/UI/Settings/SettingsView.swift:4-32` (add `.test` tab to enum)
- Modify: `Shared/Resources/en.lproj/Localizable.strings` (add localization key)
- Modify: `Shared/Resources/ru.lproj/Localizable.strings` (add localization key)

**Step 1: Add `.test` case to `SettingsTab` enum**

In `macOS/UI/Settings/SettingsView.swift`, add the new tab:

```swift
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, models, indicator, history, language, pro, permissions, test
    // ...
    var label: String {
        switch self {
        // ... existing cases ...
        case .test: return "settings.tab.test".localized
        }
    }

    var icon: String {
        switch self {
        // ... existing cases ...
        case .test: return "mic.badge.plus"
        }
    }
}
```

**Step 2: Route to `TestTranscriptionView` in `detailContent`**

```swift
case .test: TestTranscriptionView()
```

**Step 3: Add localization strings**

In `en.lproj/Localizable.strings`:
```
"settings.tab.test" = "Test";
```

In `ru.lproj/Localizable.strings`:
```
"settings.tab.test" = "Тест";
```

**Step 4: Build and verify tab appears**

Run: Build via Xcode or `swift build`
Expected: New "Test" tab visible in Settings sidebar with mic.badge.plus icon

**Step 5: Commit**

```bash
git add macOS/UI/Settings/SettingsView.swift Shared/Resources/en.lproj/Localizable.strings Shared/Resources/ru.lproj/Localizable.strings
git commit -m "feat: add Test tab to macOS Settings"
```

---

## Task 2: Create macOS `TestTranscriptionView` with PTT recording

**Files:**
- Create: `macOS/UI/Settings/TestTranscriptionView.swift`
- Modify: `macOS/App/AppDelegate.swift` (expose services for test view)

**Step 1: Create `TestTranscriptionView` with PTT button**

Create `macOS/UI/Settings/TestTranscriptionView.swift`:

```swift
import SwiftUI

struct TestTranscriptionView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var modelManager: ModelManager

    @State private var resultText = ""
    @State private var isProcessing = false
    @State private var errorMessage: String?

    private let audioCaptureService = AudioCaptureService()
    private let transcriptionEngine: TranscriptionEngine

    init() {
        // Access shared transcription engine from AppDelegate
        let appDelegate = NSApp.delegate as! AppDelegate
        transcriptionEngine = appDelegate.transcriptionEngine
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // PTT section
                VStack(spacing: 12) {
                    Text("Тест записи")
                        .font(.headline)

                    pttButton

                    stateLabel
                }

                // Result display
                if !resultText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Результат")
                                .font(.headline)
                            Spacer()
                            Button("Копировать") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(resultText, forType: .string)
                            }
                            .buttonStyle(.bordered)
                        }

                        Text(resultText)
                            .textSelection(.enabled)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.controlBackgroundColor))
                            .cornerRadius(8)
                    }
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            .padding()
        }
    }

    private var pttButton: some View {
        Circle()
            .fill(sessionManager.state == .recording ? Color.red : Color.blue)
            .frame(width: 80, height: 80)
            .overlay(
                Image(systemName: sessionManager.state == .recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.white)
            )
            .shadow(color: sessionManager.state == .recording ? .red.opacity(0.4) : .blue.opacity(0.3), radius: 8)
            .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
                if pressing {
                    startRecording()
                } else {
                    stopAndTranscribe()
                }
            }, perform: {})
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch sessionManager.state {
        case .idle:
            Text("Удерживайте кнопку для записи")
                .foregroundColor(.secondary)
        case .recording:
            Text("Запись...")
                .foregroundColor(.red)
        case .transcribing:
            ProgressView("Транскрипция...")
        default:
            EmptyView()
        }
    }

    private func startRecording() {
        guard sessionManager.state == .idle || sessionManager.state == .done("") || true else { return }
        errorMessage = nil
        sessionManager.state = .recording
        audioCaptureService.startCapture()
    }

    private func stopAndTranscribe() {
        guard sessionManager.state == .recording else { return }
        let audioData = audioCaptureService.stopCapture()
        sessionManager.state = .transcribing

        Task {
            do {
                let result = try await transcriptionEngine.transcribe(audioData: audioData)
                await MainActor.run {
                    resultText = result.text
                    sessionManager.state = .idle
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    sessionManager.state = .idle
                }
            }
        }
    }
}
```

**Step 2: Expose `transcriptionEngine` in AppDelegate**

In `macOS/App/AppDelegate.swift`, change `transcriptionEngine` from `private` to `private(set)`:

```swift
// Before:
private var transcriptionEngine: TranscriptionEngine!

// After:
private(set) var transcriptionEngine: TranscriptionEngine!
```

**Step 3: Build and verify PTT recording works**

Run: Build and open Settings → Test tab. Hold the mic button, speak, release.
Expected: Text appears in the result area.

**Step 4: Commit**

```bash
git add macOS/UI/Settings/TestTranscriptionView.swift macOS/App/AppDelegate.swift
git commit -m "feat: add PTT test recording to macOS Settings"
```

---

## Task 3: Add `AudioFileDecoder` — convert audio files to PCM

This shared utility decodes audio files (WAV, M4A, CAF, MP3, AIFF — anything `AVAudioFile` supports) to 16kHz Int16 mono PCM `Data`, the format `TranscriptionEngine.transcribe()` expects.

**Files:**
- Create: `Shared/Core/AudioFileDecoder.swift`

**Step 1: Create `AudioFileDecoder`**

Create `Shared/Core/AudioFileDecoder.swift`:

```swift
import Foundation
import AVFoundation

enum AudioFileDecoder {

    enum DecoderError: LocalizedError {
        case cannotOpenFile(String)
        case conversionFailed(String)
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .cannotOpenFile(let path): return "Не удалось открыть файл: \(path)"
            case .conversionFailed(let reason): return "Ошибка конвертации: \(reason)"
            case .emptyResult: return "Файл не содержит аудиоданных"
            }
        }
    }

    /// Decode any AVAudioFile-supported format to 16kHz Int16 mono PCM Data.
    static func decode(url: URL) throws -> Data {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw DecoderError.cannotOpenFile(error.localizedDescription)
        }

        let srcFormat = file.processingFormat
        guard let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw DecoderError.conversionFailed("Cannot create target format")
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw DecoderError.conversionFailed("Cannot create converter from \(srcFormat) to \(dstFormat)")
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            throw DecoderError.conversionFailed("Cannot create source buffer")
        }
        try file.read(into: srcBuffer)

        let ratio = 16000.0 / srcFormat.sampleRate
        let outputFrames = AVAudioFrameCount(Double(frameCount) * ratio)
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outputFrames) else {
            throw DecoderError.conversionFailed("Cannot create destination buffer")
        }

        var error: NSError?
        converter.convert(to: dstBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return srcBuffer
        }
        if let error = error {
            throw DecoderError.conversionFailed(error.localizedDescription)
        }

        guard dstBuffer.frameLength > 0 else {
            throw DecoderError.emptyResult
        }

        let byteCount = Int(dstBuffer.frameLength) * MemoryLayout<Int16>.size
        return Data(bytes: dstBuffer.int16ChannelData![0], count: byteCount)
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: Build complete

**Step 3: Commit**

```bash
git add Shared/Core/AudioFileDecoder.swift
git commit -m "feat: add AudioFileDecoder for converting audio files to PCM"
```

---

## Task 4: Vendor OGG Opus decoding libraries

`AVAudioFile` does not support OGG Opus (Telegram voice messages). We need to vendor the C libraries `libogg`, `libopus`, and `libopusfile` and build them as static libraries, similar to how whisper.cpp is vendored.

**Files:**
- Create: `scripts/build-opusfile.sh` (build script)
- Create: `Sources/COpus/include/shim.h` (C bridge header)
- Create: `Sources/COpus/shim.c` (C bridge implementation)
- Modify: `Package.swift` (add COpus target and linker flags)
- Modify: `project.yml` (add COpus target and linker flags)

**Step 1: Create build script for OGG/Opus libraries**

Create `scripts/build-opusfile.sh`:

```bash
#!/bin/bash
set -euo pipefail

# Build libogg, libopus, and libopusfile as static universal libraries for macOS
# and arm64 for iOS, similar to how whisper.cpp is vendored.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$PROJECT_DIR/vendor"
BUILD_DIR="$VENDOR_DIR/opus-build"

OGG_VERSION="1.3.5"
OPUS_VERSION="1.5.2"
OPUSFILE_VERSION="0.12"

OGG_URL="https://downloads.xiph.org/releases/ogg/libogg-${OGG_VERSION}.tar.gz"
OPUS_URL="https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz"
OPUSFILE_URL="https://downloads.xiph.org/releases/opus/opusfile-${OPUSFILE_VERSION}.tar.gz"

PLATFORM="${1:-macos}"  # macos or ios

echo "=== Building OGG/Opus/Opusfile ($PLATFORM) ==="

mkdir -p "$BUILD_DIR/src"
cd "$BUILD_DIR/src"

# Download sources if not cached
for pkg in "libogg-${OGG_VERSION}" "opus-${OPUS_VERSION}" "opusfile-${OPUSFILE_VERSION}"; do
    if [ ! -d "$pkg" ]; then
        case "$pkg" in
            libogg*) url="$OGG_URL" ;;
            opus-*)  url="$OPUS_URL" ;;
            opusfile*) url="$OPUSFILE_URL" ;;
        esac
        echo "Downloading $pkg..."
        curl -sL "$url" | tar xz
    fi
done

build_lib() {
    local src_dir="$1"
    local arch="$2"
    local prefix="$BUILD_DIR/$PLATFORM-$arch"

    mkdir -p "$prefix"
    cd "$BUILD_DIR/src/$src_dir"

    local host=""
    local cflags="-O2"
    local sdk_path=""

    if [ "$PLATFORM" = "ios" ]; then
        sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
        cflags="$cflags -isysroot $sdk_path -arch $arch -mios-version-min=15.0"
        host="--host=aarch64-apple-darwin"
    else
        sdk_path=$(xcrun --sdk macosx --show-sdk-path)
        cflags="$cflags -isysroot $sdk_path -arch $arch -mmacosx-version-min=11.0"
        if [ "$arch" = "arm64" ]; then
            host="--host=aarch64-apple-darwin"
        else
            host="--host=x86_64-apple-darwin"
        fi
    fi

    # Add ogg headers for opus/opusfile builds
    local extra_flags=""
    if [ "$src_dir" != "libogg-${OGG_VERSION}" ]; then
        extra_flags="--with-ogg=$prefix"
        cflags="$cflags -I$prefix/include"
    fi

    # opusfile needs opus too
    if [[ "$src_dir" == opusfile* ]]; then
        extra_flags="$extra_flags --disable-http --disable-examples"
        cflags="$cflags -I$prefix/include"
        export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
    fi

    make clean 2>/dev/null || true
    CFLAGS="$cflags" LDFLAGS="-L$prefix/lib" \
        ./configure $host --prefix="$prefix" \
        --enable-static --disable-shared --disable-doc \
        $extra_flags \
        > /dev/null 2>&1
    make -j$(sysctl -n hw.ncpu) > /dev/null 2>&1
    make install > /dev/null 2>&1
    cd "$BUILD_DIR/src"
}

if [ "$PLATFORM" = "ios" ]; then
    ARCHS="arm64"
else
    ARCHS="arm64 x86_64"
fi

for arch in $ARCHS; do
    echo "Building libogg ($arch)..."
    build_lib "libogg-${OGG_VERSION}" "$arch"
    echo "Building libopus ($arch)..."
    build_lib "opus-${OPUS_VERSION}" "$arch"
    echo "Building libopusfile ($arch)..."
    build_lib "opusfile-${OPUSFILE_VERSION}" "$arch"
done

# Create universal binaries (macOS only)
OUTPUT_DIR="$BUILD_DIR/$PLATFORM-universal"
mkdir -p "$OUTPUT_DIR/lib" "$OUTPUT_DIR/include"

if [ "$PLATFORM" = "macos" ]; then
    for lib in libogg libopus libopusfile; do
        lipo -create \
            "$BUILD_DIR/$PLATFORM-arm64/lib/${lib}.a" \
            "$BUILD_DIR/$PLATFORM-x86_64/lib/${lib}.a" \
            -output "$OUTPUT_DIR/lib/${lib}.a"
    done
    cp -R "$BUILD_DIR/$PLATFORM-arm64/include/"* "$OUTPUT_DIR/include/"
else
    for lib in libogg libopus libopusfile; do
        cp "$BUILD_DIR/$PLATFORM-arm64/lib/${lib}.a" "$OUTPUT_DIR/lib/"
    done
    cp -R "$BUILD_DIR/$PLATFORM-arm64/include/"* "$OUTPUT_DIR/include/"
fi

echo ""
echo "=== Done ==="
echo "Output: $OUTPUT_DIR"
ls -la "$OUTPUT_DIR/lib/"
```

Make executable:
```bash
chmod +x scripts/build-opusfile.sh
```

**Step 2: Run the build script**

```bash
./scripts/build-opusfile.sh macos
```

Expected: Libraries built at `vendor/opus-build/macos-universal/lib/`

**Step 3: Create C bridge for Swift**

Create `Sources/COpus/include/shim.h`:

```c
#ifndef COPUS_SHIM_H
#define COPUS_SHIM_H

#include <opusfile.h>

#endif
```

Create `Sources/COpus/shim.c`:

```c
#include "shim.h"
```

**Step 4: Add COpus target and linker flags to `Package.swift`**

Add the COpus system library target and link it in the Corvin target. Add to the linker settings:

```swift
// In targets array, add:
.systemLibrary(
    name: "COpus",
    path: "Sources/COpus",
    pkgConfig: nil
),

// In Corvin target linkerSettings, add:
.unsafeFlags(["-L", "vendor/opus-build/macos-universal/lib"]),
.linkedLibrary("opusfile"),
.linkedLibrary("opus"),
.linkedLibrary("ogg"),
```

And add header search path:
```swift
.headerSearchPath("../vendor/opus-build/macos-universal/include"),
.headerSearchPath("../vendor/opus-build/macos-universal/include/opus"),
```

**Step 5: Add to `project.yml`**

In the Corvin (macOS) target settings, add to `OTHER_LDFLAGS`:
```
-lopusfile -lopus -logg
```

Add to `HEADER_SEARCH_PATHS`:
```
$(PROJECT_DIR)/vendor/opus-build/macos-universal/include
$(PROJECT_DIR)/vendor/opus-build/macos-universal/include/opus
```

Add to `LIBRARY_SEARCH_PATHS`:
```
$(PROJECT_DIR)/vendor/opus-build/macos-universal/lib
```

Do the same for CorviniOS target but with `ios-universal` paths.

**Step 6: Verify build**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: Build complete

**Step 7: Commit**

```bash
git add scripts/build-opusfile.sh Sources/COpus/ Package.swift project.yml
git commit -m "feat: vendor libogg/libopus/libopusfile for OGG Opus decoding"
```

---

## Task 5: Add OGG Opus decoding to `AudioFileDecoder`

**Files:**
- Modify: `Shared/Core/AudioFileDecoder.swift`

**Step 1: Add `decodeOggOpus` method**

Add to `AudioFileDecoder`:

```swift
/// Decode OGG Opus file to 16kHz Int16 mono PCM Data.
/// Uses libopusfile which always decodes to 48kHz — we then downsample to 16kHz.
static func decodeOggOpus(url: URL) throws -> Data {
    guard let opFile = op_open_file(url.path, nil) else {
        throw DecoderError.cannotOpenFile(url.lastPathComponent)
    }
    defer { op_free(opFile) }

    // libopusfile always decodes to 48000 Hz, interleaved stereo or mono
    let channels = op_channel_count(opFile, -1)

    // Read all PCM samples (48kHz float)
    var allSamples = [Float]()
    let bufSize = 5760 * 2 // max Opus frame * stereo
    var buf = [Float](repeating: 0, count: bufSize)

    while true {
        let read = op_read_float(opFile, &buf, Int32(bufSize / Int(channels)), nil)
        if read <= 0 { break }
        let frameCount = Int(read)

        if channels == 1 {
            allSamples.append(contentsOf: buf[0..<frameCount])
        } else {
            // Downmix stereo to mono
            for i in 0..<frameCount {
                let mono = (buf[i * 2] + buf[i * 2 + 1]) / 2.0
                allSamples.append(mono)
            }
        }
    }

    guard !allSamples.isEmpty else {
        throw DecoderError.emptyResult
    }

    // Downsample 48kHz → 16kHz (ratio 3:1)
    let step = 3 // 48000 / 16000
    var pcmData = Data()
    pcmData.reserveCapacity(allSamples.count / step * MemoryLayout<Int16>.size)

    for i in stride(from: 0, to: allSamples.count, by: step) {
        let clamped = max(-1.0, min(1.0, allSamples[i]))
        var sample = Int16(clamped * 32767.0)
        withUnsafeBytes(of: &sample) { pcmData.append(contentsOf: $0) }
    }

    return pcmData
}
```

**Step 2: Update `decode(url:)` to route OGG files**

Modify the existing `decode(url:)` to detect OGG and dispatch accordingly:

```swift
static func decode(url: URL) throws -> Data {
    let ext = url.pathExtension.lowercased()

    // OGG Opus requires special decoder (AVAudioFile doesn't support it)
    if ext == "ogg" || ext == "opus" || ext == "oga" {
        return try decodeOggOpus(url: url)
    }

    // All other formats via AVAudioFile
    let file: AVAudioFile
    // ... rest of existing implementation
}
```

**Step 3: Build and verify**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: Build complete

**Step 4: Commit**

```bash
git add Shared/Core/AudioFileDecoder.swift
git commit -m "feat: add OGG Opus decoding via libopusfile"
```

---

## Task 6: Add file import UI to macOS `TestTranscriptionView`

**Files:**
- Modify: `macOS/UI/Settings/TestTranscriptionView.swift`

**Step 1: Add file import section below the PTT button**

Add an "Import File" section with an `NSOpenPanel`:

```swift
// Add after the PTT section in the VStack:

Divider()

// File import section
VStack(spacing: 12) {
    Text("Транскрипция файла")
        .font(.headline)

    Text("Поддерживаемые форматы: OGG (Telegram), WAV, M4A, MP3, AIFF")
        .font(.caption)
        .foregroundColor(.secondary)

    HStack(spacing: 12) {
        Button {
            importFile()
        } label: {
            Label("Выбрать файл", systemImage: "doc.badge.plus")
        }
        .buttonStyle(.bordered)

        if let fileName = importedFileName {
            Text(fileName)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
```

**Step 2: Add state properties and import function**

```swift
@State private var importedFileName: String?

private func importFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [
        .audio,
        UTType(filenameExtension: "ogg")!,
        UTType(filenameExtension: "opus")!,
    ]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = "Выберите аудиофайл для транскрипции"

    guard panel.runModal() == .OK, let url = panel.url else { return }

    importedFileName = url.lastPathComponent
    errorMessage = nil
    resultText = ""
    sessionManager.state = .transcribing

    Task {
        do {
            let pcmData = try AudioFileDecoder.decode(url: url)
            let result = try await transcriptionEngine.transcribe(audioData: pcmData)
            await MainActor.run {
                resultText = result.text
                sessionManager.state = .idle
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                sessionManager.state = .idle
            }
        }
    }
}
```

**Step 3: Build and test with a real OGG file**

Run: Build, open Settings → Test, click "Выбрать файл", pick an OGG voice message.
Expected: File transcribed, text displayed.

**Step 4: Commit**

```bash
git add macOS/UI/Settings/TestTranscriptionView.swift
git commit -m "feat: add file import for audio transcription in macOS test tab"
```

---

## Task 7: Add file import to iOS `MainView`

**Files:**
- Modify: `iOS/UI/MainView.swift`
- Modify: `iOS/App/iOSAppState.swift`

**Step 1: Add file import button below PTT in `MainView.swift`**

After the PTT test section (around line 145), add:

```swift
Divider()

VStack(spacing: 12) {
    Text("Транскрипция файла")
        .font(.headline)

    Text("OGG (Telegram), WAV, M4A, MP3, AIFF")
        .font(.caption)
        .foregroundColor(.secondary)

    Button {
        showingFilePicker = true
    } label: {
        Label("Выбрать файл", systemImage: "doc.badge.plus")
    }
    .buttonStyle(.borderedProminent)

    if let fileName = importedFileName {
        Text(fileName)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
.fileImporter(
    isPresented: $showingFilePicker,
    allowedContentTypes: [.audio, UTType(filenameExtension: "ogg")!, UTType(filenameExtension: "opus")!],
    allowsMultipleSelection: false
) { result in
    switch result {
    case .success(let urls):
        guard let url = urls.first else { return }
        importedFileName = url.lastPathComponent
        appState.transcribeFile(url: url)
    case .failure(let error):
        flog("File import error: \(error)")
    }
}
```

Add state properties:
```swift
@State private var showingFilePicker = false
@State private var importedFileName: String?
```

Add import at top:
```swift
import UniformTypeIdentifiers
```

**Step 2: Add `transcribeFile()` to `iOSAppState`**

In `iOS/App/iOSAppState.swift`, add:

```swift
func transcribeFile(url: URL) {
    guard sessionManager.state == .idle || sessionManager.state != .recording else { return }

    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }

    sessionManager.state = .transcribing

    Task {
        do {
            let pcmData = try AudioFileDecoder.decode(url: url)
            let result = try await transcriptionService.transcribe(audioData: pcmData)
            await MainActor.run {
                UIPasteboard.general.string = result.text
                sessionManager.state = .done(result.text)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    if case .done = self.sessionManager.state {
                        self.sessionManager.state = .idle
                    }
                }
            }
        } catch {
            await MainActor.run {
                sessionManager.state = .error(error.localizedDescription)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if case .error = self.sessionManager.state {
                        self.sessionManager.state = .idle
                    }
                }
            }
        }
    }
}
```

**Step 3: Build and test on iOS**

Run: Build CorviniOS scheme, open app, tap "Выбрать файл", pick an OGG from Files.
Expected: File transcribed, text copied to clipboard and displayed.

**Step 4: Commit**

```bash
git add iOS/UI/MainView.swift iOS/App/iOSAppState.swift
git commit -m "feat: add file import for audio transcription on iOS"
```

---

## Task 8: Add OGG Opus build to iOS build script

**Files:**
- Modify: `scripts/build-whisper-ios.sh` (or call opus build separately)
- Modify: `scripts/build-dmg.sh` (ensure macOS opus libs are built)

**Step 1: Add opus build to iOS CI**

In `.github/workflows/testflight-ios.yml`, add step before `Build & Upload`:

```yaml
- name: Build OGG/Opus libraries (iOS)
  run: ./scripts/build-opusfile.sh ios
```

**Step 2: Add opus build to macOS CI**

In `.github/workflows/testflight-macos.yml`, add step before `Build & Upload`:

```yaml
- name: Build OGG/Opus libraries (macOS)
  run: ./scripts/build-opusfile.sh macos
```

**Step 3: Update `build-dmg.sh` to build opus before packaging**

Add after whisper build step:

```bash
# Step 1b: Build OGG/Opus libraries
echo "[1b/4] Building OGG/Opus libraries..."
"$PROJECT_DIR/scripts/build-opusfile.sh" macos
```

**Step 4: Commit**

```bash
git add scripts/ .github/workflows/
git commit -m "ci: add OGG/Opus library build to CI pipelines and DMG build"
```

---

## Task 9: Add sandbox entitlement for file access (macOS)

Since the macOS app is sandboxed (for TestFlight), `NSOpenPanel` needs the user-selected file read entitlement.

**Files:**
- Modify: `macOS/Resources/Corvin.entitlements`

**Step 1: Add file read entitlement**

Add to `Corvin.entitlements`:

```xml
<key>com.apple.security.files.user-selected.read-only</key>
<true/>
```

This allows reading files the user explicitly picks via `NSOpenPanel`.

**Step 2: Commit**

```bash
git add macOS/Resources/Corvin.entitlements
git commit -m "feat: add user-selected file read entitlement for file import"
```

---

## Summary

| Task | Description | Platform |
|------|-------------|----------|
| 1 | Add "Test" tab to Settings enum + localization | macOS |
| 2 | Create `TestTranscriptionView` with PTT recording | macOS |
| 3 | Create `AudioFileDecoder` for standard audio formats | Shared |
| 4 | Vendor libogg/libopus/libopusfile C libraries | Build |
| 5 | Add OGG Opus decoding to `AudioFileDecoder` | Shared |
| 6 | Add file import UI to macOS test view | macOS |
| 7 | Add file import UI + handler to iOS | iOS |
| 8 | Update CI and build scripts for opus libraries | CI |
| 9 | Add sandbox file-read entitlement | macOS |
| 10 | Register audio file types + "Open With" on macOS | macOS |
| 11 | Register audio file types + "Open With" on iOS | iOS |

**Dependencies:** Task 3 before 5, 6, 7. Task 4 before 5. Task 1 before 2. Task 2 before 6. Tasks 3+5 before 10, 11.

---

## Task 10: Register audio file types + "Open With" handler on macOS

Enable "Open With → Corvin" in Finder for audio files (OGG, WAV, M4A, MP3, AIFF, OPUS). When a file is opened with Corvin, the app opens the Test tab and auto-transcribes the file.

**Files:**
- Modify: `macOS/Resources/Info.plist` (add CFBundleDocumentTypes + UTImportedTypeDeclarations for OGG)
- Modify: `macOS/App/AppDelegate.swift` (handle `application(_:open:)`)

**Step 1: Add CFBundleDocumentTypes to Info.plist**

Add before `</dict></plist>`:

```xml
<key>CFBundleDocumentTypes</key>
<array>
    <dict>
        <key>CFBundleTypeName</key>
        <string>Audio File</string>
        <key>CFBundleTypeRole</key>
        <string>Viewer</string>
        <key>LSHandlerRank</key>
        <string>Alternate</string>
        <key>LSItemContentTypes</key>
        <array>
            <string>public.audio</string>
            <string>org.xiph.ogg-audio</string>
            <string>public.opus-audio</string>
        </array>
    </dict>
</array>
<key>UTImportedTypeDeclarations</key>
<array>
    <dict>
        <key>UTTypeIdentifier</key>
        <string>org.xiph.ogg-audio</string>
        <key>UTTypeDescription</key>
        <string>OGG Audio</string>
        <key>UTTypeConformsTo</key>
        <array>
            <string>public.audio</string>
        </array>
        <key>UTTypeTagSpecification</key>
        <dict>
            <key>public.filename-extension</key>
            <array>
                <string>ogg</string>
                <string>oga</string>
            </array>
            <key>public.mime-type</key>
            <array>
                <string>audio/ogg</string>
            </array>
        </dict>
    </dict>
    <dict>
        <key>UTTypeIdentifier</key>
        <string>public.opus-audio</string>
        <key>UTTypeDescription</key>
        <string>Opus Audio</string>
        <key>UTTypeConformsTo</key>
        <array>
            <string>public.audio</string>
        </array>
        <key>UTTypeTagSpecification</key>
        <dict>
            <key>public.filename-extension</key>
            <array>
                <string>opus</string>
            </array>
            <key>public.mime-type</key>
            <array>
                <string>audio/opus</string>
            </array>
        </dict>
    </dict>
</array>
```

**Step 2: Handle file open in AppDelegate**

Add to `AppDelegate`:

```swift
func application(_ application: NSApplication, open urls: [URL]) {
    guard let url = urls.first else { return }
    flog("application(open:) \(url.lastPathComponent)")
    // Open settings to test tab and trigger transcription
    showSettingsWindow(tab: .test)
    // Post notification for TestTranscriptionView to pick up
    NotificationCenter.default.post(
        name: .transcribeFileRequest,
        object: nil,
        userInfo: ["url": url]
    )
}
```

Add notification name:
```swift
extension Notification.Name {
    static let transcribeFileRequest = Notification.Name("transcribeFileRequest")
}
```

**Step 3: Handle notification in TestTranscriptionView**

Add `.onReceive` in TestTranscriptionView to listen for file open requests and auto-transcribe.

**Step 4: Commit**

```bash
git add macOS/Resources/Info.plist macOS/App/AppDelegate.swift macOS/UI/Settings/TestTranscriptionView.swift
git commit -m "feat: register audio file types and handle Open With on macOS"
```

---

## Task 11: Register audio file types + "Open With" handler on iOS

Enable "Open In → Corvin" from Telegram and Files app on iOS. When a file is shared to Corvin, the app opens and auto-transcribes it.

**Files:**
- Modify: `iOS/Resources/Info.plist` (add CFBundleDocumentTypes + UTImportedTypeDeclarations)
- Modify: `iOS/App/CorviniOSApp.swift` (handle `.onOpenURL`)
- Modify: `iOS/App/iOSAppState.swift` (add file URL handling)

**Step 1: Add CFBundleDocumentTypes to iOS Info.plist**

Same document types as macOS (see Task 10 Step 1).

**Step 2: Handle URL open in CorviniOSApp**

Add `.onOpenURL` modifier to the main view:

```swift
.onOpenURL { url in
    appState.transcribeFile(url: url)
}
```

The `transcribeFile(url:)` method already exists from Task 7 — it handles security-scoped resource access and transcription.

**Step 3: Commit**

```bash
git add iOS/Resources/Info.plist iOS/App/CorviniOSApp.swift
git commit -m "feat: register audio file types and handle Open With on iOS"
```
