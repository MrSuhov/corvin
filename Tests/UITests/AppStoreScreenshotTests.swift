import XCTest

/// Captures App Store screenshots.
///
/// Runs against the **simulator**, not a device. On a device the keep-alive
/// Picture-in-Picture window sits on top of every frame, so each capture would
/// carry a stray video overlay; switching the background mode off just to take
/// screenshots changes what the app looks like in a way that is not worth
/// automating. The simulator has no PiP at all, which is exactly what we want.
///
/// Drive it through `scripts/screenshots-appstore.sh`, which seeds a realistic
/// state (model installed, history populated, Corvin enabled as a keyboard)
/// before running. Screenshots are attached to the test result bundle; the
/// script exports and renames them.
final class AppStoreScreenshotTests: XCTestCase {

    private var app: XCUIApplication!

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.corvinvoice.ios")
        app.launch()
        // Loading the whisper model and standing the IPC listener back up both
        // happen on launch; without this the first capture catches spinners.
        sleep(5)
    }

    /// The keyboard is the product, so it leads. The history tab's search field
    /// is the only text input inside the app, which saves the capture from
    /// having to drive Safari or Notes.
    func testCaptureKeyboard() throws {
        // The globe is tapped by position: it belongs to the keyboard process
        // and its accessibility label is localised. The offsets are calibrated
        // per idiom against the bottom-left key of the system keyboard.
        try XCTSkipIf(isPad, "globe offset is calibrated for iPhone only")

        try tap(tab: "История")
        let search = app.searchFields.firstMatch
        guard search.waitForExistence(timeout: 15) else {
            XCTFail("history search field not found")
            return
        }
        search.tap()
        sleep(3)

        // The system keyboard comes up first; the globe key cycles to the next
        // installed one. .GlobalPreferences lists Corvin immediately after the
        // Russian keyboard, so a single tap lands on it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.067, dy: 0.958)).tap()

        // Nothing here can be waited on properly: the keys belong to the
        // keyboard process and are not exposed to this query tree, and
        // XCUIApplication reports no state for an app extension. So this is a
        // plain wait, sized for the worst case — the extension is launched on
        // demand and the first switch after an install cold-starts KeyboardKit,
        // which took over six seconds on a freshly booted simulator and caught
        // the system keyboard mid-switch.
        //
        // Check the captured file: Corvin's layout is the one with the blue
        // microphone key and the "RU" locale key next to "123".
        sleep(15)
        capture(named: "01-keyboard")
    }

    func testCaptureAppScreens() throws {
        try tap(tab: "Модели")
        capture(named: "02-models")

        try tap(tab: "История")
        capture(named: "03-history")

        try tap(tab: "Настройки")
        capture(named: "04-settings")

        // Opens scrolled to the top, where the setup instructions dominate; the
        // microphone further down is the better shot.
        //
        // On iPhone this screen also carries "PiP не поддерживается", which is
        // true of the simulator and only of the simulator — do not ship the
        // iPhone copy of this one. It is clean on iPad, where the content fits
        // without scrolling.
        try tap(tab: "Запись")
        let scroll = app.scrollViews.firstMatch
        scroll.swipeUp()
        scroll.swipeUp()
        sleep(1)
        capture(named: "05-record")
    }

    /// iPhone puts the tabs in a `tabBar`; iPadOS 26 floats them above the
    /// content, where they are plain buttons rather than tab-bar children.
    /// firstMatch throughout: iPadOS exposes each tab twice, and an ambiguous
    /// query refuses to tap.
    private func tap(tab: String) throws {
        let inTabBar = app.tabBars.buttons[tab].firstMatch
        if inTabBar.waitForExistence(timeout: 10) {
            inTabBar.tap()
        } else {
            let loose = app.buttons[tab].firstMatch
            guard loose.waitForExistence(timeout: 10) else {
                XCTFail("tab '\(tab)' not found — tab labels may have changed")
                return
            }
            loose.tap()
        }
        sleep(2)
    }

    private func capture(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
