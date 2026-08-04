import SwiftUI

/// Reads one book from the shelf. This view is just a router: it looks up
/// the book's `LibraryIndexEntry.sourceType` and hands off entirely to one
/// of two independent reading engines, per the Phase 1 architecture split
/// (isolated PDF pipeline, EPUB pipeline untouched):
///
/// - `.epub` — `LibraryReaderBody` below, unchanged: `BookChapterWebView`
///   (CSS-column pagination inside a `WKWebView`), loading the book's full
///   text from disk (`LibraryStore.load`) only while this view is on
///   screen, and releasing it again once dismissed.
/// - `.pdf` — `PDFReaderView` (`PDFReaderView.swift`), native PDFKit
///   rendering of the original file (`LibraryStore.pdfURL`), never routed
///   through `BookChapterWebView`/text reflow at all.
///
/// The two engines share nothing at render time — no common "reading view"
/// protocol, no fallback from one into the other — by design: a PDF that
/// used to get flattened into `<p>` tags for the WebView pipeline now never
/// touches that pipeline in the first place.
struct LibraryReaderView: View {
    let bookId: UUID
    let fallbackTitle: String

    @EnvironmentObject private var store: AppStore

    private var indexEntry: LibraryIndexEntry? {
        store.state.libraryBooks.first { $0.id == bookId }
    }

    var body: some View {
        switch indexEntry?.sourceType ?? .epub {
        case .pdf:
            PDFReaderView(bookId: bookId, fallbackTitle: fallbackTitle)
        case .epub:
            LibraryReaderBody(bookId: bookId, fallbackTitle: fallbackTitle)
        }
    }
}

