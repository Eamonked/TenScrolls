import SwiftUI

struct TodayView: View {
    @EnvironmentObject var store: AppStore
    var openJournal: () -> Void
    var openInfo: () -> Void
    var openNotifSettings: () -> Void
    var promptSkip: (String) -> Void
    var openScroll: (Scroll) -> Void
    @State private var newHabit = ""

    var theme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                RankBar(info: store.state.levelInfo(), brass: theme.brass, brassDim: theme.brassDim, glow: theme.glow)

                activeScrollCard

                if store.state.targetScrollId != nil {
                    stamps
                }

                streakRow

                habitsSection

                Button {
                    openJournal()
                } label: {
                    Label("Add today's reflection", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle(brass: theme.brass, glow: theme.glow))

                Color.clear.frame(height: 10)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }
        .background(Palette.background)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("DAY \(min(store.state.totalDaysCompleted + 1, 300)) OF 300")
                    .font(AppFont.mono(11))
                    .tracking(1.4)
                    .foregroundColor(theme.brass)
                Text("Today").font(AppFont.display(28))
                    .foregroundColor(Palette.text)
            }
            Spacer()
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "diamond").font(.system(size: 12))
                    Text("\(store.state.sealsAvailable)").font(AppFont.mono(12))
                }
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(Palette.ink2)
                .overlay(Capsule().stroke(Palette.inkLine, lineWidth: 1))
                .clipShape(Capsule())
                .foregroundColor(theme.brass)

                Button(action: openNotifSettings) {
                    Image(systemName: store.state.notifPrefs.enabled ? "bell.fill" : "bell")
                        .foregroundColor(store.state.notifPrefs.enabled ? theme.brass : Palette.textDim)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Palette.ink2))
                        .overlay(Circle().stroke(Palette.inkLine, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button(action: openInfo) {
                    Image(systemName: "info")
                        .foregroundColor(Palette.textDim)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Palette.ink2))
                        .overlay(Circle().stroke(Palette.inkLine, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var activeScrollCard: some View {
        if let active = store.state.activeScroll {
            let days = store.state.scrollDaysCompleted(active.id)
            CardView {
                Text("ACTIVE SCROLL").font(AppFont.mono(10)).tracking(1.4).foregroundColor(Palette.textFaint)
                Text("Scroll \(active.roman)\(active.title.isEmpty ? "" : " — \(active.title)")")
                    .font(AppFont.display(19)).foregroundColor(Palette.text)
                    .padding(.top, 2)
                if !active.theme.isEmpty {
                    Text(active.theme).font(.system(size: 13)).italic().foregroundColor(Palette.textDim)
                        .padding(.top, 2)
                }
                ProgressTrack(pct: min(100, Double(days) / 30 * 100), brassDim: theme.brassDim, glow: theme.glow)
                    .padding(.top, 12)
                Text("\(days) of 30 days complete")
                    .font(AppFont.mono(11)).foregroundColor(Palette.textFaint)
                    .padding(.top, 7)
            }
        } else if let reread = store.state.rereadScroll, let cs = store.state.cycleState {
            let done = cs.daysThisScroll.count
            let goal = Constants.cycleGoalDays
            CardView {
                HStack {
                    Text("CYCLE \(cs.cycle) · REVISITING").font(AppFont.mono(10)).tracking(1.4).foregroundColor(Palette.textFaint)
                    Spacer()
                    Text("SCROLL \(reread.roman) OF X").font(AppFont.mono(10)).tracking(1.4).foregroundColor(Palette.textFaint)
                }
                Text("Scroll \(reread.roman)\(reread.title.isEmpty ? "" : " — \(reread.title)")")
                    .font(AppFont.display(19)).foregroundColor(Palette.text)
                    .padding(.top, 2)
                if !reread.theme.isEmpty {
                    Text(reread.theme).font(.system(size: 13)).italic().foregroundColor(Palette.textDim)
                        .padding(.top, 2)
                }
                ProgressTrack(pct: min(100, Double(done) / Double(goal) * 100), brassDim: theme.brassDim, glow: theme.glow)
                    .padding(.top, 12)
                Text("\(done) of \(goal) days revisited — then the next scroll comes round")
                    .font(AppFont.mono(11)).foregroundColor(Palette.textFaint)
                    .padding(.top, 7)
                Button {
                    openScroll(reread)
                } label: {
                    Label("Read this scroll", systemImage: "book")
                }
                .buttonStyle(GhostButtonStyle())
                .padding(.top, 12)
            }
        } else {
            CardView {
                Text("All ten scrolls mastered").font(AppFont.display(19)).foregroundColor(Palette.text)
                Text("The practice isn't a checklist — it works by returning to the ideas. Begin a new cycle to revisit each scroll, one at a time. Your daily reading keeps counting.")
                    .font(.system(size: 13)).foregroundColor(Palette.textDim).padding(.top, 4)
                Button {
                    store.beginCycle()
                } label: {
                    Label("Begin a new cycle", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(PrimaryButtonStyle(brass: theme.brass, glow: theme.glow))
                .padding(.top, 14)
            }
        }
    }

    private var stamps: some View {
        let key = DateKey.today()
        let entry = store.state.log[key] ?? DayEntry(scrollId: store.state.targetScrollId ?? 0)
        let customPrefs = store.state.windowPrefs
        return HStack(spacing: 12) {
            StampButton(
                label: "DAWN",
                systemImage: "sunrise.fill",
                done: entry.dawn,
                brass: theme.brass,
                glow: theme.glow,
                windowStatus: Session.dawn.windowStatus(startedAt: entry.dawnStartedAt, customPrefs: customPrefs)
            ) {
                let wasDone = entry.dawn
                store.toggleSession(\.dawn)
                if wasDone { promptSkip(key) }
            }
            StampButton(
                label: "MIDDAY",
                systemImage: "sun.max.fill",
                done: entry.midday,
                brass: theme.brass,
                glow: theme.glow,
                windowStatus: Session.midday.windowStatus(startedAt: entry.middayStartedAt, customPrefs: customPrefs)
            ) {
                let wasDone = entry.midday
                store.toggleSession(\.midday)
                if wasDone { promptSkip(key) }
            }
            StampButton(
                label: "DUSK",
                systemImage: "sunset.fill",
                done: entry.dusk,
                brass: theme.brass,
                glow: theme.glow,
                windowStatus: Session.dusk.windowStatus(startedAt: entry.duskStartedAt, customPrefs: customPrefs)
            ) {
                let wasDone = entry.dusk
                store.toggleSession(\.dusk)
                if wasDone { promptSkip(key) }
            }
        }
        .padding(.vertical, 4)
    }

    private var streakRow: some View {
        HStack(spacing: 18) {
            HStack(spacing: 5) {
                Image(systemName: "flame.fill")
                Text("\(store.state.currentStreak) day streak")
            }
            HStack(spacing: 5) {
                Image(systemName: "shield.fill")
                let s = store.state.shieldsAvailable
                Text("\(s) shield\(s == 1 ? "" : "s")")
            }
        }
        .font(AppFont.mono(12))
        .foregroundColor(theme.brass)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    private var habitsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Today's Habits")
            CardView {
                if store.state.habits.isEmpty {
                    EmptyState(text: "No habits yet. Add one below.")
                }
                VStack(spacing: 0) {
                    ForEach(store.state.habits) { habit in
                        VStack(spacing: 0) {
                            HabitRow(
                                habit: habit,
                                done: habit.completedDates.contains(DateKey.today()),
                                streak: store.state.habitStreak(habit),
                                green: Palette.green,
                                onToggle: { store.toggleHabit(habit.id) },
                                onDelete: { store.removeHabit(habit.id) }
                            )
                            if habit.id != store.state.habits.last?.id {
                                Divider().background(Palette.ink3)
                            }
                        }
                    }
                }
                HStack(spacing: 8) {
                    TextField("Add a habit to track daily…", text: $newHabit)
                        .textFieldStyle(AppTextFieldStyle())
                        .onSubmit(commitHabit)
                    Button(action: commitHabit) {
                        Image(systemName: "plus")
                    }
                    .frame(width: 40, height: 40)
                    .background(Palette.ink3)
                    .foregroundColor(theme.brass)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.inkLine, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding(.top, 12)
            }
        }
    }

    private func commitHabit() {
        let trimmed = newHabit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.addHabit(trimmed)
        newHabit = ""
    }
}