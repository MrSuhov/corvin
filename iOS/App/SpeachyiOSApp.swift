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
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some Scene {
        WindowGroup {
            // One `.id` at the root is the whole iOS refresh mechanism. `.localized`
            // resolves when a body runs, so a language change only shows up where
            // something re-renders; rebuilding here covers every screen and sheet,
            // including views that know nothing about localization.
            //
            // `appState` is a @StateObject on the App struct, i.e. outside this
            // subtree, so the rebuild does not restart the IPC server or reload
            // the whisper model.
            Group {
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
            .id(localization.currentLanguage)
        }
    }
}
