import Foundation
import Combine
import WidgetKit
import UIKit

/// Snapshot struct to hold all data needed for persistence and widgets
private struct PersistSnapshot: Sendable {
    let streak: Int
    let activeScrollRoman: String
    let activeScrollTitle: String
    let daysCompletedOnActive: Int
    let dawnComplete: Bool
    let middayComplete: Bool
    let duskComplete: Bool
    let themeId: String
    let lastUpdated: Date

    let journalEntries: [JournalWidgetData.JournalWidgetEntry]
    let journalThemeId: String
    let journalLastUpdated: Date

    let encodedState: Data?
}

/// This pattern is used to collect all data needed for persistence and widget updates
/// on the main actor before passing it to a detached background task. This avoids
/// crossing actor boundaries from a background context, which could cause concurrency issues.

@MainActor
final class AppStore: ObservableObject {
    @Published var state: AppState
    @Published var toast: String?
    /// Set when saved data existed but failed to decode at launch (see `init`).
    /// Unlike `toast`, this doesn't auto-dismiss — it's surfaced as a blocking
    /// `.alert` (see `ContentView`) so the user actually sees it and knows their
    /// raw data was preserved under a recovery key rather than silently discarded.
    @Published var dataRecoveryNotice: String?
    /// When non-nil, the full-screen incoming-call screen is presented for this session.
    @Published var incomingCall: PendingCall?
    /// Bound to the root TabView so notifications can route the user to the Today tab.
    @Published var selectedTab: Int = 0
    /// Set when a `tenscrolls://addfriend?code=...` link is opened (see
    /// `handleIncomingURL`). `CaravanView` consumes and clears this to prefill
    /// and submit the add-friend field.
    @Published var pendingFriendCode: String? = nil
    /// Set when a `tenscrolls://joingroup?code=...` link is opened (see
    /// `handleIncomingURL`). `CaravanView` consumes and clears this to prefill
    /// and submit the join-group field.
    @Published var pendingGroupCode: String? = nil
    /// Set when a `tenscrolls://journal?id=...` link is opened (see
    /// `handleIncomingURL`) — tapping the Journal Reflection widget, including
    /// on the Lock Screen. `JournalView` consumes and clears this to scroll to
    /// and expand the matching entry.
    @Published var pendingJournalEntryId: String? = nil
    /// Scrolls shared to this device (directly or via a reading group) still
    /// awaiting a decision. Refreshed on Caravan-tab appear and app
    /// foreground — see `refreshPendingShares()`.
    @Published var pendingScrollShares: [PendingScrollShare] = []
    /// Reading groups this device belongs to, for the share-recipient picker
    /// and the Caravan tab's group list.
    @Published var myReadingGroups: [ReadingGroupSummary] = []
    /// DM inbox — one row per mutual friend. Refreshed on Caravan-tab appear,
    /// same cadence as `myReadingGroups`. See `refreshDMThreads()`.
    @Published var dmThreads: [DMThreadSummary] = []
    /// Cheers sent to this device that haven't been acknowledged yet — the
    /// in-app fallback for when a push notification was missed or dismissed
    /// without tapping "Got it". Refreshed on Caravan-tab appear and app
    /// foreground, same cadence as `pendingScrollShares`.
    @Published var pendingCheers: [PendingCheer] = []
    /// Set the moment `bestStreak` newly crosses one of `Constants.milestones`
    /// (7/14/30/60/100 days). `ContentView` presents `MilestoneCelebrationView`
    /// while this is non-nil, then clears it on dismiss.
    @Published var milestoneReached: Int? = nil
    /// Set the instant a day's third session (dawn/midday/dusk) is completed —
    /// i.e. the transition into `allComplete`, not every toggle afterward.
    /// `ContentView` presents `DayCompleteView` while this is true, then
    /// clears it on dismiss. See `toggleSession`.
    @Published var dayComplete: Bool = false

    private var prevLevel: Int
    private var prevMasteredIds: [Int]
    private var prevEarnedIds: [String]
    private var prevBestStreak: Int
    private var toastTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?

    /// How long to wait after the last mutation before actually writing to disk.
    /// Coalesces bursts of rapid-fire mutations (e.g. every keystroke while
    /// journaling) into a single encode + write instead of one per change.
    private static let persistDebounceNanoseconds: UInt64 = 350_000_000

    private nonisolated let defaultsKey = "ten-scrolls-state"
    let leaderboard = SupabaseLeaderboard()
    let sharing = SupabaseSharing()
    let messaging = SupabaseMessaging()
    let subscription = SupabaseSubscription()
    let notifier = NotificationManager()
    
    /// Set when the Day 3 trial offer should be presented
    @Published var shouldShowTrialOffer: Bool = false
    
    /// Set when the Day 30 paywall should be presented
    @Published var shouldShowDay30Paywall: Bool = false

