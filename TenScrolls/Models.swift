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

    /// Which paragraph of `notes` the reader last stopped at, so reopening the
    /// scroll can resume there instead of dumping them back at the top. Cleared
    /// once the reading is actually finished for the day.
    var bookmarkParagraphIndex: Int? = nil

    /// Splits `notes` into paragraph-sized reading units, using a blank line
    /// as the only real paragraph break. `notes` is normalized at write time
    /// (see `Scroll.normalizedNotes`), so this just splits on it — but it
    /// re-normalizes here too as a safety net for any notes written before
    /// that existed, or set some other way (e.g. sync, scripting).
    var paragraphs: [String] {
        Scroll.normalizedNotes(notes)
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

extension Scroll {
    /// Reflows pasted text so a single blank line is the only thing that
    /// counts as a paragraph break. Notes/Word/OCR pastes typically insert a
    /// line break after every line — left alone, that shatters `paragraphs`
    /// into one fragment per line. This collapses those stray single breaks
    /// back into flowing sentences while leaving intentional blank-line
    /// breaks (and existing well-formed paragraphs) untouched.
    static func normalizedNotes(_ raw: String) -> String {
        let blocks = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { block -> String in
                block
                    .components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
        return blocks.joined(separator: "\n\n")
    }
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

    // The moment the reader actually opened the scroll for this session — captured
    // the instant the reading view appears, before the mark-complete tap. This is
    // the true commitment moment; the stamp tap is just bookkeeping that can lag
    // behind it by a few minutes. Used to keep a session markable even if the
    // window rolls over in that gap. First-write-wins per session, per day.
    var dawnStartedAt: Date? = nil
    var middayStartedAt: Date? = nil
    var duskStartedAt: Date? = nil

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

    /// Get the moment the reader opened this session's scroll to read it, if any.
    func startedAt(for session: Session) -> Date? {
        switch session {
        case .dawn: return dawnStartedAt
        case .midday: return middayStartedAt
        case .dusk: return duskStartedAt
        }
    }

    /// Record the first time the reader opened this session's scroll today.
    /// Deliberately first-write-wins: only the earliest engagement counts as the anchor.
    mutating func setStarted(_ session: Session, at timestamp: Date) {
        switch session {
        case .dawn: if dawnStartedAt == nil { dawnStartedAt = timestamp }
        case .midday: if middayStartedAt == nil { middayStartedAt = timestamp }
        case .dusk: if duskStartedAt == nil { duskStartedAt = timestamp }
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
    
    /// Time window for this session (in local time). Accepts optional custom preferences;
    /// falls back to hardcoded defaults when nil.
    func timeWindow(customPrefs: SessionWindowPrefs? = nil) -> SessionTimeWindow {
        if let prefs = customPrefs {
            let (start, end) = prefs.window(for: self)
            if let window = SessionTimeWindow.parse(start: start, end: end) {
                return window
            }
        }
        // Fallback to defaults
        switch self {
        case .dawn: return SessionTimeWindow(start: (5, 0), end: (11, 0))
        case .midday: return SessionTimeWindow(start: (11, 0), end: (16, 0))
        case .dusk: return SessionTimeWindow(start: (16, 0), end: (23, 0))
        }
    }
    
    /// Check if this session is currently within its eligible time window
    func isEligible(at date: Date = Date(), customPrefs: SessionWindowPrefs? = nil) -> Bool {
        timeWindow(customPrefs: customPrefs).contains(date)
    }

    /// How long after a window closes a session can still be stamped, provided the
    /// reader actually opened the scroll (started reading) before it closed. This
    /// absorbs the gap between finishing the read and tapping the stamp elsewhere
    /// in the app — the read is the real commitment, the tap is just bookkeeping —
    /// without weakening the window for someone who never opened the scroll at all.
    static let markGraceMinutes = 30

    /// Whether this session can still be marked complete right now. Honors the
    /// live window first; if that's closed, falls back to `startedAt` — the
    /// timestamp captured when the reader opened the scroll — and allows a bounded
    /// grace period past the window's close, but only if that engagement itself
    /// happened inside the window.
    func isMarkable(at now: Date = Date(), startedAt: Date?, customPrefs: SessionWindowPrefs? = nil) -> Bool {
        let window = timeWindow(customPrefs: customPrefs)
        if window.contains(now) { return true }
        guard let startedAt, window.contains(startedAt) else { return false }
        let graceDeadline = window.endDate(anchoredTo: now).addingTimeInterval(TimeInterval(Session.markGraceMinutes * 60))
        return now <= graceDeadline
    }
    
    /// Window status for UI display
    func windowStatus(at date: Date = Date(), customPrefs: SessionWindowPrefs? = nil) -> SessionWindowStatus {
        let window = timeWindow(customPrefs: customPrefs)
        if window.contains(date) {
            return .open
        } else if window.isPast(date) {
            return .closed
        } else {
            return .upcoming
        }
    }

    /// Window status for UI display, aware of a recorded reading-start anchor.
    /// Use this wherever a stamp button reflects `isMarkable`, so the label never
    /// says "closed" for a session the reader can still tap.
    func windowStatus(at date: Date = Date(), startedAt: Date?, customPrefs: SessionWindowPrefs? = nil) -> SessionWindowStatus {
        let base = windowStatus(at: date, customPrefs: customPrefs)
        guard base == .closed else { return base }
        return isMarkable(at: date, startedAt: startedAt, customPrefs: customPrefs) ? .grace : .closed
    }
}

/// Time window configuration for a reading session
struct SessionTimeWindow {
    let start: (hour: Int, minute: Int)
    let end: (hour: Int, minute: Int)
    
    /// Parse "HH:mm" strings into a SessionTimeWindow. Returns nil if parsing fails
    /// or if the time range is invalid (end before start).
    static func parse(start: String, end: String) -> SessionTimeWindow? {
        let startParts = start.split(separator: ":")
        let endParts = end.split(separator: ":")
        
        guard startParts.count == 2, endParts.count == 2,
              let startHour = Int(startParts[0]), let startMin = Int(startParts[1]),
              let endHour = Int(endParts[0]), let endMin = Int(endParts[1]),
              startHour >= 0, startHour < 24, startMin >= 0, startMin < 60,
              endHour >= 0, endHour < 24, endMin >= 0, endMin < 60 else {
            return nil
        }
        
        let startMinutes = startHour * 60 + startMin
        let endMinutes = endHour * 60 + endMin
        guard endMinutes > startMinutes else { return nil }
        
        return SessionTimeWindow(
            start: (startHour, startMin),
            end: (endHour, endMin)
        )
    }
    
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

    /// This window's end time as a concrete Date on the same calendar day as `date`.
    /// Used to compute grace-period deadlines past the window's close.
    func endDate(anchoredTo date: Date) -> Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = end.hour
        components.minute = end.minute
        return calendar.date(from: components) ?? date
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
    case grace     // Window closed, but reading started in time — still markable
    case closed    // Window has closed, and it's too late to mark

    var displayText: String {
        switch self {
        case .upcoming: return "Opens later"
        case .open: return "Available now"
        case .grace: return "Still markable — you started in time"
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
