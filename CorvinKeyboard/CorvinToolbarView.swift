import SwiftUI

struct CorvinToolbarView: View {
    @ObservedObject var pttController: PTTController

    var body: some View {
        HStack(spacing: 12) {
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
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.8))
                .cornerRadius(12)

                Spacer()

                Text("Отпустите для транскрипции")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if pttController.isTranscribing {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Транскрипция...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let error = pttController.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .lineLimit(3)
            } else {
                Spacer()
            }

            Spacer()

            // Mic PTT button — hold to record, release to transcribe
            Image(systemName: pttController.isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 18))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(pttController.isRecording ? Color.red : (pttController.lastError != nil ? Color.orange : Color.blue))
                .clipShape(Circle())
                .accessibilityIdentifier("corvin_mic_button")
                .accessibilityLabel("Микрофон")
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            // Don't retry if there was an error (prevents spam)
                            if !pttController.isRecording && pttController.lastError == nil {
                                pttController.startRecording()
                            }
                        }
                        .onEnded { _ in
                            if pttController.isRecording {
                                pttController.stopRecording()
                            }
                            // Clear error on gesture end so next tap can try again
                            if pttController.lastError != nil {
                                pttController.lastError = nil
                            }
                        }
                )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: 44)
    }
}
