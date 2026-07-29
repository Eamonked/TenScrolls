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
    /// Which chapter the reader last stopped at. Kept here (not in the
    /// `Book` file) so bookmarking while reading never requires rewriting
    /// the book's full text back to disk.
    var bookmarkChapterIndex: Int = 0
    /// Reading position within `bookmarkChapterIndex`, as a 0...1 fraction
    /// of the chapter's page count rather than a paragraph index — the
    /// position a CSS-column-paginated page count is derived from can shift
    /// with font size or rotation, so a fraction survives that the way an
    /// index wouldn't. `nil` for a book that hasn't been opened yet.
    var bookmarkScrollFraction: Double? = nil
}

/// A single chapter's worth of reading — its own natural chunk (an EPUB
/// chapter, or a run of PDF pages), pre-split into paragraphs the same way a
/// scroll's notes are, so the reading view can render it with the same
/// lazy, paragraph-at-a-time approach.
///
/// `html` carries the chapter's original (sanitized) markup for EPUB-sourced
/// books — table/list/blockquote structure, images inlined as base64 data
/// URIs — so a WKWebView-based renderer can lay it out faithfully instead of
/// the flattened `paragraphs` array losing that structure. It's empty for
/// PDF-sourced chapters, which have no native markup to preserve; those fall
/// back to the plain-paragraph rendering path. `paragraphs` is kept
/// regardless — "Save as Scroll", word counts, and journal quoting all want
/// plain text, and for EPUB chapters it's derived from `html` at import time
/// rather than being the only thing stored.
struct BookChapter: Identifiable, Codable, Equatable {
    var id: Int
    var title: String?
    var html: String = ""
    var paragraphs: [String]

    init(id: Int, title: String?, html: String = "", paragraphs: [String]) {
        self.id = id
        self.title = title
        self.html = html
        self.paragraphs = paragraphs
    }

    // Custom decoding so chapters saved before `html` existed still decode —
    // a missing key becomes "" (the plain-paragraph fallback) instead of
    // throwing and making a previously-imported book unreadable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        html = try container.decodeIfPresent(String.self, forKey: .html) ?? ""
        paragraphs = try container.decode([String].self, forKey: .paragraphs)
    }
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
    ///
    /// `html`, when provided, carries each chapter's sanitized original
    /// markup (EPUB imports only — see `EPUBParser`) — one entry per chunk,
    /// same order. `nil`, or a shorter array than `chunks`, is fine: PDF
    /// imports pass `nil` since PDFKit's page text has no native markup to
    /// preserve, and any chapter without a corresponding entry just gets "".
    static func from(filename: String, chunks: [String], titles: [String?], html: [String]? = nil, bookTitle: String? = nil) -> (book: Book, index: LibraryIndexEntry) {
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
            chapters.append(BookChapter(id: i, title: titles[safe: i] ?? nil, html: html?[safe: i] ?? "", paragraphs: paragraphs))
        }

        // Prefer the EPUB's own declared title (from <dc:title>) over a
        // guess derived from chapter 1's heading — a book that opens with
        // "Chapter One" or "Prologue" should never get filed on the shelf
        // under that string. Only fall back to the chapter-heading guess,
        // then the filename, when no real title was found.
        let inferredTitle = titles.compactMap { $0 }.first
        let displayTitle = (filename as NSString).deletingPathExtension
        let title = bookTitle?.isEmpty == false ? bookTitle!
            : (inferredTitle?.isEmpty == false ? inferredTitle! : displayTitle)

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

// `Array.subscript(safe:)` now lives in TextPagination.swift, shared with
// the Library and Scroll readers.
