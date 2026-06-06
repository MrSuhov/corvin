import SwiftUI

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        flog("AppDelegate: handleEventsForBackgroundURLSession \(identifier)")
        // Store the completion handler to be called when all events are processed
        BackgroundSessionManager.shared.backgroundCompletionHandler = completionHandler
    }
}

/// Manages background session completion handlers
class BackgroundSessionManager {
    static let shared = BackgroundSessionManager()
    var backgroundCompletionHandler: (() -> Void)?

    func callCompletionHandlerIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            if let handler = self?.backgroundCompletionHandler {
                flog("BackgroundSessionManager: calling completion handler")
                handler()
                self?.backgroundCompletionHandler = nil
            }
        }
    }
}

@main
struct CorviniOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = iOSAppState()

    var body: some Scene {
        WindowGroup {
            if appState.onboardingCompleted {
                MainView()
                    .environmentObject(appState.sessionManager)
                    .environmentObject(appState.modelManager)
                    .environmentObject(appState.historyStore)
                    .environmentObject(appState)
                    .onOpenURL { url in
                        appState.transcribeFile(url: url)
                    }
            } else {
                iOSOnboardingView(onComplete: {
                    appState.onboardingCompleted = true
                })
                .environmentObject(appState.modelManager)
            }
        }
    }
}