/// The original EPUB reading screen, renamed from `LibraryReaderView` but
/// otherwise untouched — `WKWebView`/CSS-column pagination, chapter-by-
/// chapter loading, Apple-Books-style chrome. See `LibraryReaderView` above
/// for the routing that now sits in front of this.
struct LibraryReaderBody: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.appearanceMode) var appearanceMode
    let bookId: UUID
    let fallbackTitle: String

    @State private var book: Book?
    @State private var loadError: String?
    @State private var showFontControl = false
    @State private var showTableOfContents = false

    // Highlight actions: set when the reader picks "Add to Journal" or "Save
    // as Scroll" from a text selection; presenting the matching sheet is
    // driven off these, the same pattern the Scroll reading view uses.
    @State private var pendingJournalExcerpt: String?
    @State private var pendingScrollExcerpt: String?
    /// Set only when `pendingScrollExcerpt` came from "Make this chapter a
    /// Scroll" (so the chapter's own title can prefill the destination
    /// sheet); left nil for a plain text-selection excerpt, which has no
    /// natural title of its own.
    @State private var pendingScrollSuggestedTitle: String?
    /// Presented instead of `ScrollDestinationSheet` when a non-Plus reader
    /// tries to save Library text into a scroll — writing into a scroll's
    /// notes is an edit of Plus-gated scroll content (same as opening one
    /// to read it), so it needs the same gate. See `requestSaveAsScroll`.
    @State private var showScrollPlusGate = false

    // MARK: WKWebView reading state
    @State private var htmlCurrentChapterIndex: Int = 0
    @State private var htmlCurrentPage: Int = 0
    @State private var htmlPageCount: Int = 1
    /// A fraction to restore the next time the currently-loading chapter
    /// settles — set when jumping to a new chapter (table of contents, a
    /// swipe past a chapter edge, or the initial saved bookmark) and left
    /// alone otherwise, so `BookChapterWebView` can tell a genuine jump
    /// apart from a same-chapter reload (rotation, font size, theme).
    @State private var htmlInitialFraction: Double? = nil
    @State private var htmlProxy = BookWebReaderProxy()

    var theme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }
    private var fontScale: CGFloat { CGFloat(store.state.readingFontScale) }

    private var indexEntry: LibraryIndexEntry? {
        store.state.libraryBooks.first { $0.id == bookId }
    }

    private var currentChapterIndex: Int { htmlCurrentChapterIndex }

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        Group {
            if let book {
                readingViewHTML(book, colors: colors)
            } else if let loadError {
                errorView(loadError, colors: colors)
            } else {
                loadingView(colors)
            }
        }
        .background(colors.background)
        .navigationTitle(navigationTitleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let book, book.chapters.count > 1 {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showTableOfContents = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                }
            }
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
                        brass: theme.brass
                    )
                    .presentationCompactAdaptation(.popover)
                }
            }
        }
        .sheet(isPresented: $showTableOfContents) {
            if let book {
                BookTableOfContentsSheet(
                    book: book,
                    currentChapterIndex: currentChapterIndex,
                    brass: theme.brass,
                    onSelect: { index in
                        htmlInitialFraction = 0
                        htmlCurrentChapterIndex = index
                        showTableOfContents = false
                    },
                    onMakeScroll: { index in
                        guard let chapter = book.chapters[safe: index] else { return }
                        requestSaveAsScroll(chapter.paragraphs.joined(separator: "\n\n"), suggestedTitle: chapter.title)
                        showTableOfContents = false
                    }
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { pendingJournalExcerpt != nil },
            set: { if !$0 { pendingJournalExcerpt = nil } }
        )) {
            if let excerpt = pendingJournalExcerpt, let book {
                JournalComposerSheet(scroll: nil, initialText: quotedExcerpt(excerpt, book: book)) { entryText in
                    store.addJournalEntry(entryText, scrollId: nil, bookTitle: book.title)
                    pendingJournalExcerpt = nil
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { pendingScrollExcerpt != nil },
            set: { if !$0 { pendingScrollExcerpt = nil } }
        )) {
            if let excerpt = pendingScrollExcerpt {
                ScrollDestinationSheet(text: excerpt, suggestedTitle: pendingScrollSuggestedTitle) {
                    pendingScrollExcerpt = nil
                    pendingScrollSuggestedTitle = nil
                }
            }
        }
        .fullScreenCover(isPresented: $showScrollPlusGate) {
            Day30PaywallView()
        }
        .task { await load() }
    }

    /// Mirrors Apple Books: the small nav-bar title reads as the current
    /// chapter while there's more than one, and falls back to the book's own
    /// title for single-chapter books (or before anything has loaded).
    private var navigationTitleText: String {
        guard let book else { return fallbackTitle }
        guard book.chapters.count > 1, let chapter = book.chapters[safe: currentChapterIndex],
              let title = chapter.title, !title.isEmpty else {
            return book.title
        }
        return title
    }

    private func loadingView(_ colors: AdaptivePalette) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Opening book…").foregroundColor(colors.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String, colors: AdaptivePalette) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(colors.red)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundColor(colors.textDim)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Reading view

    /// One `BookChapterWebView` loaded with whichever chapter is current.
    /// Crossing a chapter boundary is driven by `BookChapterWebView`'s
    /// `onRequestNextChapter`/`onRequestPreviousChapter` (an edge-of-content
    /// swipe) or by the footer chevrons / table of contents, all of which
    /// go through `htmlGoNext`/`htmlGoPrevious` or set `htmlCurrentChapterIndex`
    /// directly.
    private func readingViewHTML(_ book: Book, colors: AdaptivePalette) -> some View {
        let chapterIndex = min(max(0, htmlCurrentChapterIndex), max(0, book.chapters.count - 1))
        return GeometryReader { geo in
            BookChapterWebView(
                html: chapterHTML(for: book.chapters[chapterIndex]),
                theme: theme,
                appearanceMode: appearanceMode,
                fontScale: fontScale,
                size: geo.size,
                currentPage: $htmlCurrentPage,
                pageCount: $htmlPageCount,
                initialFraction: htmlInitialFraction,
                proxy: htmlProxy,
                onRequestNextChapter: {
                    guard chapterIndex < book.chapters.count - 1 else { return }
                    htmlInitialFraction = 0
                    htmlCurrentChapterIndex = chapterIndex + 1
                },
                onRequestPreviousChapter: {
                    guard chapterIndex > 0 else { return }
                    htmlInitialFraction = 1
                    htmlCurrentChapterIndex = chapterIndex - 1
                },
                onAddToJournal: { excerpt in
                    pendingJournalExcerpt = excerpt
                },
                onSaveAsScroll: { excerpt in
                    requestSaveAsScroll(excerpt, suggestedTitle: nil)
                }
            )
            .onChange(of: htmlCurrentPage) { _, newValue in
                guard htmlPageCount > 0 else { return }
                let fraction = htmlPageCount > 1 ? Double(newValue) / Double(htmlPageCount - 1) : 0
                store.setLibraryBookmark(bookId: bookId, chapterIndex: chapterIndex, scrollFraction: fraction)
            }
        }
        .safeAreaInset(edge: .bottom) {
            let multiChapter = book.chapters.count > 1
            ReadingProgressBar(
                progress: htmlPageCount > 1 ? Double(htmlCurrentPage) / Double(htmlPageCount - 1) : 1,
                caption: htmlPageProgressCaption(book: book),
                brass: theme.brass,
                backgroundColor: colors.background,
                onTapCaption: multiChapter ? { showTableOfContents = true } : nil,
                onPrevious: (htmlCurrentPage > 0 || chapterIndex > 0) ? { htmlGoPrevious(book: book) } : nil,
                onNext: (htmlCurrentPage < htmlPageCount - 1 || chapterIndex < book.chapters.count - 1) ? { htmlGoNext(book: book) } : nil
            )
        }
    }

    /// A chapter's sanitized markup, or — for the rare chapter that has
    /// none (extraction failed for just this one, or the book predates
    /// HTML capture) — its plain paragraphs wrapped in `<p>` tags, so
    /// `BookChapterWebView` always has something structurally valid to lay
    /// out rather than an empty page.
    private func chapterHTML(for chapter: BookChapter) -> String {
        guard chapter.html.isEmpty else { return chapter.html }
        return chapter.paragraphs.map { paragraph in
            let escaped = paragraph
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return "<p>\(escaped)</p>"
        }.joined()
    }

    /// Steps to the next page within the current chapter, or — if already
    /// on the last page — straight to the next chapter's first page. Used
    /// by the footer's chevron, which (unlike an edge-of-content swipe) has
    /// no scroll gesture of its own to read an overscroll from.
    private func htmlGoNext(book: Book) {
        if htmlCurrentPage < htmlPageCount - 1 {
            htmlProxy.goToNextPage()
        } else if htmlCurrentChapterIndex < book.chapters.count - 1 {
            htmlInitialFraction = 0
            htmlCurrentChapterIndex += 1
        }
    }

    /// Mirrors `htmlGoNext(book:)` for the previous-page chevron.
    private func htmlGoPrevious(book: Book) {
        if htmlCurrentPage > 0 {
            htmlProxy.goToPreviousPage()
        } else if htmlCurrentChapterIndex > 0 {
            htmlInitialFraction = 1
            htmlCurrentChapterIndex -= 1
        }
    }

    private func htmlPageProgressCaption(book: Book) -> String {
        let chapterNum = min(max(0, htmlCurrentChapterIndex), max(0, book.chapters.count - 1)) + 1
        let localPage = htmlCurrentPage + 1
        let totalLocalPages = max(1, htmlPageCount)
        if book.chapters.count > 1 {
            return "Chapter \(chapterNum) of \(book.chapters.count) \u{B7} Page \(localPage) of \(totalLocalPages)"
        } else {
            return "Page \(localPage) of \(totalLocalPages)"
        }
    }

    /// Single entry point for both "Save as Scroll" triggers (a text
    /// selection's menu action, and "Make this chapter a Scroll" from the
    /// table of contents) — gates on Plus access before staging the excerpt
    /// for `ScrollDestinationSheet`, same as `ContentView.attemptOpenScroll`
    /// gates opening a scroll to read.
    private func requestSaveAsScroll(_ text: String, suggestedTitle: String?) {
        guard store.state.hasPlusAccess else {
            showScrollPlusGate = true
            return
        }
        pendingScrollSuggestedTitle = suggestedTitle
        pendingScrollExcerpt = text
    }

    // MARK: - Bookmark restore

    /// Mirrors `ScrollEditorSheet.quotedExcerpt`, attributing the quote to
    /// the book's title rather than a scroll's roman numeral.
    private func quotedExcerpt(_ excerpt: String, book: Book) -> String {
        "\u{201C}\(excerpt)\u{201D}\n\n\u{2014} \(book.title)"
    }

    private func load() async {
        guard book == nil else { return }
        do {
            let loaded = try LibraryStore.load(bookId)
            await MainActor.run {
                book = loaded
                if let entry = indexEntry {
                    htmlCurrentChapterIndex = min(max(0, entry.bookmarkChapterIndex), max(0, loaded.chapters.count - 1))
                    htmlInitialFraction = entry.bookmarkScrollFraction ?? 0
                }
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "This book couldn't be opened."
            await MainActor.run { loadError = message }
        }
    }
}
