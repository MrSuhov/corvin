import SwiftUI

extension View {
    /// "Connect the dictionary?" for a pairing link — from the camera through
    /// `corvin://sync-pair`, or pasted on the dictionary screen. Pairing is
    /// never silent: a link alone must not join this phone to someone's group.
    func syncPairingConfirmation(invite: Binding<SyncPairing.Invite?>) -> some View {
        alert("dictation.sync.confirm.title".localized,
              isPresented: Binding(get: { invite.wrappedValue != nil },
                                   set: { if !$0 { invite.wrappedValue = nil } }),
              presenting: invite.wrappedValue) { pending in
            Button("dictation.sync.confirm.ok".localized) { DictionarySync.shared.pair(with: pending) }
            Button("common.cancel".localized, role: .cancel) {}
        } message: { pending in
            Text("dictation.sync.confirm.message".localized(
                with: pending.deviceName.isEmpty ? "Mac" : pending.deviceName))
        }
    }
}