    init() {
        let loadedState: AppState
        if let data = UserDefaults.standard.data(forKey: defaultsKey) {
            do {
                loadedState = try JSONDecoder().decode(AppState.self, from: data)
            } catch {
                // Saved data exists but failed to decode — this should never silently
                // wipe progress. Keep the raw bytes under a recovery key so they aren't
                // lost, and surface the failure instead of guessing it's a fresh install.
                UserDefaults.standard.set(data, forKey: defaultsKey + ".recovery")
                assertionFailure("Failed to decode saved AppState, preserved raw data under '\(defaultsKey).recovery': \(error)")
                self.dataRecoveryNotice = "We couldn't load your saved reading progress. A backup of the raw data was kept on this device — please contact support if this keeps happening."
                loadedState = AppState.defaultState()
            }
        } else {
            loadedState = AppState.defaultState()
        }
        // No seeding needed here — defaultState() starts with zero habits
        // by design (see its doc comment), and existing saved state is used
        // as-is however many/few habits the reader has added.
        let seededState = loadedState
        self.state = seededState

        let info = seededState.levelInfo()
        self.prevLevel = info.level
        self.prevMasteredIds = seededState.scrolls.filter { $0.status == .mastered }.map { $0.id }
        self.prevEarnedIds = seededState.achievements.filter { $0.earned }.map { $0.def.id }
        self.prevBestStreak = seededState.bestStreak
        publishSnapshotIfNeeded()

        notifier.registerDelegate()
        notifier.onIncomingCall = { [weak self] (session: Session) in
            self?.selectedTab = 0
            self?.incomingCall = PendingCall(session: session)
        }
        notifier.onReminderTap = { [weak self] (_: Session) in
            self?.selectedTab = 0
        }
        notifier.onCheerAcknowledged = { [weak self] (cheerIdString: String) in
            guard let id = UUID(uuidString: cheerIdString) else { return }
            self?.acknowledgeCheer(id: id)
        }
        notifier.onShareReceived = { [weak self] in
            self?.selectedTab = 3
            Task { await self?.refreshPendingShares() }
        }
        syncNotifications()

        NotificationCenter.default.addObserver(
            forName: AppDelegate.deviceTokenNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let token = notification.object as? String else { return }
            Task { @MainActor in
                #if DEBUG
                await self?.leaderboard.registerPushToken(token, environment: "sandbox")
                #else
                await self?.leaderboard.registerPushToken(token, environment: "production")
                #endif
            }
        }
        registerForRemoteNotificationsIfAuthorized()

        // Fire-and-forget, lives for the app's process lifetime — the
        // event-driven half of subscription reconciliation (see
        // observeStoreKitEntitlementChanges / reconcileStoreKitEntitlement).
        // `Transaction.updates` is an infinite async sequence, so this Task
        // is intentionally never awaited or cancelled here.
        Task { [weak self] in
            await self?.observeStoreKitEntitlementChanges()
        }
    }

    // MARK: - Notifications

    /// Which of today's sessions are already complete.
    private var doneSessionsToday: Set<Session> {
        let entry = state.log[DateKey.today()]
        return Set(Session.allCases.filter { entry?.isCompleted(for: $0) ?? false })
    }

