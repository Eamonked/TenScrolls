import SwiftUI
import PDFKit

// MARK: - Reading engine (native PDFKit)

/// Renders a `.pdf`-sourced Library book directly through PDFKit's own
/// vector rasterizer, instead of the flattened-to-text/WKWebView reflow
/// path `BookChapterWebView` uses for EPUB. This is the deliberate Phase 2
/// split: a PDF's page geometry, images, columns, and typography all render
/// exactly as the file itself defines them, and pinch-zoom has real page
/// content to scale into rather than reflowable text with nothing to zoom.
///
/// `PDFView`'s own `.singlePageContinuous` display mode only rasterizes the
/// visible page plus a small look-ahead/look-behind buffer and recycles the
/// rest — the same "virtualized" behavior `BookChapterWebView` gets for
/// free from one-chapter-at-a-time loading, but here it's native to the
/// rendering engine rather than a side effect of how content is chunked.
struct PDFPageView: UIViewRepresentable {
    let url: URL
    @Binding var currentPageIndex: Int
    @Binding var pageCount: Int
    /// A page index to jump to once, the first time it's set to a non-nil
    /// value different from wherever the view already is — mirrors
    /// `BookChapterWebView.initialFraction`'s "read once" restore pattern
    /// for a saved bookmark, without fighting the reader's own subsequent
    /// navigation on every `updateUIView`.
    var pendingJumpPageIndex: Int?
    var onDocumentLoaded: (PDFDocument) -> Void
    var onSelectionChange: (String?) -> Void
    var onAddToJournal: ((String) -> Void)?
    var onSaveAsScroll: ((String) -> Void)?
    var proxy: PDFReaderProxy?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> NativePDFView {
        let view = NativePDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .horizontal
        view.usePageViewController(true, withViewOptions: nil)
        // Deliberately NOT disabling zoom the way the old WebView-based
        // path did (`user-scalable=no` in `BookChapterWebView.document`) —
        // a fixed-layout PDF page is exactly the kind of content pinch-zoom
        // is for. `maxScaleFactor` is set relative to the fit-to-width
        // scale once the document loads (see `Coordinator.documentDidLoad`),
        // since PDFKit has no fixed document size to compute a flat 400%
        // against ahead of time.
        view.minScaleFactor = view.scaleFactorForSizeToFit
        view.delegate = context.coordinator
        view.onAddToJournal = onAddToJournal
        view.onSaveAsScroll = onSaveAsScroll
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.pageChanged),
            name: .PDFViewPageChanged, object: view
        )
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.selectionChanged),
            name: .PDFViewSelectionChanged, object: view
        )
        context.coordinator.pdfView = view
        proxy?.pdfView = view
        if let document = PDFDocument(url: url) {
            view.document = document
            context.coordinator.documentDidLoad(document, in: view)
        }
        return view
    }

    func updateUIView(_ view: NativePDFView, context: Context) {
        view.onAddToJournal = onAddToJournal
        view.onSaveAsScroll = onSaveAsScroll
        proxy?.pdfView = view
        guard let pendingJumpPageIndex,
              pendingJumpPageIndex != context.coordinator.lastAppliedJump,
              let document = view.document,
              let page = document.page(at: pendingJumpPageIndex) else { return }
        context.coordinator.lastAppliedJump = pendingJumpPageIndex
        view.go(to: page)
    }

    static func dismantleUIView(_ view: NativePDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject, PDFViewDelegate {
        var parent: PDFPageView
        weak var pdfView: NativePDFView?
        var lastAppliedJump: Int?

        init(_ parent: PDFPageView) { self.parent = parent }

        func documentDidLoad(_ document: PDFDocument, in view: PDFView) {
            parent.pageCount = document.pageCount
            parent.onDocumentLoaded(document)
            // 400%+ relative to the page's own fit-to-width scale, matching
            // the spec's "pinch-to-zoom up to 400%+" against the page as
            // the reader actually sees it, not an arbitrary absolute value.
            DispatchQueue.main.async {
                view.maxScaleFactor = max(view.scaleFactorForSizeToFit * 4.5, view.maxScaleFactor)
            }
        }

        @objc func pageChanged() {
            guard let pdfView, let document = pdfView.document, let page = pdfView.currentPage else { return }
            parent.currentPageIndex = document.index(for: page)
        }

        @objc func selectionChanged() {
            let text = pdfView?.currentSelection?.string
            parent.onSelectionChange(text)
        }
    }
}

