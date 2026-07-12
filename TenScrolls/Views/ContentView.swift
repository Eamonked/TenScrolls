import SwiftUI

enum ActiveSheet: Identifiable {
    case journal
    case scrollEditor(Scroll)
    case info
    case notifSettings
    case skipReason(date: String, isMissedDay: Bool)
    case search

    var id: String {
        switch self {
        case .journal: return "journal"
        case .scrollEditor(let s): return "scroll-\(s.id)"
        case .info: return "info"
        case .notifSettings: return "notif"
        case .skipReason(let d, _): return "skip-\(d)"
        case .search: return "search"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeSheet: ActiveSheet?
    @State private var activeCall: PendingCall?
    @State private var showWeeklyRecap = false

    var currentTheme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    var body: some View {
        ZStack(alignment: .top) {
            Palette.background.ignoresSafeArea()

            TabView(selection: $store.selectedTab) {
                NavigationStack {
                    TodayView(openJournal: { activeSheet = .journal },
                              openInfo: { activeSheet = .info },
                              openNotifSettings: { activeSheet = .notifSettings },
                              promptSkip: { date in
                                  activeSheet = .skipReason(date: date, isMissedDay: false)
                              },
                              openScroll: { scroll in activeSheet = .scrollEditor(scroll) })
                        .hideNavigationBar()
                }
                .tabItem { Label("Today", systemImage: "sunrise") }
                .tag(0)

                NavigationStack {
                    ScrollsView(onOpenScroll: { id in
                        if let scroll = store.state.scrolls.first(where: { $0.id == id }) {
                            activeSheet = .scrollEditor(scroll)
                        }
                    })
                    .hideNavigationBar()
                }
                .tabItem { Label("Scrolls", systemImage: "scroll") }
                .tag(1)

                NavigationStack {
                    JournalView(openJournal: { activeSheet = .journal },
                                openSearch: { activeSheet = .search })
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

            if let toast = store.toast {
                ToastView(message: toast, brass: currentTheme.brass)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
                    .animation(.easeOut(duration: 0.3), value: store.toast)
            }
        }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(for: sheet)
        }
        #if os(macOS)
        .sheet(item: $activeCall) { call in
            IncomingCallView(
                session: call.session,
                onAccept: { store.answerCall() },
                onDecline: { store.declineCall() }
            )
        }
        #else
        .fullScreenCover(item: $activeCall) { call in
            IncomingCallView(
                session: call.session,
                onAccept: { store.answerCall() },
                onDecline: { store.declineCall() }
            )
        }
        #endif
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
        #if os(macOS)
        .sheet(isPresented: $showWeeklyRecap) { WeeklyRecapView() }
        #else
        .fullScreenCover(isPresented: $showWeeklyRecap) { WeeklyRecapView() }
        #endif
        .onAppear {
            store.checkPendingAlarmSession()
            runStartOfDayChecks()
        }
        .onChange(of: scenePhase) { _, phase in
            // Refresh one-shot escalation calls whenever the app returns to the foreground.
            if phase == .active {
                store.checkPendingAlarmSession()
                store.syncNotifications()
                runStartOfDayChecks()
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
        case .journal:
            JournalComposerSheet(scroll: store.state.activeScroll) { text in
                store.addJournalEntry(text)
                activeSheet = nil
            }
        case .scrollEditor(let scroll):
            ScrollEditorSheet(scroll: scroll, onSave: { updated in
                store.saveScroll(updated)
                activeSheet = nil
            }, onReadingStarted: {
                store.recordReadingStarted()
            })
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
                activeSheet = .scrollEditor(scroll)
            }
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