    /// Rebuild scheduled notifications from current prefs + today's progress. Cheap and
    /// idempotent; call it after session changes, pref changes, and on foreground.
    ///
    /// Branches on OS version: AlarmKit (`AlarmScheduler`) on iOS 26+, the old
    /// calendar-notification path (`notifier`) below that. `AlarmScheduler.reschedule`
    /// is async, so this stays a fire-and-forget `Task` here rather than making every
    /// caller of `syncNotifications()` async too — matches the previous fire-and-forget
    /// behavior of the `notifier` path.
    func syncNotifications() {
        if #available(iOS 26.1, *) {
            let prefs = state.notifPrefs
            let done = doneSessionsToday
            Task { await AlarmScheduler.shared.reschedule(from: prefs, doneSessions: done) }
        } else {
            notifier.reschedule(prefs: state.notifPrefs, doneSessions: doneSessionsToday)
        }
    }

    func updateNotifPrefs(_ prefs: NotificationPrefs) {
        state.notifications = prefs
        afterMutation()
        syncNotifications()
    }

    func updateWindowPrefs(_ prefs: SessionWindowPrefs) {
        state.sessionWindows = prefs
        afterMutation()
    }

    /// Toggles reminders, requesting system permission first when turning them on.
    func setNotificationsEnabled(_ enabled: Bool) async {
        if enabled {
            let granted: Bool
            if #available(iOS 26.1, *) {
                granted = await AlarmScheduler.shared.requestAuthorizationIfNeeded()
            } else {
                granted = await notifier.requestAuthorization()
            }
            guard granted else { return }
            // Local scheduling (reminders/calls/AlarmKit) is independent of
            // remote push — cheers need APNs specifically, so register for a
            // device token whenever the user has granted notification
            // permission at all, regardless of which local path is active.
            UIApplication.shared.registerForRemoteNotifications()
        }
        var prefs = state.notifPrefs
        prefs.enabled = enabled
        updateNotifPrefs(prefs)
    }

    /// Re-registers for a device token on every launch if permission was
    /// already granted in a previous session — Apple's recommended pattern,
    /// since tokens can rotate and this is cheap/idempotent to repeat.
    func registerForRemoteNotificationsIfAuthorized() {
        Task {
            let status = await notifier.authorizationStatus()
            guard status == .authorized else { return }
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// Check if the app was launched from an AlarmKit "Open the app" intent
    /// (iOS 26+ only — a no-op below that). If so, route to the Today tab.
    func checkPendingAlarmSession() {
        guard #available(iOS 26.1, *) else { return }
        let key = AlarmScheduler.pendingSessionDefaultsKey
        guard UserDefaults.standard.string(forKey: key) != nil else { return }
        UserDefaults.standard.removeObject(forKey: key)
        selectedTab = 0
    }

    /// Accept the incoming call: dismiss it and land on the Today tab.
    func answerCall() {
        selectedTab = 0
        incomingCall = nil
    }

    func declineCall() {
        incomingCall = nil
    }

    /// Debounces persistence: cancels any pending write and schedules a new one.
    /// Only the last state in a burst of rapid mutations actually gets encoded
    /// and written, and the encode/write itself happens off the main actor so
    /// typing or tapping never blocks on disk I/O.
    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: AppStore.persistDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            guard let snapshot = await self?.makePersistSnapshot() else { return }
            AppStore.persist(snapshot: snapshot)
        }
    }

    /// Writes the current state immediately, bypassing the debounce. Call this
    /// when the app is about to leave the foreground (or terminate) so a pending
    /// debounced write isn't lost.
    func flushPendingPersist() {
        persistTask?.cancel()
        persistTask = nil
        Task.detached(priority: .utility) { [weak self] in
            guard let snapshot = await self?.makePersistSnapshot() else { return }
            AppStore.persist(snapshot: snapshot)
        }
    }

    /// Gathers a snapshot of all data needed for persistence and widgets on the MainActor
    @MainActor
    private func makePersistSnapshot() -> PersistSnapshot {
        let todayKey = DateKey.today()
        let todayLog = state.log[todayKey]
        let activeScroll = state.activeScroll
        let daysCompleted = activeScroll.map { state.scrollDaysCompleted($0.id) } ?? 0
        let themeId = state.activeThemeId
        let streak = state.currentStreak

        // Export journal data for journal widget. The widget only draws from
        // entries the reader has explicitly starred for it; until at least one
        // exists, fall back to the most recent entries so the widget isn't
        // empty for a new reader who hasn't discovered starring yet.
        let eligible = state.journal.filter { !$0.isDraft && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let pinned = eligible.filter { $0.isPinnedForWidget }
        let journalEntries = (pinned.isEmpty ? eligible.sorted { $0.date > $1.date } : pinned)
            .prefix(50) // Cap so widget data size stays reasonable
            .map { entry -> JournalWidgetData.JournalWidgetEntry in
                let scroll = state.scrolls.first { $0.id == entry.scrollId }
                return JournalWidgetData.JournalWidgetEntry(
                    id: entry.id,
                    text: entry.text,
                    date: DateKey.short(entry.date),
                    scrollRoman: scroll?.roman
                )
            }

        let encodedState = try? JSONEncoder().encode(state)

        return PersistSnapshot(
            streak: streak,
            activeScrollRoman: activeScroll?.roman ?? "X",
            activeScrollTitle: activeScroll?.title ?? "",
            daysCompletedOnActive: daysCompleted,
            dawnComplete: todayLog?.dawn ?? false,
            middayComplete: todayLog?.midday ?? false,
            duskComplete: todayLog?.dusk ?? false,
            themeId: themeId,
            lastUpdated: Date(),

            journalEntries: Array(journalEntries),
            journalThemeId: themeId,
            journalLastUpdated: Date(),

            encodedState: encodedState
        )
    }

    /// Writes data to disk and updates widgets off the main actor.
    private nonisolated static func persist(snapshot: PersistSnapshot) {
        WidgetData.save(
            WidgetData(
                streak: snapshot.streak,
                activeScrollRoman: snapshot.activeScrollRoman,
                activeScrollTitle: snapshot.activeScrollTitle,
                daysCompletedOnActive: snapshot.daysCompletedOnActive,
                dawnComplete: snapshot.dawnComplete,
                middayComplete: snapshot.middayComplete,
                duskComplete: snapshot.duskComplete,
                themeId: snapshot.themeId,
                lastUpdated: snapshot.lastUpdated
            )
        )
        JournalWidgetData.save(
            JournalWidgetData(
                entries: snapshot.journalEntries,
                themeId: snapshot.journalThemeId,
                lastUpdated: snapshot.journalLastUpdated
            )
        )

        if let data = snapshot.encodedState {
            UserDefaults.standard.set(data, forKey: "ten-scrolls-state")
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func afterMutation() {
        schedulePersist()
        checkForNewMilestones()
        publishSnapshotIfNeeded()
    }

    /// Internal (not `private`) so paywall/purchase-flow views can surface
    /// user-facing errors (e.g. a failed StoreKit purchase) through the same
    /// toast mechanism as everything else, rather than each inventing its own.
    func showToast(_ message: String) {
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

        // Streak milestones (7/14/30/60/100 days) get their own celebratory
        // sheet with a share action, independent of the toast above — a
        // toast is easy to miss and gives no way to act on the moment.
        if let newMilestone = Constants.milestones.filter({ state.bestStreak >= $0 && prevBestStreak < $0 }).max() {
            milestoneReached = newMilestone
        }

        prevLevel = info.level
        prevMasteredIds = masteredIds
        prevEarnedIds = earnedIds
        prevBestStreak = state.bestStreak
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
        let preferredCode = state.traderCode
        let name = state.traderName
        Task {
            // Reserves preferredCode server-side, or a freshly generated one if
            // another device already claimed it. Only the first successful
            // claim actually changes anything locally on subsequent calls.
            let confirmedCode = await leaderboard.claimIdentity(preferredCode: preferredCode, name: name)
            if confirmedCode != state.traderCode {
                state.traderCode = confirmedCode
                schedulePersist()
            }
            await leaderboard.publish(code: confirmedCode, snapshot: snapshot)
        }
    }

    // MARK: - Mutations

    /// Called the moment the reader opens a scroll to read it — before any stamp
    /// tap. Anchors whichever session is currently eligible so that a later tap
    /// (possibly after the window has rolled over) can still land. See
    /// `Session.isMarkable`.
    func recordReadingStarted(at date: Date = Date()) {
        let customPrefs = state.windowPrefs
        guard let eligible = Session.allCases.first(where: { $0.isEligible(at: date, customPrefs: customPrefs) }) else { return }
        guard let targetId = state.targetScrollId else { return }
        let key = DateKey.today()
        var entry = state.log[key] ?? DayEntry(scrollId: targetId)
        entry.setStarted(eligible, at: date)
        state.log[key] = entry
    }

    func toggleSession(_ sessionType: Session) {
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
        let customPrefs = state.windowPrefs
        if !sessionType.isMarkable(at: currentTime, startedAt: entry.startedAt(for: sessionType), customPrefs: customPrefs) {
            let status = sessionType.windowStatus(at: currentTime, customPrefs: customPrefs)
            switch status {
            case .upcoming:
                showToast("\(sessionType.label) opens at \(sessionType.timeWindow(customPrefs: customPrefs).displayRange)")
            case .closed:
                showToast("\(sessionType.label) window has closed for today")
            case .open, .grace:
                break // Should not reach here — isMarkable already returned false
            }
            return
        }
        
        // Toggle with timestamp tracking
        let wasSet = entry.isCompleted(for: sessionType)
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
            let avail = max(0, state.totalDaysCompleted / 7 - state.shieldUsedDates.count + (state.purchasedShields ?? 0))
            if avail > 0 {
                state.shieldUsedDates.append(yesterday)
            }
        }

        state.bestStreak = max(state.bestStreak, state.currentStreak)
        afterMutation()

        // The day-complete celebration fires on the transition into
        // allComplete, not on every subsequent toggle (e.g. un-stamping and
        // re-stamping the same session).
        if entry.allComplete, !wasComplete {
            dayComplete = true
        }

        // Check for engagement milestones (Day 3 trial offer)
        checkEngagementMilestones()
        
        // Cancel the escalation call immediately when a session is completed
        if !wasSet && entry.isCompleted(for: sessionType) {
            if #available(iOS 26.1, *) {
                let rawSession = sessionType.rawValue
                Task { await AlarmScheduler.shared.handleStop(sessionId: rawSession) }
            } else {
                notifier.cancelEscalationCall(for: sessionType)
            }
        }
        
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

    /// Imports plain text into a single scroll's notes, replacing whatever
    /// was there. The title is only filled in when the scroll doesn't
    /// already have one, so this never clobbers a title the user wrote.
    func importDocument(text: String, title: String?, intoScrollId scrollId: Int) {
        guard let idx = state.scrolls.firstIndex(where: { $0.id == scrollId }) else { return }
        var scroll = state.scrolls[idx]
        scroll.notes = Scroll.normalizedNotes(text)
        if scroll.title.isEmpty, let title, !title.isEmpty {
            scroll.title = title
        }
        state.scrolls[idx] = scroll
        afterMutation()
    }

    /// Spreads `chunks` across all ten scrolls in order — `chunks[0]` -> Scroll I,
    /// `chunks[1]` -> Scroll II, and so on. `chunks` must already be split into
    /// exactly ten pieces (see `DocumentSplitter.distribute`).
    func importDocumentAcrossAllScrolls(_ chunks: [String]) {
        let ordered = state.scrolls.sorted { $0.id < $1.id }
        for (scroll, chunk) in zip(ordered, chunks) where !chunk.isEmpty {
            guard let idx = state.scrolls.firstIndex(where: { $0.id == scroll.id }) else { continue }
            state.scrolls[idx].notes = Scroll.normalizedNotes(chunk)
        }
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

    // MARK: - Library

    /// Adds a whole imported document as a book on the library shelf, rather
    /// than into a scroll. The full text is written straight to its own file
    /// via `LibraryStore` — never through `state`/`persist` — so however big
    /// the book is, it can't bloat the UserDefaults blob the rest of the app
    /// state rides in. Only the small `LibraryIndexEntry` (title/chapter
    /// count) joins `state.library`.
    ///
    /// `html`, when the source was an EPUB, carries each chapter's sanitized
    /// original markup (see `EPUBParser`) so the Library reader can render
    /// tables/lists/images faithfully instead of the flattened plain-text
    /// fallback. `nil` for PDF imports.
    ///
    /// `pdfData`, when present, is the PDF's original, unmodified bytes —
    /// this is what makes the book a `.pdf`-sourced book. It's written to
    /// its own file via `LibraryStore.savePDF` and opened directly by the
    /// native `PDFReaderView`; `chunks`/`titles` are still extracted and
    /// stored as before (see `Documentimportsheet`), but only as a fallback
    /// text layer — the actual reading experience never flattens the PDF
    /// the way the old text-reflow pipeline did.
    func addBookToLibrary(filename: String, chunks: [String], titles: [String?], html: [String]? = nil, bookTitle: String? = nil, pdfData: Data? = nil, coverData: Data? = nil) throws {
        let sourceType: BookSource = pdfData != nil ? .pdf : .epub
        let (book, builtIndex) = Book.from(filename: filename, chunks: chunks, titles: titles, html: html, bookTitle: bookTitle, sourceType: sourceType)
        try LibraryStore.save(book)
        if let pdfData {
            try LibraryStore.savePDF(pdfData, for: book.id)
        }
        var index = builtIndex
        // Best-effort: a cover thumbnail is a nice-to-have for identifying
        // the book on the shelf, not something worth failing the whole
        // import over if the write happens to fail.
        if let coverData, (try? LibraryStore.saveCover(coverData, for: book.id)) != nil {
            index.hasCover = true
        }
        state.libraryBooks.append(index)
        afterMutation()
    }

    /// Removes a book: drops its metadata from state and deletes its file on
    /// disk. Irreversible — callers should confirm with the user first.
    func removeBook(_ id: UUID) {
        state.libraryBooks.removeAll { $0.id == id }
        LibraryStore.delete(id)
        afterMutation()
    }

    /// Records where the reader stopped in a book, as a 0...1 fraction of
    /// the chapter's page count rather than a paragraph index, since a
    /// CSS-column page count can shift with font size or rotation in a way
    /// a paragraph index survives but a raw page number wouldn't. Only
    /// touches the small index entry in `state` — the book's own file on
    /// disk is never rewritten just to bookmark a reading position. See
    /// `LibraryIndexEntry.bookmarkScrollFraction`.
    func setLibraryBookmark(bookId: UUID, chapterIndex: Int, scrollFraction: Double) {
        guard let idx = state.libraryBooks.firstIndex(where: { $0.id == bookId }) else { return }
        state.libraryBooks[idx].bookmarkChapterIndex = chapterIndex
        state.libraryBooks[idx].bookmarkScrollFraction = scrollFraction
        afterMutation()
    }

    /// Mirrors `setLibraryBookmark(bookId:chapterIndex:scrollFraction:)` for
    /// `.pdf` books, whose reading position is a plain PDFKit page index
    /// rather than a chapter + fraction — see
    /// `LibraryIndexEntry.bookmarkPDFPageIndex`.
    func setLibraryPDFBookmark(bookId: UUID, pageIndex: Int) {
        guard let idx = state.libraryBooks.firstIndex(where: { $0.id == bookId }),
              state.libraryBooks[idx].bookmarkPDFPageIndex != pageIndex else { return }
        state.libraryBooks[idx].bookmarkPDFPageIndex = pageIndex
        afterMutation()
    }

    func addJournalEntry(_ text: String) {
        addJournalEntry(text, scrollId: state.activeScroll?.id)
    }

    /// Adds a journal entry for a specific scroll — used when quoting a
    /// highlighted excerpt, which should stay attributed to the scroll being
    /// read even during the reread cycle, when `activeScroll` is nil.
    /// `bookTitle` is set instead when the quote came from a Library book
    /// rather than a scroll.
    func addJournalEntry(_ text: String, scrollId: Int?, bookTitle: String? = nil) {
        let entry = JournalEntry(
            id: "j\(Int(Date().timeIntervalSince1970 * 1000))",
            date: DateKey.today(),
            scrollId: scrollId,
            text: text,
            isDraft: false,
            bookTitle: bookTitle
        )
        state.journal.append(entry)
        afterMutation()
    }

    /// Toggles whether an entry is included in the Journal Reflection widget's
    /// rotation — the reader's way of curating which reflections are worth
    /// resurfacing at random, rather than the widget grabbing anything.
    func toggleJournalPinForWidget(_ id: String) {
        guard let idx = state.journal.firstIndex(where: { $0.id == id }) else { return }
        state.journal[idx].isPinnedForWidget.toggle()
        afterMutation()
    }

    func addDraftEntry() {
        let entry = JournalEntry(
            id: "j\(Int(Date().timeIntervalSince1970 * 1000))",
            date: DateKey.today(),
            scrollId: state.activeScroll?.id,
            text: "",
            isDraft: true
        )
        state.journal.append(entry)
        afterMutation()
    }

    func updateJournalEntry(_ id: String, text: String) {
        guard let idx = state.journal.firstIndex(where: { $0.id == id }) else { return }
        state.journal[idx].text = text
        afterMutation()
    }

    func publishDraft(_ id: String) {
        guard let idx = state.journal.firstIndex(where: { $0.id == id }) else { return }
        state.journal[idx].isDraft = false
        state.journal[idx].date = DateKey.today()
        afterMutation()
    }

    func convertToDraft(_ id: String) {
        guard let idx = state.journal.firstIndex(where: { $0.id == id }) else { return }
        state.journal[idx].isDraft = true
        afterMutation()
    }

    func deleteJournalEntry(_ id: String) {
        state.journal.removeAll { $0.id == id }
        afterMutation()
    }

    func resetAll() {
        // The index entries are about to be wiped along with the rest of
        // state — delete the books' files too, or they'd sit on disk
        // forever with nothing left pointing at them.
        for entry in state.libraryBooks {
            LibraryStore.delete(entry.id)
        }
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

    func setAppearanceMode(_ mode: AppearanceMode) {
        state.appearanceMode = mode
        afterMutation()
    }

    /// Updates the shared reading text-size preference (the "Aa" control in
    /// both the Scrolls reader and the Library reader). Debounced-persisted
    /// like everything else, so dragging the control repeatedly doesn't spam disk writes.
    func setReadingFontScale(_ scale: Double) {
        state.readingFontScale = scale
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
        schedulePersist()
        // Best-effort server sync (migration 007) — this is what lets
        // send_direct_message later tell whether the pair is mutual.
        // `friendCodes` stays the source of truth for what CaravanView shows
        // either way; this just teaches the backend the same thing.
        Task { await messaging.addFriendLink(code: code) }
    }

    func removeFriend(_ code: String) {
        state.friendCodes.removeAll { $0 == code }
        schedulePersist()
        Task { await messaging.removeFriendLink(code: code) }
    }

    /// Backfills `friend_links` for every locally-added friend. Safe to call
    /// repeatedly — `add_friend_link` is an idempotent upsert (`ON CONFLICT
    /// DO NOTHING`). Exists so friends added before migration 007 existed
    /// still become mutual once both sides have opened the app again,
    /// without anyone needing to remove-and-re-add each other. Called from
    /// `CaravanView`'s existing load cycle alongside `refreshReadingGroups()`.
    func syncFriendLinks() async {
        for code in state.friendCodes {
            await messaging.addFriendLink(code: code)
        }
    }

    // MARK: - Cheers (push + acknowledgment)

    /// Polls for cheers sent to this device that haven't been acknowledged
    /// yet. Same idea as `refreshPendingShares` — the push is the primary
    /// delivery path, but a poll on Caravan-tab appear/foreground catches
    /// anything missed (notification dismissed unseen, permission denied, etc).
    func refreshPendingCheers() async {
        pendingCheers = await leaderboard.fetchUnacknowledgedCheers()
    }

    /// Marks a cheer received, locally and server-side. Removes it from
    /// `pendingCheers` immediately (optimistic) since this is called both
    /// from the notification's "Got it" action and from the in-app banner.
    func acknowledgeCheer(id: UUID) {
        pendingCheers.removeAll { $0.cheer_id == id }
        Task { await leaderboard.acknowledgeCheer(id: id) }
    }

    // MARK: - Invite links

    /// Handles this app's `tenscrolls://` custom URL scheme. Three hosts are
    /// recognized:
    ///
    /// - `tenscrolls://addfriend?code=XXXXX`, generated by the Caravan's
    ///   "Share invite link" action (see `CaravanView.inviteURL`). Routes to
    ///   the Caravan tab and stages the code for `CaravanView` to prefill and
    ///   submit — see `pendingFriendCode`.
    /// - `tenscrolls://joingroup?code=XXXXX`, generated by the share button
    ///   on each `ReadingGroupRow`. Routes to the Caravan tab and stages the
    ///   code for `CaravanView` to prefill and submit the join-group field —
    ///   see `pendingGroupCode`.
    /// - `tenscrolls://journal?id=XXXXX`, generated by the Journal Reflection
    ///   widget for whichever entry it's currently displaying (see
    ///   `JournalWidget.deepLinkURL`), including on the Lock Screen. Routes to
    ///   the Journal tab and stages the id for `JournalView` to scroll to and
    ///   expand — see `pendingJournalEntryId`.
    ///
    /// This is a custom URL scheme only; there's no Universal Link fallback
    /// yet; that needs a domain Eamon controls to host an
    /// apple-app-site-association file, plus the Associated Domains
    /// capability. Until that exists, tapping a link on a device without
    /// the app installed just fails silently rather than falling through to
    /// an App Store / web landing page.
    func handleIncomingURL(_ url: URL) {
        guard url.scheme == "tenscrolls" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        switch url.host {
        case "addfriend":
            guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
                  !code.isEmpty else { return }
            pendingFriendCode = code.uppercased()
            selectedTab = 3
        case "joingroup":
            guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
                  !code.isEmpty else { return }
            pendingGroupCode = code.uppercased()
            selectedTab = 3
        case "journal":
            guard let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
                  !id.isEmpty else { return }
            pendingJournalEntryId = id
            selectedTab = 2
        default:
            break
        }
    }

    // MARK: - Scroll sharing & reading groups

    /// Polls for scrolls shared to this device. Cheap and safe to call often
    /// (Caravan-tab appear, app foreground) — the push (`send-share-push`)
    /// is the primary delivery path, same pattern as cheers, but this poll
    /// catches anything missed (notification dismissed unseen, permission
    /// denied, no token registered yet, etc).
    func refreshPendingShares() async {
        pendingScrollShares = await sharing.fetchPendingShares()
    }

    func refreshReadingGroups() async {
        myReadingGroups = await sharing.fetchMyGroups()
    }

    enum GroupActionResult {
        case success(String)
        case failure(String)
    }

    /// Creates a new reading group and adds it to `myReadingGroups` on success.
    func createReadingGroup(name: String) async -> GroupActionResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure("Give the group a name first.") }
        switch await sharing.createGroup(name: trimmed) {
        case .created(let id, let code, let groupName):
            myReadingGroups.append(ReadingGroupSummary(group_id: id, name: groupName, group_code: code, member_count: 1))
            return .success("Created \u{201C}\(groupName)\u{201D} \u{2014} code \(code)")
        case .failure(let error):
            return .failure(Self.friendlyGroupError(error))
        case .joined:
            return .failure("Unexpected response creating the group.")
        }
    }

    /// Joins an existing reading group by its 6-character code and refreshes
    /// the full group list (rather than appending locally) since the joined
    /// group's real member count matters immediately.
    func joinReadingGroup(code: String) async -> GroupActionResult {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure("Enter a group code first.") }
        switch await sharing.joinGroup(code: trimmed) {
        case .joined(_, let name):
            await refreshReadingGroups()
            return .success("Joined \u{201C}\(name)\u{201D}")
        case .failure(let error):
            return .failure(Self.friendlyGroupError(error))
        case .created:
            return .failure("Unexpected response joining the group.")
        }
    }

    private static func friendlyGroupError(_ code: String) -> String {
        switch code {
        case "no_identity": return "Set your trader handle first, then try again."
        case "group_not_found": return "No group found with that code."
        case "name_required": return "Give the group a name first."
        case "network_error": return "Couldn't reach the server. Try again shortly."
        default: return "Something went wrong. Try again shortly."
        }
    }

    /// Shares one scroll's full title + notes to each selected recipient
    /// (trader codes and/or group ids) as separate calls, so one bad code
    /// doesn't block the rest. Returns true only if every recipient succeeded.
    func shareScroll(_ scroll: Scroll, toTraderCodes traderCodes: [String], toGroupIds groupIds: [UUID]) async -> Bool {
        var allSucceeded = true
        for code in traderCodes {
            let ok = await sharing.shareScroll(scrollNumber: scroll.id, title: scroll.title, notes: scroll.notes, toTraderCode: code)
            allSucceeded = allSucceeded && ok
        }
        for groupId in groupIds {
            let ok = await sharing.shareScroll(scrollNumber: scroll.id, title: scroll.title, notes: scroll.notes, toGroupId: groupId)
            allSucceeded = allSucceeded && ok
        }
        return allSucceeded
    }

    /// Imports a shared scroll's title + notes into one of this device's own
    /// ten scroll slots — "slots into the app like it was always theirs."
    /// Only overwrites that slot's content; unlock/mastery status for the
    /// slot is untouched, same as any other scroll edit. Marks the share
    /// resolved server-side so it stops reappearing on future polls.
    func importSharedScroll(_ share: PendingScrollShare, intoSlot slot: Int) {
        guard let idx = state.scrolls.firstIndex(where: { $0.id == slot }) else { return }
        state.scrolls[idx].title = share.title
        state.scrolls[idx].notes = Scroll.normalizedNotes(share.notes)
        pendingScrollShares.removeAll { $0.id == share.id }
        afterMutation()
        showToast("Added \u{201C}\(share.title.isEmpty ? "Scroll \(state.scrolls[idx].roman)" : share.title)\u{201D} to Scroll \(state.scrolls[idx].roman)")
        Task { await sharing.resolveShare(id: share.id, status: "imported") }
    }

    func dismissSharedScroll(_ share: PendingScrollShare) {
        pendingScrollShares.removeAll { $0.id == share.id }
        Task { await sharing.resolveShare(id: share.id, status: "dismissed") }
    }

    // MARK: - Direct messages

    /// Refreshes the DM inbox (one row per mutual friend, most recent
    /// activity first). Cheap enough to call on Caravan-tab appear, same
    /// cadence as `refreshReadingGroups()`.
    func refreshDMThreads() async {
        dmThreads = await messaging.fetchDMThreads()
    }

    /// Sends a DM and refreshes the inbox on success so the new message's
    /// preview shows up immediately. Returns the server's error code on
    /// failure (e.g. "not_mutual_friends") so the caller can show something
    /// more specific than a generic toast, or nil on success.
    @discardableResult
    func sendDirectMessage(toCode: String, body: String) async -> String? {
        let error = await messaging.sendDirectMessage(toCode: toCode, body: body)
        if error == nil {
            await refreshDMThreads()
        }
        return error
    }

    /// Fetches a page of a conversation with one friend, newest first. Pass
    /// `before` (the oldest `sent_at` already loaded) to page further back.
    func fetchDirectMessages(withCode: String, before: Date? = nil) async -> [DirectMessage] {
        await messaging.fetchDirectMessages(withCode: withCode, before: before)
    }

    /// Marks a thread read and refreshes the inbox so its unread badge
    /// clears. Call when a DM thread view is opened.
    func markDMRead(withCode: String) async {
        await messaging.markRead(withCode: withCode)
        await refreshDMThreads()
    }

    // MARK: - Subscription & Monetization
    
    /// Fetches and caches the user's current subscription status
    func refreshSubscriptionStatus() async {
        do {
            let info = try await subscription.fetchSubscriptionStatus()
            state.cachedSubscriptionStatus = info.subscriptionStatus
            afterMutation()
            
            // Check for trial expiry
            let expiryResult = try await subscription.checkTrialExpiry()
            if expiryResult.expired {
                state.cachedSubscriptionStatus = .lapsed
                afterMutation()
                showToast("Your trial has ended. Upgrade to keep full access.")
            }

            // Cross-check a server-reported 'active' subscriber against
            // StoreKit's own entitlement truth. This is the poll-based half
            // of reconciliation (see StoreKitManager.observeTransactionUpdates
            // for the event-driven half) — it's what catches a cancellation/
            // refund/failed-renewal that happened while the app was closed,
            // since nothing pushes that change to us otherwise.
            if state.cachedSubscriptionStatus == .active {
                await reconcileStoreKitEntitlement()
            }
        } catch {
            // Best effort - leave cached status unchanged on failure
        }
    }

    /// Confirms a cached `active` status is still backed by a real StoreKit
    /// entitlement, and downgrades server-side if not. Called from two
    /// places: the poll in `refreshSubscriptionStatus()` above (foreground/
    /// trial-check cadence) and `onEntitlementChange` in
    /// `observeStoreKitEntitlementChanges()` below (event-driven, while the
    /// app is already running). Both funnel through here so the downgrade
    /// logic — and its toast — exist in exactly one place.
    private func reconcileStoreKitEntitlement() async {
        let stillActive = await StoreKitManager.shared.hasActiveEntitlement()
        guard !stillActive else { return }
        do {
            let result = try await subscription.deactivateSubscription()
            if result.changed {
                state.cachedSubscriptionStatus = .lapsed
                afterMutation()
                showToast("Your Plus subscription has ended.")
            }
        } catch {
            // Best effort — if this fails, the next foreground/transaction
            // event will retry. subscription_status stays stale in the
            // meantime, same as any other best-effort sync in this app.
        }
    }

    /// Starts the long-lived StoreKit transaction listener for the app's
    /// lifetime. Fire-and-forget from `init` — this `Task` is never awaited
    /// or cancelled explicitly; it lives as long as the process does, same
    /// as the `NotificationCenter` observer registered alongside it in init.
    private func observeStoreKitEntitlementChanges() async {
        await StoreKitManager.shared.observeTransactionUpdates { [weak self] stillActive in
            guard let self, !stillActive else { return }
            await self.reconcileStoreKitEntitlement()
        }
    }
    
    /// Starts a free trial (called from trial offer UI)
    func startTrial() async -> Bool {
        do {
            let result = try await subscription.startTrial()
            if result.success {
                state.cachedSubscriptionStatus = .trialing
                state.hasShownTrialOffer = true
                afterMutation()
                showToast("Trial started! Enjoy full access for 10 days.")
                return true
            } else {
                showToast(result.message ?? "Couldn't start trial. Try again.")
                return false
            }
        } catch {
            showToast("Couldn't start trial. Check your connection.")
            return false
        }
    }
    
    /// Activates Plus subscription after a successful IAP purchase.
    /// `signedTransaction` is StoreKit's signed JWS for the completed
    /// purchase (see `StoreKitManager.PurchaseOutcome.success`) — the server
    /// re-verifies it against Apple's certificates before activating
    /// anything; a locally-successful purchase alone is never trusted.
    func activateSubscription(signedTransaction: String) async -> Bool {
        do {
            let result = try await subscription.activateSubscription(signedTransaction: signedTransaction)
            if result.success {
                state.cachedSubscriptionStatus = .active
                afterMutation()
                showToast("Welcome to Plus! Full access unlocked.")
                return true
            }
            showToast(result.message ?? "Couldn't verify your purchase. Contact support.")
            return false
        } catch {
            showToast("Couldn't activate subscription. Contact support.")
            return false
        }
    }
    
    /// Checks engagement milestones and triggers trial offer at Day 3.
    /// Skipped while an incoming call is up — that's the one screen in this
    /// app that's genuinely time-sensitive and shouldn't be interrupted.
    func checkEngagementMilestones() {
        guard incomingCall == nil else { return }

        // Day 3 consecutive days trigger
        if state.shouldOfferTrial && !shouldShowTrialOffer {
            shouldShowTrialOffer = true
        }
        
        // Day 30 paywall check
        if state.shouldShowDay30Paywall && !shouldShowDay30Paywall {
            shouldShowDay30Paywall = true
        }
    }
    
    /// Dismisses the trial offer (user said no or dismissed)
    func dismissTrialOffer() {
        state.hasShownTrialOffer = true
        shouldShowTrialOffer = false
        afterMutation()
    }
    
    /// Dismisses the Day 30 paywall
    func dismissDay30Paywall() {
        state.hasShownDay30Paywall = true
        shouldShowDay30Paywall = false
        afterMutation()
    }
    
    /// Checks if user can access a specific scroll. Scroll I is always free —
    /// it's the hook, and gating it hurt conversion more than it helped. Every
    /// other scroll (II+) requires an active Plus subscription or trial. The
    /// day-progress unlock (`scroll.status`) still governs which scroll is
    /// next in the sequence; this is the subscription gate layered on top.
    /// Kept `async` (no network round trip needed anymore) so call sites
    /// don't need to change.
    func canAccessScroll(_ scrollId: Int) async -> ScrollAccess {
        if scrollId == 1 {
            return ScrollAccess(scrollId: scrollId, isAccessible: true, reason: .unlocked)
        }
        if state.hasPlusAccess {
            return ScrollAccess(scrollId: scrollId, isAccessible: true, reason: .trialActive)
        }
        return ScrollAccess(
            scrollId: scrollId,
            isAccessible: false,
            reason: .subscriptionRequired(daysCompleted: state.totalDaysCompleted)
        )
    }
    
    /// Call this on app foreground and after session completion
    func onAppForeground() async {
        await refreshSubscriptionStatus()
        checkEngagementMilestones()
    }
}
