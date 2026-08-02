import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Which layout the shelf is currently browsed in. Persisted locally (not
/// through `AppState`) since it's a display preference, not reading data —
/// no reason for it to ride along in the synced/backed-up app state blob.
private enum LibraryViewMode: String {
    case list
    case grid
}

/// Context menu content shared by every place a book can be long-pressed —
/// the list row, a grid cell, and a cover-flow card — so "Share" / "Remove"
/// stay in one place instead of three copies drifting apart.
@ViewBuilder
private func libraryContextMenuItems(
    for entry: LibraryIndexEntry,
    onShare: @escaping (LibraryIndexEntry) -> Void,
    onDelete: @escaping (LibraryIndexEntry) -> Void
) -> some View {
    Button {
        onShare(entry)
    } label: {
        Label("Share what I'm reading", systemImage: "square.and.arrow.up")
    }
    Button(role: .destructive) {
        onDelete(entry)
    } label: {
        Label("Remove Book", systemImage: "trash")
    }
}

/// The library shelf: full-length books imported outside the ten scrolls,
/// for reading alongside the daily practice rather than as part of it.
/// Only ever works with `LibraryIndexEntry` metadata here — the actual text
/// is loaded on demand by `LibraryReaderView` when a book is opened, and
/// released again once the reader navigates back.
struct LibraryView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.appearanceMode) var appearanceMode
    @Environment(\.dismiss) private var dismiss
    @State private var showImport = false
    @State private var pendingDelete: LibraryIndexEntry?
    @AppStorage("tenscrolls.libraryViewMode") private var viewModeRaw: String = LibraryViewMode.grid.rawValue
    #if canImport(UIKit)
    @State private var shareImage: UIImage?
    @State private var showShare = false
    #endif

    private var viewMode: LibraryViewMode {
        get { LibraryViewMode(rawValue: viewModeRaw) ?? .grid }
    }

    var theme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    private var books: [LibraryIndexEntry] {
        store.state.libraryBooks.sorted { $0.addedAt > $1.addedAt }
    }

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("THE SHELF").font(AppFont.mono(11)).tracking(1.4).foregroundColor(theme.brass)
                        Text("Library").font(AppFont.display(28)).foregroundColor(colors.text)
                    }
                    Text("Full books live here, separate from your ten scrolls — something to read alongside the daily practice, at whatever pace you like.")
                        .font(.system(size: 13)).foregroundColor(colors.textDim)
                        .padding(.bottom, 8)

                    if books.isEmpty {
                        emptyState(colors)
                    } else {
                        // A quick, flip-through way to recognize a book by its
                        // cover before committing to the fuller list/grid below.
                        CoverFlowView(
                            books: books, theme: theme, colors: colors,
                            onShare: shareBook, onDelete: { pendingDelete = $0 }
                        )
                        .padding(.bottom, 2)

                        viewModeToggle(colors)

                        switch viewMode {
                        case .list:
                            VStack(spacing: 10) {
                                ForEach(books) { entry in
                                    NavigationLink {
                                        LibraryReaderView(bookId: entry.id, fallbackTitle: entry.title)
                                    } label: {
                                        BookRow(entry: entry, theme: theme, colors: colors)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        libraryContextMenuItems(for: entry, onShare: shareBook, onDelete: { pendingDelete = $0 })
                                    }
                                }
                            }
                        case .grid:
                            BookGridView(
                                books: books, theme: theme, colors: colors,
                                onShare: shareBook, onDelete: { pendingDelete = $0 }
                            )
                        }
                    }

                    Button {
                        showImport = true
                    } label: {
                        Label("Add a Book", systemImage: "plus")
                    }
                    .buttonStyle(GhostButtonStyle())
                    .padding(.top, 4)

                    Color.clear.frame(height: 10)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }
            .background(colors.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .sheet(isPresented: $showImport) {
            DocumentImportSheet(defaultDestination: .library)
        }
        #if canImport(UIKit)
        .sheet(isPresented: $showShare) {
            if let shareImage {
                ActivityShareSheet(items: [shareImage])
            }
        }
        #endif
        .confirmationDialog(
            pendingDelete.map { "Remove “\($0.title)”?" } ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let id = pendingDelete?.id { store.removeBook(id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This can't be undone — the book's text will be deleted from this device.")
        }
    }

    private func viewModeToggle(_ colors: AdaptivePalette) -> some View {
        HStack {
            Spacer()
            Picker("Layout", selection: Binding(
                get: { viewMode },
                set: { viewModeRaw = $0.rawValue }
            )) {
                Image(systemName: "list.bullet").tag(LibraryViewMode.list)
                Image(systemName: "square.grid.2x2").tag(LibraryViewMode.grid)
            }
            .pickerStyle(.segmented)
            .frame(width: 96)
        }
    }

    #if canImport(UIKit)
    private func shareBook(_ entry: LibraryIndexEntry) {
        let subject: ReadingShareSubject
        switch entry.sourceType {
        case .pdf:
            subject = .book(
                title: entry.title,
                author: entry.author ?? "",
                chapter: entry.bookmarkPDFPageIndex > 0 ? entry.bookmarkPDFPageIndex + 1 : 0,
                chapterCount: entry.chapterCount,
                unit: .page
            )
        case .epub:
            let started = entry.bookmarkChapterIndex > 0 || (entry.bookmarkScrollFraction ?? 0) > 0
            subject = .book(
                title: entry.title,
                author: entry.author ?? "",
                chapter: started ? entry.bookmarkChapterIndex + 1 : 0,
                chapterCount: entry.chapterCount,
                unit: .chapter
            )
        }
        shareImage = NowReadingCard.renderImage(subject: subject, traderName: store.state.traderName, theme: theme)
        showShare = shareImage != nil
    }
    #else
    private func shareBook(_ entry: LibraryIndexEntry) {}
    #endif

    private func emptyState(_ colors: AdaptivePalette) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .font(.system(size: 30))
                .foregroundColor(colors.textFaint)
            Text("No books yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(colors.text)
            Text("Import a PDF or EPUB to start a shelf of books to read alongside your scrolls.")
                .font(.system(size: 12.5))
                .foregroundColor(colors.textDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(colors.ink2)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(colors.inkLine, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Cover flow

/// A horizontal, center-weighted carousel of book covers — a lightweight
/// take on the classic "cover flow" browsing pattern: covers scale up and
/// square on as they approach center, and recede/tilt away to either side,
/// so a book can be picked out by its cover alone rather than its title
/// text. Tapping a card opens that book; long-press gets the same
/// share/remove menu as the list and grid.
private struct CoverFlowView: View {
    let books: [LibraryIndexEntry]
    let theme: ThemeOption
    let colors: AdaptivePalette
    let onShare: (LibraryIndexEntry) -> Void
    let onDelete: (LibraryIndexEntry) -> Void

    // Tracked via `onScrollGeometryChange` below rather than a per-card
    // `GeometryReader` reading `.global` frames on every scroll frame —
    // that pattern is fragile under fast scrolling (nested geometry reads
    // recomputing live transforms during layout) and was producing
    // "Modifying state during view update" faults and a Metal draw-
    // validation crash. `onScrollGeometryChange`'s `action` closure runs
    // outside the render pass, same as `.onChange`, so it's safe to write
    // to `@State` from.
    @State private var scrollOffsetX: CGFloat = 0

    private let cardWidth: CGFloat = 108
    private let cardHeight: CGFloat = 152
    private let cardSpacing: CGFloat = 22
    private var stride: CGFloat { cardWidth + cardSpacing }

    var body: some View {
        GeometryReader { outer in
            let viewportWidth = outer.size.width
            let sidePadding = max(0, (viewportWidth - cardWidth) / 2)
            let viewportCenter = scrollOffsetX + viewportWidth / 2

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: cardSpacing) {
                    ForEach(Array(books.enumerated()), id: \.element.id) { index, entry in
                        // Distance of this card's center from the carousel's
                        // own center, in card-widths — pure arithmetic from
                        // the card's known position and the tracked scroll
                        // offset, never a live per-card geometry read.
                        let cardCenter = sidePadding + CGFloat(index) * stride + cardWidth / 2
                        let clamped = max(-2.5, min(2.5, (cardCenter - viewportCenter) / stride))

                        NavigationLink {
                            LibraryReaderView(bookId: entry.id, fallbackTitle: entry.title)
                        } label: {
                            BookCoverView(entry: entry, theme: theme, colors: colors, cornerRadius: 6)
                                .frame(width: cardWidth, height: cardHeight)
                                .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 6)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            libraryContextMenuItems(for: entry, onShare: onShare, onDelete: onDelete)
                        }
                        .rotation3DEffect(
                            .degrees(Double(clamped) * -50),
                            axis: (x: 0, y: 1, z: 0),
                            anchor: .center,
                            perspective: 0.55
                        )
                        .scaleEffect(1 - min(0.24, abs(clamped) * 0.18))
                        .offset(x: -clamped * 16)
                        .zIndex(1 - Double(abs(clamped)))
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, sidePadding)
            }
            .scrollTargetBehavior(.viewAligned)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.x
            } action: { _, newValue in
                scrollOffsetX = newValue
            }
        }
        .frame(height: cardHeight + 30)
    }
}

// MARK: - Grid

/// The shelf as a grid of covers — same books as the list, laid out for
/// scanning by cover art rather than reading titles top to bottom.
private struct BookGridView: View {
    let books: [LibraryIndexEntry]
    let theme: ThemeOption
    let colors: AdaptivePalette
    let onShare: (LibraryIndexEntry) -> Void
    let onDelete: (LibraryIndexEntry) -> Void

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 130), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(books) { entry in
                NavigationLink {
                    LibraryReaderView(bookId: entry.id, fallbackTitle: entry.title)
                } label: {
                    VStack(spacing: 6) {
                        BookCoverView(entry: entry, theme: theme, colors: colors)
                            .aspectRatio(2.0 / 3.0, contentMode: .fit)
                            .shadow(color: .black.opacity(0.25), radius: 5, x: 0, y: 3)
                        Text(entry.title)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(colors.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    libraryContextMenuItems(for: entry, onShare: onShare, onDelete: onDelete)
                }
            }
        }
    }
}

// MARK: - Cover art

/// A book's cover thumbnail, loaded from disk when one was saved at import
/// time (see `LibraryStore.coverURL`), or a generated placeholder card
/// (title, source-type icon, brass accent) when it wasn't — an EPUB with no
/// declared cover image, a PDF whose first page couldn't be rendered, or a
/// book imported before cover extraction existed. Used by the list row, the
/// grid, and the cover-flow carousel, so every view of the shelf shows the
/// same art.
private struct BookCoverView: View {
    let entry: LibraryIndexEntry
    let theme: ThemeOption
    let colors: AdaptivePalette
    var cornerRadius: CGFloat = 8

    #if canImport(UIKit)
    @State private var image: UIImage?
    #endif

    var body: some View {
        ZStack {
            #if canImport(UIKit)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
            #else
            placeholder
            #endif
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(colors.inkLine, lineWidth: 1))
        #if canImport(UIKit)
        .task(id: entry.id) { await loadCover() }
        #endif
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [theme.brassDim.opacity(0.4), colors.ink2],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            VStack(spacing: 6) {
                Image(systemName: entry.sourceType == .pdf ? "doc.richtext" : "book.closed")
                    .font(.system(size: 20))
                    .foregroundColor(theme.brass)
                Text(entry.title)
                    .font(AppFont.display(11.5))
                    .foregroundColor(colors.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 6)
            }
        }
    }

    #if canImport(UIKit)
    private func loadCover() async {
        guard entry.hasCover, image == nil else { return }
        let id = entry.id
        let loaded = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let url = LibraryStore.coverURL(for: id), let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
        guard !Task.isCancelled else { return }
        image = loaded
    }
    #endif
}

