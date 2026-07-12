import SwiftUI
import UserNotifications
import AlarmKit
import Combine

struct ScrollEditorSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let scroll: Scroll
    var onSave: (Scroll) -> Void
    var onReadingComplete: (() -> Void)? = nil  // Callback when friction gate is passed
    var onReadingStarted: (() -> Void)? = nil  // Callback the instant the reading view first appears

    @State private var title: String
    @State private var theme: String
    @State private var notes: String
    @State private var editing = false
    
    // Intentional friction gate state
    @State private var scrollProgress: CGFloat = 0
    @State private var hasScrolledToBottom = false
    @State private var readingStartTime: Date?
    @State private var currentTime = Date()  // For timer updates

    // Highlight-to-journal state: set when the reader picks "Add to Journal"
    // from a text selection; presenting a sheet for it is driven off this.
    @State private var pendingExcerpt: String?

    // `scroll` is a snapshot taken when the sheet was presented, so writing
    // a bookmark to the store doesn't change what this view sees. Track the
    // tap locally too, purely so the "you stopped here" feedback shows up
    // the instant it happens rather than the next time the scroll is opened.
    @State private var justBookmarkedIndex: Int?
    private let bookmarkHaptic = UIImpactFeedbackGenerator(style: .light)
    
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    private var minimumReadingTimeSeconds: TimeInterval { 30 } // Minimum 30 seconds
    private var hasMetTimeRequirement: Bool {
        guard let startTime = readingStartTime else { return false }
        return currentTime.timeIntervalSince(startTime) >= minimumReadingTimeSeconds
    }
    private var canComplete: Bool {
        let result = editing || hasScrolledToBottom && hasMetTimeRequirement
        // Notify when reading is complete (for session validation)
        if result && !editing && onReadingComplete != nil {
            Task { @MainActor in
                onReadingComplete?()
            }
        }
        return result
    }

    init(scroll: Scroll, onSave: @escaping (Scroll) -> Void, onReadingComplete: (() -> Void)? = nil, onReadingStarted: (() -> Void)? = nil) {
        self.scroll = scroll
        self.onSave = onSave
        self.onReadingComplete = onReadingComplete
        self.onReadingStarted = onReadingStarted
        _title = State(initialValue: scroll.title)
        _theme = State(initialValue: scroll.theme)
        _notes = State(initialValue: scroll.notes)
    }

    var themeOption: ThemeOption { Palette.theme(for: store.state.activeThemeId) }
    var hasContent: Bool { !title.isEmpty || !notes.isEmpty || !theme.isEmpty }
    var days: Int { store.state.scrollDaysCompleted(scroll.id) }

    var body: some View {
        NavigationStack {
            ScrollView {
                if editing {
                    editingView
                } else {
                    readingView
                }
            }
            .background(Palette.ink2.ignoresSafeArea())
            .navigationTitle(editing ? "Edit Scroll \(scroll.roman)" : "Scroll \(scroll.roman)")
            .inlineNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if editing {
                            editing = false
                        } else if canComplete {
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: editing ? "chevron.left" : "xmark")
                            if !editing && !canComplete && hasContent {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(Palette.textFaint)
                            }
                        }
                    }
                    .disabled(!editing && !canComplete && hasContent)
                    .opacity((editing || canComplete || !hasContent) ? 1.0 : 0.5)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if editing {
                        Button("Save") {
                            var updated = scroll
                            updated.title = title
                            updated.theme = theme
                            updated.notes = Scroll.normalizedNotes(notes)
                            onSave(updated)
                            editing = false
                        }
                    } else {
                        Button {
                            editing = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: editing)
        }
        .presentationDetents([.large])
        .onAppear {
            // If the scroll has no content yet, start in edit mode
            if !hasContent { editing = true }
        }
        .onReceive(timer) { time in
            currentTime = time
        }
        .interactiveDismissDisabled(!canComplete && hasContent && !editing)
    }
    // MARK: - Reading View

    private var readingView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Header ornament
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Text("⟐")
                                .font(.system(size: 22))
                                .foregroundColor(themeOption.brass.opacity(0.5))
                            Text("SCROLL \(scroll.roman)")
                                .font(AppFont.mono(11))
                                .tracking(2.4)
                                .foregroundColor(themeOption.brass.opacity(0.7))
                        }
                        Spacer()
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 20)
                    .id("top")

                    // Status pill
                    HStack {
                        Spacer()
                        statusPill
                        Spacer()
                    }
                    .padding(.bottom, 28)

                    // Title
                    if !title.isEmpty {
                        Text(title)
                            .font(AppFont.display(26, weight: .bold))
                            .foregroundColor(Palette.text)
                            .multilineTextAlignment(.leading)
                            .padding(.bottom, 4)
                    }

                    // Theme line
                    if !theme.isEmpty {
                        Text(theme)
                            .font(.system(size: 15, weight: .medium, design: .serif))
                            .italic()
                            .foregroundColor(themeOption.brass)
                            .padding(.bottom, 20)
                    }

                    // Decorative divider
                    if !title.isEmpty || !theme.isEmpty {
                        HStack(spacing: 10) {
                            Rectangle().fill(themeOption.brass.opacity(0.2)).frame(height: 1)
                            Circle().fill(themeOption.brass.opacity(0.35)).frame(width: 5, height: 5)
                            Rectangle().fill(themeOption.brass.opacity(0.2)).frame(height: 1)
                        }
                        .padding(.bottom, 24)
                    }

                    // Notes body — rendered paragraph by paragraph so each one
                    // can be highlighted (Add to Journal) and tapped (bookmark
                    // where reading stopped) independently.
                    if !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 22) {
                            ForEach(Array(scroll.paragraphs.enumerated()), id: \.offset) { index, paragraph in
                                paragraphBlock(paragraph, index: index)
                                    .id(index)
                            }
                        }
                    }

                    // Empty state
                    if !hasContent {
                        VStack(spacing: 14) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 32))
                                .foregroundColor(Palette.textFaint)
                            Text("No notes yet")
                                .font(AppFont.display(18))
                                .foregroundColor(Palette.textDim)
                            Text("Tap the pencil icon above to transcribe\nyour title and notes from the book.")
                                .font(.system(size: 13))
                                .foregroundColor(Palette.textFaint)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                    }

                    // Bottom ornament and friction gate indicator
                    VStack(spacing: 16) {
                        HStack {
                            Spacer()
                            Text("⟐")
                                .font(.system(size: 18))
                                .foregroundColor(themeOption.brass.opacity(0.25))
                            Spacer()
                        }
                        
                        // Reading progress indicator
                        if hasContent && !canComplete {
                            VStack(spacing: 8) {
                                if !hasScrolledToBottom {
                                    Label("Scroll to the end to complete", systemImage: "arrow.down")
                                        .font(.system(size: 13))
                                        .foregroundColor(Palette.textFaint)
                                } else if !hasMetTimeRequirement {
                                    let remaining = Int(minimumReadingTimeSeconds - currentTime.timeIntervalSince(readingStartTime ?? Date()))
                                    Label("Take your time (\(max(0, remaining))s)", systemImage: "clock")
                                        .font(.system(size: 13))
                                        .foregroundColor(Palette.textFaint)
                                }
                            }
                            .padding(.vertical, 12)
                        }
                    }
                    .padding(.top, 36)
                    .padding(.bottom, 20)
                    .id("bottom")
                    
                    // Invisible marker for scroll detection
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            // When this appears, user has scrolled to bottom
                            if hasContent && !hasScrolledToBottom {
                                hasScrolledToBottom = true
                            }
                        }
                }
                .padding(.horizontal, 28)
            }
            .onAppear {
                if hasContent && readingStartTime == nil {
                    readingStartTime = Date()
                    onReadingStarted?()
                }
                if let bookmark = scroll.bookmarkParagraphIndex {
                    // Slight delay lets the ScrollView finish laying out before
                    // we ask it to jump — jumping on the same frame it appears
                    // can silently no-op.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        withAnimation { proxy.scrollTo(bookmark, anchor: .top) }
                    }
                }
            }
            .onChange(of: hasScrolledToBottom) { _, finished in
                // The reading is done — the bookmark has served its purpose.
                if finished, scroll.bookmarkParagraphIndex != nil {
                    store.setBookmark(scrollId: scroll.id, paragraphIndex: nil)
                }
            }
            .sheet(isPresented: Binding(
                get: { pendingExcerpt != nil },
                set: { if !$0 { pendingExcerpt = nil } }
            )) {
                if let excerpt = pendingExcerpt {
                    JournalComposerSheet(scroll: scroll, initialText: quotedExcerpt(excerpt)) { text in
                        store.addJournalEntry(text, scrollId: scroll.id)
                        pendingExcerpt = nil
                    }
                }
            }
        }
    }

    private func quotedExcerpt(_ excerpt: String) -> String {
        "\u{201C}\(excerpt)\u{201D}\n\n— Scroll \(scroll.roman)"
    }

    @ViewBuilder
    private func paragraphBlock(_ paragraph: String, index: Int) -> some View {
        let isBookmarked = scroll.bookmarkParagraphIndex == index || justBookmarkedIndex == index
        VStack(alignment: .leading, spacing: 8) {
            if isBookmarked {
                Label("You stopped here", systemImage: "bookmark.fill")
                    .font(AppFont.mono(10))
                    .tracking(0.6)
                    .foregroundColor(themeOption.brass)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            SelectableParagraphView(
                text: paragraph,
                fontSize: 16,
                textColor: UIColor(Palette.text.opacity(0.92)),
                lineSpacing: 7,
                onAddToJournal: { excerpt in
                    pendingExcerpt = excerpt
                },
                onTapped: {
                    bookmarkHaptic.impactOccurred()
                    withAnimation(.easeOut(duration: 0.2)) {
                        justBookmarkedIndex = index
                    }
                    store.setBookmark(scrollId: scroll.id, paragraphIndex: index)
                }
            )
        }
        .padding(.vertical, isBookmarked ? 10 : 0)
        .padding(.horizontal, isBookmarked ? 10 : 0)
        .background(isBookmarked ? themeOption.brass.opacity(0.07) : Color.clear)
        .cornerRadius(8)
        .animation(.easeOut(duration: 0.2), value: isBookmarked)
    }

    // MARK: - Editing View

    private var editingView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if scroll.status == .active {
                Text("Complete 30 days on this scroll to earn 200 XP, 20 seals, and unlock the next.")
                    .font(.system(size: 13)).foregroundColor(Palette.textDim)
                    .padding(.bottom, 6)
            } else if scroll.status == .locked {
                Text("This scroll is locked. You can still transcribe its title and notes — it will become your active practice once unlocked.")
                    .font(.system(size: 13)).foregroundColor(Palette.textDim)
                    .padding(.bottom, 6)
            }
            Text("TITLE").font(AppFont.mono(10.5)).tracking(1.2).foregroundColor(Palette.textFaint)
            TextField("Give this scroll a title", text: $title).textFieldStyle(AppTextFieldStyle())

            Text("ONE-LINE THEME").font(AppFont.mono(10.5)).tracking(1.2).foregroundColor(Palette.textFaint).padding(.top, 12)
            TextField("e.g. what this scroll asks of you", text: $theme).textFieldStyle(AppTextFieldStyle())

            HStack {
                Text("YOUR NOTES").font(AppFont.mono(10.5)).tracking(1.2).foregroundColor(Palette.textFaint)
                Spacer()
                if !notes.isEmpty {
                    Button("Clean up") {
                        notes = Scroll.normalizedNotes(notes)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(themeOption.brass)
                }
            }
            .padding(.top, 12)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $notes)
                    .frame(minHeight: 200)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(Palette.ink3)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.inkLine, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .foregroundColor(Palette.text)
                if notes.isEmpty {
                    Text("Paste or type freely — leave a blank line between paragraphs, and everything else sorts itself out.")
                        .font(.system(size: 13))
                        .foregroundColor(Palette.textFaint)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            Text("Tip: pasted text often has a line break after every line. Tap “Clean up” and it'll reflow into proper paragraphs.")
                .font(.system(size: 11.5))
                .foregroundColor(Palette.textFaint)
                .padding(.top, 4)
        }
        .padding(20)
    }

    // MARK: - Status Pill

    private var statusPill: some View {
        let (label, icon, color): (String, String, Color) = {
            switch scroll.status {
            case .mastered: return ("Mastered", "rosette", Palette.green)
            case .active: return ("Day \(days) of 30", "flame", themeOption.brass)
            case .locked: return ("Locked", "lock.fill", Palette.textFaint)
            }
        }()
        return HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(label.uppercased()).font(AppFont.mono(10)).tracking(1)
        }
        .foregroundColor(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}

