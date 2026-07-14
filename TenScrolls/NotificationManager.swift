import Foundation
import UserNotifications
import Combine

/// Owns the app's local-notification scheduling and acts as the notification-center
/// delegate. It schedules two kinds of notifications per session:
///
///  - a **daily repeating reminder** at the chosen time, and
///  - a one-shot **escalation "call"** at `time + callTimeoutMinutes`, added only when
///    the session is still incomplete. The call is what surfaces the full-screen
///    incoming-call screen.
///
/// iOS cannot launch a CallKit-style full-screen UI from the background for a local
/// notification (that path is reserved for VoIP + PushKit). So the escalation is a
/// loud, time-sensitive notification; tapping it (or opening the app) presents the
/// in-app incoming-call screen via the callbacks below.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {

    /// Called when a "call" escalation is tapped, or delivered while the app is
    /// foregrounded. The store turns this into a full-screen incoming-call screen.
    var onIncomingCall: ((Session) -> Void)?
    /// Called when an ordinary reminder is tapped — used to route to the Today tab.
    var onReminderTap: ((Session) -> Void)?

    private let center = UNUserNotificationCenter.current()

    func registerDelegate() {
        center.delegate = self
        
        let acceptAction = UNNotificationAction(identifier: "accept", title: "Accept", options: .foreground)
        let declineAction = UNNotificationAction(identifier: "decline", title: "Decline", options: .destructive)
        let callCategory = UNNotificationCategory(identifier: "call", actions: [acceptAction, declineAction], intentIdentifiers: [], options: [])
        
        center.setNotificationCategories([callCategory])
    }

    // MARK: - Authorization

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    // MARK: - Scheduling

    /// Rebuilds the full pending-notification set from the current prefs. `doneSessions`
    /// are the sessions already completed today — their escalation calls are skipped.
    func reschedule(prefs: NotificationPrefs, doneSessions: Set<Session>) {
        center.removeAllPendingNotificationRequests()
        guard prefs.enabled else { return }

        for session in Session.allCases {
            guard let (hour, minute) = parseTime(prefs.time(for: session)) else { continue }

            // Daily repeating reminder.
            let reminder = UNMutableNotificationContent()
            reminder.title = "Ten Scrolls — \(session.label)"
            reminder.body = session.reminderBody
            reminder.sound = .default
            reminder.userInfo = ["session": session.rawValue, "type": "reminder"]
            var comps = DateComponents()
            comps.hour = hour
            comps.minute = minute
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
            center.add(UNNotificationRequest(identifier: reminderID(session), content: reminder, trigger: trigger))

            // One-shot escalation call — only if the session isn't already done today.
            guard prefs.callEnabled, !doneSessions.contains(session) else { continue }
            let fireDate = nextDate(hour: hour, minute: minute, plusMinutes: prefs.callTimeoutMinutes)
            let call = UNMutableNotificationContent()
            call.title = "\(session.label) reading — incoming call"
            call.body = "You haven't finished your \(session.label) reading. Tap to answer."
            call.sound = .defaultCritical // full-volume if the Critical Alerts entitlement is present; otherwise degrades to default
            call.userInfo = ["session": session.rawValue, "type": "call"]
            call.interruptionLevel = .timeSensitive
            call.categoryIdentifier = "call"
            let callComps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: fireDate)
            let callTrigger = UNCalendarNotificationTrigger(dateMatching: callComps, repeats: false)
            center.add(UNNotificationRequest(identifier: callID(session), content: call, trigger: callTrigger))
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        // A call arriving while the app is open should present the call screen directly,
        // not a banner. Reminders show a normal banner.
        if (info["type"] as? String) == "call" {
            if let raw = info["session"] as? String, let session = Session(rawValue: raw) {
                onIncomingCall?(session)
            }
            return []
        }
        return [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let raw = info["session"] as? String, let session = Session(rawValue: raw) else { return }

        // If the user tapped the "Decline" button on the lock screen, do nothing.
        // iOS will dismiss the notification automatically and the app stays in the background.
        if response.actionIdentifier == "decline" {
            return
        }
        
        if (info["type"] as? String) == "call" {
            onIncomingCall?(session)
        } else {
            onReminderTap?(session)
        }
    }

    // MARK: - Helpers

    private func reminderID(_ session: Session) -> String { "reminder-\(session.rawValue)" }
    private func callID(_ session: Session) -> String { "call-\(session.rawValue)" }
    
    /// Cancel the escalation call for a specific session. Called when a session
    /// is completed to prevent the call from firing later.
    func cancelEscalationCall(for session: Session) {
        center.removePendingNotificationRequests(withIdentifiers: [callID(session)])
    }

    private func parseTime(_ string: String) -> (hour: Int, minute: Int)? {
        let parts = string.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        return (hour, minute)
    }

    /// The next future occurrence of `hour:minute` shifted by `plusMinutes`.
    private func nextDate(hour: Int, minute: Int, plusMinutes: Int) -> Date {
        let calendar = Calendar.current
        let now = Date()
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        var fire = calendar.date(from: comps) ?? now
        fire = calendar.date(byAdding: .minute, value: plusMinutes, to: fire) ?? fire
        if fire <= now {
            fire = calendar.date(byAdding: .day, value: 1, to: fire) ?? fire
        }
        return fire
    }
}
