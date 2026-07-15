import Foundation
import AlarmKit
import AppIntents
import UserNotifications
import SwiftUI
import Combine

// MARK: - Metadata passed into the Live Activity / alert

struct ScrollAlarmMetadata: AlarmMetadata {
    var sessionId: String   // Session.rawValue ("dawn" / "midday" / "dusk")
    var isEscalationCall: Bool
}

// MARK: - App Intents fired from the alert's buttons

/// Fired by the "Open the app" secondary button.
struct OpenScrollSessionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Open Ten Scrolls"
    static var openAppWhenRun: Bool = true
    static var isDiscoverable: Bool = false  // Not a user-facing shortcut

    @Parameter(title: "Session")
    var sessionId: String

    init() {}
    init(sessionId: String) { self.sessionId = sessionId }

    func perform() async throws -> some IntentResult {
        // Stash which session was tapped so the app can route to it on launch.
        UserDefaults.standard.set(sessionId, forKey: AlarmScheduler.pendingSessionDefaultsKey)
        return .result()
    }
}

/// Fired by the stop button. AlarmKit stops the alarm itself, but hooking it
/// lets us cancel a pending escalation call.
struct StopScrollSessionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Alarm"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false  // Not a user-facing shortcut

    @Parameter(title: "Session")
    var sessionId: String

    init() {}
    init(sessionId: String) { self.sessionId = sessionId }

    func perform() async throws -> some IntentResult {
        await AlarmScheduler.shared.handleStop(sessionId: sessionId)
        return .result()
    }
}

// MARK: - AppShortcuts Provider (for intent registration)

@available(iOS 26, *)
struct TenScrollsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // Empty - our intents are only used internally by AlarmKit
        // But this provider ensures the intents are registered with the system
        return []
    }
}

// MARK: - AlarmScheduler

/// Drop-in replacement for the old `store.notifier` calendar-notification
/// scheduling. Mirrors the same surface (`authorizationStatus`, prefs-driven
/// rescheduling) but rings through AlarmKit on iOS 26+.
///
/// The old `NotificationManager` is kept for pre-iOS 26 fallback — see
/// `AppStore` for the `#available` branching.
@available(iOS 26, *)
@MainActor
final class AlarmScheduler: ObservableObject {
    static let shared = AlarmScheduler()
    nonisolated static let pendingSessionDefaultsKey = "TenScrolls.pendingSessionFromAlarm"

    @Published var authorizationState: AlarmManager.AuthorizationState = .notDetermined

    private let defaults = UserDefaults.standard
    private func idKey(_ session: Session, call: Bool = false) -> String {
        "TenScrolls.alarmID.\(session.rawValue)\(call ? ".call" : "")"
    }
    
    // Helper: daily recurrence requires all seven weekdays
    private static let everyDay: Alarm.Schedule.Relative.Recurrence =
        .weekly([.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday])

    private init() {}

    // MARK: Authorization

    func refreshAuthorizationState() async {
        authorizationState = AlarmManager.shared.authorizationState
    }

