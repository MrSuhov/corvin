import XCTest

/// Captures App Store screenshots from a real device.
///
/// Screenshots are attached to the test result bundle; pull them out with
///   xcrun xcresulttool export attachments --path <bundle>.xcresult --output-path <dir>
///
/// Run against a connected device:
///   xcodebuild test -project Corvin.xcodeproj -scheme CorviniOS \
///     -destination 'id=<device udid>' \
///     -only-testing:CorvinUITests/AppStoreScreenshotTests \
///     -resultBundlePath /tmp/CorvinShots.xcresult
///
/// The device screen must be unlocked, and onboarding already completed —
/// otherwise the first screenshot captures the onboarding flow instead of the app.
final class AppStoreScreenshotTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.corvinvoice.ios")
        app.launch()
        // The app rebuilds its PiP layer and IPC listener on launch; give the UI
        // a moment so the status rows show their settled state rather than spinners.
        sleep(3)
    }

    func testCaptureAppStoreScreenshots() throws {
        capture(named: "01-record")

        for (tab, name) in [("Модели", "02-models"),
                            ("Настройки", "03-settings"),
                            ("История", "04-history")] {
            let button = app.tabBars.buttons[tab]
            guard button.waitForExistence(timeout: 10) else {
                XCTFail("tab \(tab) not found — tab bar labels may have changed")
                return
            }
            button.tap()
            sleep(2)
            capture(named: name)
        }

        // Back to the main tab so the device is left in a sane state.
        app.tabBars.buttons["Запись"].tap()
    }

    private func capture(named name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
