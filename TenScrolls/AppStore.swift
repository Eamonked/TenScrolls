import Foundation
import Combine
import WidgetKit
import AlarmKit

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
        let loadedState: AppState
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(AppState.self, from: data) {
            loadedState = decoded
        } else {
            loadedState = AppState.defaultState()
        }
        self.state = loadedState

        let info = loadedState.levelInfo()
        self.prevLevel = info.level
        self.prevMasteredIds = loadedState.scrolls.filter { $0.status == .mastered }.map { $0.id }
        self.prevEarnedIds = loadedState.achievements.filter { $0.earned }.map { $0.def.id }
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
        if #available(iOS 26, *) {
            let done = doneSessionsToday
            Task { await AlarmScheduler.shared.reschedule(from: state.notifPrefs, doneSessions: done) }
        } else {
            notifier.reschedule(prefs: state.notifPrefs, doneSessions: doneSessionsToday)
        }
    }

    func updateNotifPrefs(_ prefs: NotificationPrefs) {
        state.notifications = prefs
        afterMutation()
        syncNotifications()
    }

    /// Toggles reminders, requesting system permission first when turning them on.
    func setNotificationsEnabled(_ enabled: Bool) async {
        if enabled {
            if #available(iOS 26, *) {
                let granted = await AlarmScheduler.shared.requestAuthorizationIfNeeded()
                guard granted else { return }
            } else {
                let granted = await notifier.requestAuthorization()
                guard granted else { return }
            }
        }
        var prefs = state.notifPrefs
        prefs.enabled = enabled
        updateNotifPrefs(prefs)
    }

    /// Check if the app was launched from an AlarmKit "Open the app" intent.
    /// If so, route to the Today tab and clear the pending key.
    func checkPendingAlarmSession() {
        if #available(iOS 26, *) {
            let key = AlarmScheduler.pendingSessionDefaultsKey
            if let _ = UserDefaults.standard.string(forKey: key) {
                selectedTab = 0
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
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
        let stateData = try? JSONEncoder().encode(state)
        
        let todayKey = DateKey.today()
        let todayLog = state.log[todayKey]
        let activeScroll = state.activeScroll
        let daysCompleted = activeScroll.map { state.scrollDaysCompleted($0.id) } ?? 0
        let themeId = state.activeThemeId
        let streak = state.currentStreak
        
        let wData = WidgetData(
            streak: streak,
            activeScrollRoman: activeScroll?.roman ?? "X",
            activeScrollTitle: activeScroll?.title ?? "",
            daysCompletedOnActive: daysCompleted,
            dawnComplete: todayLog?.dawn ?? false,
            middayComplete: todayLog?.midday ?? false,
            duskComplete: todayLog?.dusk ?? false,
            themeId: themeId,
            lastUpdated: Date()
        )
        WidgetData.save(wData)
        
        DispatchQueue.global(qos: .background).async {
            if let data = stateData {
                UserDefaults.standard.set(data, forKey: self.defaultsKey)
            }
            WidgetCenter.shared.reloadAllTimelines()
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

    /// Called the moment the reader opens a scroll to read it — before any stamp
    /// tap. Anchors whichever session is currently eligible so that a later tap
    /// (possibly after the window has rolled over) can still land. See
    /// `Session.isMarkable`.
    func recordReadingStarted(at date: Date = Date()) {
        guard let eligible = Session.allCases.first(where: { $0.isEligible(at: date) }) else { return }
        guard let targetId = state.targetScrollId else { return }
        let key = DateKey.today()
        var entry = state.log[key] ?? DayEntry(scrollId: targetId)
        entry.setStarted(eligible, at: date)
        state.log[key] = entry
    }

    func toggleSession(_ session: WritableKeyPath<DayEntry, Bool>) {
        // Determine which session this is
        let sessionType: Session = {
            switch session {
            case \DayEntry.dawn: return .dawn
            case \DayEntry.midday: return .midday
            case \DayEntry.dusk: return .dusk
            default: return .dawn // fallback, should never happen
            }
        }()
        
        // Log against the active scroll on the first pass, or the reread scroll in cycle mode.
        guard let targetId = state.targetScrollId else { return }
        let key = DateKey.today()
        let wasComplete = state.log[key]?.allComplete ?? false
        var entry = state.log[key] ?? DayEntry(scrollId: targetId)
        entry.scrollId = targetId

        // Validate eligibility. The live window is checked first; if it's already
        // closed, fall back to the reader's recorded start time for this session —
        // if they opened the scroll while the window was still open, a bounded
        // grace period covers the gap between finishing the read and tapping the
        // stamp, so a completed read isn't punished by unrelated UI lag.
        let currentTime = Date()
        if !sessionType.isMarkable(at: currentTime, startedAt: entry.startedAt(for: sessionType)) {
            let status = sessionType.windowStatus(at: currentTime)
            switch status {
            case .upcoming:
                showToast("\(sessionType.label) opens at \(sessionType.timeWindow.displayRange)")
            case .closed:
                showToast("\(sessionType.label) window has closed for today")
            case .open, .grace:
                break // Should not reach here — isMarkable already returned false
            }
            return
        }
        
        // Toggle with timestamp tracking
        let wasSet = entry[keyPath: session]
        if wasSet {
            entry.clearCompleted(sessionType)
        } else {
            entry.setCompleted(sessionType, at: currentTime)
        }
        
        state.log[key] = entry

        // Mastery only applies while an unmastered scroll is active (the first pass).
        if entry.allComplete, let active = state.activeScroll, active.id == targetId {
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

        // Cycle mode: a newly-completed day advances the reread rotation; un-stamping
        // the same day before it rotates walks it back.
        if state.isCycleActive {
            if entry.allComplete, !wasComplete {
                advanceCycle(completedKey: key)
            } else if wasComplete, !entry.allComplete {
                state.cycleState?.daysThisScroll.removeAll { $0 == key }
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

    /// Begins the rereading loop once every scroll is mastered.
    func beginCycle() {
        guard state.allScrollsMastered, state.cycleState == nil else { return }
        let firstId = state.scrolls.map(\.id).min() ?? 1
        state.cycleState = CycleState(cycle: 2, currentScrollId: firstId, daysThisScroll: [])
        afterMutation()
        showToast("A new cycle begins — revisit Scroll \(state.rereadScroll?.roman ?? "I")")
        syncNotifications()
    }

    /// Records a completed reread day and rotates to the next scroll once the goal is met.
    private func advanceCycle(completedKey: String) {
        guard var cs = state.cycleState, !cs.daysThisScroll.contains(completedKey) else { return }
        cs.daysThisScroll.append(completedKey)
        if cs.daysThisScroll.count >= Constants.cycleGoalDays {
            cs.daysThisScroll = []
            let ids = state.scrolls.map(\.id).sorted()
            if let idx = ids.firstIndex(of: cs.currentScrollId), idx + 1 < ids.count {
                cs.currentScrollId = ids[idx + 1]
            } else {
                cs.currentScrollId = ids.first ?? 1
                cs.cycle += 1
            }
        }
        state.cycleState = cs
    }

    func recordSkipReason(_ reason: String, for date: String) {
        if var entry = state.log[date] {
            entry.skipReason = reason
            state.log[date] = entry
        } else {
            if state.missedDayReasons == nil {
                state.missedDayReasons = [:]
            }
            state.missedDayReasons?[date] = reason
        }
        afterMutation()
    }

    func shouldShowWeeklyRecap() -> Bool {
        let today = DateKey.today()
        if state.lastWeeklyRecapDate == today { return false }
        
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: Date())
        // Sunday (1) or Monday (2)
        guard weekday == 1 || weekday == 2 else { return false }
        
        if let last = state.lastWeeklyRecapDate {
            let lastDate = DateKey.date(from: last)
            let daysSince = calendar.dateComponents([.day], from: lastDate, to: Date()).day ?? 0
            if daysSince < 6 { return false }
        }
        
        // Ensure they have actually been using the app for at least a few days
        guard state.totalDaysCompleted >= 3 else { return false }
        
        return true
    }

    func recordWeeklyRecapShown() {
        state.lastWeeklyRecapDate = DateKey.today()
        afterMutation()
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

    /// Records (or clears, if paragraphIndex is nil) which paragraph the reader
    /// last stopped at for a scroll, so reopening it can resume there.
    func setBookmark(scrollId: Int, paragraphIndex: Int?) {
        guard let idx = state.scrolls.firstIndex(where: { $0.id == scrollId }),
              state.scrolls[idx].bookmarkParagraphIndex != paragraphIndex else { return }
        state.scrolls[idx].bookmarkParagraphIndex = paragraphIndex
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

    /// Adds a journal entry for a specific scroll — used when quoting a
    /// highlighted excerpt, which should stay attributed to the scroll being
    /// read even during the reread cycle, when `activeScroll` is nil.
    func addJournalEntry(_ text: String, scrollId: Int?) {
        let entry = JournalEntry(
            id: "j\(Int(Date().timeIntervalSince1970 * 1000))",
            date: DateKey.today(),
            scrollId: scrollId,
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

    func buyShield(cost: Int) -> Bool {
        guard state.sealsAvailable >= cost else { return false }
        state.purchasedShields = (state.purchasedShields ?? 0) + 1
        afterMutation()
        return true
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
