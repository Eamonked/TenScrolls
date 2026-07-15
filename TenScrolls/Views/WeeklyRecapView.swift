import SwiftUI

struct WeeklyRecapView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.appearanceMode) var appearanceMode
    @Environment(\.dismiss) private var dismiss

    var theme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }
    
    // Derived Data

    /// Date keys for the last seven days (today back through six days ago).
    private var weekDayKeys: [String] {
        let today = DateKey.today()
        return (0..<7).map { DateKey.add(-$0, to: today) }
    }

    private var daysCompleted: Int {
        weekDayKeys.filter { store.state.isDayComplete($0) }.count
    }
    
    private var highlightEntry: JournalEntry? {
        let today = Date()
        let calendar = Calendar.current
        let recentEntries = store.state.journal.filter {
            let entryDate = DateKey.date(from: $0.date)
            let daysSince = calendar.dateComponents([.day], from: entryDate, to: today).day ?? 0
            return daysSince < 7 && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return recentEntries.randomElement()
    }
    
    // Helper function to get day name from date key
    private func dayName(for dateKey: String) -> String {
        let date = DateKey.date(from: dateKey)
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE" // Full day name
        return formatter.string(from: date).uppercased()
    }
    
    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        NavigationStack {
            ZStack {
                colors.background.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 30) {
                        
                        // Header
                        VStack(spacing: 8) {
                            Text("Your Week")
                                .font(AppFont.mono(12))
                                .tracking(2.0)
                                .foregroundColor(theme.brass)
                            Text("Looking Back")
                                .font(AppFont.display(32))
                                .foregroundColor(colors.text)
                        }
                        .padding(.top, 40)
                        
                        // Stats Card
                        VStack(spacing: 20) {
                            HStack {
                                StatBox(title: "DAYS READ", value: "\(daysCompleted)/7", theme: theme, colors: colors)
                                StatBox(title: "STREAK", value: "\(store.state.currentStreak)", theme: theme, colors: colors)
                            }
                            
                            // Habit Health
                            VStack(alignment: .leading, spacing: 12) {
                                Text("HABIT HEALTH").font(AppFont.mono(10)).tracking(1.5).foregroundColor(colors.textDim)
                                if store.state.habits.isEmpty {
                                    Text("No habits tracked this week.")
                                        .font(.system(size: 13))
                                        .foregroundColor(colors.textFaint)
                                }
                                ForEach(store.state.habits) { habit in
                                    HStack {
                                        Text(habit.name)
                                            .font(.system(size: 14))
                                            .foregroundColor(colors.text)
                                        Spacer()
                                        let upheld = weekDayKeys.filter { habit.completedDates.contains($0) }.count
                                        Text("\(upheld)/7")
                                            .font(AppFont.mono(12))
                                            .foregroundColor(upheld == 0 ? colors.textFaint : theme.brass)
                                    }
                                }
                            }
                            .padding(.top, 10)
                        }
                        .padding(24)
                        .background(colors.ink2)
                        .cornerRadius(20)
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(colors.inkLine, lineWidth: 1))
                        .padding(.horizontal, 24)
                        
                        // Reflection
                        if let entry = highlightEntry {
                            VStack(spacing: 16) {
                                Text("A THOUGHT FROM \(dayName(for: entry.date))")
                                    .font(AppFont.mono(11))
                                    .tracking(2.0)
                                    .foregroundColor(theme.brass)
                                
                                Text("\"\(entry.text)\"")
                                    .font(.system(size: 18, weight: .regular, design: .serif))
                                    .italic()
                                    .foregroundColor(colors.text)
                                    .multilineTextAlignment(.center)
                                    .lineSpacing(6)
                                    .padding(.horizontal, 20)
                            }
                            .padding(.top, 20)
                        }
                        
                        Spacer(minLength: 40)
                        
                        Button {
                            store.recordWeeklyRecapShown()
                            dismiss()
                        } label: {
                            Text("Continue to Today")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(colors.background)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(theme.brass)
                                .cornerRadius(14)
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)
                    }
                }
            }
            .navigationBarHidden(true)
        }
    }
}

private struct StatBox: View {
    let title: String
    let value: String
    let theme: ThemeOption
    let colors: AdaptivePalette
    
    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(AppFont.mono(10))
                .tracking(1.5)
                .foregroundColor(colors.textDim)
            Text(value)
                .font(AppFont.display(24))
                .foregroundColor(colors.text)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(colors.ink3)
        .cornerRadius(12)
    }
}
