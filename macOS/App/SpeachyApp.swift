import SwiftUI

@main
struct CorvinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No visible scenes — all windows are managed by AppDelegate
        Settings {
            EmptyView()
        }
    }
}
