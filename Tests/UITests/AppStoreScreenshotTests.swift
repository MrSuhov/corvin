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

        tap(tab: .history)
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
        tap(tab: .models)
        capture(named: "02-models")

        tap(tab: .history)
        capture(named: "03-history")

        tap(tab: .settings)
        capture(named: "04-settings")

        // Opens scrolled to the top, where the setup instructions dominate; the
        // microphone further down is the better shot.
        //
        // On iPhone this screen also carries "PiP не поддерживается", which is
        // true of the simulator and only of the simulator — do not ship the
        // iPhone copy of this one. It is clean on iPad, where the content fits
        // without scrolling.
        tap(tab: .record)
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 10), "record screen has no scroll view")
        scroll.swipeUp()
        scroll.swipeUp()
        sleep(1)
        capture(named: "05-record")
    }

    /// The tabs of `MainView`, in declaration order. The order is what actually
    /// selects them — see `tap(tab:)`.
    private enum Tab: String, CaseIterable {
        case record = "tab.record"
        case models = "tab.models"
        case settings = "tab.settings"
        case history = "tab.history"

        var position: Int { Self.allCases.firstIndex(of: self)! }
    }

    /// Tabs cannot be found by label — the labels are localized and this test
    /// runs once per language — and cannot be found by identifier either: the
    /// tab bar button is built by SwiftUI, and the identifier set on the
    /// `tabItem`'s `Image` does not reach it on iOS 26.1, where every button
    /// comes back with an empty identifier. Position is what is left, and it is
    /// stable: it is `MainView`'s declaration order.
    ///
    /// iPhone puts the tabs in a `tabBar`; iPadOS 26 floats them above the
    /// content, where they are plain buttons rather than tab-bar children, and
    /// where the identifier may well survive. Hence the two lookups.
    /// firstMatch throughout: iPadOS exposes each tab twice, and an ambiguous
    /// query refuses to tap.
    private func tap(tab: Tab) {
        let bar = app.tabBars.firstMatch
        let button: XCUIElement
        if bar.waitForExistence(timeout: 15), bar.buttons.count == Tab.allCases.count {
            button = bar.buttons.element(boundBy: tab.position)
        } else if app.buttons[tab.rawValue].firstMatch.waitForExistence(timeout: 5) {
            button = app.buttons[tab.rawValue].firstMatch
        } else {
            XCTFail("""
                tab '\(tab.rawValue)' not found.
                tabBars.buttons: \(describe(app.tabBars.buttons))
                buttons: \(describe(app.buttons))
                """)
            return
        }

        // A tap issued shortly after a screenshot is swallowed every few
        // attempts: the tab stays where it was, and the next capture then
        // silently repeats the previous screen — a run produced a
        // byte-identical 03-history/04-settings pair that way. So the tap is
        // not assumed to have landed; it is repeated until the tab reports
        // itself selected.
        for attempt in 1...4 {
            button.tap()
            if selected(button, within: 5) {
                sleep(1)  // let the content settle before it is photographed
                return
            }
            print("tab '\(tab.rawValue)': tap \(attempt) did not take, retrying")
        }
        XCTFail("tab '\(tab.rawValue)' would not select after 4 taps")
    }

    private func selected(_ element: XCUIElement, within timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isSelected { return true }
            usleep(250_000)
        }
        return element.isSelected
    }

    private func describe(_ query: XCUIElementQuery) -> String {
        query.allElementsBoundByIndex
            .map { "[id=\($0.identifier) label=\($0.label)]" }
            .joined(separator: " ")
    }

    private func capture(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
