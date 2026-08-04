import SwiftUI

/// $500 Club rebuild of the Journal screen. Same public surface as before
/// (`openSearch`), same draft/publish/pin/delete/deep-link plumbing via
/// `AppStore`. The header's plus button was removed — it duplicated the
/// pencil button's inline-draft flow via a separate modal composer; see
/// `TodayView.reflectionButton` for the one remaining place that still
/// switches to this tab and starts a draft from outside it.
struct JournalView: View {
    @EnvironmentObject var store: AppStore
    var openSearch: () -> Void

    private enum Filter: String, CaseIterable { case all = "All", starred = "Starred", reflections = "Reflections" }
    @State private var filter: Filter = .all

    private var draftEntries: [JournalEntry] {
        store.state.journal.filter { $0.isDraft }
    }

    private var publishedEntries: [JournalEntry] {
        let base = store.state.journal.filter { !$0.isDraft }.sorted { $0.date > $1.date }
        switch filter {
        case .all: return base
        case .starred: return base.filter { $0.isPinnedForWidget }
        case .reflections: return base.filter { $0.scrollId == nil && ($0.bookTitle ?? "").isEmpty }
        }
    }

    /// Groups published entries into "Today" / "This Week" / "Earlier"
    /// buckets, in that order, dropping empty buckets entirely.
    private var groups: [(label: String, entries: [JournalEntry])] {
        let today = DateKey.today()
        let weekAgo = DateKey.add(-7, to: today)
        var todayBucket: [JournalEntry] = []
        var weekBucket: [JournalEntry] = []
        var earlierBucket: [JournalEntry] = []
        for entry in publishedEntries {
            if entry.date == today { todayBucket.append(entry) }
            else if entry.date > weekAgo { weekBucket.append(entry) }
            else { earlierBucket.append(entry) }
        }
        var result: [(String, [JournalEntry])] = []
        if !todayBucket.isEmpty { result.append(("Today", todayBucket)) }
        if !weekBucket.isEmpty { result.append(("This Week", weekBucket)) }
        if !earlierBucket.isEmpty { result.append(("Earlier", earlierBucket)) }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
            }
            .scrollDismissesKeyboard(.interactively)
            .background(LuxColor.bg.ignoresSafeArea())
            .onAppear { scrollToPendingEntry(proxy: proxy) }
            .onChange(of: store.pendingJournalEntryId) { _, _ in
                scrollToPendingEntry(proxy: proxy)
            }
        }
    }

    private func scrollToPendingEntry(proxy: ScrollViewProxy) {
        guard let id = store.pendingJournalEntryId else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation { proxy.scrollTo(id, anchor: .top) }
        }
        store.pendingJournalEntryId = nil
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            filterChips

            if !draftEntries.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("DRAFTS").luxEyebrow()
                    ForEach(draftEntries) { entry in
                        DraftEntryRow(
                            entry: entry,
                            scroll: store.state.scrolls.first(where: { $0.id == entry.scrollId }),
                            onUpdate: { store.updateJournalEntry(entry.id, text: $0) },
                            onPublish: { store.publishDraft(entry.id) },
                            onDelete: { store.deleteJournalEntry(entry.id) }
                        )
                    }
                }
            }

            ForEach(groups, id: \.label) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(group.label.uppercased()).luxEyebrow()
                    VStack(spacing: 10) {
                        ForEach(group.entries) { entry in
                            JournalEntryRow(
                                entry: entry,
                                scroll: store.state.scrolls.first(where: { $0.id == entry.scrollId }),
                                initiallyExpanded: entry.id == store.pendingJournalEntryId,
                                onDelete: { store.deleteJournalEntry(entry.id) },
                                onConvertToDraft: { store.convertToDraft(entry.id) },
                                onTogglePin: { store.toggleJournalPinForWidget(entry.id) }
                            )
                            .id(entry.id)
                        }
                    }
                }
            }

            if draftEntries.isEmpty && publishedEntries.isEmpty {
                LuxEmptyLine(text: "No reflections yet. Tap + to write about today's practice.", height: 80)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 120)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Roman.from(max(0, publishedEntries.count))) ENTRIES").luxEyebrow()
                Text("Journal")
                    .font(LuxFont.serif(32))
                    .tracking(-0.3)
                    .foregroundColor(LuxColor.textPrimary)
            }
            Spacer()
            HStack(spacing: 10) {
                LuxIconButton(systemImage: "magnifyingglass", action: openSearch)
                LuxIconButton(systemImage: "square.and.pencil", action: { store.addDraftEntry() })
            }
        }
    }

    private var filterChips: some View {
        HStack(spacing: 20) {
            ForEach(Filter.allCases, id: \.self) { f in
                Button {
                    withAnimation(LuxMotion.standard) { filter = f }
                } label: {
                    VStack(spacing: 6) {
                        Text(f.rawValue)
                            .font(LuxFont.sans(10, weight: .medium))
                            .tracking(1.2)
                            .foregroundColor(filter == f ? LuxColor.textPrimary : LuxColor.textSecondary)
                        Rectangle()
                            .fill(filter == f ? LuxColor.gold : Color.clear)
                            .frame(height: 1)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

// MARK: - Draft row

private struct DraftEntryRow: View {
    let entry: JournalEntry
    let scroll: Scroll?
    let onUpdate: (String) -> Void
    let onPublish: () -> Void
    let onDelete: () -> Void
    @State private var editedText: String
    @State private var showDeleteConfirmation = false
    @FocusState private var isFocused: Bool

    init(entry: JournalEntry, scroll: Scroll?, onUpdate: @escaping (String) -> Void, onPublish: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.entry = entry
        self.scroll = scroll
        self.onUpdate = onUpdate
        self.onPublish = onPublish
        self.onDelete = onDelete
        _editedText = State(initialValue: entry.text)
    }

    var body: some View {
        LuxCard(cornerRadius: 16, showsNoise: false) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("DRAFT \u{00B7} Scroll \(scroll?.roman ?? "\u{2014}")")
                        .font(LuxFont.mono(9))
                        .foregroundColor(LuxColor.textMuted)
                    Spacer()
                    // Always-visible way to back out — dismisses the keyboard and, if
                    // nothing's been written yet, discards the empty draft outright
                    // (nothing to lose, so no confirmation). This used to be reachable
                    // only via a hidden long-press context menu.
                    Button(action: handleClose) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(LuxColor.textMuted)
                    }
                    .buttonStyle(.plain)
                    if !editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button(action: onPublish) {
                            Image(systemName: "checkmark.circle").foregroundColor(LuxColor.gold)
                        }
                        .buttonStyle(.plain)
                    }
                }
                TextEditor(text: $editedText)
                    .font(LuxFont.sans(13))
                    .foregroundColor(LuxColor.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 80)
                    .focused($isFocused)
                    .onChange(of: editedText) { _, newValue in onUpdate(newValue) }
                    .onAppear { if entry.text.isEmpty { isFocused = true } }
                    .toolbar {
                        // Standard iOS keyboard-dismiss affordance — the app had no
                        // Done button anywhere and tapping outside the text view
                        // didn't resign focus either, so the keyboard had no way
                        // to go away short of force-quitting or finding the hidden
                        // delete action.
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done", action: handleClose)
                        }
                    }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(LuxColor.goldMuted.opacity(0.4), lineWidth: 0.5))
        .contextMenu {
            Button(role: .destructive) { showDeleteConfirmation = true } label: {
                Label("Delete Draft", systemImage: "trash")
            }
        }
        .confirmationDialog("Delete this draft?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Dismisses the keyboard; if the draft is still empty, also removes the
    /// row entirely — closing an empty draft should feel like backing out of
    /// something you never started, not a decision that needs confirming.
    /// A draft with text in it is left alone (already auto-saved via
    /// `onUpdate` on every keystroke), so closing the keyboard never loses
    /// anything the reader typed.
    private func handleClose() {
        isFocused = false
        if editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onDelete()
        }
    }
}

// MARK: - Entry row

private struct JournalEntryRow: View {
    let entry: JournalEntry
    let scroll: Scroll?
    let onDelete: () -> Void
    let onConvertToDraft: () -> Void
    let onTogglePin: () -> Void
    @State private var expanded: Bool
    @State private var showDeleteConfirmation = false

    init(entry: JournalEntry, scroll: Scroll?, initiallyExpanded: Bool = false, onDelete: @escaping () -> Void, onConvertToDraft: @escaping () -> Void, onTogglePin: @escaping () -> Void) {
        self.entry = entry
        self.scroll = scroll
        self.onDelete = onDelete
        self.onConvertToDraft = onConvertToDraft
        self.onTogglePin = onTogglePin
        _expanded = State(initialValue: initiallyExpanded)
    }

    private var sourceLabel: String {
        if let bookTitle = entry.bookTitle, !bookTitle.isEmpty { return bookTitle.uppercased() }
        if let scroll { return "SCROLL \(scroll.roman)" }
        return "REFLECTION"
    }

    /// Never surfaces a raw URL or email address in the preview — swaps
    /// either for a bracketed placeholder instead.
    private var sanitizedPreview: String {
        var text = entry.text
        if text.range(of: #"https?://\S+"#, options: .regularExpression) != nil {
            text = text.replacingOccurrences(of: #"https?://\S+"#, with: "[Link]", options: .regularExpression)
        }
        if text.range(of: #"[\w.+-]+@[\w-]+\.[\w.-]+"#, options: .regularExpression) != nil {
            text = text.replacingOccurrences(of: #"[\w.+-]+@[\w-]+\.[\w.-]+"#, with: "[Letter]", options: .regularExpression)
        }
        return text
    }

    var body: some View {
        LuxRowCard(cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(DateKey.short(entry.date).uppercased()) \u{2022} \(sourceLabel)")
                        .font(LuxFont.mono(9))
                        .foregroundColor(LuxColor.textMuted)
                    Spacer()
                    Image(systemName: entry.isPinnedForWidget ? "star.fill" : "star")
                        .font(.system(size: 11, weight: .light))
                        .foregroundColor(entry.isPinnedForWidget ? LuxColor.gold : LuxColor.textMuted)
                }
                Text(sanitizedPreview)
                    .font(LuxFont.sans(14))
                    .foregroundColor(LuxColor.textSecondary)
                    .lineSpacing(4)
                    .lineLimit(expanded ? nil : 2)
            }
            .padding(16)
            .frame(minHeight: 80, alignment: .topLeading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(LuxMotion.standard) { expanded.toggle() }
        }
        .contextMenu {
            Button(action: onTogglePin) {
                Label(entry.isPinnedForWidget ? "Remove from Widget" : "Feature in Widget", systemImage: entry.isPinnedForWidget ? "star.slash" : "star")
            }
            Button(action: onConvertToDraft) {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive) { showDeleteConfirmation = true } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .confirmationDialog("Delete this entry?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        }
    }
}
