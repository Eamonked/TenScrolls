import SwiftUI

/// $500 Club rebuild of the Today screen. Same public surface as before,
/// minus `openJournal` (see `addButton` below) — same AppStore/
/// AppState calls otherwise, only the presentation changed.
///
/// The old separate "Practice" and "Add today's reflection" rows are now
/// one button (`addButton`) so there's a single obvious place to add
/// something new. Tapping it asks which of the two the reader means via a
/// `.confirmationDialog`, then routes to exactly the same destinations as
/// before (`openHabits()` / the Journal tab draft flow).
struct TodayView: View {
    @EnvironmentObject var store: AppStore
    var openInfo: () -> Void
    var openNotifSettings: () -> Void
    var promptSkip: (String) -> Void
    var openScroll: (Scroll) -> Void
    var openHabits: () -> Void

    @State private var showingAddChoice = false

    private var todayEntry: DayEntry? {
        store.state.log[DateKey.today()]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                heroSection
                streakRow
                addButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 120)
        }
        .background(LuxColor.bg.ignoresSafeArea())
        .confirmationDialog("What would you like to add?", isPresented: $showingAddChoice, titleVisibility: .visible) {
            Button("New Habit") { openHabits() }
            Button("Reflection") { addReflection() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("DAY \(min(store.state.totalDaysCompleted + 1, 300)) OF 300")
                    .luxEyebrow()
                Text("Today")
                    .font(LuxFont.serif(34))
                    .tracking(-0.3)
                    .foregroundColor(LuxColor.textPrimary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 10) {
                    LevelRingView(progress: store.state.levelInfo().pct / 100, label: Roman.from(max(1, store.state.levelInfo().level)))
                    LuxIconButton(systemImage: store.state.notifPrefs.enabled ? "bell.fill" : "bell", tinted: store.state.notifPrefs.enabled, action: openNotifSettings)
                    LuxIconButton(systemImage: "info", action: openInfo)
                }
                SealsPillView(count: store.state.sealsAvailable)
            }
        }
    }

    // MARK: - Hero (active scroll)

    @ViewBuilder
    private var heroSection: some View {
        if let active = store.state.activeScroll {
            activeScrollHero(scroll: active, days: store.state.scrollDaysCompleted(active.id), captionPrefix: nil)
        } else if let reread = store.state.rereadScroll, let cs = store.state.cycleState {
            activeScrollHero(scroll: reread, days: cs.daysThisScroll.count, captionPrefix: "CYCLE \(cs.cycle) \u{00B7} REVISITING")
        } else {
            LuxCard {
                VStack(spacing: 16) {
                    Text("All Ten Scrolls Mastered")
                        .font(LuxFont.serif(22))
                        .foregroundColor(LuxColor.textPrimary)
                        .multilineTextAlignment(.center)
                    Text("The practice isn't a checklist \u{2014} it works by returning to the ideas. Begin a new cycle to revisit each scroll, one at a time.")
                        .font(LuxFont.sans(13))
                        .foregroundColor(LuxColor.textSecondary)
                        .multilineTextAlignment(.center)
                    Button {
                        store.beginCycle()
                    } label: {
                        Text("Begin a New Cycle")
                    }
                    .buttonStyle(LuxPrimaryButtonStyle())
                    .padding(.top, 4)
                }
            }
        }
    }

    private func activeScrollHero(scroll: Scroll, days: Int, captionPrefix: String?) -> some View {
        LuxCard {
            VStack(spacing: 20) {
                Button { openScroll(scroll) } label: {
                    VStack(spacing: 6) {
                        Text(captionPrefix ?? "ACTIVE SCROLL")
                            .luxEyebrow(color: LuxColor.textMuted, tracking: 1.6)
                        Text("Scroll \(scroll.roman)\(scroll.title.isEmpty ? "" : " \u{2014} \(scroll.title)")")
                            .font(LuxFont.serif(20))
                            .foregroundColor(LuxColor.textPrimary)
                            .multilineTextAlignment(.center)
                        if !scroll.theme.isEmpty {
                            Text(scroll.theme)
                                .font(LuxFont.sans(13))
                                .italic()
                                .foregroundColor(LuxColor.goldMuted)
                                .multilineTextAlignment(.center)
                        }
                        LuxThinProgress(pct: Double(days) / 30.0)
                            .padding(.top, 6)
                        Text("Day \(Roman.from(max(1, days))) of \(Roman.from(30))")
                            .font(LuxFont.mono(10))
                            .tracking(0.8)
                            .foregroundColor(LuxColor.textSecondary)
                    }
                }
                .buttonStyle(.plain)

                LuxDayTimeline(entry: todayEntry, customPrefs: store.state.windowPrefs, onToggle: handleToggle)

                if let nextSession = nextIncompleteSession {
                    Button {
                        openScroll(scroll)
                    } label: {
                        HStack(spacing: 6) {
                            Text("Read \(nextSession.label) Scroll")
                            Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .buttonStyle(LuxPrimaryButtonStyle())
                }
            }
        }
    }

    private var nextIncompleteSession: Session? {
        Session.allCases.first { !(todayEntry?.isCompleted(for: $0) ?? false) }
    }

    private func handleToggle(_ session: Session) {
        let key = DateKey.today()
        let wasDone = store.state.log[key]?.isCompleted(for: session) ?? false
        store.toggleSession(session)
        if wasDone { promptSkip(key) }
    }

    // MARK: - Streak row

    private var streakRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame").font(.system(size: 10, weight: .light))
            Text("\(Roman.from(max(0, store.state.currentStreak))) DAY STREAK")
            Text("\u{2022}").foregroundColor(LuxColor.textMuted)
            Image(systemName: "shield").font(.system(size: 10, weight: .light))
            Text("\(Roman.from(max(0, store.state.shieldsAvailable))) SHIELDS")
        }
        .font(LuxFont.sans(10, weight: .medium))
        .tracking(1.2)
        .foregroundColor(LuxColor.textSecondary)
        .opacity(0.8)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Add (habit or reflection)

    /// Single entry point for both the old "Practice" row (opens `HabitsView`
    /// as a sheet) and the old "Add today's reflection" row (drops into a
    /// Journal draft). Tapping this just asks which one via a
    /// `.confirmationDialog` in `body` — keeps Today simple with one obvious
    /// button instead of two similar-looking rows.
    private var addButton: some View {
        LuxReflectionBookCard(subtitle: addSubtitle) {
            showingAddChoice = true
        }
    }

    private var addSubtitle: String {
        let habits = store.state.habits
        guard !habits.isEmpty else { return "Add a habit or a reflection" }
        let key = DateKey.today()
        let done = habits.filter { $0.completedDates.contains(key) }.count
        return "\(done) of \(habits.count) habits today \u{2022} tap to add more"
    }

    /// Switches to the Journal tab and starts an inline draft there (the
    /// same flow as JournalView's pencil button) rather than presenting the
    /// old modal `JournalComposerSheet` — that sheet is now reserved for
    /// quote-capture from the Scroll/Library readers (see `Sheets.swift`).
    /// `DraftEntryRow.onAppear` autofocuses the new draft's text field once
    /// the tab switch lands, so this still drops the reader straight into
    /// writing.
    private func addReflection() {
        store.selectedTab = 2
        store.addDraftEntry()
    }
}