struct JournalComposerSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let scroll: Scroll?
    var onSave: (String) -> Void
    @State private var text: String

    init(scroll: Scroll?, initialText: String = "", onSave: @escaping (String) -> Void) {
        self.scroll = scroll
        self.onSave = onSave
        _text = State(initialValue: initialText)
    }

    var themeOption: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(scroll.map { "SCROLL \($0.roman)" } ?? "GENERAL") · \(DateKey.short(DateKey.today())) · +15 XP")
                    .font(AppFont.mono(10.5)).tracking(1.0).foregroundColor(Palette.textFaint)
                HStack {
                    Spacer()
                    if !text.isEmpty {
                        Button("Clean up") {
                            text = Scroll.normalizedNotes(text)
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(themeOption.brass)
                    }
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .frame(minHeight: 220)
                        .padding(8)
                        .scrollContentBackground(.hidden)
                        .background(Palette.ink3)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.inkLine, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .foregroundColor(Palette.text)
                    if text.isEmpty {
                        Text("What stood out today? Write freely — leave a blank line between thoughts if you want them kept separate.")
                            .font(.system(size: 13))
                            .foregroundColor(Palette.textFaint)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
                Button("Save entry") {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onSave(Scroll.normalizedNotes(trimmed))
                }
                .buttonStyle(PrimaryButtonStyle(brass: themeOption.brass, glow: themeOption.glow, disabled: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.top, 8)
                Spacer()
            }
            .padding(20)
            .background(Palette.ink2.ignoresSafeArea())
            .navigationTitle("Today's Reflection")
            .inlineNavigationBarTitle()
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
    /// Tracks AlarmKit denied state on iOS 26+ (AlarmKit auth is checked via
    /// AlarmScheduler.shared.authorizationState, but we mirror it here for the
    /// denied-warning banner which needs a simple bool).
    @State private var alarmAuthDenied: Bool = false

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
                        if isAuthorizationDenied {
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

                    if prefs.enabled && isAuthorized {
                        Button {
                            if #available(iOS 26, *) {
                                AlarmScheduler.shared.sendTest()
                            } else {
                                store.notifier.sendTest()
                            }
                        } label: {
                            Label("Send test alarm", systemImage: "paperplane")
                        }
                        .buttonStyle(GhostButtonStyle())

                        if prefs.callEnabled {
                            Button {
                                if #available(iOS 26, *) {
                                    AlarmScheduler.shared.sendTestCall()
                                } else {
                                    store.notifier.sendTestCall()
                                }
                            } label: {
                                Label("Test escalation call", systemImage: "phone.arrow.up.right")
                            }
                            .buttonStyle(GhostButtonStyle())
                            Text("Fires in 5 seconds. Background the app or lock the screen, then tap the notification.")
                                .font(.system(size: 11))
                                .foregroundColor(Palette.textFaint)
                                .padding(.horizontal, 4)
                        }
                    }

                    Color.clear.frame(height: 8)
                }
                .padding(20)
            }
            .background(Palette.ink2.ignoresSafeArea())
            .navigationTitle("Reminders")
            .inlineNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .presentationDetents([.large])
        .task {
            if #available(iOS 26, *) {
                await AlarmScheduler.shared.refreshAuthorizationState()
                alarmAuthDenied = AlarmScheduler.shared.authorizationState == .denied
            } else {
                status = await store.notifier.authorizationStatus()
            }
        }
    }

    /// Whether authorization is granted (works across both paths).
    private var isAuthorized: Bool {
        if #available(iOS 26, *) {
            return !alarmAuthDenied && AlarmScheduler.shared.authorizationState == .authorized
        } else {
            return status == .authorized
        }
    }

    /// Whether authorization has been explicitly denied.
    private var isAuthorizationDenied: Bool {
        if #available(iOS 26, *) {
            return alarmAuthDenied
        } else {
            return status == .denied
        }
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
            .inlineNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
    }


