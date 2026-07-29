import SwiftUI
import UserNotifications
import AlarmKit
import Combine

struct ScrollEditorSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.appearanceMode) var appearanceMode
    @Environment(\.dismiss) private var dismiss
    let scroll: Scroll
    var onSave: (Scroll) -> Void
    var onReadingComplete: (() -> Void)? = nil  // Callback when friction gate is passed
    var onReadingStarted: (() -> Void)? = nil  // Callback the instant the reading view first appears

    @State private var title: String
    @State private var theme: String
    @State private var notes: String
    @State private var editing = false
    @State private var showFontControl = false

    // Intentional friction gate state — now driven by page position within
    // the WKWebView-paginated reading engine (`BookChapterWebView`, see
    // BookWebReader.swift) rather than scroll offset or the old
    // `TextPaginator`-based paragraph page list.
    @State private var htmlCurrentPage: Int = 0
    // Starts at 0, not 1, even though a single-page scroll's *real*
    // pageCount also settles at 1 — if this defaulted to 1, the very
    // first measurement for a one-page scroll would set it to the same
    // value it already had, `.onChange(of: htmlPageCount)` below would
    // never fire (no actual change), and `hasReachedLastPage` would never
    // flip true: the reader hits the only page there is, the friction
    // hint still says "Swipe to the end to complete", and the close
    // button stays disabled forever with no way to tell why. Starting at
    // 0 guarantees the first real settle (0 -> anything, including 1) is
    // always a genuine change.
    @State private var htmlPageCount: Int = 0
    // Was hardcoded to 0 — meaning every scroll always opened back at page
    // one, no matter where the reader last stopped (`Scroll.bookmarkParagraphIndex`,
    // see Models.swift, exists specifically so reopening can resume there).
    // Set from the bookmark in `init` below instead: an exact page isn't
    // knowable ahead of layout, but the bookmarked paragraph's position
    // among all paragraphs is a reasonable stand-in fraction, the same way
    // `LibraryIndexEntry.bookmarkScrollFraction` approximates a page
    // position for the Library reader.
    @State private var htmlInitialFraction: Double?
    @State private var htmlProxy = BookWebReaderProxy()
    @State private var hasReachedLastPage = false
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
    // Guards `onReadingComplete` so it fires exactly once per sheet
    // presentation. `canComplete` is referenced from several places in the
    // view body (toolbar button state, interactiveDismissDisabled,
    // safeAreaInset) and SwiftUI may re-evaluate a computed property on
    // each of those, so the actual notification is driven off a single
    // `.onChange(of: canComplete)` below rather than from inside the
    // computed property itself.
    @State private var readingCompleteFired = false
    private let bookmarkHaptic = UIImpactFeedbackGenerator(style: .light)
    
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    private var minimumReadingTimeSeconds: TimeInterval { 30 } // Minimum 30 seconds
    private var hasMetTimeRequirement: Bool {
        guard let startTime = readingStartTime else { return false }
        return currentTime.timeIntervalSince(startTime) >= minimumReadingTimeSeconds
    }
    private var canComplete: Bool {
        editing || hasReachedLastPage && hasMetTimeRequirement
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
    private var fontScale: CGFloat { CGFloat(store.state.readingFontScale) }

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        NavigationStack {
            Group {
                if editing {
                    ScrollView { editingView }
                } else {
                    readingView
                }
            }
            .background(colors.ink2.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                if !editing && hasContent {
                    VStack(spacing: 0) {
                        if !canComplete {
                            frictionHintView
                        }
                        ReadingProgressBar(
                            progress: pageProgressValue,
                            caption: pageProgressCaption,
                            brass: themeOption.brass,
                            backgroundColor: colors.ink2,
                            onPrevious: htmlCurrentPage > 0 ? { htmlProxy.goToPreviousPage() } : nil,
                            onNext: htmlCurrentPage < htmlPageCount - 1 ? { htmlProxy.goToNextPage() } : nil
                        )
                    }
                }
            }
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
                                    .foregroundColor(colors.textFaint)
                            }
                        }
                    }
                    .disabled(!editing && !canComplete && hasContent)
                    .opacity((editing || canComplete || !hasContent) ? 1.0 : 0.5)
                }
                if !editing && hasContent {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showFontControl = true
                        } label: {
                            Text("Aa").font(.system(size: 15, weight: .semibold, design: .serif))
                        }
                        .popover(isPresented: $showFontControl) {
                            ReadingFontSizeControl(
                                scale: Binding(
                                    get: { store.state.readingFontScale },
                                    set: { store.setReadingFontScale($0) }
                                ),
                                brass: themeOption.brass
                            )
                            .presentationCompactAdaptation(.popover)
                        }
                    }
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
        .onChange(of: canComplete) { _, newValue in
            guard newValue, !editing, !readingCompleteFired, onReadingComplete != nil else { return }
            readingCompleteFired = true
            onReadingComplete?()
        }
        .interactiveDismissDisabled(!canComplete && hasContent && !editing)
    }
    // MARK: - Reading View

    /// Inner HTML for the WKWebView-based reading engine (`BookChapterWebView`,
    /// see `BookWebReader.swift`). The ornament/status-pill/title/theme header
    /// is flowed at the very top of the document — rather than passed in
    /// separately — so the CSS-column pagination naturally lands it on page
    /// one, the same "only-on-first-page" placement the old `pageContent`'s
    /// `isFirstPage` check used to enforce explicitly. Each paragraph carries
    /// a `data-p="N"` attribute so `BookChapterWebView.paragraphTapBridgeScript`
    /// can report taps back for bookmarking, and the currently-bookmarked
    /// paragraph (if any) gets the `bookmarked` class/label that
    /// `BookChapterWebView.document`'s injected CSS already styles.
    private var scrollHTML: String {
        let colors = AdaptivePalette(mode: appearanceMode)
        let brass = themeOption.brass.hexString()

        var html = ""
        html += "<div style=\"text-align:center;margin-bottom:6px;\">"
        html += "<span style=\"font-size:22px;color:\(brass)88;\">⟐</span>"
        html += "</div>"
        html += "<div style=\"text-align:center;font-family:-apple-system,sans-serif;font-size:11px;letter-spacing:2.4px;color:\(brass)B3;margin-bottom:20px;\">SCROLL \(scroll.roman)</div>"
        html += "<div style=\"text-align:center;margin-bottom:28px;\">\(statusPillHTML)</div>"

        // Sized in `em`, not a fontScale-baked `px` value: the body's own
        // font-size already carries `fontScale` (see
        // `BookChapterWebView.document`), so these scale with it for free.
        // Baking `fontScale` in here directly used to mean every "Aa" size
        // change produced a different `html` string, which made
        // `BookChapterWebView.updateUIView`'s `sameContent` check (see
        // BookWebReader.swift) think the chapter itself had changed — so
        // instead of keeping the reader's current page, it reset to
        // `htmlInitialFraction` (always page 0 here) on every font
        // adjustment, which looked like swiping had stopped working.
        if !title.isEmpty {
            html += "<h1 style=\"font-family:Georgia,serif;font-size:1.625em;margin:0 0 4px 0;\">\(Self.escapeHTML(title))</h1>"
        }
        if !theme.isEmpty {
            html += "<div style=\"font-style:italic;color:\(brass);font-size:0.9375em;margin-bottom:20px;\">\(Self.escapeHTML(theme))</div>"
        }
        if !title.isEmpty || !theme.isEmpty {
            html += "<hr style=\"border:none;border-top:1px solid \(brass)33;margin:0 0 24px 0;\">"
        }

        for (index, paragraph) in scroll.paragraphs.enumerated() {
            let isBookmarked = scroll.bookmarkParagraphIndex == index
            var p = isBookmarked ? "<p data-p=\"\(index)\" class=\"bookmarked\">" : "<p data-p=\"\(index)\">"
            if isBookmarked {
                p += "<span class=\"bookmark-label\">You stopped here</span>"
            }
            p += Self.escapeHTML(paragraph)
            p += "</p>"
            html += p
        }

        html += "<div style=\"text-align:center;margin-top:36px;\"><span style=\"font-size:18px;color:\(brass)40;\">⟐</span></div>"
        // colors.textDim currently unused by this template, but kept in scope
        // for the next header/footer tweak that needs a non-brass color.
        _ = colors
        return html
    }

    /// HTML counterpart to `statusPill`, since the status pill needs to be
    /// part of `scrollHTML`'s flowed document rather than a native SwiftUI
    /// overlay now that the header lives inside the page-one column.
    private var statusPillHTML: String {
        let colors = AdaptivePalette(mode: appearanceMode)
        let (label, hex): (String, String) = {
            switch scroll.status {
            case .mastered: return ("MASTERED", colors.green.hexString())
            case .active: return ("DAY \(days) OF 30", themeOption.brass.hexString())
            case .locked: return ("LOCKED", colors.textFaint.hexString())
            }
        }()
        return "<span style=\"display:inline-block;font-family:-apple-system,sans-serif;font-size:10px;letter-spacing:1px;color:\(hex);background:\(hex)1F;padding:5px 12px;border-radius:999px;\">\(label)</span>"
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Reads through `BookChapterWebView` (the same WKWebView, CSS-column
    /// pagination engine `LibraryReaderView` uses) instead of the old
    /// `TextPaginator`/`PageTurnContainer` paragraph-page pipeline, so the
    /// two readers share one rendering engine rather than two different
    /// ones. The friction gate (must reach the end + a minimum dwell time
    /// before the scroll counts as read) keys off `htmlCurrentPage`
    /// reaching the last page the engine reports; the minimum-time half is
    /// unchanged.
    private var readingView: some View {
        GeometryReader { geo in
            Group {
                if !hasContent {
                    emptyStateView
                } else {
                    BookChapterWebView(
                        html: scrollHTML,
                        theme: themeOption,
                        appearanceMode: appearanceMode,
                        fontScale: fontScale,
                        size: geo.size,
                        currentPage: $htmlCurrentPage,
                        pageCount: $htmlPageCount,
                        initialFraction: htmlInitialFraction,
                        proxy: htmlProxy,
                        onAddToJournal: { excerpt in
                            pendingExcerpt = excerpt
                        },
                        onParagraphTap: { index in
                            bookmarkHaptic.impactOccurred()
                            withAnimation(.easeOut(duration: 0.2)) {
                                justBookmarkedIndex = index
                            }
                            store.setBookmark(scrollId: scroll.id, paragraphIndex: index)
                        }
                    )
                    .background(AdaptivePalette(mode: appearanceMode).ink2)
                    .onChange(of: htmlCurrentPage) { _, newValue in
                        if htmlPageCount > 0 && newValue >= htmlPageCount - 1 {
                            hasReachedLastPage = true
                        }
                    }
                    .onChange(of: htmlPageCount) { _, newValue in
                        // A scroll short enough to fit on one page is, by
                        // definition, already at its last page the moment
                        // it appears — mirrors the old paginate()'s
                        // `newPages.count <= 1` case. Checked against
                        // exactly 1, not `<= 1`: `htmlPageCount` also
                        // transiently passes through 0 while a same-content
                        // reload (font size, theme) is mid-reformat (see
                        // `Coordinator.performLoad`'s `pageCount = 0`), and
                        // that transient 0 used to trip this same check —
                        // falsely marking a scroll "finished" on every font
                        // size tick.
                        if newValue == 1 {
                            hasReachedLastPage = true
                        }
                    }
                }
            }
            .onAppear {
                if hasContent && readingStartTime == nil {
                    readingStartTime = Date()
                    onReadingStarted?()
                }
            }
        }
        .onChange(of: hasReachedLastPage) { _, finished in
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

    /// The friction-gate progress hint that used to live inside
    /// `footerBlock`, on the last page of the continuous/paragraph reader.
    /// Pulled out into the chrome above `ReadingProgressBar` instead, since
    /// it depends on `currentTime` (a per-second timer) and the WKWebView's
    /// paginated HTML document shouldn't be regenerated every second just
    /// to update a caption.
    @ViewBuilder
    private var frictionHintView: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        Group {
            if !hasReachedLastPage {
                Label("Swipe to the end to complete", systemImage: "arrow.right")
            } else if !hasMetTimeRequirement {
                let remaining = Int(minimumReadingTimeSeconds - currentTime.timeIntervalSince(readingStartTime ?? Date()))
                Label("Take your time (\(max(0, remaining))s)", systemImage: "clock")
            }
        }
        .font(.system(size: 13))
        .foregroundColor(colors.textFaint)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(colors.ink2)
    }

    private var emptyStateView: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        return VStack(spacing: 14) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 32))
                .foregroundColor(colors.textFaint)
            Text("No notes yet")
                .font(AppFont.display(18))
                .foregroundColor(colors.textDim)
            Text("Tap the pencil icon above to transcribe\nyour title and notes from the book.")
                .font(.system(size: 13))
                .foregroundColor(colors.textFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Progress

    /// Progress mirrors the WKWebView-paginated reading engine's own page
    /// count/index (`htmlPageCount`/`htmlCurrentPage`) rather than the old
    /// `pages`/`currentPageIndex` paragraph-page list, since pagination is
    /// now computed by `BookChapterWebView`'s CSS columns, not here.
    private var pageProgressValue: Double {
        guard htmlPageCount > 1 else { return hasReachedLastPage ? 1 : 0 }
        return Double(htmlCurrentPage) / Double(htmlPageCount - 1)
    }

    private var pageProgressCaption: String {
        if hasReachedLastPage && htmlCurrentPage >= htmlPageCount - 1 {
            return "End of Scroll \(scroll.roman)"
        }
        return "Page \(htmlCurrentPage + 1) of \(max(1, htmlPageCount)) · Scroll \(scroll.roman)"
    }

    private func quotedExcerpt(_ excerpt: String) -> String {
        "\u{201C}\(excerpt)\u{201D}\n\n— Scroll \(scroll.roman)"
    }

    // MARK: - Editing View

    private var editingView: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        return VStack(alignment: .leading, spacing: 4) {
            if scroll.status == .active {
                Text("Complete 30 days on this scroll to earn 200 XP, 20 seals, and unlock the next.")
                    .font(.system(size: 13)).foregroundColor(colors.textDim)
                    .padding(.bottom, 6)
            } else if scroll.status == .locked {
                Text("This scroll is locked. You can still transcribe its title and notes — it will become your active practice once unlocked.")
                    .font(.system(size: 13)).foregroundColor(colors.textDim)
                    .padding(.bottom, 6)
            }
            Text("TITLE").font(AppFont.mono(10.5)).tracking(1.2).foregroundColor(colors.textFaint)
            TextField("Give this scroll a title", text: $title).textFieldStyle(AppTextFieldStyle())

            Text("ONE-LINE THEME").font(AppFont.mono(10.5)).tracking(1.2).foregroundColor(colors.textFaint).padding(.top, 12)
            TextField("e.g. what this scroll asks of you", text: $theme).textFieldStyle(AppTextFieldStyle())

            HStack {
                Text("YOUR NOTES").font(AppFont.mono(10.5)).tracking(1.2).foregroundColor(colors.textFaint)
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
                    .background(colors.ink3)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(colors.inkLine, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .foregroundColor(colors.text)
                if notes.isEmpty {
                    Text("Paste or type freely — leave a blank line between paragraphs, and everything else sorts itself out.")
                        .font(.system(size: 13))
                        .foregroundColor(colors.textFaint)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            Text("Tip: pasted text often has a line break after every line. Tap “Clean up” and it'll reflow into proper paragraphs.")
                .font(.system(size: 11.5))
                .foregroundColor(colors.textFaint)
                .padding(.top, 4)
        }
        .padding(20)
    }

    // MARK: - Status Pill

    private var statusPill: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        let (label, icon, color): (String, String, Color) = {
            switch scroll.status {
            case .mastered: return ("Mastered", "rosette", colors.green)
            case .active: return ("Day \(days) of 30", "flame", themeOption.brass)
            case .locked: return ("Locked", "lock.fill", colors.textFaint)
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
    @Environment(\.appearanceMode) var appearanceMode
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
        let colors = AdaptivePalette(mode: appearanceMode)
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(scroll.map { "SCROLL \($0.roman)" } ?? "GENERAL") · \(DateKey.short(DateKey.today())) · +15 XP")
                    .font(AppFont.mono(10.5)).tracking(1.0).foregroundColor(colors.textFaint)
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
                        .background(colors.ink3)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(colors.inkLine, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .foregroundColor(colors.text)
                    if text.isEmpty {
                        Text("What stood out today? Write freely — leave a blank line between thoughts if you want them kept separate.")
                            .font(.system(size: 13))
                            .foregroundColor(colors.textFaint)
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
            .background(colors.ink2.ignoresSafeArea())
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
    @Environment(\.appearanceMode) var appearanceMode
    @Environment(\.dismiss) private var dismiss

    @State private var status: UNAuthorizationStatus = .notDetermined
    /// Tracks AlarmKit denied state on iOS 26+ (AlarmKit auth is checked via
    /// AlarmScheduler.shared.authorizationState, but we mirror it here for the
    /// denied-warning banner which needs a simple bool).
    @State private var alarmAuthDenied: Bool = false

    var themeOption: ThemeOption { Palette.theme(for: store.state.activeThemeId) }
    private var prefs: NotificationPrefs { store.state.notifPrefs }

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Get reminded when it's time for your Dawn, Midday, and Dusk reading. If a session goes unanswered, Ten Scrolls escalates to a full-screen call.")
                        .font(.system(size: 13)).foregroundColor(colors.textDim)

                    // Master toggle
                    CardView {
                        HStack {
                            Image(systemName: prefs.enabled ? "bell.badge.fill" : "bell.slash")
                                .foregroundColor(prefs.enabled ? themeOption.brass : colors.textFaint)
                            Text(prefs.enabled ? "Reminders on" : "Reminders off")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(colors.text)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { prefs.enabled },
                                set: { newValue in Task { await store.setNotificationsEnabled(newValue) } }
                            ))
                            .labelsHidden()
                            .tint(themeOption.brass)
                        }
                        if isAuthorizationDenied {
                            Divider().background(colors.ink3).padding(.vertical, 10)
                            Label("Notifications are turned off in iOS Settings. Enable them for Ten Scrolls to receive reminders.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.system(size: 12)).foregroundColor(colors.textDim)
                        }
                    }

                    // Reading windows — this is also the reminder clock now.
                    SectionLabel(text: "Reading Windows")
                    Text("Reminders fire the moment each window opens, and escalation calls never ring after it closes — one clock for eligibility and reminders.")
                        .font(.system(size: 12)).foregroundColor(colors.textDim)
                    CardView {
                        windowRow(session: .dawn)
                        Divider().background(colors.ink3)
                        windowRow(session: .midday)
                        Divider().background(colors.ink3)
                        windowRow(session: .dusk)
                        
                        if hasInvalidWindows {
                            Divider().background(colors.ink3).padding(.vertical, 10)
                            Label("One or more windows have invalid times. They'll use defaults until fixed.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.system(size: 12)).foregroundColor(colors.textDim)
                        }
                    }
                    
                    Button {
                        updateWindowPrefs { prefs in
                            prefs.dawnStart = "05:00"
                            prefs.dawnEnd = "11:00"
                            prefs.middayStart = "11:00"
                            prefs.middayEnd = "16:00"
                            prefs.duskStart = "16:00"
                            prefs.duskEnd = "23:00"
                        }
                    } label: {
                        Label("Reset to defaults", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(GhostButtonStyle())
                    .font(.system(size: 13))

                    // Escalation call
                    SectionLabel(text: "Escalation Call")
                    CardView {
                        HStack {
                            Image(systemName: "phone.arrow.up.right")
                                .foregroundColor(prefs.callEnabled ? themeOption.brass : colors.textFaint)
                            Text("Call me if unanswered")
                                .font(.system(size: 14)).foregroundColor(colors.text)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { prefs.callEnabled },
                                set: { v in update { $0.callEnabled = v } }
                            ))
                            .labelsHidden()
                            .tint(themeOption.brass)
                        }
                        if prefs.callEnabled {
                            Divider().background(colors.ink3).padding(.vertical, 12)
                            Stepper(value: Binding(
                                get: { prefs.callTimeoutMinutes },
                                set: { v in update { $0.callTimeoutMinutes = v } }
                            ), in: 1...120, step: 1) {
                                Text("After \(prefs.callTimeoutMinutes) min")
                                    .font(.system(size: 14)).foregroundColor(colors.text)
                            }
                        }
                    }
                    .disabled(!prefs.enabled)
                    .opacity(prefs.enabled ? 1 : 0.5)

                    Color.clear.frame(height: 8)
                }
                .padding(20)
            }
            .background(colors.ink2.ignoresSafeArea())
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
            if #available(iOS 26.1, *) {
                await AlarmScheduler.shared.refreshAuthorizationState()
                alarmAuthDenied = AlarmScheduler.shared.authorizationState == .denied
            } else {
                status = await store.notifier.authorizationStatus()
            }
        }
    }

    /// Whether authorization is granted (works across both paths).
    private var isAuthorized: Bool {
        if #available(iOS 26.1, *) {
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

    private func windowRow(session: Session) -> some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        let windowPrefs = store.state.windowPrefs
        let (startTime, endTime) = windowPrefs.window(for: session)
        
        return VStack(spacing: 8) {
            HStack {
                Label(session.label, systemImage: session.systemImage)
                    .font(.system(size: 14))
                    .foregroundColor(colors.text)
                Spacer()
            }
            
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Opens").font(.system(size: 11)).foregroundColor(colors.textFaint)
                    DatePicker("", selection: Binding(
                        get: { dateFromHHmm(startTime) },
                        set: { newDate in updateWindow(session: session, start: hhmm(from: newDate), end: endTime) }
                    ), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Closes").font(.system(size: 11)).foregroundColor(colors.textFaint)
                    DatePicker("", selection: Binding(
                        get: { dateFromHHmm(endTime) },
                        set: { newDate in updateWindow(session: session, start: startTime, end: hhmm(from: newDate)) }
                    ), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                }
            }
        }
        .padding(.vertical, 6)
    }
    
    private var hasInvalidWindows: Bool {
        let prefs = store.state.windowPrefs
        return SessionTimeWindow.parse(start: prefs.dawnStart, end: prefs.dawnEnd) == nil ||
               SessionTimeWindow.parse(start: prefs.middayStart, end: prefs.middayEnd) == nil ||
               SessionTimeWindow.parse(start: prefs.duskStart, end: prefs.duskEnd) == nil
    }

    /// Applies a mutation to the current prefs and persists + reschedules.
    private func update(_ mutate: (inout NotificationPrefs) -> Void) {
        var p = store.state.notifPrefs
        mutate(&p)
        store.updateNotifPrefs(p)
    }
    
    private func updateWindow(session: Session, start: String, end: String) {
        updateWindowPrefs { prefs in
            switch session {
            case .dawn:
                prefs.dawnStart = start
                prefs.dawnEnd = end
            case .midday:
                prefs.middayStart = start
                prefs.middayEnd = end
            case .dusk:
                prefs.duskStart = start
                prefs.duskEnd = end
            }
        }
    }
    
    private func updateWindowPrefs(_ mutate: (inout SessionWindowPrefs) -> Void) {
        var p = store.state.windowPrefs
        mutate(&p)
        store.updateWindowPrefs(p)
    }
}

/// "HH:mm" → today's `Date` at that time (for DatePicker binding).
/// Delegates to `TimeUtils.dateFromHHmm` so parsing/anchoring behavior stays
/// consistent with `AlarmScheduler` and `NotificationManager` — this used to
/// build `DateComponents` with only hour/minute and no year/month/day, which
/// left the resulting `Date` on an unanchored day and could make the picker
/// show the wrong date/time.
private func dateFromHHmm(_ string: String) -> Date {
    TimeUtils.dateFromHHmm(string)
}

/// `Date` → "HH:mm".
private func hhmm(from date: Date) -> String {
    TimeUtils.hhmm(from: date)
}

struct InfoSheet: View {
    @Environment(\.appearanceMode) var appearanceMode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Work through one scroll at a time, reading it three times a day — dawn, midday, and dusk — for 30 days before moving to the next. Ten scrolls, thirty days each, roughly a year of practice.")
                    Text("Every session earns XP toward your rank. Full days and streak milestones earn seals, spendable on cosmetic seal colors. Every 7 completed days banks a streak shield that auto-covers one missed day.")
                    Text("Set a trader handle in The Caravan tab to join the shared leaderboard and compare streaks with friends. Your handle, level, and streak become visible to other traders once set.")
                    Text("Add your own title, theme, and notes to each scroll from your copy of the book — this app doesn't include the text itself, just the structure and the game layer to help you stay with it.")
                }
                .font(.system(size: 13)).foregroundColor(colors.textDim)
                .padding(20)
            }
            .background(colors.ink2.ignoresSafeArea())
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
    @Environment(\.appearanceMode) var appearanceMode
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: AppStore

    let dateKey: String
    var isMissedDay: Bool = false
    var onSubmit: (String) -> Void

    let quickReasons = ["Busy", "Forgot", "Travel", "Didn't feel like it"]
    @State private var customReason = ""

    var themeOption: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(isMissedDay ? "You missed a day." : "You skipped a session.")
                        .font(AppFont.display(24))
                        .foregroundColor(colors.text)

                    Text("What got in the way? Logging this helps you notice patterns over time.")
                        .font(.system(size: 14))
                        .foregroundColor(colors.textDim)

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
                                .background(colors.ink3)
                                .foregroundColor(colors.text)
                                .cornerRadius(10)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(colors.inkLine, lineWidth: 1))
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
                        .background(colors.ink3)
                        .foregroundColor(themeOption.brass)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(colors.inkLine, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .disabled(customReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.top, 4)

                    Button("Skip without noting") {
                        dismiss()
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(colors.textDim)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 24)
                }
                .padding(24)
            }
            .background(colors.ink2.ignoresSafeArea())
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
