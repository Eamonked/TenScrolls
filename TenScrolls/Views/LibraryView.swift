import SwiftUI

/// The library shelf: full-length books imported outside the ten scrolls,
/// for reading alongside the daily practice rather than as part of it.
/// Only ever works with `LibraryIndexEntry` metadata here — the actual text
/// is loaded on demand by `LibraryReaderView` when a book is opened, and
/// released again once the reader navigates back.
struct LibraryView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.appearanceMode) var appearanceMode
    @State private var showImport = false
    @State private var pendingDelete: LibraryIndexEntry?

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
                        ForEach(books) { entry in
                            NavigationLink {
                                LibraryReaderView(bookId: entry.id, fallbackTitle: entry.title)
                            } label: {
                                BookRow(entry: entry, theme: theme, colors: colors)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    pendingDelete = entry
                                } label: {
                                    Label("Remove Book", systemImage: "trash")
                                }
                            }
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
        }
        .sheet(isPresented: $showImport) {
            DocumentImportSheet(defaultDestination: .library)
        }
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

private struct BookRow: View {
    let entry: LibraryIndexEntry
    let theme: ThemeOption
    let colors: AdaptivePalette

    private var progressLabel: String {
        guard entry.chapterCount > 0 else { return "Not started" }
        let chapter = min(entry.bookmarkChapterIndex + 1, entry.chapterCount)
        return entry.bookmarkParagraphIndex == nil && entry.bookmarkChapterIndex == 0
            ? "Not started"
            : "Chapter \(chapter) of \(entry.chapterCount)"
    }

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(colors.ink2)
                    .overlay(Circle().stroke(colors.inkLine, lineWidth: 1.5))
                    .frame(width: 42, height: 42)
                Image(systemName: "book.closed")
                    .font(.system(size: 15))
                    .foregroundColor(theme.brass)
            }
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
