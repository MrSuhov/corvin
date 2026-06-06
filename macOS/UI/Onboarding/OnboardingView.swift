import SwiftUI

struct OnboardingView: View {
    @ObservedObject var modelManager: ModelManager
    @ObservedObject private var localization = LocalizationManager.shared
    let audioCaptureService: AudioCaptureService
    let accessibilityService: AccessibilityService
    let onComplete: () -> Void

    @State private var currentStep = 0
    @State private var isTestRecording = false
    @State private var testLevel: CGFloat = 0
    @State private var heardSound = false

    var body: some View {
        VStack(spacing: 0) {
            // Progress
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(i <= currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(height: 4)
                }
            }
            .padding()

            Spacer()

            // Content
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: microphoneStep
                case 2: modelStep
                case 3: testStep
                case 4: doneStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)

            Spacer()

            // Navigation
            HStack {
                if currentStep > 0 && currentStep < 4 {
                    Button("onboarding.back".localized) {
                        if currentStep == 3 { stopTest() }
                        currentStep -= 1
                    }
                }
                Spacer()
                if currentStep < 4 {
                    Button("onboarding.next".localized) { advanceStep() }
                        .modifier(ProminentButtonCompat())
                }
            }
            .padding()
        }
        .frame(width: 500, height: 400)
        .id(localization.currentLanguage)
        .onDisappear { stopTest() }
    }

    private func advanceStep() {
        if currentStep == 0 {
            accessibilityService.requestAccessibilityPermission()
        }
        if currentStep == 1 {
            audioCaptureService.requestMicrophonePermission { _ in }
        }
        if currentStep == 3 {
            stopTest()
        }
        currentStep += 1
    }

    // MARK: - Test recording

    private func toggleTestRecording() {
        if isTestRecording {
            stopTest()
        } else {
            heardSound = false
            audioCaptureService.onLevel = { lvl in
                testLevel = min(1.0, CGFloat(lvl) * 10)
                if lvl > 0.02 { heardSound = true }
            }
            audioCaptureService.startCapture()
            isTestRecording = true
        }
    }

    private func stopTest() {
        guard isTestRecording else { return }
        _ = audioCaptureService.stopCapture()
        audioCaptureService.onLevel = nil
        testLevel = 0
        isTestRecording = false
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Picker("", selection: $localization.currentLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .labelsHidden()
                .frame(width: 160)
            }
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)
            Text("onboarding.welcome".localized)
                .font(.title)
                .bold()
            Text("onboarding.welcome.desc".localized)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Text("onboarding.welcome.accessibility".localized)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var microphoneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)
            Text("onboarding.mic.title".localized)
                .font(.title2)
                .bold()
            Text("onboarding.mic.desc".localized)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
    }

    private var modelStep: some View {
        VStack(spacing: 12) {
            Text("onboarding.model.title".localized)
                .font(.title2)
                .bold()
            Text("onboarding.model.hint".localized(with: modelManager.recommendedModel?.name ?? "small"))
                .font(.caption)
                .foregroundColor(.secondary)

            ModelManagerView()
                .environmentObject(modelManager)
                .frame(maxHeight: 250)

            Button("onboarding.model.skip".localized) {
                currentStep = 4
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    private var testStep: some View {
        VStack(spacing: 16) {
            MicLevelBars(level: testLevel)
            Text("onboarding.test.title".localized)
                .font(.title2)
                .bold()
            Text("onboarding.test.desc".localized)
                .foregroundColor(.secondary)

            Button(isTestRecording ? "onboarding.test.stop".localized : "onboarding.test.start".localized) {
                toggleTestRecording()
            }
            .modifier(ProminentButtonCompat())

            if heardSound {
                Text("onboarding.test.heard".localized)
                    .foregroundColor(.green)
                    .padding()
                    .background(Color.green.opacity(0.12))
                    .cornerRadius(8)
            }
        }
    }

    private var doneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)
            Text("onboarding.done.title".localized)
                .font(.title)
                .bold()
            Text("onboarding.done.desc".localized)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Button("onboarding.done.start".localized) {
                onComplete()
            }
            .modifier(ProminentButtonCompat())
        }
    }
}

// MARK: - Live mic level indicator

/// A small row of bars whose heights track a normalized mic level (0…1).
/// Flat when silent, rising when the user speaks.
private struct MicLevelBars: View {
    let level: CGFloat

    private let multipliers: [CGFloat] = [0.4, 0.7, 1.0, 0.85, 1.0, 0.7, 0.4]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(multipliers.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 5, height: max(4, level * 56 * multipliers[i]))
            }
        }
        .frame(height: 60)
        .animation(.easeOut(duration: 0.1), value: level)
    }
}
