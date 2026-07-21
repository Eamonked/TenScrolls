import Foundation

// MARK: - Models

/// Metadata for a book on the shelf — everything `AppState`/`ProgressTabView`
/// needs to list and open a book, without ever holding the book's text.
/// Lives in `AppState.library`, so it rides along with the normal
/// UserDefaults-backed save/load cycle like everything else — safe to do
/// since it's small no matter how many books are on the shelf.
struct LibraryIndexEntry: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var author: String?
    var addedAt: Date
    var chapterCount: Int
    var totalParagraphCount: Int
    /// Which chapter/paragraph the reader last stopped at. Kept here (not in
    /// the `Book` file) so bookmarking while reading never requires
    /// rewriting the book's full text back to disk.
    var bookmarkChapterIndex: Int = 0
    var bookmarkParagraphIndex: Int? = nil
}

/// A single chapter's worth of reading — its own natural chunk (an EPUB
/// chapter, or a run of PDF pages), pre-split into paragraphs the same way a
/// scroll's notes are, so the reading view can render it with the same
/// lazy, paragraph-at-a-time approach.
struct BookChapter: Identifiable, Codable, Equatable {
    var id: Int
    var title: String?
    var paragraphs: [String]
}

/// The full contents of one imported book. Never held in `AppState` — always
/// loaded from disk on demand by `LibraryStore` and released once the reader
/// navigates away.
struct Book: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var author: String?
    var chapters: [BookChapter]
}

// MARK: - Disk-backed store

enum LibraryStoreError: LocalizedError {
    case notFound

    var errorDescription: String? {
        switch self {
        case .notFound: return "That book's file couldn't be found on disk."
        }
    }
}

/// Persists full book text as one JSON file per book under the app's
/// Documents directory — deliberately outside `UserDefaults`, which isn't
/// meant to hold multi-megabyte blobs (the whole plist gets loaded into
/// memory on every read/write). `AppState` only ever carries the small
/// `LibraryIndexEntry` metadata; this store is where the actual text lives,
/// and it's only touched when a book is added, opened, or removed.
enum LibraryStore {
    private static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Library", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Writes a book's full contents to its own file. Runs off the main
    /// actor (see `AppStore.addBookToLibrary`) since encoding a book-length
    /// string is real work we don't want blocking the UI.
    static func save(_ book: Book) throws {
        let data = try JSONEncoder().encode(book)
        try data.write(to: fileURL(for: book.id), options: .atomic)
    }

    static func load(_ id: UUID) throws -> Book {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw LibraryStoreError.notFound }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Book.self, from: data)
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }
}

// MARK: - Building a Book from parsed document chunks

extension Book {
    /// Builds a `Book` (and its matching index entry) from a parsed
    /// document's ordered chunks — the same `[String]` the import sheet
    /// already produces for EPUB chapters or PDF pages. Each chunk becomes
    /// one chapter, split into paragraphs the same way scroll notes are.
    static func from(filename: String, chunks: [String], titles: [String?]) -> (book: Book, index: LibraryIndexEntry) {
        let id = UUID()
        var chapters: [BookChapter] = []
        chapters.reserveCapacity(chunks.count)
        var totalParagraphs = 0
        for (i, chunk) in chunks.enumerated() {
            let paragraphs = Scroll.normalizedNotes(chunk)
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !paragraphs.isEmpty else { continue }
            totalParagraphs += paragraphs.count
            chapters.append(BookChapter(id: i, title: titles[safe: i] ?? nil, paragraphs: paragraphs))
        }

        let inferredTitle = titles.compactMap { $0 }.first
        let displayTitle = (filename as NSString).deletingPathExtension
        let title = inferredTitle?.isEmpty == false ? inferredTitle! : displayTitle

        let book = Book(id: id, title: title, author: nil, chapters: chapters)
        let index = LibraryIndexEntry(
            id: id,
            title: title,
            author: nil,
            addedAt: Date(),
            chapterCount: chapters.count,
            totalParagraphCount: totalParagraphs
        )
        return (book, index)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
