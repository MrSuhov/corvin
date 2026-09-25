import AppKit

/// AppKit entry point. All windows are AppDelegate's own; there is no SwiftUI
/// `App`, because an `App` needs a scene, and the only one that opens nothing at
/// launch — an empty `Settings` — owned ⌘, and "Corvin → Settings…": they
/// opened its blank window, left behind once the real one was closed. The main
/// menu (`MainMenu`) now sends both to the real settings window.
@main
enum CorvinApp {
    /// `NSApplication.delegate` is weak.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.mainMenu = MainMenu.make(settingsTarget: delegate)
        app.run()
    }
}
