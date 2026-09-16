import SwiftUI

/// The floating pill while a call records: app, warning, both levels, elapsed
/// time and Stop.
struct CallIndicatorView: View {
    @ObservedObject var recorder: CallRecorder
    @ObservedObject private var localization = LocalizationManager.shared

    static let width: CGFloat = 300

    var body: some View {
        HStack(spacing: 8) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if let warning = recorder.warning {
                    Button(action: CallRecorder.openSystemAudioSettings) {
                        Text(warning.text)
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 4)
            if case .recording(_, let since) = recorder.state {
                levelBar(recorder.levels.me)
                levelBar(recorder.levels.other)
                Text(Self.elapsed(since: since))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                Button(action: recorder.stop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("call.indicator.stop".localized)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(width: Self.width, height: 44)
        .modifier(BlurBackgroundCompat())
        .clipShape(Capsule())
        .id(localization.currentLanguage)
    }

    private var title: String {
        switch recorder.state {
        case .recording(let app, _): return app.name
        case .starting: return "call.menu.starting".localized
        case .finishing: return "call.menu.finishing".localized
        case .failed(let message): return message.text
        case .idle: return ""
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch recorder.state {
        case .recording:
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
        case .starting, .finishing:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
                .font(.system(size: 14))
        case .idle:
            EmptyView()
        }
    }

    /// Speech RMS sits around 0.05–0.2; scaled so normal speech fills the bar.
    private func levelBar(_ rms: Float) -> some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.25))
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.red.opacity(0.8))
                .frame(height: CGFloat(min(1, rms * 6)) * 20)
        }
        .frame(width: 3, height: 20)
    }

    static func elapsed(since start: Date) -> String {
        let total = max(0, Int(Date().timeIntervalSince(start)))
        return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }
}
