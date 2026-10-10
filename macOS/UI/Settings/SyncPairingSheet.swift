import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

/// The pairing QR code: the iPhone camera opens the `corvin://sync-pair` link
/// in Corvin, which asks before joining. The link carries the group key, so
/// it is shown, never sent anywhere.
struct SyncPairingSheet: View {
    let invite: SyncPairing.Invite
    let onClose: () -> Void

    @State private var copied = false

    private var link: String { SyncPairing.url(for: invite).absoluteString }

    var body: some View {
        VStack(spacing: 14) {
            Text("dictation.sync.sheet.title".localized)
                .font(.headline)

            if let image = Self.qrImage(for: link) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .padding(10)
                    .background(Color.white)
            }

            Text("dictation.sync.sheet.message".localized)
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 320)

            HStack {
                Button(copied ? "common.copy".localized + " ✓" : "dictation.sync.copyLink".localized) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                    copied = true
                }
                Spacer()
                Button("common.done".localized, action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(width: 320)
        }
        .padding(24)
    }

    private static func qrImage(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: output.extent.size)
    }
}
