import SwiftUI

enum ActiveSheet: Identifiable {
    case scrollEditor(Scroll)
    case info
    case notifSettings
    case skipReason(date: String, isMissedDay: Bool)
    case search
    case library
    case habits

    var id: String {
        switch self {
        case .scrollEditor(let s): return "scroll-\(s.id)"
        case .info: return "info"
        case .notifSettings: return "notif"
        case .skipReason(let d, _): return "skip-\(d)"
        case .search: return "search"
        case .library: return "library"
        case .habits: return "habits"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var activeSheet: ActiveSheet?
    @State private var activeCall: PendingCall?
    @State private var showWeeklyRecap = false

    var currentTheme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    /// `.scrollEditor` (the Scroll reading/editing view) and `.library`
    /// (the Shelf, and — pushed inside its own `NavigationStack` — the Book
    /// reading view) are the two deep-reading surfaces in the app, so they
    /// present full screen via `.fullScreenCover` rather than as a
    /// card-style `.sheet`. Every other `ActiveSheet` case is a lighter,
    /// dismiss-anytime overlay and keeps the standard sheet presentation.
    /// Both presentations below key off this same single source of truth
    /// so only one is ever active at a time.
    private func isFullScreenPresentation(_ sheet: ActiveSheet) -> Bool {
        switch sheet {
        case .scrollEditor, .library: return true
        case .info, .notifSettings, .skipReason, .search, .habits: return false
        }
    }

    /// Filters `activeSheet` down to the card-style cases for `.sheet(item:)`.
    private var sheetBinding: Binding<ActiveSheet?> {
        Binding(
            get: { activeSheet.flatMap { isFullScreenPresentation($0) ? nil : $0 } },
            set: { newValue in
                if let newValue {
                    activeSheet = newValue
                } else if let current = activeSheet, !isFullScreenPresentation(current) {
                    activeSheet = nil
                }
            }
        )
    }

    /// Filters `activeSheet` down to the full-screen cases for `.fullScreenCover(item:)`.
    private var fullScreenSheetBinding: Binding<ActiveSheet?> {
        Binding(
            get: { activeSheet.flatMap { isFullScreenPresentation($0) ? $0 : nil } },
            set: { newValue in
                if let newValue {
                    activeSheet = newValue
                } else if let current = activeSheet, isFullScreenPresentation(current) {
                    activeSheet = nil
                }
            }
        )
    }

    /// The stored appearance preference (which may be `.system`) resolved
    /// against the device's live system color scheme. Everything in this
    /// view — and everything re-published to descendants below — uses this
    /// concrete value rather than the raw stored one.
    var resolvedAppearanceMode: AppearanceMode {
        store.state.appearanceMode.resolved(systemColorScheme: systemColorScheme)
    }

    var body: some View {
        ZStack(alignment: .top) {
            let colors = AdaptivePalette(mode: resolvedAppearanceMode)
            colors.background.ignoresSafeArea()

            TabView(selection: $store.selectedTab) {
                NavigationStack {
                    TodayView(openInfo: { activeSheet = .info },
                              openNotifSettings: { activeSheet = .notifSettings },
                              promptSkip: { date in
                                  activeSheet = .skipReason(date: date, isMissedDay: false)
                              },
                              openScroll: { scroll in attemptOpenScroll(scroll) },
                              openHabits: { activeSheet = .habits })
                        .hideNavigationBar()
                }
                // Today/Scrolls/Journal/Caravan/Progress (the Lux rebuild)
                // now read `LuxColor`, which is itself a dynamic `Color` —
                // see the doc comment on `enum LuxColor` in AppTheme.swift.
                // No `.preferredColorScheme` override needed here: the
                // app-wide one set at the WindowGroup root (from the
                // Appearance picker in Settings) already reaches this tab's
                // content *and* its system-drawn chrome (keyboard,
                // `.confirmationDialog`, status bar) consistently.
                .tabItem { Label("Today", systemImage: "sunrise") }
                .tag(0)

                NavigationStack {
                    ScrollsView(onOpenScroll: { id in
                        if let scroll = store.state.scrolls.first(where: { $0.id == id }) {
                            attemptOpenScroll(scroll)
                        }
                    }, openLibrary: { activeSheet = .library })
                    .hideNavigationBar()
                }
                .tabItem { Label("Scrolls", systemImage: "scroll") }
                .tag(1)

                NavigationStack {
                    JournalView(openSearch: { activeSheet = .search })
                        .hideNavigationBar()
                }
                .tabItem { Label("Journal", systemImage: "book") }
                .tag(2)

                NavigationStack {
                    CaravanView()
                        .hideNavigationBar()
                }
                .tabItem { Label("Caravan", systemImage: "person.3") }
                .tag(3)

                NavigationStack {
                    ProgressTabView()
                        .hideNavigationBar()
                }
                .tabItem { Label("Progress", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(4)
            }
            .tint(currentTheme.brass)
            .injectAppearanceMode(store.state.appearanceMode)

            if let toast = store.toast {
                ToastView(message: toast, brass: currentTheme.brass)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
                    .animation(.easeOut(duration: 0.3), value: store.toast)
                    .injectAppearanceMode(store.state.appearanceMode)
            }
        }
        .sheet(item: sheetBinding) { sheet in
            sheetContent(for: sheet)
                .injectAppearanceMode(store.state.appearanceMode)
        }
        .fullScreenCover(item: fullScreenSheetBinding) { sheet in
            sheetContent(for: sheet)
                .injectAppearanceMode(store.state.appearanceMode)
        }
        .fullScreenCover(item: $activeCall) { call in
            IncomingCallView(
                session: call.session,
                onAccept: { store.answerCall() },
                onDecline: { store.declineCall() }
            )
            .injectAppearanceMode(store.state.appearanceMode)
        }
        .onChange(of: store.incomingCall) { _, newCall in
            if let call = newCall {
                if activeSheet != nil {
                    // Dismiss the open sheet first
                    activeSheet = nil
                    // Wait for the dismissal animation to complete before presenting the call
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        activeCall = call
                    }
                } else {
                    activeCall = call
                }
            } else {
                activeCall = nil
            }
        }
        .fullScreenCover(isPresented: $showWeeklyRecap) { WeeklyRecapView() }
        .fullScreenCover(
            isPresented: Binding(
                get: { store.milestoneReached != nil },
                set: { if !$0 { store.milestoneReached = nil } }
            )
        ) {
            if let milestone = store.milestoneReached {
                MilestoneCelebrationView(milestone: milestone)
                    .injectAppearanceMode(store.state.appearanceMode)
            }
        }
        // Day-complete celebration — fires the moment the third session of the
        // day is stamped (see `AppStore.toggleSession`). Presented after the
        // milestone cover in this chain so a streak milestone and a day-complete
        // on the same tap don't fight; SwiftUI queues the second fullScreenCover
        // to appear once the first is dismissed.
        .fullScreenCover(
            isPresented: Binding(
                get: { store.dayComplete },
                set: { if !$0 { store.dayComplete = false } }
            )
        ) {
            DayCompleteView()
                .injectAppearanceMode(store.state.appearanceMode)
        }
        // Day 3 trial offer — fires the moment `checkEngagementMilestones()`
        // sees 3 consecutive completed days (from `toggleSession`) or on
        // foreground (`onAppForeground`). `dismissTrialOffer()` marks it seen
        // either way, whether closed via "Maybe later" or a swipe-down.
        .fullScreenCover(
            isPresented: Binding(
                get: { store.shouldShowTrialOffer },
                set: { if !$0 { store.dismissTrialOffer() } }
            )
        ) {
            TrialOfferView()
                .injectAppearanceMode(store.state.appearanceMode)
        }
        // Day 30 hard paywall on Scroll II — same trigger/dismiss pattern.
        .fullScreenCover(
            isPresented: Binding(
                get: { store.shouldShowDay30Paywall },
                set: { if !$0 { store.dismissDay30Paywall() } }
            )
        ) {
            Day30PaywallView()
                .injectAppearanceMode(store.state.appearanceMode)
        }
        .alert(
            "Data Recovery",
            isPresented: Binding(
                get: { store.dataRecoveryNotice != nil },
                set: { if !$0 { store.dataRecoveryNotice = nil } }
            ),
            presenting: store.dataRecoveryNotice
        ) { _ in
            Button("OK") { store.dataRecoveryNotice = nil }
        } message: { notice in
            Text(notice)
        }
        .onAppear {
            store.checkPendingAlarmSession()
            runStartOfDayChecks()
            // Refreshes cached subscription status (catches trial expiry) and
            // re-checks the Day 3 / Day 30 triggers against current progress —
            // covers the case where a threshold was crossed in a previous
            // session and the reader is only now reopening the app.
            Task { await store.onAppForeground() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // Refresh one-shot escalation calls whenever the app returns to the foreground.
                store.checkPendingAlarmSession()
                store.syncNotifications()
                runStartOfDayChecks()
                // Shares do get a push (trg_share_push -> send-share-push), but
                // it's best-effort: the recipient may not have granted permission
                // or registered a token yet. This foreground poll is the backstop
                // that guarantees delivery regardless of push state.
                Task { await store.refreshPendingShares() }
                Task { await store.onAppForeground() }
            } else if phase == .inactive || phase == .background {
                // Persistence is debounced while the app is active; make sure a
                // pending write lands before we might get suspended or killed.
                store.flushPendingPersist()
            }
        }
    }

    /// Single choke point for opening any scroll's reader — every scroll
    /// goes through `AppStore.canAccessScroll` (see its doc comment) before
    /// the editor sheet is allowed to present. Scroll I is always free;
    /// Scroll II+ requires Plus. On denial, routes to the Plus paywall
    /// instead — this is the actual enforcement point, since `scroll.status`
    /// only tracks day-progress unlocking, not subscription.
    private func attemptOpenScroll(_ scroll: Scroll) {
        Task {
            let access = await store.canAccessScroll(scroll.id)
            if access.isAccessible {
                activeSheet = .scrollEditor(scroll)
            } else {
                store.shouldShowDay30Paywall = true
            }
        }
    }

    /// Checks that fire when the app comes to the foreground: prompt for a missed
    /// day, then offer the weekly recap (only if nothing else grabbed the screen).
    private func runStartOfDayChecks() {
        checkMissedYesterday()
        if activeSheet == nil, store.incomingCall == nil, store.shouldShowWeeklyRecap() {
            showWeeklyRecap = true
        }
    }

    @ViewBuilder
    private func sheetContent(for sheet: ActiveSheet) -> some View {
        switch sheet {
        case .scrollEditor(let scroll):
            // Route through the Lux $500-club reader. For locked scrolls that
            // have no content yet, ScrollReaderView immediately shows its empty
            // state with a pencil shortcut — same behaviour as before, without
            // the old AdaptivePalette chrome.
            ScrollReaderView(
                scroll: scroll,
                onSave: { updated in
                    store.saveScroll(updated)
                },
                onReadingStarted: {
                    store.recordReadingStarted()
                }
            )
        case .info:
            InfoSheet()
        case .notifSettings:
            NotificationSettingsModal()
        case .skipReason(let date, let isMissedDay):
            SkipReasonSheet(dateKey: date, isMissedDay: isMissedDay) { reason in
                store.recordSkipReason(reason, for: date)
            }
        case .search:
            SearchView { scroll in
                attemptOpenScroll(scroll)
            }
        case .library:
            LibraryView()
        case .habits:
            HabitsView()
        }
    }

    private func checkMissedYesterday() {
        let yesterday = DateKey.add(-1, to: DateKey.today())
        
        // Have they ever completed a day? (to avoid prompting new users)
        guard store.state.totalDaysCompleted > 0 else { return }
        
        let hasReason = store.state.log[yesterday]?.skipReason != nil || store.state.missedDayReasons?[yesterday] != nil
        if hasReason { return }

        let shieldUsed = store.state.shieldUsedDates.contains(yesterday)
        if shieldUsed { return }

        if let entry = store.state.log[yesterday], entry.sessionCount == 0 {
            // Opened app but 0 sessions
            activeSheet = .skipReason(date: yesterday, isMissedDay: true)
        } else if store.state.log[yesterday] == nil {
            // Didn't open app at all yesterday
            activeSheet = .skipReason(date: yesterday, isMissedDay: true)
        }
    }
}