/// A thin 2pt gold progress line for the hero card (percent through the
/// current scroll's 30 days) — distinct from `LuxDayTimeline`'s session dots.
private struct LuxThinProgress: View {
    let pct: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(LuxColor.cardBorder).frame(height: 2)
                Rectangle().fill(LuxColor.gold).frame(width: geo.size.width * max(0, min(1, pct)), height: 2)
            }
        }
        .frame(height: 2)
        .frame(maxWidth: 160)
    }
}

/// Three-column Dawn / Midday / Dusk timeline connected by a hairline,
/// replacing the old five-node `DayJourneyPath` circle path. Each column
/// shows a line icon, the session label, and either a gold check (done) or
/// its live countdown / clock text in stone.
private struct LuxDayTimeline: View {
    let entry: DayEntry?
    let customPrefs: SessionWindowPrefs?
    let onToggle: (Session) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 0) {
                column(.dawn, icon: "sun.max", now: context.date)
                connector
                column(.midday, icon: "sun.max.fill", now: context.date)
                connector
                column(.dusk, icon: "moon.stars", now: context.date)
            }
        }
    }

    private var connector: some View {
        Rectangle().fill(LuxColor.cardBorder).frame(height: 0.5).padding(.bottom, 22)
    }

    private func column(_ session: Session, icon: String, now: Date) -> some View {
        let done = entry?.isCompleted(for: session) ?? false
        let status = session.windowStatus(at: now, startedAt: entry?.startedAt(for: session), customPrefs: customPrefs)
        let interactive = done || status == .open || status == .grace

        return Button {
            onToggle(session)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .light))
                    .foregroundColor(done ? LuxColor.gold : LuxColor.textMuted)
                Text(session.label.uppercased())
                    .font(LuxFont.sans(8, weight: .medium))
                    .tracking(1.2)
                    .foregroundColor(LuxColor.textSecondary)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(LuxColor.gold)
                } else {
                    Text(status == .upcoming ? clockLabel(session) : (status.displayHint))
                        .font(LuxFont.mono(9))
                        .foregroundColor(LuxColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(!interactive)
        .opacity(interactive || done ? 1 : 0.5)
    }

    private func clockLabel(_ session: Session) -> String {
        let window = session.timeWindow(customPrefs: customPrefs)
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        var c = DateComponents()
        c.hour = window.start.hour
        c.minute = window.start.minute
        let d = Calendar.current.date(from: c) ?? Date()
        return f.string(from: d)
    }
}

private extension SessionWindowStatus {
    /// Short lowercase hint used in the timeline column when a session isn't
    /// done yet: "in iv hours" reads too fussy in Roman numerals here, so
    /// this stays in plain words per column, kept intentionally terse.
    var displayHint: String {
        switch self {
        case .open: return "now"
        case .grace: return "grace"
        case .closed: return "missed"
        case .upcoming: return ""
        }
    }
}