// MARK: - List row

private struct BookRow: View {
    let entry: LibraryIndexEntry
    let theme: ThemeOption
    let colors: AdaptivePalette

    private var progressLabel: String {
        guard entry.chapterCount > 0 else { return "Not started" }
        switch entry.sourceType {
        case .pdf:
            // PDFs track reading position as a page index (see
            // `LibraryIndexEntry.bookmarkPDFPageIndex`), not the chapter +
            // scroll-fraction pair EPUBs use — `chapterCount` here still
            // holds the page count from import (one chunk per PDF page, see
            // `PDFImporter.extractPages`), so it doubles as the total for
            // this label.
            let page = min(entry.bookmarkPDFPageIndex + 1, entry.chapterCount)
            return entry.bookmarkPDFPageIndex > 0 ? "Page \(page) of \(entry.chapterCount)" : "Not started"
        case .epub:
            let chapter = min(entry.bookmarkChapterIndex + 1, entry.chapterCount)
            let started = entry.bookmarkChapterIndex > 0 || (entry.bookmarkScrollFraction ?? 0) > 0
            return started ? "Chapter \(chapter) of \(entry.chapterCount)" : "Not started"
        }
    }

    var body: some View {
        HStack(spacing: 13) {
            BookCoverView(entry: entry, theme: theme, colors: colors, cornerRadius: 6)
                .frame(width: 40, height: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 14.5, weight: .semibold)).foregroundColor(colors.text)
                    .lineLimit(1)
                Text(progressLabel.uppercased())
                    .font(AppFont.mono(10.5)).foregroundColor(colors.textFaint)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(colors.textFaint)
        }
        .padding(14)
        .background(colors.ink2)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(colors.inkLine, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
