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
    
    // Timestamp tracking for server-side validation
    var dawnCompletedAt: Date? = nil
    var middayCompletedAt: Date? = nil
    var duskCompletedAt: Date? = nil
    
    /// Optional reason recorded when a user un-stamps a session or reflects on a missed day.
    var skipReason: String? = nil

    var allComplete: Bool { dawn && midday && dusk }
    var sessionCount: Int { [dawn, midday, dusk].filter { $0 }.count }
    
    /// Get completion timestamp for a specific session
    func completedAt(for session: Session) -> Date? {
        switch session {
        case .dawn: return dawnCompletedAt
        case .midday: return middayCompletedAt
        case .dusk: return duskCompletedAt
        }
    }
    
    /// Set completion for a session with timestamp
    mutating func setCompleted(_ session: Session, at timestamp: Date = Date()) {
        switch session {
        case .dawn:
            dawn = true
            dawnCompletedAt = timestamp
        case .midday:
            midday = true
            middayCompletedAt = timestamp
        case .dusk:
            dusk = true
            duskCompletedAt = timestamp
        }
    }
    
    /// Clear completion for a session
    mutating func clearCompleted(_ session: Session) {
        switch session {
        case .dawn:
            dawn = false
            dawnCompletedAt = nil
        case .midday:
            midday = false
            middayCompletedAt = nil
        case .dusk:
            dusk = false
            duskCompletedAt = nil
        }
    }
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
    
    /// Time window for this session (in local time)
    var timeWindow: SessionTimeWindow {
        switch self {
        case .dawn: return SessionTimeWindow(start: (5, 0), end: (11, 0))
        case .midday: return SessionTimeWindow(start: (11, 0), end: (16, 0))
        case .dusk: return SessionTimeWindow(start: (16, 0), end: (23, 0))
        }
    }
    
    /// Check if this session is currently within its eligible time window
    func isEligible(at date: Date = Date()) -> Bool {
        timeWindow.contains(date)
    }
    
    /// Window status for UI display
    func windowStatus(at date: Date = Date()) -> SessionWindowStatus {
        if timeWindow.contains(date) {
            return .open
        } else if timeWindow.isPast(date) {
            return .closed
        } else {
            return .upcoming
        }
    }
}

/// Time window configuration for a reading session
struct SessionTimeWindow {
    let start: (hour: Int, minute: Int)
    let end: (hour: Int, minute: Int)
    
    func contains(_ date: Date) -> Bool {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return false }
        
        let currentMinutes = hour * 60 + minute
        let startMinutes = start.hour * 60 + start.minute
        let endMinutes = end.hour * 60 + end.minute
        
        return currentMinutes >= startMinutes && currentMinutes < endMinutes
    }
    
    func isPast(_ date: Date) -> Bool {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return false }
        
        let currentMinutes = hour * 60 + minute
        let endMinutes = end.hour * 60 + end.minute
        
        return currentMinutes >= endMinutes
    }
    
    /// Formatted time range for display
    var displayRange: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        
        var components = DateComponents()
        components.hour = start.hour
        components.minute = start.minute
        let startDate = Calendar.current.date(from: components) ?? Date()
        
        components.hour = end.hour
        components.minute = end.minute
        let endDate = Calendar.current.date(from: components) ?? Date()
        
        return "\(formatter.string(from: startDate)) – \(formatter.string(from: endDate))"
    }
}

enum SessionWindowStatus {
    case upcoming  // Window hasn't opened yet
    case open      // Currently in the window
    case closed    // Window has closed
    
    var displayText: String {
        switch self {
        case .upcoming: return "Opens later"
        case .open: return "Available now"
        case .closed: return "Window closed"
        }
    }
}

/// Represents a session completion attempt with server-ready validation
struct SessionCompletion: Codable, Equatable {
    let session: Session
    let dateKey: String
    let scrollId: Int
    let completedAt: Date  // Client timestamp - server will override with now()
    let scrollProgressValidated: Bool  // Client-side friction gate passed
    
    /// Validate this completion is within acceptable time windows
    func isValid() -> Bool {
        // Check if session window is currently open
        guard session.isEligible(at: completedAt) else { return false }
        
        // Check if this is for today
        guard dateKey == DateKey.today() else { return false }
        
        // Check if scroll friction was satisfied
        guard scrollProgressValidated else { return false }
        
        return true
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

/// Tracks the rereading loop that begins once all ten scrolls are mastered.
/// The practice is repetition-based, so instead of "read once, achievement
/// unlocked" the reader revisits one scroll at a time on a rotation. Reads use
/// the same three-session ritual as the first pass, so streaks and XP continue.
struct CycleState: Codable, Equatable {
    /// Which pass through the ten scrolls this is (2 = second pass, and so on).
    var cycle: Int = 2
    /// The scroll currently being revisited (1...10).
    var currentScrollId: Int = 1
    /// Date keys ("yyyy-MM-dd") fully completed for the current scroll this pass.
    var daysThisScroll: [String] = []
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
    /// Days of revisiting a scroll before the reread rotation advances to the next.
    static let cycleGoalDays = 7

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
