import SwiftUI

/// What still has to come up before the app can hand the user back to whatever
/// they were typing in.
///
/// Shown only on the keyboard's wake path. Without it the user is looking at an
/// apparently idle screen while three separate things start behind it, with no
/// way to tell a slow cold launch from a hang.
struct WakeProgress {
    enum Stage {
        case waiting
        case returning
        /// Something never came up. We stay put rather than return into a suspension.
        case timedOut
        /// Ready, but there is no way to open the app they came from.
        case noReturnRoute
    }

    var listening = false
    var holdingBackground = false
    var modelLoaded = false
    var stage: Stage = .waiting
}

struct WakeProgressView: View {
    let progress: WakeProgress
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                Text("wake.title".localized)
                    .font(.headline)

                VStack(alignment: .leading, spacing: 12) {
                    step("wake.step.listening".localized, done: progress.listening)
                    step("wake.step.background".localized, done: progress.holdingBackground)
                    step("wake.step.model".localized, done: progress.modelLoaded)
                }

                footer
            }
            .padding(20)
            .frame(maxWidth: 340, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)
            .padding(24)
        }
    }

    private func step(_ title: String, done: Bool) -> some View {
        HStack(spacing: 10) {
            // Fixed width on both states, so the labels do not shift sideways
            // as each step finishes.
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            .frame(width: 22)

            Text(title)
                .font(.subheadline)
                .foregroundColor(done ? .secondary : .primary)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch progress.stage {
        case .waiting:
            EmptyView()
        case .returning:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.8)
                Text("wake.returning".localized)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        case .timedOut:
            explanation("wake.timedOut".localized)
        case .noReturnRoute:
            explanation("wake.noReturn".localized)
        }
    }

    private func explanation(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text)
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("wake.dismiss".localized, action: onDismiss)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}
