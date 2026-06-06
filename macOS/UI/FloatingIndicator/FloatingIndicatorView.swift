import SwiftUI

struct FloatingIndicatorView: View {
    let state: SessionState
    @ObservedObject var sessionManager: SessionManager
    @ObservedObject private var localization = LocalizationManager.shared
    @State private var pulseAnimation = false
    @State private var audioLevels: [CGFloat] = [0.3, 0.5, 0.7, 0.4, 0.6]
    @State private var animationTimer: Timer?

    var body: some View {
        HStack(spacing: 8) {
            stateIcon
            stateText
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 120, maxWidth: 200, minHeight: 44, maxHeight: 44)
        .modifier(BlurBackgroundCompat())
        .clipShape(Capsule())
        .id(localization.currentLanguage)
        .onAppear {
            if case .recording = state {
                startAnimations()
            }
        }
        .onDisappear {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch state {
        case .recording:
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .scaleEffect(pulseAnimation ? 1.3 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulseAnimation)

        case .transcribing:
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)

        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 14))

        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
                .font(.system(size: 14))

        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var stateText: some View {
        switch state {
        case .recording:
            HStack(spacing: 2) {
                // Audio waveform bars
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.red.opacity(0.8))
                        .frame(width: 3, height: audioLevels[i] * 20)
                }

                Text(formatDuration(sessionManager.recordingDuration))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
            }

        case .transcribing:
            Text("Распознаю...")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)

        case .done(let text):
            Text(String(text.prefix(30)))
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .lineLimit(1)

        case .error(let msg):
            Text(msg)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .lineLimit(1)

        default:
            EmptyView()
        }
    }

    private func startAnimations() {
        pulseAnimation = true
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
            for i in audioLevels.indices {
                audioLevels[i] = CGFloat.random(in: 0.2...1.0)
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
