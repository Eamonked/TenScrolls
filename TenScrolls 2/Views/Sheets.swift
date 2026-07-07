import SwiftUI
import UserNotifications

struct ScrollEditorSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let scroll: Scroll
    var onSave: (Scroll) -> Void

    @State private var title: String
    @State private var theme: String
    @State private var notes: String

    init(scroll: Scroll, onSave: @escaping (Scroll) -> Void) {
        self.scroll = scroll
        self.onSave = onSave
        _title = State(initialValue: scroll.title)
        _theme = State(initialValue: scroll.theme)
        _notes = State(initialValue: scroll.notes)
    }

    var themeOption: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if scroll.status == .active {
                        Text("Complete 30 days on this scroll to earn 200 XP, 20 seals, and unlock the next.")
                            .font(.system(size: 13)).foregroundColor(Palette.textDim)
                            .padding(.bottom, 6)
                    }
                    Text("TITLE").font(AppFont.mono(10.5)).tracking(1.2).foregroundColor(Palette.textFaint)
                    TextField("Give this scroll a title", text: $title).textFieldStyle(AppTextFieldStyle())

                    Text("ONE-LINE THEME").font(AppFont.mono(10.5)).tracking(1.2).foregroundColor(Palette.textFaint).padding(.top, 12)
                    TextField("e.g. what this scroll asks of you", text: $theme).textFieldStyle(AppTextFieldStyle())

                    Text("YOUR NOTES").font(AppFont.mono(10.5)).tracking(1.2).foregroundColor(Palette.textFaint).padding(.top, 12)
                    TextEditor(text: $notes)
                        .frame(minHeight: 140)
                        .padding(8)
                        .scrollContentBackground(.hidden)
                        .background(Palette.ink3)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.inkLine, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .foregroundColor(Palette.text)

                    Button("Save") {
                        var updated = scroll
                        updated.title = title
                        updated.theme = theme
                        updated.notes = notes
                        onSave(updated)
                        dismiss()
                    }
                    .buttonStyle(PrimaryButtonStyle(brass: themeOption.brass, glow: themeOption.glow))
                    .padding(.top, 18)
                }
                .padding(20)
            }
            .background(Palette.ink2.ignoresSafeArea())
            .navigationTitle("Scroll \(scroll.roman)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .presentationDetents([.large])
    }
}

