import AppKit
import Sparkle

/// Thin wrapper around Sparkle's standard updater controller.
///
/// `SPUStandardUpdaterController` with `startingUpdater: true` kicks off the
/// background update schedule (governed by `SUEnableAutomaticChecks` /
/// `SUScheduledCheckInterval` in Info.plist) and provides the standard UI for
/// the "Check for Updates…" menu action.
///
/// Distribution is Developer ID + notarization (no sandbox), so no XPC installer
/// service is required — Sparkle updates the app in place.
final class UpdaterService: NSObject {
    static let shared = UpdaterService()

    private let controller: SPUStandardUpdaterController

    private override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    /// Wired to the "Check for Updates…" menu item.
    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }

    /// Disables the menu item while an update check can't be started (e.g. one is
    /// already in progress).
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdates(_:)) {
            return controller.updater.canCheckForUpdates
        }
        return true
    }
}