// MARK: - Selection menu

/// `PDFView` subclass surfacing "Save as Scroll" and "Add to Journal" in
/// the system menu over a text selection — the PDFKit counterpart to
/// `BookWebView.buildMenu(with:)`. `PDFView` exposes `currentSelection`
/// directly (unlike `WKWebView`, which needed a JS selection-change bridge),
/// so this is simpler: no `WKScriptMessageHandler` plumbing needed.
final class NativePDFView: PDFView {
    var onAddToJournal: ((String) -> Void)?
    var onSaveAsScroll: ((String) -> Void)?

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .context,
              onAddToJournal != nil || onSaveAsScroll != nil,
              let excerpt = currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !excerpt.isEmpty else { return }

        var actions: [UIMenuElement] = []
        if let onSaveAsScroll {
            actions.append(UIAction(title: "Save as Scroll", image: UIImage(systemName: "scroll")) { [weak self] _ in
                onSaveAsScroll(excerpt)
                self?.clearSelection()
            })
        }
        if let onAddToJournal {
            actions.append(UIAction(title: "Add to Journal", image: UIImage(systemName: "book")) { [weak self] _ in
                onAddToJournal(excerpt)
                self?.clearSelection()
            })
        }
        guard !actions.isEmpty else { return }
        builder.replaceChildren(ofMenu: .standardEdit) { existing in existing + actions }
    }
}

/// A tiny handle a hosting SwiftUI view can hold to drive the page view
/// programmatically (page-jump slider, TOC selection, search-result jump) —
/// the PDFKit counterpart to `BookWebReaderProxy`.
final class PDFReaderProxy {
    fileprivate weak var pdfView: NativePDFView?

    func goToPage(_ index: Int, animated: Bool = true) {
        guard let pdfView, let document = pdfView.document, let page = document.page(at: index) else { return }
        pdfView.go(to: page)
    }

    func goToNextPage() { pdfView?.goToNextPage(nil) }
    func goToPreviousPage() { pdfView?.goToPreviousPage(nil) }

    /// Jumps to and highlights the first match for `query`, searching
    /// onward from the current selection when there is one, or from the
    /// start of the document otherwise. Returns the matched selection, or
    /// nil if nothing was found — the caller uses this to drive a
    /// next/previous match affordance without re-running `findString`
    /// itself each time (see `PDFReaderView.performSearch`).
    @discardableResult
    func find(_ query: String, forward: Bool = true) -> PDFSelection? {
        guard let pdfView, let document = pdfView.document, !query.isEmpty else { return nil }
        let options: NSString.CompareOptions = forward ? [.caseInsensitive] : [.caseInsensitive, .backwards]
        if let currentSelection = pdfView.currentSelection,
           let match = document.findString(query, fromSelection: currentSelection, withOptions: options) {
            pdfView.setCurrentSelection(match, animate: true)
            pdfView.scrollSelectionToVisible(nil)
            return match
        }
        // No current selection to search onward from (first search, or
        // after a selection was cleared) — fall back to a from-scratch
        // search across the whole document.
        let allMatches = document.findString(query, withOptions: [.caseInsensitive])
        guard let first = forward ? allMatches.first : allMatches.last else { return nil }
        pdfView.setCurrentSelection(first, animate: true)
        pdfView.scrollSelectionToVisible(nil)
        return first
    }
}

// MARK: - Table of contents (PDF outline)