    /// Call this once, e.g. when the user flips the master "Reminders" toggle on.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        // VERIFY: AlarmManager.shared.authorizationState type & cases
        switch AlarmManager.shared.authorizationState {
        case .authorized:
            authorizationState = .authorized
            return true
        case .notDetermined:
            do {
                let state = try await AlarmManager.shared.requestAuthorization()
                authorizationState = state
                return state == .authorized
            } catch {
                return false
            }
        case .denied:
            authorizationState = .denied
            return false
        @unknown default:
            return false
        }
    }

    // MARK: Full reschedule from prefs

    /// Call this any time `NotificationPrefs` changes (master toggle, a time
    /// picker, or the escalation-call toggle/timeout), and any time today's
    /// session completions change.
    ///
    /// `doneSessions` are the sessions already completed today — their escalation
    /// "call" alarms are skipped, mirroring `NotificationManager.reschedule(prefs:doneSessions:)`.
    /// Without this, a completed session would still ring its "missed" call later.
    func reschedule(from prefs: NotificationPrefs, doneSessions: Set<Session> = []) async {
        await cancelAll()

        guard prefs.enabled else { return }
        guard await requestAuthorizationIfNeeded() else { return }

        for session in Session.allCases {
            let hhmm = prefs.time(for: session)
            do {
                let alarmID = try await scheduleSession(session, hhmm: hhmm)
                defaults.set(alarmID.uuidString, forKey: idKey(session))

                if prefs.callEnabled, !doneSessions.contains(session) {
                    let callID = try await scheduleEscalationCall(
                        for: session,
                        hhmm: hhmm,
                        afterMinutes: prefs.callTimeoutMinutes
                    )
                    defaults.set(callID.uuidString, forKey: idKey(session, call: true))
                }
            } catch {
                print("AlarmScheduler: failed to schedule \(session): \(error)")
            }
        }
    }

    func cancelAll() async {
        for session in Session.allCases {
            await cancel(idKey(session))
            await cancel(idKey(session, call: true))
        }
    }

    private func cancel(_ key: String) async {
        guard let raw = defaults.string(forKey: key), let id = UUID(uuidString: raw) else { return }
        // cancel(id:) is a throwing call, wrapped with try?
        _ = try? AlarmManager.shared.cancel(id: id)
        defaults.removeObject(forKey: key)
    }

    // MARK: Building a single alarm

    @discardableResult
    private func scheduleSession(_ session: Session, hhmm: String) async throws -> UUID {
        let (hour, minute) = Self.parse(hhmm)

        let time = Alarm.Schedule.Relative.Time(hour: hour, minute: minute)
        let schedule = Alarm.Schedule.Relative(time: time, repeats: Self.everyDay)

        let openButton = AlarmButton(
            text: "Open the app",
            textColor: .black,
            systemImageName: "arrow.right"
        )

        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: "\(session.label) Reading"),
            secondaryButton: openButton,
            secondaryButtonBehavior: .custom
        )

        let attributes = AlarmAttributes<ScrollAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: ScrollAlarmMetadata(sessionId: session.rawValue, isEscalationCall: false),
            tintColor: Color.brassDefault
        )

        let id = UUID()
        let openIntent = OpenScrollSessionIntent(sessionId: session.rawValue)
        let stopIntent = StopScrollSessionIntent(sessionId: session.rawValue)

        // secondaryIntent is part of AlarmConfiguration initializer
        // stopIntent wired explicitly to ensure escalation-call cancellation works
        _ = try await AlarmManager.shared.schedule(
            id: id,
            configuration: .init(
                schedule: .relative(schedule),
                attributes: attributes,
                stopIntent: stopIntent,
                secondaryIntent: openIntent
            )
        )
        return id
    }

    /// A second, later alarm that only fires if the first one's stop button
    /// was never tapped. We schedule it eagerly alongside the main alarm and
    /// cancel it from `handleStop` if the user responds in time.
    ///
    /// IMPORTANT: This uses an absolute (one-time) schedule, not a repeating one.
    /// The escalation is meant to fire only once per day, specific to today's
    /// session. A repeating schedule would cause it to ring every day at that time,
    /// creating unwanted alarms.
    @discardableResult
    private func scheduleEscalationCall(for session: Session, hhmm: String, afterMinutes: Int) async throws -> UUID {
        let (hour, minute) = Self.parse(hhmm)
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        let base = Calendar.current.nextDate(after: Date(), matching: comps, matchingPolicy: .nextTime) ?? Date()
        let escalated = base.addingTimeInterval(TimeInterval(afterMinutes * 60))

        // Use absolute schedule (one-time) instead of relative (repeating)
        let schedule = Alarm.Schedule.Absolute(date: escalated)

        let openButton = AlarmButton(text: "Open the app", textColor: .black, systemImageName: "arrow.right")

        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: "Missed \(session.label) — calling you back"),
            secondaryButton: openButton,
            secondaryButtonBehavior: .custom
        )

        let attributes = AlarmAttributes<ScrollAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: ScrollAlarmMetadata(sessionId: session.rawValue, isEscalationCall: true),
            tintColor: Color.brassDefault
        )

        let id = UUID()
        let openIntent = OpenScrollSessionIntent(sessionId: session.rawValue)
        let stopIntent = StopScrollSessionIntent(sessionId: session.rawValue)

        // secondaryIntent is part of AlarmConfiguration initializer
        // stopIntent wired explicitly to ensure escalation-call cancellation works
        _ = try await AlarmManager.shared.schedule(
            id: id,
            configuration: .init(
                schedule: .absolute(schedule),
                attributes: attributes,
                stopIntent: stopIntent,
                secondaryIntent: openIntent
            )
        )
        return id
    }

    // MARK: Stop handling

    /// Called from `StopScrollSessionIntent`. If a session was completed,
    /// cancel that session's escalation call so it doesn't ring later.
    func handleStop(sessionId: String) async {
        guard let session = Session(rawValue: sessionId) else { return }
        await cancel(idKey(session, call: true))
    }

    // MARK: Helpers

    private static func parse(_ hhmm: String) -> (Int, Int) {
        let parts = hhmm.split(separator: ":")
        let h = Int(parts.first ?? "7") ?? 7
        let m = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        return (h, m)
    }
}

// MARK: - Convenience

extension Color {
    /// Fallback tint if a theme-driven brass color isn't available in this
    /// scope (AlarmAttributes needs a concrete Color at schedule time).
    static let brassDefault = Color(red: 0.72, green: 0.58, blue: 0.30)
}