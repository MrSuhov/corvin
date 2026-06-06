import SwiftUI

struct MicButtonView: View {
    @ObservedObject var pttController: PTTController

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(buttonColor)
                .frame(width: 36, height: 36)

            // Icon
            if pttController.isTranscribing {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(0.7)
            } else {
                Image(systemName: pttController.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
            }

            // Recording duration badge
            if pttController.isRecording {
                Text(String(format: "%.0f", pttController.recordingDuration))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(4)
                    .offset(x: 14, y: -14)
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
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
