import Foundation
import Combine

@MainActor
final class AppStore: ObservableObject {
    @Published var state: AppState
    @Published var toast: String?
    /// When non-nil, the full-screen incoming-call screen is presented for this session.
    @Published var incomingCall: PendingCall?
    /// Bound to the root TabView so notifications can route the user to the Today tab.
    @Published var selectedTab: Int = 0

    private var prevLevel: Int
    private var prevMasteredIds: [Int]
    private var prevEarnedIds: [String]
    private var toastTask: Task<Void, Never>?

    private let defaultsKey = "ten-scrolls-state"
    let leaderboard = CloudKitLeaderboard()
    let notifier = NotificationManager()

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(AppState.self, from: data) {
            self.state = decoded
        } else {
            self.state = AppState.defaultState()
        }
        let info = state.levelInfo()
        self.prevLevel = info.level
        self.prevMasteredIds = state.scrolls.filter { $0.status == .mastered }.map { $0.id }
        self.prevEarnedIds = state.achievements.filter { $0.earned }.map { $0.def.id }
        publishSnapshotIfNeeded()

        notifier.registerDelegate()
        notifier.onIncomingCall = { [weak self] session in
            self?.selectedTab = 0
            self?.incomingCall = PendingCall(session: session)
        }
        notifier.onReminderTap = { [weak self] _ in
            self?.selectedTab = 0
        }
        syncNotifications()
    }

    // MARK: - Notifications

    /// Which of today's sessions are already complete.
    private var doneSessionsToday: Set<Session> {
        let entry = state.log[DateKey.today()]
        return Set(Session.allCases.filter { entry?[keyPath: $0.keyPath] ?? false })
    }

    /// Rebuild scheduled notifications from current prefs + today's progress. Cheap and
    /// idempotent; call it after session changes, pref changes, and on foreground.
    func syncNotifications() {
        notifier.reschedule(prefs: state.notifPrefs, doneSessions: doneSessionsToday)
    }

    func updateNotifPrefs(_ prefs: NotificationPrefs) {
        state.notifications = prefs
        afterMutation()
        syncNotifications()
    }

    /// Toggles reminders, requesting system permission first when turning them on.
    func setNotificationsEnabled(_ enabled: Bool) async {
        if enabled {
            let granted = await notifier.requestAuthorization()
            guard granted else { return }
        }
        var prefs = state.notifPrefs
        prefs.enabled = enabled
        updateNotifPrefs(prefs)
    }

    /// Accept the incoming call: dismiss it and land on the Today tab.
    func answerCall() {
        selectedTab = 0
        incomingCall = nil
    }

    func declineCall() {
        incomingCall = nil
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func afterMutation() {
        persist()
        checkForNewMilestones()
        publishSnapshotIfNeeded()
    }

    private func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    private func checkForNewMilestones() {
        let info = state.levelInfo()
        let masteredIds = state.scrolls.filter { $0.status == .mastered }.map { $0.id }
        let earnedIds = state.achievements.filter { $0.earned }.map { $0.def.id }

        let newMastered = masteredIds.filter { !prevMasteredIds.contains($0) }
        if let first = newMastered.first, let s = state.scrolls.first(where: { $0.id == first }) {
            showToast("Scroll \(s.roman) mastered — next scroll unlocked")
        } else if info.level > prevLevel {
            showToast("Level up — you're now a \(Constants.ranks[min(info.level, Constants.ranks.count - 1)])")
        } else {
            let newAch = earnedIds.filter { !prevEarnedIds.contains($0) }
            if let firstId = newAch.first, let a = Constants.achievementDefs.first(where: { $0.id == firstId }) {
                showToast("Achievement unlocked — \(a.name)")
            }
        }

        prevLevel = info.level
        prevMasteredIds = masteredIds
        prevEarnedIds = earnedIds
    }

    private func publishSnapshotIfNeeded() {
        guard !state.traderName.isEmpty else { return }
        let snapshot = FriendSnapshot(
            name: state.traderName,
            level: state.levelInfo().level,
            xp: state.totalXP,
            streak: state.currentStreak,
            bestStreak: state.bestStreak,
            totalDays: state.totalDaysCompleted,
            mastered: state.scrolls.filter { $0.status == .mastered }.count,
            lastActive: Date()
        )
        Task { await leaderboard.publish(code: state.traderCode, snapshot: snapshot) }
    }

    // MARK: - Mutations

    func toggleSession(_ session: WritableKeyPath<DayEntry, Bool>) {
        guard let active = state.activeScroll else { return }
        let key = DateKey.today()
        var entry = state.log[key] ?? DayEntry(scrollId: active.id)
        entry.scrollId = active.id
        entry[keyPath: session].toggle()
        state.log[key] = entry

        if entry.allComplete {
            let days = state.log.values.filter { $0.scrollId == active.id && $0.allComplete }.count
            if days >= 30 {
                if let idx = state.scrolls.firstIndex(where: { $0.id == active.id }) {
                    state.scrolls[idx].status = .mastered
                }
                if let nextIdx = state.scrolls.firstIndex(where: { $0.status == .locked }) {
                    state.scrolls[nextIdx].status = .active
                }
            }
        }

        // Streak shield: auto-cover yesterday if it was missed but the day before was complete.
        let yesterday = DateKey.add(-1, to: key)
        let dayBefore = DateKey.add(-2, to: key)
        if !state.isDayComplete(yesterday), state.isDayComplete(dayBefore), !state.shieldUsedDates.contains(yesterday) {
            let avail = max(0, state.totalDaysCompleted / 7 - state.shieldUsedDates.count)
            if avail > 0 {
                state.shieldUsedDates.append(yesterday)
            }
        }

        state.bestStreak = max(state.bestStreak, state.currentStreak)
        afterMutation()
        syncNotifications() // completing a session cancels its pending escalation call
    }

    func toggleHabit(_ habitId: String) {
        let key = DateKey.today()
        guard let idx = state.habits.firstIndex(where: { $0.id == habitId }) else { return }
        if let dIdx = state.habits[idx].completedDates.firstIndex(of: key) {
            state.habits[idx].completedDates.remove(at: dIdx)
        } else {
            state.habits[idx].completedDates.append(key)
        }
        afterMutation()
    }

    func addHabit(_ name: String) {
        state.habits.append(Habit(id: "h\(Int(Date().timeIntervalSince1970 * 1000))", name: name))
        afterMutation()
    }

    func removeHabit(_ id: String) {
        state.habits.removeAll { $0.id == id }
        afterMutation()
    }

    func saveScroll(_ updated: Scroll) {
        guard let idx = state.scrolls.firstIndex(where: { $0.id == updated.id }) else { return }
        state.scrolls[idx] = updated
        afterMutation()
    }

    func addJournalEntry(_ text: String) {
        let entry = JournalEntry(
            id: "j\(Int(Date().timeIntervalSince1970 * 1000))",
            date: DateKey.today(),
            scrollId: state.activeScroll?.id,
            text: text
        )
        state.journal.append(entry)
        afterMutation()
    }

    func deleteJournalEntry(_ id: String) {
        state.journal.removeAll { $0.id == id }
        afterMutation()
    }

    func resetAll() {
        state = AppState.defaultState()
        afterMutation()
    }

    func unlockTheme(_ id: String) {
        guard let theme = Palette.themes.first(where: { $0.id == id }) else { return }
        guard state.sealsAvailable >= theme.cost, !state.unlockedThemeIds.contains(id) else { return }
        state.unlockedThemeIds.append(id)
        afterMutation()
    }

    func equipTheme(_ id: String) {
        state.activeThemeId = id
        afterMutation()
    }

    func setTraderName(_ name: String) {
        state.traderName = name
        afterMutation()
    }

    func addFriend(_ code: String) {
        guard !state.friendCodes.contains(code), code != state.traderCode else { return }
        state.friendCodes.append(code)
        persist()
    }

    func removeFriend(_ code: String) {
        state.friendCodes.removeAll { $0 == code }
        persist()
    }
}
