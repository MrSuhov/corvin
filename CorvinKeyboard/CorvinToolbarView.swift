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
                Text(String(format: "common.duration.seconds".localized, pttController.recordingDuration))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.red.opacity(0.8))
            .cornerRadius(12)

            Text("keyboard.status.releaseToTranscribe".localized)
                .font(.caption)
                .foregroundColor(.secondary)
        } else if pttController.isStarting {
            ProgressView()
                .scaleEffect(0.7)
            Text("keyboard.status.connecting".localized)
                .font(.caption)
                .foregroundColor(.secondary)
        } else if pttController.isTranscribing {
            ProgressView()
                .scaleEffect(0.7)
            Text("keyboard.status.transcribing".localized)
                .font(.caption)
                .foregroundColor(.secondary)
        } else if let error = pttController.lastError {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.caption)
            // A suspended host is the one error the user can fix from here, so
            // it gets a button instead of an instruction to go and do it by hand.
            if error == IPCError.hostAsleepMessage, pttController.canWakeHost {
                Text("keyboard.error.hostAsleep.short".localized)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .lineLimit(1)
                Button("keyboard.wake.button".localized) {
                    pttController.wakeHostApp()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .layoutPriority(1)
            } else {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            EmptyView()
        }
    }
}
