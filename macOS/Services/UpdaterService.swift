import AppKit
import Combine
import Sparkle

/// Update handling for a menubar agent.
///
/// Sparkle's own UI is not used at all. `SPUStandardUpdaterController` brings
/// two problems for an `LSUIElement` app: its scheduler opens the release-notes
/// window unprompted, and every window it opens appears *behind* everything else
/// because an accessory app is never activated — with no Dock icon and no
/// Cmd-Tab entry, there is then no way to reach it.
///
/// So this class is the `SPUUserDriver`: every "show something" callback is
/// either a no-op or answered automatically. The whole update lives in the
/// status bar instead — a dot on the icon when a version is found, a menu item
/// that starts the update, and progress reported back into that same item.
/// Nothing is ever asked twice: clicking "Обновить" is the consent.
final class UpdaterService: NSObject, ObservableObject, SPUUpdaterDelegate, SPUUserDriver {
    static let shared = UpdaterService()

    /// Display version of a pending update, nil while up to date. Drives the
    /// status bar badge and the menu item.
    @Published private(set) var pendingUpdateVersion: String?

    /// Non-nil while an update is being fetched or installed.
    @Published private(set) var progress: Progress?

    enum Progress: Equatable {
        case starting
        case downloading(fraction: Double?)
        case extracting(fraction: Double)
        case installing
    }

    private static let defaultProbeInterval: TimeInterval = 86400
    private static let minimumProbeInterval: TimeInterval = 3600

    /// Don't hit the network the instant the app launches — the model warm-up is
    /// already competing for resources at that point.
    private static let firstProbeDelay: TimeInterval = 15

    private var updater: SPUUpdater!
    private var probeTimer: Timer?

    private var expectedDownloadBytes: UInt64 = 0
    private var receivedDownloadBytes: UInt64 = 0

    private override init() {
        super.init()

        updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: self,
            delegate: self
        )

        do {
            try updater.start()
        } catch {
            flog("updater: FAILED to start Sparkle: \(error)")
        }

        // Sparkle's scheduler would surface updates on its own timetable and in
        // its own UI. Probing is driven from here instead. Written through the
        // updater rather than left to Info.plist because a build that once
        // shipped with automatic checks on has the old value persisted in
        // UserDefaults, where it would outrank the plist.
        updater.automaticallyChecksForUpdates = false

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

    /// Checks the appcast without starting an update. Results arrive via the
    /// `SPUUpdaterDelegate` callbacks below.
    func probeForUpdate() {
        guard updater.canCheckForUpdates else {
            flog("updater: probe skipped, a session is already running")
            return
        }
        flog("updater: probing appcast")
        updater.checkForUpdateInformation()
    }

    // MARK: - Menu actions

    /// Wired to "Проверить обновления…" — silent, no window, no app activation.
    @objc func checkForUpdatesInBackground(_ sender: Any?) {
        probeForUpdate()
    }

    /// Wired to "Обновить до …". Downloads and installs without asking again;
    /// the app relaunches itself when it's done.
    @objc func installUpdate(_ sender: Any?) {
        guard updater.canCheckForUpdates else {
            flog("updater: install requested but a session is already running")
            return
        }
        flog("updater: installing \(pendingUpdateVersion ?? "?")")
        setProgress(.starting)
        updater.checkForUpdates()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdatesInBackground(_:))
            || item.action == #selector(installUpdate(_:)) {
            return updater.canCheckForUpdates
        }
        return true
    }

    private func setProgress(_ value: Progress?) {
        DispatchQueue.main.async { self.progress = value }
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        flog("updater: found version \(item.displayVersionString)")
        DispatchQueue.main.async { self.pendingUpdateVersion = item.displayVersionString }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        flog("updater: no update available")
        DispatchQueue.main.async {
            self.pendingUpdateVersion = nil
            self.progress = nil
        }
    }

    // MARK: - SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Automatic checks stay off; Corvin drives its own probing.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        setProgress(.starting)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        // The user already chose by clicking "Обновить" — don't ask again.
        flog("updater: proceeding with \(appcastItem.displayVersionString)")
        DispatchQueue.main.async { self.pendingUpdateVersion = appcastItem.displayVersionString }
        reply(.install)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        flog("updater: no update found")
        DispatchQueue.main.async {
            self.pendingUpdateVersion = nil
            self.progress = nil
        }
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        flog("updater: ERROR \(error.localizedDescription)")
        setProgress(nil)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedDownloadBytes = 0
        receivedDownloadBytes = 0
        setProgress(.downloading(fraction: nil))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedDownloadBytes = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedDownloadBytes += length
        let fraction = expectedDownloadBytes > 0
            ? min(1, Double(receivedDownloadBytes) / Double(expectedDownloadBytes))
            : nil
        setProgress(.downloading(fraction: fraction))
    }

    func showDownloadDidStartExtractingUpdate() {
        setProgress(.extracting(fraction: 0))
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        setProgress(.extracting(fraction: progress))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // This is the "Установить и перезапустить" prompt in Sparkle's own UI.
        // Installing straight away is the whole point of driving it ourselves.
        flog("updater: installing and relaunching")
        setProgress(.installing)
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        setProgress(.installing)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        flog("updater: installed, relaunched=\(relaunched)")
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        setProgress(nil)
    }
}
