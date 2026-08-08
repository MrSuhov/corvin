import AppKit
import Combine
import Sparkle

/// Thin wrapper around Sparkle's standard updater controller.
///
/// Sparkle's own scheduler is turned off: when it finds an update it pops the
/// release-notes window unprompted, which is wrong for a menubar agent. Instead
/// this service runs `checkForUpdateInformation()` on a timer — a silent probe
/// that only notifies the delegate — and surfaces the result as a dot on the
/// status bar icon plus an "Обновить" menu item. The full Sparkle UI appears
/// only once the user asks for it.
///
/// Distribution is Developer ID + notarization (no sandbox), so no XPC installer
/// service is required — Sparkle updates the app in place.
final class UpdaterService: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdaterService()

    /// Display version of a pending update, nil while up to date. Drives the
    /// status bar badge and the menu.
    @Published private(set) var pendingUpdateVersion: String?

    /// Sparkle's scheduler, if left on, shows its own window on a found update.
    private static let defaultProbeInterval: TimeInterval = 86400
    private static let minimumProbeInterval: TimeInterval = 3600

    /// Don't hit the network the instant the app launches — the model warm-up is
    /// already competing for resources at that point.
    private static let firstProbeDelay: TimeInterval = 15

    private var controller: SPUStandardUpdaterController!
    private var probeTimer: Timer?

    private override init() {
        super.init()

        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        // Written through the updater rather than left to Info.plist: a build
        // that once shipped with automatic checks on has the old value
        // persisted in UserDefaults, where it would win over the plist.
        controller.updater.automaticallyChecksForUpdates = false

        startProbing()
    }

    // MARK: - Silent probing

    private var probeInterval: TimeInterval {
        let configured = Bundle.main.object(forInfoDictionaryKey: "SUScheduledCheckInterval") as? TimeInterval
        return max(Self.minimumProbeInterval, configured ?? Self.defaultProbeInterval)
    }

    private func startProbing() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstProbeDelay) { [weak self] in
            self?.probeForUpdate()
        }

        probeTimer = Timer.scheduledTimer(withTimeInterval: probeInterval, repeats: true) { [weak self] _ in
            self?.probeForUpdate()
        }

        // A repeating Timer doesn't fire while the Mac is asleep, so a laptop
        // that's closed overnight would skip its daily check entirely.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.probeForUpdate()
        }
    }

    /// Checks the appcast without showing any UI. Results arrive via the
    /// delegate callbacks below.
    func probeForUpdate() {
        guard controller.updater.canCheckForUpdates else {
            flog("updater: probe skipped, a check is already running")
            return
        }
        flog("updater: probing appcast")
        controller.updater.checkForUpdateInformation()
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        flog("updater: found version \(item.displayVersionString)")
        DispatchQueue.main.async { self.pendingUpdateVersion = item.displayVersionString }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        flog("updater: no update available")
        DispatchQueue.main.async { self.pendingUpdateVersion = nil }
    }

    // MARK: - Menu actions

    /// Wired to both "Проверить обновления…" and "Обновить": in either case
    /// Sparkle re-fetches the appcast and presents its standard window, from
    /// which the user confirms the download and install.
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
