import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var infoOpen = false
    @State private var journalOpen = false
    @State private var notifOpen = false
    @State private var editingScroll: Scroll?

    var currentTheme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    var body: some View {
        ZStack(alignment: .top) {
            Palette.background.ignoresSafeArea()

            TabView(selection: $store.selectedTab) {
                NavigationStack {
                    TodayView(openJournal: { journalOpen = true },
                              openInfo: { infoOpen = true },
                              openNotifSettings: { notifOpen = true })
                        .navigationBarHidden(true)
                }
                .tabItem { Label("Today", systemImage: "sunrise") }
                .tag(0)

                NavigationStack {
                    ScrollsView(onOpenScroll: { id in
                        editingScroll = store.state.scrolls.first(where: { $0.id == id })
                    })
                    .navigationBarHidden(true)
                }
                .tabItem { Label("Scrolls", systemImage: "scroll") }
                .tag(1)

                NavigationStack {
                    JournalView(openJournal: { journalOpen = true })
                        .navigationBarHidden(true)
                }
                .tabItem { Label("Journal", systemImage: "book") }
                .tag(2)

                NavigationStack {
                    CaravanView()
                        .navigationBarHidden(true)
                }
                .tabItem { Label("Caravan", systemImage: "person.3") }
                .tag(3)

                NavigationStack {
                    ProgressTabView()
                        .navigationBarHidden(true)
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
        .sheet(isPresented: $journalOpen) {
            JournalComposerSheet(scroll: store.state.activeScroll) { text in
                store.addJournalEntry(text)
                journalOpen = false
            }
        }
        .sheet(item: $editingScroll) { scroll in
            ScrollEditorSheet(scroll: scroll) { updated in
                store.saveScroll(updated)
                editingScroll = nil
            }
        }
        .sheet(isPresented: $infoOpen) {
            InfoSheet()
        }
        .sheet(isPresented: $notifOpen) {
            NotificationSettingsModal()
        }
        .fullScreenCover(item: $store.incomingCall) { call in
            IncomingCallView(
                session: call.session,
                onAccept: { store.answerCall() },
                onDecline: { store.declineCall() }
            )
        }
        .onChange(of: scenePhase) { phase in
            // Refresh one-shot escalation calls whenever the app returns to the foreground.
            if phase == .active { store.syncNotifications() }
        }
    }
}
