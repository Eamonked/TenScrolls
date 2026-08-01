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
    /// Called when a cheer push notification is acknowledged — either by
    /// tapping the "Got it" action, or by opening the app via the
    /// notification's default tap. `cheerId` is threaded through as a String
    /// since `UNNotification` userInfo values must be property-list types.
    var onCheerAcknowledged: ((String) -> Void)?
    /// Called when a scroll-share push arrives while the app is foregrounded,
    /// or is tapped/opened from the background. Unlike cheers this needs no
    /// explicit acknowledgment — it just means "go refetch pending shares",
    /// since the push itself carries no local state to reconcile.
    var onShareReceived: (() -> Void)?

    private let center = UNUserNotificationCenter.current()

    func registerDelegate() {
        center.delegate = self
        
        let acceptAction = UNNotificationAction(identifier: "accept", title: "Accept", options: .foreground)
        let declineAction = UNNotificationAction(identifier: "decline", title: "Decline", options: .destructive)
        let callCategory = UNNotificationCategory(identifier: "call", actions: [acceptAction, declineAction], intentIdentifiers: [], options: [])

        // A cheer push needs an explicit acknowledgment, not just delivery —
        // "Got it" lets the recipient confirm receipt without opening the app.
        let gotItAction = UNNotificationAction(identifier: "got-it", title: "Got it", options: [])
        let cheerCategory = UNNotificationCategory(identifier: "cheer", actions: [gotItAction], intentIdentifiers: [], options: [])

        // A share push just needs to route the recipient to the Caravan tab
        // with fresh data — no explicit ack, unlike cheers.
        let viewAction = UNNotificationAction(identifier: "view", title: "View", options: [.foreground])
        let shareCategory = UNNotificationCategory(identifier: "share", actions: [viewAction], intentIdentifiers: [], options: [])

        center.setNotificationCategories([callCategory, cheerCategory, shareCategory])
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
            guard let (hour, minute) = TimeUtils.parseHHmm(prefs.time(for: session)) else { continue }

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
        // not a banner. Reminders and cheers show a normal banner.
        if (info["type"] as? String) == "call" {
            if let raw = info["session"] as? String, let session = Session(rawValue: raw) {
                onIncomingCall?(session)
            }
            return []
        }
        // A share push landing while the app is already open won't otherwise
        // trigger a refetch — there's no tap/response event in that case, so
        // this is the only hook that fires. Still shows the normal banner.
        if (info["type"] as? String) == "share" {
            onShareReceived?()
        }
        return [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo

        // Cheer pushes come from APNs directly (not scheduled locally), so
        // they carry `cheer_id`/`type` at the top level rather than a
        // `session` key. Any interaction with a cheer notification — tapping
        // the banner itself or the explicit "Got it" action — counts as
        // acknowledgment; only a bare dismissal (swipe-away) does not fire
        // `didReceive` at all, so acknowledgment stays opt-in to an actual tap.
        if (info["type"] as? String) == "cheer", let cheerId = info["cheer_id"] as? String {
            onCheerAcknowledged?(cheerId)
            return
        }

        // Share pushes: tapping the banner or the "View" action both just
        // mean "take me to the Caravan tab with fresh pending shares" —
        // there's no per-action branching like decline/got-it since a share
        // has no negative response to distinguish.
        if (info["type"] as? String) == "share" {
            onShareReceived?()
            return
        }

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
