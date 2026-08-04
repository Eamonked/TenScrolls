import SwiftUI

/// Dedicated screen for the daily practice/habit checklist — pulled out of
/// the old inline PRACTICE card on Today into its own sheet (see
/// `TodayView`'s combined "Add today's reflection" button, which offers
/// this as one of its two choices) so it has room to breathe: a real streak
/// per habit, a clearer add flow, and space to grow (editing, reordering,
/// etc.) without cramming back into the Today card.
/// Same `AppStore` surface as before — `toggleHabit`/`addHabit`/
/// `removeHabit`/`habitStreak` — only the presentation is new.
struct HabitsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var newHabit = ""
    @FocusState private var addFieldFocused: Bool

    private var habits: [Habit] { store.state.habits }

    private var doneToday: Int {
        let key = DateKey.today()
        return habits.filter { $0.completedDates.contains(key) }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if habits.isEmpty {
                    LuxEmptyLine(text: "No practices yet. Add one below.", height: 80)
                } else {
                    VStack(spacing: 10) {
                        ForEach(habits) { habit in
                            habitRow(habit)
                        }
                    }
                }

                addRow
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .background(LuxColor.bg.ignoresSafeArea())
        .onAppear { addFieldFocused = habits.isEmpty }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PRACTICE").luxEyebrow()
                Text("Practice")
                    .font(LuxFont.serif(32))
                    .tracking(-0.3)
                    .foregroundColor(LuxColor.textPrimary)
                if !habits.isEmpty {
                    Text("\(doneToday) of \(habits.count) today")
                        .font(LuxFont.sans(11))
                        .foregroundColor(LuxColor.textSecondary)
                }
            }
            Spacer()
            LuxIconButton(systemImage: "xmark", action: { dismiss() })
        }
    }

    // MARK: - Habit row

    private func habitRow(_ habit: Habit) -> some View {
        LuxRowCard(cornerRadius: 16) {
            HStack(spacing: 14) {
                Button { store.toggleHabit(habit.id) } label: {
                    LuxCheckbox(done: habit.completedDates.contains(DateKey.today()))
                }
                .buttonStyle(.plain)
                Text(habit.name)
                    .font(LuxFont.sans(14))
                    .foregroundColor(LuxColor.textPrimary)
                Spacer()
                Text(streakLabel(habit))
                    .font(LuxFont.mono(10))
                    .foregroundColor(LuxColor.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .contextMenu {
            Button(role: .destructive) { store.removeHabit(habit.id) } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    /// "II D" for a live streak, or an em dash rather than a misleading
    /// "I D" for a habit not currently on one (the old inline card's
    /// `max(1, ...)` made a 0-day streak read as a 1-day streak).
    private func streakLabel(_ habit: Habit) -> String {
        let streak = store.state.habitStreak(habit)
        return streak > 0 ? "\(Roman.from(streak)) D" : "\u{2014}"
    }

    // MARK: - Add row

    private var addRow: some View {
        LuxRowCard(cornerRadius: 16) {
            HStack(spacing: 10) {
                TextField("", text: $newHabit, prompt: Text("Add a practice\u{2026}").foregroundColor(LuxColor.textMuted))
                    .font(LuxFont.sans(13))
                    .foregroundColor(LuxColor.textPrimary)
                    .focused($addFieldFocused)
                    .onSubmit(commitHabit)
                if !newHabit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: commitHabit) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(LuxColor.gold)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func commitHabit() {
        let trimmed = newHabit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.addHabit(trimmed)
        newHabit = ""
        addFieldFocused = true
    }
}
