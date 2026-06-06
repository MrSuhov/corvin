.PHONY: vendor-macos vendor-ios project setup-macos setup-ios build-dmg deploy-testflight clean

# Build whisper.cpp for macOS (universal arm64 + x86_64)
vendor-macos:
	./scripts/build-whisper-macos.sh

# Build whisper.cpp for iOS (arm64)
vendor-ios:
	./scripts/build-whisper-ios.sh

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
