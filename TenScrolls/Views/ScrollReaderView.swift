import SwiftUI
import Combine

/// $500 Club — Lux-spec scroll reader.
///
/// Replaces the old `ScrollEditorSheet`'s reading mode with the spec's
/// design: near-black bg, top bar with X + mono caption + Aa & pencil icons,
/// serif body 18pt / leading 32, diamond ornament, breathing dot footer,
/// thin gold progress bar, and a "Seal this reading" end-sheet that calls
/// `store.toggleSession` + haptic.
///
/// The editing half (title / theme / notes) is kept as-is: tapping the
/// pencil drops into an `EditScrollSheet` that mimics the old
/// `ScrollEditorSheet.editingView` exactly, so zero data-layer changes.
///
/// Friction gate:
///   - User must reach the last page of the WKWebView-paginated document.
///   - Minimum 30-second dwell once the view first appears.
///   Only when both are met does the "Seal →" CTA become active.
///
/// Integration:
///   ContentView presents this via `.fullScreenCover(item: $activeSheet)`
///   for the `.scrollEditor` case, same as before. No AppStore changes.
struct ScrollReaderView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appearanceMode) private var appearanceMode

    let scroll: Scroll
    var onSave: (Scroll) -> Void
    /// Called the instant the reading view first appears (anchors the
    /// session start time for the grace-period gate).
    var onReadingStarted: (() -> Void)? = nil

    // MARK: - State

    @State private var htmlCurrentPage: Int = 0
    // Starts at 0 — same reasoning as ScrollEditorSheet: defaulting to 1
    // would prevent the .onChange from firing for single-page scrolls.
    @State private var htmlPageCount: Int = 0
    @State private var htmlInitialFraction: Double? = nil
    @State private var htmlProxy = BookWebReaderProxy()

    @State private var hasReachedLastPage = false
    @State private var readingStartTime: Date? = nil
    @State private var currentTime = Date()

    @State private var showSealSheet = false
    @State private var sealFired = false      // guard — fire completeSession once
    @State private var showFontControl = false
    @State private var showEdit = false
    @State private var pendingExcerpt: String? = nil
    @State private var justBookmarkedIndex: Int? = nil

    private let bookmarkHaptic = UIImpactFeedbackGenerator(style: .light)
    private let sealHaptic = UIImpactFeedbackGenerator(style: .light)
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private static let minimumReadSeconds: TimeInterval = 30

    // MARK: - Computed

    private var themeOption: ThemeOption { Palette.theme(for: store.state.activeThemeId) }
    private var days: Int { store.state.scrollDaysCompleted(scroll.id) }
    private var fontScale: CGFloat { CGFloat(store.state.readingFontScale) }

    private var hasMetTimeRequirement: Bool {
        guard let start = readingStartTime else { return false }
        return currentTime.timeIntervalSince(start) >= Self.minimumReadSeconds
    }

    /// True once friction gate is satisfied — can seal this reading.
    private var canSeal: Bool { hasReachedLastPage && hasMetTimeRequirement }

    private var pageProgress: Double {
        guard htmlPageCount > 1 else { return hasReachedLastPage ? 1 : 0 }
        return Double(htmlCurrentPage) / Double(htmlPageCount - 1)
    }

    /// Which session is currently in-window (or grace) for today.
    private var eligibleSession: Session? {
        let customPrefs = store.state.windowPrefs
        return Session.allCases.first {
            let status = $0.windowStatus(
                at: currentTime,
                startedAt: store.state.log[DateKey.today()]?.startedAt(for: $0),
                customPrefs: customPrefs
            )
            return status == .open || status == .grace
        }
    }

    private var hasContent: Bool {
        !scroll.title.isEmpty || !scroll.notes.isEmpty || !scroll.theme.isEmpty
    }

    /// Whether the session currently in-window (dawn/midday/dusk) has already
    /// been sealed for today. Distinct from `sealFired`, which only tracks
    /// whether *this view instance* fired a seal — reopening the scroll after
    /// closing and relaunching gets a fresh view (and fresh `sealFired`), so
    /// without this check a completed session's friction gate could open
    /// again and re-fire `store.toggleSession`, which *toggles* and would
    /// silently un-seal an already-completed session.
    private var alreadySealedToday: Bool {
        guard let session = eligibleSession else { return false }
        return store.state.log[DateKey.today()]?.isCompleted(for: session) ?? false
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            LuxColor.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .zIndex(1)

                if hasContent {
                    readerContent
                } else {
                    emptyState
                }
            }

            // Thin gold progress pinned to the very bottom (above home indicator)
            if hasContent {
                VStack(spacing: 0) {
                    Spacer()
                    goldProgressBar
                }
                .ignoresSafeArea(edges: .bottom)
            }
        }
        // "Seal this reading" end-sheet
        .sheet(isPresented: $showSealSheet) {
            SealReadingSheet(
                scroll: scroll,
                session: eligibleSession ?? .midday,
                canSeal: canSeal,
                onSeal: {
                    sealReading()
                    showSealSheet = false
                    dismiss()
                }
            )
            .presentationDetents([.fraction(0.45)])
            .presentationDragIndicator(.visible)
        }
        // Edit sheet (pencil icon)
        .fullScreenCover(isPresented: $showEdit) {
            EditScrollSheet(scroll: scroll, onSave: { updated in
                onSave(updated)
                showEdit = false
            })
        }
        // Highlight-to-journal
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
        .onReceive(timer) { currentTime = $0 }
        // Surface the seal sheet once the gate opens (auto-prompt). Guarded
        // against `alreadySealedToday` so reopening an already-sealed scroll
        // later in the same window doesn't re-prompt and risk un-sealing it.
        .onChange(of: canSeal) { _, newValue in
            if newValue && !sealFired && !showSealSheet && !alreadySealedToday {
                showSealSheet = true
            }
        }
        .onChange(of: hasReachedLastPage) { _, finished in
            if finished, (justBookmarkedIndex ?? scroll.bookmarkParagraphIndex) != nil {
                justBookmarkedIndex = nil
                store.setBookmark(scrollId: scroll.id, paragraphIndex: nil)
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 0) {
            // X close — only tappable once canSeal (friction gate satisfied) OR scroll has no content
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .light))
                    .foregroundColor(LuxColor.textSecondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(hasContent && !canSeal && !alreadySealedToday)
            .opacity(hasContent && !canSeal && !alreadySealedToday ? 0.35 : 1)

            Spacer()

            // "SCROLL I · DAY XVI" caption
            Text("SCROLL \(scroll.roman) \u{00B7} DAY \(Roman.from(max(1, days)))")
                .font(LuxFont.mono(10))
                .tracking(0.8)
                .foregroundColor(LuxColor.textSecondary)

            Spacer()

            HStack(spacing: 2) {
                // Aa font control
                Button {
                    showFontControl = true
                } label: {
                    Text("Aa")
                        .font(.system(size: 13, weight: .light, design: .serif))
                        .foregroundColor(LuxColor.textSecondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showFontControl) {
                    ReadingFontSizeControl(
                        scale: Binding(
                            get: { store.state.readingFontScale },
                            set: { store.setReadingFontScale($0) }
                        ),
                        brass: LuxColor.gold
                    )
                    .presentationCompactAdaptation(.popover)
                }

                // Pencil — edit mode
                Button {
                    showEdit = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 15, weight: .light))
                        .foregroundColor(LuxColor.textSecondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .background(LuxColor.bg)
        // Thin divider under top bar
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(LuxColor.cardBorder)
                .frame(height: 0.5)
        }
    }

    // MARK: - Reader content

    private var readerContent: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // WebView reader
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
                    onAddToJournal: { excerpt in pendingExcerpt = excerpt },
                    onParagraphTap: { index in
                        bookmarkHaptic.impactOccurred()
                        withAnimation(.easeOut(duration: 0.2)) {
                            justBookmarkedIndex = index
                        }
                        store.setBookmark(scrollId: scroll.id, paragraphIndex: index)
                    },
                    preservePositionAcrossReload: true
                )
                .background(LuxColor.bg)
                .onChange(of: htmlCurrentPage) { _, newValue in
                    if htmlPageCount > 0 && newValue >= htmlPageCount - 1 {
                        hasReachedLastPage = true
                    }
                }
                .onChange(of: htmlPageCount) { _, newValue in
                    if newValue == 1 { hasReachedLastPage = true }
                }
                .onAppear {
                    if readingStartTime == nil {
                        readingStartTime = Date()
                        onReadingStarted?()
                    }
                    // A fresh view instance (e.g. reopening the scroll after
                    // closing it) starts with `sealFired = false` regardless
                    // of whether today's session is already sealed. Seed it
                    // here so the friction gate can't re-fire `sealReading()`
                    // and un-seal an already-completed session.
                    if alreadySealedToday {
                        sealFired = true
                    }
                }

                // Footer: "take your time" nudge while still reading, then a
                // persistent seal affordance once the last page is reached —
                // this is the only way back into the seal sheet after it's
                // been dismissed/minimized without sealing (there's no other
                // path to reopen it once the auto-prompt has fired once).
                if !hasReachedLastPage {
                    breathingFooter
                } else {
                    sealFooter
                }
            }
        }
        // Reserve space for the gold progress bar at the very bottom
        .padding(.bottom, 24)
    }

    // MARK: - Breathing footer

    private var breathingFooter: some View {
        VStack(spacing: 8) {
            BreathingDot()
            Text("TAKE YOUR TIME")
                .font(LuxFont.sans(10, weight: .medium))
                .tracking(1.8)
                .foregroundColor(LuxColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 36)
        .background(
            LinearGradient(
                colors: [LuxColor.bg.opacity(0), LuxColor.bg.opacity(0.96)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Seal footer

    /// Persistent seal affordance once the last page is reached — replaces
    /// `breathingFooter`. This is the *only* way back into `SealReadingSheet`
    /// after it's been dismissed without sealing, since the auto-prompt in
    /// `.onChange(of: canSeal)` only fires once per false→true transition.
    /// Once the session is already sealed, this collapses into a quiet
    /// "Sealed" confirmation instead of a tappable CTA — reopening the sheet
    /// from here and tapping Seal again would call `sealReading()` a second
    /// time, and `store.toggleSession` *toggles*, so that would silently
    /// un-seal a completed session.
    private var sealFooter: some View {
        Group {
            if alreadySealedToday {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12))
                        .foregroundColor(LuxColor.success)
                    Text("SEALED")
                        .luxEyebrow(color: LuxColor.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 36)
                .background(sealFooterGradient)
            } else {
                Button {
                    showSealSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Text("SEAL THIS READING")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .luxEyebrow(color: canSeal ? LuxColor.success : LuxColor.textSecondary)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 36)
                .background(sealFooterGradient)
            }
        }
    }

    private var sealFooterGradient: some View {
        LinearGradient(
            colors: [LuxColor.bg.opacity(0), LuxColor.bg.opacity(0.96)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Gold progress bar

    private var goldProgressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(LuxColor.cardBorder)
                    .frame(height: 1)
                Rectangle()
                    .fill(LuxColor.gold)
                    .frame(width: geo.size.width * pageProgress, height: 1)
                    .animation(LuxMotion.standard, value: pageProgress)
            }
        }
        .frame(height: 1)
        .padding(.bottom, 8)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            // Diamond ornament
            Text("\u{22C4}")
                .font(.system(size: 28))
                .foregroundColor(LuxColor.goldMuted)

            Text("Scroll \(scroll.roman)")
                .font(LuxFont.serif(24))
                .foregroundColor(LuxColor.textPrimary)

            Text("No notes transcribed yet.\nTap the pencil to add your title and scroll text.")
                .font(LuxFont.sans(13))
                .foregroundColor(LuxColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                showEdit = true
            } label: {
                Text("Add Notes")
            }
            .buttonStyle(LuxPrimaryButtonStyle())
            .padding(.horizontal, 40)
            .padding(.top, 8)

            Spacer()
        }
    }

    // MARK: - HTML generation

    /// Builds the inner HTML for the WKWebView-based reading engine.
    /// Uses the Lux palette in whichever mode `appearanceMode` currently
    /// resolves to — gold accents stay constant, text/muted swap between
    /// the dark and light Lux values (mirrors `LuxColor.textPrimary` /
    /// `LuxColor.textMuted`'s own light-mode hex, kept as plain string
    /// literals here since this HTML is assembled outside SwiftUI's
    /// environment and can't resolve a dynamic `Color` on its own).
    private var scrollHTML: String {
        let isLight = appearanceMode == .light
        let goldHex = "D4AF37"
        let textHex = isLight ? "1B1712" : "F5F2ED"
        let mutedHex = isLight ? "6C665A" : "8A877E"

        var html = ""

        // Diamond ornament at the very top
        html += "<div style=\"text-align:center;margin-bottom:8px;\">"
        html += "<span style=\"font-size:20px;color:#\(goldHex)66;\">&#x22C4;</span>"
        html += "</div>"

        // Title (Cormorant Garamond fallback: Georgia)
        if !scroll.title.isEmpty {
            html += "<h1 style=\""
            html += "font-family:'CormorantGaramond-Light',Georgia,serif;"
            html += "font-size:1.55em;"
            html += "font-weight:300;"
            html += "letter-spacing:-0.02em;"
            html += "color:#\(textHex);"
            html += "text-align:center;"
            html += "margin:0 0 6px 0;"
            html += "\">\(Self.escapeHTML(scroll.title))</h1>"
        }

        // Theme / italic quote
        if !scroll.theme.isEmpty {
            html += "<div style=\""
            html += "font-style:italic;"
            html += "color:#\(goldHex)CC;"
            html += "font-size:0.9em;"
            html += "text-align:center;"
            html += "margin-bottom:22px;"
            html += "\">\(Self.escapeHTML(scroll.theme))</div>"
        }

        // Hairline separator
        if !scroll.title.isEmpty || !scroll.theme.isEmpty {
            html += "<hr style=\"border:none;border-top:0.5px solid #\(goldHex)22;margin:0 0 24px 0;\">"
        }

        // Scroll roman + day eyebrow
        html += "<div style=\""
        html += "text-align:center;"
        html += "font-family:-apple-system,sans-serif;"
        html += "font-size:10px;"
        html += "letter-spacing:1.8px;"
        html += "color:#\(mutedHex);"
        html += "margin-bottom:28px;"
        html += "text-transform:uppercase;"
        html += "\">SCROLL \(scroll.roman) \u{00B7} DAY \(Roman.from(max(1, days))) OF XXX</div>"

        // Body paragraphs
        let effectiveBookmark = justBookmarkedIndex ?? scroll.bookmarkParagraphIndex
        for (index, paragraph) in scroll.paragraphs.enumerated() {
            let isBookmarked = effectiveBookmark == index
            var p = isBookmarked
                ? "<p data-p=\"\(index)\" class=\"bookmarked\">"
                : "<p data-p=\"\(index)\">"
            if isBookmarked {
                p += "<span class=\"bookmark-label\">You stopped here</span>"
            }
            p += Self.escapeHTML(paragraph)
            p += "</p>"
            html += p
        }

        // Closing diamond
        html += "<div style=\"text-align:center;margin-top:48px;\">"
        html += "<span style=\"font-size:16px;color:#\(goldHex)33;\">&#x22C4;</span>"
        html += "</div>"

        return html
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func quotedExcerpt(_ excerpt: String) -> String {
        "\u{201C}\(excerpt)\u{201D}\n\n\u{2014} Scroll \(scroll.roman)"
    }

    // MARK: - Sealing

    private func sealReading() {
        guard !sealFired else { return }
        sealFired = true
        sealHaptic.impactOccurred()
        if let session = eligibleSession {
            store.toggleSession(session)
        }
    }
}

// MARK: - Seal Reading Sheet

/// The 90%-scroll end-sheet. "Seal this reading" header + gold primary CTA.
/// Presented automatically once `canSeal` flips true; also reachable manually
/// from a future "Seal →" button if we ever add one to the progress bar chrome.
private struct SealReadingSheet: View {
    @EnvironmentObject var store: AppStore
    let scroll: Scroll
    let session: Session
    let canSeal: Bool
    let onSeal: () -> Void

    var body: some View {
        ZStack {
            LuxColor.card.ignoresSafeArea()
            NoiseTextureView().ignoresSafeArea()

            VStack(spacing: 24) {
                // Diamond ornament
                Text("\u{22C4}")
                    .font(.system(size: 24))
                    .foregroundColor(LuxColor.goldMuted)

                VStack(spacing: 8) {
                    Text("Seal this reading")
                        .font(LuxFont.serif(22))
                        .foregroundColor(LuxColor.textPrimary)

                    Text("\(session.label.uppercased()) \u{00B7} SCROLL \(scroll.roman) \u{00B7} DAY \(Roman.from(max(1, store.state.scrollDaysCompleted(scroll.id))))")
                        .font(LuxFont.mono(10))
                        .tracking(1)
                        .foregroundColor(LuxColor.textSecondary)
                }

                Button {
                    onSeal()
                } label: {
                    HStack(spacing: 6) {
                        Text("Seal")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(LuxPrimaryButtonStyle(disabled: !canSeal))
                .disabled(!canSeal)
                .padding(.horizontal, 32)

                if !canSeal {
                    Text("Finish reading to seal.")
                        .font(LuxFont.sans(10))
                        .tracking(0.5)
                        .foregroundColor(LuxColor.textMuted)
                }
            }
            .padding(32)
        }
    }
}

// MARK: - Edit Scroll Sheet (pencil)

/// Thin wrapper around the existing edit-mode UI from `ScrollEditorSheet`,
/// presented as a full-screen cover from the reader's pencil button.
/// Saves via `onSave` — no AppStore mutation here, caller handles it.
private struct EditScrollSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var store: AppStore

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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    // Status note
                    if scroll.status == .active {
                        Text("Complete 30 days on this scroll to earn XP and seals, then unlock the next.")
                            .font(LuxFont.sans(13))
                            .foregroundColor(LuxColor.textSecondary)
                            .padding(.bottom, 8)
                    } else if scroll.status == .locked {
                        Text("This scroll is locked. You can still draft its title and notes ahead of time.")
                            .font(LuxFont.sans(13))
                            .foregroundColor(LuxColor.textSecondary)
                            .padding(.bottom, 8)
                    }

                    fieldLabel("TITLE")
                    TextField("Give this scroll a title", text: $title)
                        .luxTextField()

                    fieldLabel("ONE-LINE THEME")
                        .padding(.top, 14)
                    TextField("e.g. what this scroll asks of you", text: $theme)
                        .luxTextField()

                    HStack {
                        fieldLabel("YOUR NOTES")
                        Spacer()
                        if !notes.isEmpty {
                            Button("Clean up") {
                                notes = Scroll.normalizedNotes(notes)
                            }
                            .font(LuxFont.sans(11, weight: .medium))
                            .foregroundColor(LuxColor.gold)
                        }
                    }
                    .padding(.top, 14)

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $notes)
                            .frame(minHeight: 220)
                            .padding(10)
                            .scrollContentBackground(.hidden)
                            .background(LuxColor.cardBorder.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(LuxColor.cardBorder, lineWidth: 0.5)
                            )
                            .foregroundColor(LuxColor.textPrimary)
                            .font(LuxFont.sans(14))
                        if notes.isEmpty {
                            Text("Paste or type freely — leave a blank line between paragraphs.")
                                .font(LuxFont.sans(13))
                                .foregroundColor(LuxColor.textMuted)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }

                    Text("Tip: pasted text often has a line break after every line. Tap \u{201C}Clean up\u{201D} to reflow into proper paragraphs.")
                        .font(LuxFont.sans(11))
                        .foregroundColor(LuxColor.textMuted)
                        .padding(.top, 6)
                }
                .padding(20)
                .padding(.bottom, 40)
            }
            .background(LuxColor.bg.ignoresSafeArea())
            .navigationTitle("Scroll \(scroll.roman)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(LuxColor.bg, for: .navigationBar)
            .toolbarColorScheme(colorScheme, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .light))
                            .foregroundColor(LuxColor.textSecondary)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = scroll
                        updated.title = title
                        updated.theme = theme
                        updated.notes = Scroll.normalizedNotes(notes)
                        onSave(updated)
                    }
                    .font(LuxFont.sans(14, weight: .medium))
                    .foregroundColor(LuxColor.gold)
                }
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(LuxFont.sans(10, weight: .medium))
            .tracking(1.4)
            .foregroundColor(LuxColor.textMuted)
    }
}

// MARK: - TextField style helper

private extension View {
    /// Lux-styled text field: warmWhite text, stone border underline.
    func luxTextField() -> some View {
        self
            .font(LuxFont.sans(15))
            .foregroundColor(LuxColor.textPrimary)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(LuxColor.cardBorder)
                    .frame(height: 0.5)
            }
    }
}

// MARK: - Preview

#Preview {
    let store = AppStore()
    let scroll = store.state.scrolls.first!
    return ScrollReaderView(
        scroll: scroll,
        onSave: { _ in }
    )
    .environmentObject(store)
}
