import SwiftUI

/// Status strip above the keyboard.
///
/// This is the only place the extension can tell the user *why* dictation is not working —
/// the mic key alone just turns orange, which is indistinguishable from "transcribing".
struct CorvinToolbarView: View {
    @ObservedObject var pttController: PTTController

    var body: some View {
        HStack(spacing: 8) {
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(height: 44)
    }

    @ViewBuilder
    private var content: some View {
        if pttController.isRecording {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                Text(String(format: "%.1fс", pttController.recordingDuration))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.red.opacity(0.8))
            .cornerRadius(12)

            Text("Отпустите для транскрипции")
                .font(.caption)
                .foregroundColor(.secondary)
        } else if pttController.isStarting {
            ProgressView()
                .scaleEffect(0.7)
            Text("Подключение к Corvin…")
                .font(.caption)
                .foregroundColor(.secondary)
        } else if pttController.isTranscribing {
            ProgressView()
                .scaleEffect(0.7)
            Text("Транскрипция…")
                .font(.caption)
                .foregroundColor(.secondary)
        } else if let error = pttController.lastError {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.caption)
            Text(error)
                .font(.caption)
                .foregroundColor(.orange)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            EmptyView()
        }
    }
}
