import UIKit
import SwiftUI
import KeyboardKit

class KeyboardViewController: KeyboardInputViewController {

    private var pttController: PTTController!

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        flog("Keyboard viewDidAppear")
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        flog("Keyboard viewWillDisappear")
    }

    override func viewWillSetupKeyboardView() {
        super.viewWillSetupKeyboardView()
        flog("Keyboard viewWillSetupKeyboardView")

        pttController = PTTController(textDocumentProxy: textDocumentProxy)

        // Read enabled languages from settings
        let defaults = UserDefaults(suiteName: "group.com.corvinvoice.app")
        let languagesString = defaults?.string(forKey: "keyboardLanguages") ?? "en,ru"
        let enabledLanguages = languagesString.split(separator: ",").map { String($0) }

        // Configure available locales based on settings
        let locales = enabledLanguages.map { Locale(identifier: $0) }
        state.keyboardContext.locales = locales.isEmpty ? [Locale(identifier: "en")] : locales

        let handler = CustomActionHandler(
            pttController: pttController,
            inputController: self
        )
        services.actionHandler = handler

        let ptt = pttController!
        let showLang = locales.count > 1
        setupKeyboardView { controller in
            KeyboardView(
                layout: CorvinLayout.make(for: controller.state.keyboardContext, showLanguageButton: showLang),
                services: controller.services,
                buttonContent: { params in
                    if case .custom(let name) = params.item.action, name == "corvin_mic" {
                        MicKeyContent(pttController: ptt)
                    } else {
                        params.view
                    }
                },
                buttonView: { params in
                    if case .custom(let name) = params.item.action, name == "corvin_mic" {
                        MicKeyButton(pttController: ptt)
                    } else {
                        params.view
                    }
                },
                collapsedView: { $0.view },
                emojiKeyboard: { $0.view },
                toolbar: { _ in EmptyView() }
            )
        }
    }
}

/// Content inside the mic key button
struct MicKeyContent: View {
    @ObservedObject var pttController: PTTController

    var body: some View {
        if pttController.isTranscribing {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(0.6)
        } else {
            Image(systemName: pttController.isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white)
        }
    }
}

/// Full mic key button with background
struct MicKeyButton: View {
    @ObservedObject var pttController: PTTController

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(buttonColor)

            MicKeyContent(pttController: pttController)

            // Recording duration badge
            if pttController.isRecording {
                Text(String(format: "%.0f", pttController.recordingDuration))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(3)
                    .offset(x: 16, y: -16)
            }
        }
        .aspectRatio(1, contentMode: .fit)  // Square aspect ratio
        .padding(5)  // Match standard button insets
        .contentShape(Rectangle())  // Make entire area tappable
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pttController.isRecording && !pttController.isTranscribing && pttController.lastError == nil {
                        pttController.startRecording()
                    }
                }
                .onEnded { _ in
                    if pttController.isRecording {
                        pttController.stopRecording()
                    }
                    if pttController.lastError != nil {
                        pttController.lastError = nil
                    }
                }
        )
    }

    private var buttonColor: Color {
        if pttController.isRecording {
            return .red
        } else if pttController.isTranscribing {
            return .orange
        } else if pttController.lastError != nil {
            return .orange
        } else {
            return .blue
        }
    }
}
