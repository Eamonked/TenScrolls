import SwiftUI
import UIKit

/// Handles remote-notification registration plumbing that SwiftUI's `App`
/// protocol has no hook for. Forwards both outcomes to `AppStore` via
/// `NotificationCenter` so this stays a thin adapter rather than owning any
/// app state itself.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static let deviceTokenNotification = Notification.Name("DeviceTokenRegistered")

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        NotificationCenter.default.post(name: Self.deviceTokenNotification, object: token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Best-effort feature — no remote token means cheers just won't push;
        // in-app polling (`fetch_unacknowledged_cheers`) still covers it.
    }
}

/// Maps the user's in-app appearance choice to the value `.preferredColorScheme`
/// expects. `.system` must map to `nil` — that's the only way to tell
/// SwiftUI/UIKit "don't override anything, defer to the real system setting."
/// Passing `.light`/`.dark` here for the `.system` case (or hardcoding either
/// case outright) would re-break `@Environment(\.colorScheme)` for every
/// child view, including `AppearanceMode.resolved(systemColorScheme:)`.
private func preferredColorScheme(for mode: AppearanceMode) -> ColorScheme? {
    switch mode {
    case .system: return nil
    case .light: return .light
    case .dark: return .dark
    }
}

@main
struct TenScrollsApp: App {
    @StateObject private var store = AppStore()
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Surfaces a missing/mismatched App Group entitlement in the console
        // at launch, rather than as a silently-empty widget later — see
        // `WidgetStorage.logStartupDiagnostics`.
        WidgetStorage.logStartupDiagnostics(caller: "app")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(preferredColorScheme(for: store.state.appearanceMode))
                .onOpenURL { url in
                    store.handleIncomingURL(url)
                }
        }
    }
}
