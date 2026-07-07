import Foundation

enum ScrollStatus: String, Codable {
    case locked, active, mastered
}

struct Scroll: Identifiable, Codable, Equatable {
    var id: Int
    var roman: String
    var title: String = ""
    var theme: String = ""
    var notes: String = ""
    var status: ScrollStatus
}

struct DayEntry: Codable, Equatable {
    var scrollId: Int
    var dawn: Bool = false
    var midday: Bool = false
    var dusk: Bool = false

    var allComplete: Bool { dawn && midday && dusk }
    var sessionCount: Int { [dawn, midday, dusk].filter { $0 }.count }
}

struct Habit: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var completedDates: [String] = []
}

// MARK: - Reading sessions & reminders

/// The three daily reading sessions. Backs both the day log and the reminder scheduler.
enum Session: String, Codable, CaseIterable, Identifiable {
    case dawn, midday, dusk
    var id: String { rawValue }

    var label: String {
        switch self {
        case .dawn: return "Dawn"
        case .midday: return "Midday"
        case .dusk: return "Dusk"
        }
    }

    var systemImage: String {
        switch self {
        case .dawn: return "sunrise.fill"
        case .midday: return "sun.max.fill"
        case .dusk: return "sunset.fill"
        }
    }

    /// Maps a session onto its flag in the day log.
    var keyPath: WritableKeyPath<DayEntry, Bool> {
        switch self {
        case .dawn: return \.dawn
        case .midday: return \.midday
        case .dusk: return \.dusk
        }
    }

    var reminderBody: String {
        switch self {
        case .dawn: return "Time for your morning reading. Start the day with intention."
        case .midday: return "Midday reading — pause, re-read, and refocus."
        case .dusk: return "Evening reading — close the day with your scroll."
        }
    }
}

/// User-configurable reminder settings. Times are stored as "HH:mm" 24-hour strings
/// to stay parity-compatible with the web prototype's persisted shape.
struct NotificationPrefs: Codable, Equatable {
    var enabled: Bool = false
    var dawnTime: String = "06:00"
    var middayTime: String = "12:00"
    var duskTime: String = "18:00"
    /// When a session is still incomplete this many minutes after its reminder,
    /// escalate to a full-screen "incoming call".
    var callEnabled: Bool = true
    var callTimeoutMinutes: Int = 15

    func time(for session: Session) -> String {
        switch session {
        case .dawn: return dawnTime
        case .midday: return middayTime
        case .dusk: return duskTime
        }
    }
}

/// A pending escalation shown as the full-screen incoming-call screen.
struct PendingCall: Identifiable, Equatable {
    let id = UUID()
    let session: Session
}

struct JournalEntry: Identifiable, Codable, Equatable {
    var id: String
    var date: String
    var scrollId: Int?
    var text: String
}

struct AchievementDef: Identifiable {
    let id: String
    let name: String
    let desc: String
    let test: (AppState) -> Bool
}

struct FriendSnapshot: Codable, Equatable, Sendable {
    var name: String
    var level: Int
    var xp: Int
    var streak: Int
    var bestStreak: Int
    var totalDays: Int
    var mastered: Int
    var lastActive: Date
}

struct LeaderboardEntry: Identifiable, Equatable, Sendable {
    var id: String { code }
    var code: String
    var snapshot: FriendSnapshot
}

enum Constants {
    static let romans = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"]
    static let ranks = [
        "Apprentice", "Peddler", "Trader", "Merchant", "Journeyman",
        "Caravan Leader", "Master Trader", "Silk Road Merchant",
        "Renowned Merchant", "Legendary Trader", "Master of Commerce", "Grand Merchant"
    ]
    static let milestones = [7, 14, 30, 60, 100]

    static let achievementDefs: [AchievementDef] = [
        AchievementDef(id: "first-seal", name: "First Seal", desc: "Complete your first reading session") { $0.totalSessionsCompleted >= 1 },
        AchievementDef(id: "perfect-day", name: "Perfect Day", desc: "Complete all three sessions in one day") { $0.totalDaysCompleted >= 1 },
        AchievementDef(id: "week-streak", name: "Week Streak", desc: "Reach a 7-day streak") { $0.bestStreak >= 7 },
        AchievementDef(id: "month-streak", name: "Iron Will", desc: "Reach a 30-day streak") { $0.bestStreak >= 30 },
        AchievementDef(id: "first-scroll", name: "First Scroll", desc: "Master your first scroll") { $0.scrolls.filter { $0.status == .mastered }.count >= 1 },
        AchievementDef(id: "halfway", name: "Halfway There", desc: "Master five scrolls") { $0.scrolls.filter { $0.status == .mastered }.count >= 5 },
        AchievementDef(id: "all-ten", name: "Grand Merchant", desc: "Master all ten scrolls") { $0.scrolls.filter { $0.status == .mastered }.count >= 10 },
        AchievementDef(id: "century", name: "Century", desc: "Complete 100 total days") { $0.totalDaysCompleted >= 100 },
        AchievementDef(id: "reflective", name: "Reflective", desc: "Write ten journal entries") { $0.journal.count >= 10 },
        AchievementDef(id: "habit-builder", name: "Habit Builder", desc: "Keep a habit going for 7 days straight") { state in
            state.habits.contains { state.habitStreak($0) >= 7 }
        },
    ]
}
