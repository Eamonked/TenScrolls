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

@main
struct TenScrollsApp: App {
    @StateObject private var store = AppStore()
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    store.handleIncomingURL(url)
                }
        }
    }
}
