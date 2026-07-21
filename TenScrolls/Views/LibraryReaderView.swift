import SwiftUI

/// Reads one book from the shelf. The book's full text is loaded from disk
/// only when this view appears, and released again once it's dismissed —
/// `AppState`/`AppStore` never hold it. Paragraphs render the same lazy,
/// one-`UITextView`-per-visible-paragraph way scrolls do, chapter by
/// chapter, so even a very long book stays light in memory.
struct LibraryReaderView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.appearanceMode) var appearanceMode
    let bookId: UUID
    let fallbackTitle: String

    @State private var book: Book?
    @State private var loadError: String?
    @State private var chapterIndex: Int = 0

    var theme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    private var indexEntry: LibraryIndexEntry? {
        store.state.libraryBooks.first { $0.id == bookId }
    }

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        Group {
            if let book {
                readingView(book, colors: colors)
            } else if let loadError {
                errorView(loadError, colors: colors)
            } else {
                loadingView(colors)
            }
        }
        .background(colors.background)
        .navigationTitle(book?.title ?? fallbackTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let book, book.chapters.count > 1 {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        ForEach(Array(book.chapters.enumerated()), id: \.offset) { i, chapter in
                            Button(chapterLabel(chapter, index: i)) { chapterIndex = i }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                }
            }
        }
        .task { await load() }
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

    private func readingView(_ book: Book, colors: AdaptivePalette) -> some View {
        let chapter = book.chapters[safe: chapterIndex]
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let title = chapter?.title, !title.isEmpty {
                        Text(title)
                            .font(AppFont.display(20))
                            .foregroundColor(colors.text)
                            .padding(.bottom, 4)
                    }

                    // Lazy for the same reason the scroll reading view is —
                    // a chapter can still run to hundreds of paragraphs, and
                    // only the ones on/near screen should become real
                    // UITextViews at any one time.
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(Array((chapter?.paragraphs ?? []).enumerated()), id: \.offset) { index, paragraph in
                            SelectableParagraphView(
                                text: paragraph,
                                fontSize: 16,
                                textColor: UIColor(colors.text.opacity(0.92)),
                                lineSpacing: 7,
                                onTapped: {
                                    store.setLibraryBookmark(bookId: bookId, chapterIndex: chapterIndex, paragraphIndex: index)
                                }
                            )
                            .id(index)
                        }
                    }

                    chapterNavigation(book, colors: colors)
                }
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
            .onAppear {
                if let entry = indexEntry {
                    chapterIndex = min(entry.bookmarkChapterIndex, max(0, book.chapters.count - 1))
                    if let paragraph = entry.bookmarkParagraphIndex {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            withAnimation { proxy.scrollTo(paragraph, anchor: .top) }
                        }
                    }
                }
            }
            .onChange(of: chapterIndex) { _, newValue in
                store.setLibraryBookmark(bookId: bookId, chapterIndex: newValue, paragraphIndex: nil)
            }
        }
    }

    private func chapterNavigation(_ book: Book, colors: AdaptivePalette) -> some View {
        HStack {
            Button {
                chapterIndex = max(0, chapterIndex - 1)
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(chapterIndex == 0)

            Spacer()

            Text("Chapter \(chapterIndex + 1) of \(book.chapters.count)")
                .font(AppFont.mono(11))
                .foregroundColor(colors.textFaint)

            Spacer()

            Button {
                chapterIndex = min(book.chapters.count - 1, chapterIndex + 1)
            } label: {
                Label("Next", systemImage: "chevron.right")
                    .labelStyle(.trailingIcon)
            }
            .disabled(chapterIndex >= book.chapters.count - 1)
        }
        .font(.system(size: 13))
        .foregroundColor(theme.brass)
        .padding(.top, 8)
    }

    private func chapterLabel(_ chapter: BookChapter, index: Int) -> String {
        if let title = chapter.title, !title.isEmpty { return title }
        return "Chapter \(index + 1)"
    }

    private func load() async {
        guard book == nil else { return }
        do {
            let loaded = try LibraryStore.load(bookId)
            await MainActor.run { book = loaded }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "This book couldn't be opened."
            await MainActor.run { loadError = message }
        }
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.title
            configuration.icon
        }
    }
}

private extension LabelStyle where Self == TrailingIconLabelStyle {
    static var trailingIcon: TrailingIconLabelStyle { TrailingIconLabelStyle() }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
