.PHONY: lint-l10n l10n-report vendor-macos vendor-ios project setup-macos setup-ios build-dmg deploy-testflight clean

# Build whisper.cpp for macOS (universal arm64 + x86_64)
vendor-macos:
	./scripts/build-whisper-macos.sh
	./scripts/build-transcribe-macos.sh

# Build whisper.cpp and opus for iOS (arm64, device + simulator).
# The simulator slices are needed for the App Store screenshot run, which
# cannot use a device: the keep-alive PiP window would appear in every frame.
vendor-ios:
	./scripts/build-whisper-ios.sh
	./scripts/build-transcribe-ios.sh
	./scripts/build-opusfile.sh ios
	./scripts/build-opusfile.sh iossim

# Generate Xcode project (requires xcodegen: brew install xcodegen)
project:
	xcodegen generate

# Full macOS setup
setup-macos: vendor-macos project
	@echo "macOS setup complete. Run ./scripts/build-dmg.sh or open Corvin.xcodeproj."

# Full iOS setup
setup-ios: vendor-ios project
	@echo "iOS setup complete. Open Corvin.xcodeproj, select CorviniOS scheme."

# Build macOS DMG
build-dmg:
	./scripts/build-dmg.sh

# Deploy to TestFlight (ios, macos, or all)
deploy-testflight:
	./scripts/deploy-testflight.sh all

clean:
	rm -rf vendor/whisper.cpp/build-*
	rm -rf build
	rm -rf .build

# Localization guardrail. `lint-l10n` fails on drift; `l10n-report` just prints
# per-language coverage so you can see what is left to translate.
lint-l10n:
	./scripts/check-localization.py

l10n-report:
	./scripts/check-localization.py --report
