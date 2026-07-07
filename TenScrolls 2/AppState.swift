import Foundation

struct AppState: Codable, Equatable {
    var scrolls: [Scroll]
    var log: [String: DayEntry] = [:]
    var journal: [JournalEntry] = []
    var habits: [Habit]
    var bestStreak: Int = 0
    var shieldUsedDates: [String] = []
    var unlockedThemeIds: [String] = ["brass"]
    var activeThemeId: String = "brass"
    var traderCode: String
    var traderName: String = ""
    var friendCodes: [String] = []
    /// Optional so state persisted before this feature existed still decodes cleanly
    /// (a missing key becomes nil rather than throwing and wiping progress).
    var notifications: NotificationPrefs? = nil

    /// Reminder settings with sane defaults when none have been persisted yet.
    var notifPrefs: NotificationPrefs { notifications ?? NotificationPrefs() }

    static func defaultState() -> AppState {
        let scrolls = Constants.romans.enumerated().map { (i, r) in
            Scroll(id: i + 1, roman: r, status: i == 0 ? .active : .locked)
        }
        let habits = [
            Habit(id: "h1", name: "Greeted someone with genuine warmth"),
            Habit(id: "h2", name: "Took one small action despite fear"),
        ]
        return AppState(scrolls: scrolls, habits: habits, traderCode: AppState.generateTraderCode())
    }

    static func generateTraderCode() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).compactMap { _ in chars.randomElement() })
    }
}

// MARK: - Date helpers

enum DateKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone.current
        return f
    }()

    static func today() -> String { formatter.string(from: Date()) }

    static func string(from date: Date) -> String { formatter.string(from: date) }

    static func date(from key: String) -> Date { formatter.date(from: key) ?? Date() }

    static func add(_ days: Int, to key: String) -> String {
        let base = date(from: key)
        let newDate = Calendar.current.date(byAdding: .day, value: days, to: base) ?? base
        return string(from: newDate)
    }

    static func short(_ key: String) -> String {
        let d = date(from: key)
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }
}

// MARK: - Derived game logic (mirrors the web prototype's pure functions)

extension AppState {
    var activeScroll: Scroll? { scrolls.first(where: { $0.status == .active }) }

    func scrollDaysCompleted(_ scrollId: Int) -> Int {
        log.values.filter { $0.scrollId == scrollId && $0.allComplete }.count
    }

    var totalDaysCompleted: Int {
        scrolls.reduce(0) { $0 + scrollDaysCompleted($1.id) }
    }

    func isDayComplete(_ key: String) -> Bool {
        if let e = log[key], e.allComplete { return true }
        return shieldUsedDates.contains(key)
    }

    var currentStreak: Int {
        let today = DateKey.today()
        var key = isDayComplete(today) ? today : DateKey.add(-1, to: today)
        var streak = 0
        while isDayComplete(key) {
            streak += 1
            key = DateKey.add(-1, to: key)
        }
        return streak
    }

    func habitStreak(_ habit: Habit) -> Int {
        var streak = 0
        var key = DateKey.today()
        let set = Set(habit.completedDates)
        while set.contains(key) {
            streak += 1
            key = DateKey.add(-1, to: key)
        }
        return streak
    }

    var totalSessionsCompleted: Int {
        var n = 0
        for e in log.values {
            if e.dawn { n += 1 }
            if e.midday { n += 1 }
            if e.dusk { n += 1 }
        }
        return n
    }

    var totalXP: Int {
        var xp = 0
        for e in log.values {
            if e.dawn { xp += 10 }
            if e.midday { xp += 10 }
            if e.dusk { xp += 10 }
            if e.allComplete { xp += 20 }
        }
        xp += habits.reduce(0) { $0 + $1.completedDates.count * 5 }
        xp += journal.count * 15
        xp += scrolls.filter { $0.status == .mastered }.count * 200
        return xp
    }

    struct LevelInfo {
        let level: Int
        let rank: String
        let into: Int
        let need: Int
        let pct: Double
    }

    func levelInfo() -> LevelInfo {
        var level = 0
        var remaining = totalXP
        var need = 120
        while remaining >= need {
            remaining -= need
            level += 1
            need = 120 + level * 30
        }
        let rank = Constants.ranks[min(level, Constants.ranks.count - 1)]
        let pct = need > 0 ? min(100.0, Double(remaining) / Double(need) * 100.0) : 0
        return LevelInfo(level: level, rank: rank, into: remaining, need: need, pct: pct)
    }

    var sealsEarned: Int {
        let mastered = scrolls.filter { $0.status == .mastered }.count
        let milestonesReached = Constants.milestones.filter { bestStreak >= $0 }.count
        return totalDaysCompleted + milestonesReached * 5 + mastered * 20
    }

    var sealsSpent: Int {
        unlockedThemeIds.filter { $0 != "brass" }.reduce(0) { sum, id in
            sum + (Palette.themes.first(where: { $0.id == id })?.cost ?? 0)
        }
    }

    var sealsAvailable: Int { sealsEarned - sealsSpent }

    var shieldsAvailable: Int {
        max(0, totalDaysCompleted / 7 - shieldUsedDates.count)
    }

    var achievements: [(def: AchievementDef, earned: Bool)] {
        Constants.achievementDefs.map { ($0, $0.test(self)) }
    }
}