/// A contents list built from the PDF's own embedded outline/bookmarks —
/// the PDF counterpart to `BookTableOfContentsSheet`. Falls back to a plain
/// page list for a PDF with no outline (scanned documents, most receipts/
/// forms, and plenty of ordinary PDFs never declare one).
struct PDFOutlineSheet: View {
    @Environment(\.appearanceMode) var appearanceMode
    @Environment(\.dismiss) private var dismiss
    let document: PDFDocument
    let title: String
    let brass: Color
    let onSelect: (Int) -> Void

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        NavigationStack {
            Group {
                if let root = document.outlineRoot, root.numberOfChildren > 0 {
                    List {
                        outlineRows(root, depth: 0, colors: colors)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                } else {
                    List {
                        ForEach(0..<document.pageCount, id: \.self) { index in
                            Button {
                                onSelect(index)
                                dismiss()
                            } label: {
                                Text("Page \(index + 1)")
                                    .font(.system(size: 15, design: .serif))
                                    .foregroundColor(colors.text)
                            }
                            .listRowBackground(colors.ink2)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(colors.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func outlineRows(_ outline: PDFOutline, depth: Int, colors: AdaptivePalette) -> some View {
        ForEach(0..<outline.numberOfChildren, id: \.self) { i in
            if let child = outline.child(at: i) {
                Button {
                    // `PDFDocument.index(for:)` is PDFKit's own native
                    // lookup (returns `NSNotFound` rather than `nil` when
                    // the page isn't part of this document) — deliberately
                    // not wrapped in a same-signature extension here, which
                    // would shadow the native method instead of overriding
                    // it and recurse into itself.
                    if let dest = child.destination, let page = dest.page {
                        let index = document.index(for: page)
                        if index != NSNotFound {
                            onSelect(index)
                            dismiss()
                        }
                    }
                } label: {
                    Text(child.label ?? "Untitled")
                        .font(.system(size: 15, design: .serif))
                        .foregroundColor(colors.text)
                        .padding(.leading, CGFloat(depth) * 14)
                }
                .listRowBackground(colors.ink2)
                // Wrapped in `AnyView`: a `some View`-returning function
                // can't call itself — the compiler needs a concrete type for
                // the opaque return before it can resolve what "itself"
                // even is, which a genuinely recursive call can never
                // supply. `AnyView` breaks that cycle by type-erasing the
                // recursive branch (arbitrarily deep outline nesting is
                // rare enough that the erasure's runtime cost here is
                // irrelevant).
                if child.numberOfChildren > 0 {
                    AnyView(outlineRows(child, depth: depth + 1, colors: colors))
                }
            }
        }
    }
}

// MARK: - Full reading view

/// The Library's PDF counterpart to `LibraryReaderView`'s
/// `readingViewHTML(_:colors:)` — a whole `NavigationStack`-hosted screen
/// (TOC, page-jump, search, bottom progress bar), not just the raw page
/// surface. `LibraryReaderView` picks between this and its own WKWebView
/// path based on `LibraryIndexEntry.sourceType`.
struct PDFReaderView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.appearanceMode) var appearanceMode
    let bookId: UUID
    let fallbackTitle: String

    @State private var document: PDFDocument?
    @State private var currentPageIndex: Int = 0
    @State private var pageCount: Int = 1
    @State private var pendingJumpPageIndex: Int?
    @State private var showOutline = false
    @State private var showPageSlider = false
    @State private var sliderValue: Double = 0
    @State private var showSearch = false
    @State private var searchQuery = ""
    @State private var searchHasResult = true

    @State private var pendingJournalExcerpt: String?
    @State private var pendingScrollExcerpt: String?

    private let proxy = PDFReaderProxy()

    var theme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    private var indexEntry: LibraryIndexEntry? {
        store.state.libraryBooks.first { $0.id == bookId }
    }

    private var bookTitle: String { indexEntry?.title ?? fallbackTitle }

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        Group {
            if let fileURL {
                readerBody(fileURL, colors: colors)
            } else {
                errorView("This PDF couldn't be found on disk.", colors: colors)
            }
        }
        .background(colors.background)
        .navigationTitle(bookTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { restoreBookmark() }
    }

    private var fileURL: URL? { LibraryStore.pdfURL(for: bookId) }

    private func readerBody(_ url: URL, colors: AdaptivePalette) -> some View {
        // Dark-mode adaptation without altering the underlying file: PDFKit
        // renders the page's own colors as-is, so a "night mode" here uses
        // the same invert + hue-rotate trick common to PDF/e-reader apps —
        // it recolors the *rendered pixels* on the fly, leaving the PDF
        // itself untouched, rather than trying to rewrite the document.
        ZStack {
            PDFPageView(
                url: url,
                currentPageIndex: $currentPageIndex,
                pageCount: $pageCount,
                pendingJumpPageIndex: pendingJumpPageIndex,
                onDocumentLoaded: { doc in
                    document = doc
                },
                onSelectionChange: { _ in },
                onAddToJournal: { excerpt in pendingJournalExcerpt = excerpt },
                onSaveAsScroll: { excerpt in pendingScrollExcerpt = excerpt },
                proxy: proxy
            )
            .modifier(NightModeAdaptation(isDark: appearanceMode == .dark))
        }
        .onChange(of: currentPageIndex) { _, newValue in
            store.setLibraryPDFBookmark(bookId: bookId, pageIndex: newValue)
            sliderValue = Double(newValue)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
            }
            if document?.outlineRoot != nil || pageCount > 1 {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showOutline = true } label: { Image(systemName: "list.bullet") }
                }
            }
        }
        .sheet(isPresented: $showOutline) {
            if let document {
                PDFOutlineSheet(document: document, title: bookTitle, brass: theme.brass) { index in
                    pendingJumpPageIndex = index
                }
            }
        }
        .sheet(isPresented: $showPageSlider) {
            pageSliderSheet(colors: colors)
        }
        .sheet(isPresented: $showSearch) {
            searchSheet(colors: colors)
        }
        .sheet(isPresented: Binding(
            get: { pendingJournalExcerpt != nil },
            set: { if !$0 { pendingJournalExcerpt = nil } }
        )) {
            if let excerpt = pendingJournalExcerpt {
                JournalComposerSheet(scroll: nil, initialText: quotedExcerpt(excerpt)) { entryText in
                    store.addJournalEntry(entryText, scrollId: nil, bookTitle: bookTitle)
                    pendingJournalExcerpt = nil
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { pendingScrollExcerpt != nil },
            set: { if !$0 { pendingScrollExcerpt = nil } }
        )) {
            if let excerpt = pendingScrollExcerpt {
                ScrollDestinationSheet(text: excerpt, suggestedTitle: nil) {
                    pendingScrollExcerpt = nil
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            ReadingProgressBar(
                progress: pageCount > 1 ? Double(currentPageIndex) / Double(pageCount - 1) : 1,
                caption: "Page \(currentPageIndex + 1) of \(pageCount)",
                brass: theme.brass,
                backgroundColor: colors.background,
                onTapCaption: { sliderValue = Double(currentPageIndex); showPageSlider = true },
                onPrevious: currentPageIndex > 0 ? { proxy.goToPreviousPage() } : nil,
                onNext: currentPageIndex < pageCount - 1 ? { proxy.goToNextPage() } : nil
            )
        }
    }

    // MARK: - Page-jump slider

    private func pageSliderSheet(colors: AdaptivePalette) -> some View {
        VStack(spacing: 18) {
            Text("Page \(Int(sliderValue) + 1) of \(pageCount)")
                .font(AppFont.mono(13))
                .foregroundColor(colors.textDim)
            Slider(
                value: $sliderValue, in: 0...Double(max(0, pageCount - 1)), step: 1,
                onEditingChanged: { editing in
                    if !editing { pendingJumpPageIndex = Int(sliderValue) }
                }
            )
            .tint(theme.brass)
            .padding(.horizontal, 24)
        }
        .padding(.vertical, 28)
        .presentationDetents([.height(140)])
        .background(colors.ink2)
    }

    // MARK: - Search

    private func searchSheet(colors: AdaptivePalette) -> some View {
        NavigationStack {
            VStack(spacing: 14) {
                TextField("Search this book", text: $searchQuery, onCommit: { performSearch(forward: true) })
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)
                if !searchHasResult {
                    Text("No matches found").font(.system(size: 12.5)).foregroundColor(colors.textFaint)
                }
                HStack(spacing: 20) {
                    Button("Previous") { performSearch(forward: false) }
                    Button("Next") { performSearch(forward: true) }
                }
                .disabled(searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
            .padding(.top, 24)
            .background(colors.background.ignoresSafeArea())
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showSearch = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func performSearch(forward: Bool) {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchHasResult = proxy.find(query, forward: forward) != nil
    }

    // MARK: - Helpers

    private func quotedExcerpt(_ excerpt: String) -> String {
        "\u{201C}\(excerpt)\u{201D}\n\n\u{2014} \(bookTitle)"
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

    private func restoreBookmark() {
        guard let entry = indexEntry, entry.bookmarkPDFPageIndex > 0, pendingJumpPageIndex == nil else { return }
        pendingJumpPageIndex = entry.bookmarkPDFPageIndex
        currentPageIndex = entry.bookmarkPDFPageIndex
        sliderValue = Double(entry.bookmarkPDFPageIndex)
    }
}

/// Recolors the rendered PDF surface for dark mode without touching the
/// file itself — the standard invert + hue-rotate trick (the same one
/// Kindle/most PDF readers use for "night mode" on fixed-layout pages).
/// A no-op in light mode.
private struct NightModeAdaptation: ViewModifier {
    let isDark: Bool
    func body(content: Content) -> some View {
        if isDark {
            content.colorInvert().hueRotation(.degrees(180))
        } else {
            content
        }
    }
}