struct JournalComposerSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let scroll: Scroll?
    var onSave: (String) -> Void
    @State private var text = ""

    var themeOption: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(scroll.map { "SCROLL \($0.roman)" } ?? "GENERAL") · \(DateKey.short(DateKey.today())) · +15 XP")
                    .font(AppFont.mono(10.5)).tracking(1.0).foregroundColor(Palette.textFaint)
                TextEditor(text: $text)
                    .frame(minHeight: 220)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(Palette.ink3)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.inkLine, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .foregroundColor(Palette.text)
                Button("Save entry") {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onSave(trimmed)
                }
                .buttonStyle(PrimaryButtonStyle(brass: themeOption.brass, glow: themeOption.glow, disabled: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.top, 8)
                Spacer()
            }
            .padding(20)
            .background(Palette.ink2.ignoresSafeArea())
            .navigationTitle("Today's Reflection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct NotificationSettingsModal: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var status: UNAuthorizationStatus = .notDetermined

    var themeOption: ThemeOption { Palette.theme(for: store.state.activeThemeId) }
    private var prefs: NotificationPrefs { store.state.notifPrefs }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Get reminded when it's time for your Dawn, Midday, and Dusk reading. If a session goes unanswered, Ten Scrolls escalates to a full-screen call.")
                        .font(.system(size: 13)).foregroundColor(Palette.textDim)

                    // Master toggle
                    CardView {
                        HStack {
                            Image(systemName: prefs.enabled ? "bell.badge.fill" : "bell.slash")
                                .foregroundColor(prefs.enabled ? themeOption.brass : Palette.textFaint)
                            Text(prefs.enabled ? "Reminders on" : "Reminders off")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(Palette.text)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { prefs.enabled },
                                set: { newValue in Task { await store.setNotificationsEnabled(newValue) } }
                            ))
                            .labelsHidden()
                            .tint(themeOption.brass)
                        }
                        if status == .denied {
                            Divider().background(Palette.ink3).padding(.vertical, 10)
                            Label("Notifications are turned off in iOS Settings. Enable them for Ten Scrolls to receive reminders.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.system(size: 12)).foregroundColor(Palette.textDim)
                        }
                    }

                    // Reminder times
                    SectionLabel(text: "Reminder Times")
                    CardView {
                        timeRow(session: .dawn, keyPath: \.dawnTime)
                        Divider().background(Palette.ink3)
                        timeRow(session: .midday, keyPath: \.middayTime)
                        Divider().background(Palette.ink3)
                        timeRow(session: .dusk, keyPath: \.duskTime)
                    }
                    .disabled(!prefs.enabled)
                    .opacity(prefs.enabled ? 1 : 0.5)

                    // Escalation call
                    SectionLabel(text: "Escalation Call")
                    CardView {
                        HStack {
                            Image(systemName: "phone.arrow.up.right")
                                .foregroundColor(prefs.callEnabled ? themeOption.brass : Palette.textFaint)
                            Text("Call me if unanswered")
                                .font(.system(size: 14)).foregroundColor(Palette.text)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { prefs.callEnabled },
                                set: { v in update { $0.callEnabled = v } }
                            ))
                            .labelsHidden()
                            .tint(themeOption.brass)
                        }
                        if prefs.callEnabled {
                            Divider().background(Palette.ink3).padding(.vertical, 12)
                            Stepper(value: Binding(
                                get: { prefs.callTimeoutMinutes },
                                set: { v in update { $0.callTimeoutMinutes = v } }
                            ), in: 1...120, step: 1) {
                                Text("After \(prefs.callTimeoutMinutes) min")
                                    .font(.system(size: 14)).foregroundColor(Palette.text)
                            }
                        }
                    }
                    .disabled(!prefs.enabled)
                    .opacity(prefs.enabled ? 1 : 0.5)

                    if prefs.enabled && status == .authorized {
                        Button {
                            store.notifier.sendTest()
                        } label: {
                            Label("Send test notification", systemImage: "paperplane")
                        }
                        .buttonStyle(GhostButtonStyle())
                    }

                    Color.clear.frame(height: 8)
                }
                .padding(20)
            }
            .background(Palette.ink2.ignoresSafeArea())
            .navigationTitle("Reminders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .presentationDetents([.large])
        .task { status = await store.notifier.authorizationStatus() }
    }

    private func timeRow(session: Session, keyPath: WritableKeyPath<NotificationPrefs, String>) -> some View {
        HStack {
            Label(session.label, systemImage: session.systemImage)
                .font(.system(size: 14))
                .foregroundColor(Palette.text)
            Spacer()
            DatePicker("", selection: Binding(
                get: { dateFromHHmm(prefs[keyPath: keyPath]) },
                set: { newDate in update { $0[keyPath: keyPath] = hhmm(from: newDate) } }
            ), displayedComponents: .hourAndMinute)
            .labelsHidden()
        }
        .padding(.vertical, 6)
    }

    /// Applies a mutation to the current prefs and persists + reschedules.
    private func update(_ mutate: (inout NotificationPrefs) -> Void) {
        var p = store.state.notifPrefs
        mutate(&p)
        store.updateNotifPrefs(p)
    }
}

/// "HH:mm" → today's `Date` at that time (for DatePicker binding).
private func dateFromHHmm(_ string: String) -> Date {
    let parts = string.split(separator: ":")
    var comps = DateComponents()
    comps.hour = Int(parts.first ?? "0") ?? 0
    comps.minute = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
    return Calendar.current.date(from: comps) ?? Date()
}

/// `Date` → "HH:mm".
private func hhmm(from date: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
}

struct InfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Work through one scroll at a time, reading it three times a day — dawn, midday, and dusk — for 30 days before moving to the next. Ten scrolls, thirty days each, roughly a year of practice.")
                    Text("Every session earns XP toward your rank. Full days and streak milestones earn seals, spendable on cosmetic seal colors. Every 7 completed days banks a streak shield that auto-covers one missed day.")
                    Text("Set a trader handle in The Caravan tab to join the shared leaderboard and compare streaks with friends. Your handle, level, and streak become visible to other traders once set.")
                    Text("Add your own title, theme, and notes to each scroll from your copy of the book — this app doesn't include the text itself, just the structure and the game layer to help you stay with it.")
                }
                .font(.system(size: 13)).foregroundColor(Palette.textDim)
                .padding(20)
            }
            .background(Palette.ink2.ignoresSafeArea())
            .navigationTitle("How This Works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