struct SkipReasonSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: AppStore

    let dateKey: String
    var isMissedDay: Bool = false
    var onSubmit: (String) -> Void

    let quickReasons = ["Busy", "Forgot", "Travel", "Didn't feel like it"]
    @State private var customReason = ""

    var themeOption: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(isMissedDay ? "You missed a day." : "You skipped a session.")
                        .font(AppFont.display(24))
                        .foregroundColor(Palette.text)

                    Text("What got in the way? Logging this helps you notice patterns over time.")
                        .font(.system(size: 14))
                        .foregroundColor(Palette.textDim)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(quickReasons, id: \.self) { reason in
                            Button(action: {
                                onSubmit(reason)
                                dismiss()
                            }) {
                                HStack {
                                    Text(reason)
                                    Spacer()
                                    Image(systemName: "plus.circle")
                                }
                                .padding()
                                .background(Palette.ink3)
                                .foregroundColor(Palette.text)
                                .cornerRadius(10)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.inkLine, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("Other reason...", text: $customReason)
                            .textFieldStyle(AppTextFieldStyle())
                            .onSubmit(submitCustom)
                        
                        Button(action: submitCustom) {
                            Image(systemName: "arrow.up")
                        }
                        .frame(width: 40, height: 40)
                        .background(Palette.ink3)
                        .foregroundColor(themeOption.brass)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.inkLine, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .disabled(customReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.top, 4)

                    Button("Skip without noting") {
                        dismiss()
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Palette.textDim)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 24)
                }
                .padding(24)
            }
            .background(Palette.ink2.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func submitCustom() {
        let text = customReason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            onSubmit(text)
            dismiss()
        }
    }
}
