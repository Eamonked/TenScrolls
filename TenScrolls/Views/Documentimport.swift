import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(Compression)
import Compression
#endif
#if canImport(UIKit)
import UIKit
#endif

enum DocumentImportError: LocalizedError {
    case unsupportedFileType
    case encrypted
    case noExtractableText
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            return "That file type isn't supported — only PDF and EPUB are."
        case .encrypted:
            return "This PDF is password-protected. Remove the password and try again."
        case .noExtractableText:
            return "No selectable text was found. Scanned/image-only PDFs aren't supported yet."
        case .unreadable(let reason):
            return reason
        }
    }
}

// MARK: - PDF

enum PDFImporter {
    /// Extracts each page's text, dropping empty pages (common at the start/
    /// end of scanned-cover PDFs). Pages are kept separate rather than joined
    /// up front so callers can chunk by page when spreading across scrolls.
    static func extractPages(from url: URL) throws -> [String] {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: url) else {
            throw DocumentImportError.unreadable("This PDF couldn't be opened — it may be corrupted.")
        }
        if document.isLocked {
            throw DocumentImportError.encrypted
        }
        let pages: [String] = (0..<document.pageCount).compactMap { i in
            guard let page = document.page(at: i) else { return nil }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        guard !pages.isEmpty else { throw DocumentImportError.noExtractableText }
        return pages
        #else
        throw DocumentImportError.unsupportedFileType
        #endif
    }
}

// MARK: - EPUB

enum EPUBParser {
    /// Extracts the book's declared title (<metadata><dc:title>) plus each
    /// spine chapter as sanitized HTML and its plain-text paragraphs, in
    /// reading order. Each chapter also gets a rough per-chapter title
    /// derived from its first line, since chapter titles live in the
    /// (frequently EPUB2-vs-3-inconsistent) nav/NCX document, which this
    /// deliberately doesn't parse to keep scope contained — that guess is
    /// only ever meant for chapter headings, never as a stand-in for the
    /// book's own title.
    ///
    /// `html` is sanitized before it's returned — scripts and stylesheets
    /// stripped, local images inlined as base64 data URIs, external
    /// http(s):// references neutralized — so it's safe to load directly
    /// into a WKWebView later without a custom URL scheme handler or a
    /// network round-trip. `text` is unchanged from before: the same
    /// blank-line-joined paragraphs every other reading/import path expects.
    static func extractChapters(from url: URL) throws -> (bookTitle: String?, chapters: [(title: String?, html: String, text: String)]) {
        let data = try Data(contentsOf: url)
        let zip = try MinimalZip(data: data)

        guard let containerData = try? zip.contents(of: "META-INF/container.xml") else {
            throw DocumentImportError.unreadable("This doesn't look like a valid EPUB (missing container.xml).")
        }
        let containerDelegate = ContainerXMLDelegate()
        let containerParser = XMLParser(data: containerData)
        containerParser.delegate = containerDelegate
        containerParser.parse()
        guard let opfPath = containerDelegate.opfPath else {
            throw DocumentImportError.unreadable("Couldn't locate the EPUB's package file.")
        }

        guard let opfData = try? zip.contents(of: opfPath) else {
            throw DocumentImportError.unreadable("Couldn't read the EPUB's package file.")
        }
        let opfDelegate = OPFDelegate()
        let opfParser = XMLParser(data: opfData)
        opfParser.delegate = opfDelegate
        opfParser.parse()

        guard !opfDelegate.spine.isEmpty else {
            throw DocumentImportError.unreadable("This EPUB has no readable chapters.")
        }

        // The book's real title lives in <metadata><dc:title>, not in any
        // chapter's body text. Prefer it (when present and non-empty) over
        // the per-chapter heading guesses below, which are only ever a rough
        // stand-in for chapter 1's own heading, not the book's title.
        let bookTitle = opfDelegate.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? opfDelegate.title
            : nil

        let opfBase = (opfPath as NSString).deletingLastPathComponent

        var chapters: [(title: String?, html: String, text: String)] = []
        for id in opfDelegate.spine {
            guard let href = opfDelegate.manifest[id] else { continue }
            let path = opfBase.isEmpty ? href : "\(opfBase)/\(href)"
            guard let htmlData = try? zip.contents(of: path),
                  let paragraphs = try? htmlToPlainText(htmlData), !paragraphs.isEmpty else { continue }
            let title = deriveTitle(fromParagraphs: paragraphs)
            let rawHTML = String(data: htmlData, encoding: .utf8) ?? String(data: htmlData, encoding: .isoLatin1) ?? ""
            let sanitized = sanitizeChapterHTML(rawHTML, zip: zip, chapterPath: path)
            chapters.append((title, sanitized, paragraphs.joined(separator: "\n\n")))
        }

        guard !chapters.isEmpty else {
            throw DocumentImportError.unreadable("No readable chapters were found in this EPUB.")
        }
        return (bookTitle, chapters)
    }

    /// Many EPUBs (this one included) mark a chapter's heading with two
    /// separate lines — a short label like "CHAPTER ONE" followed by the
    /// actual descriptive title, e.g. "The Matthew Effect" — rather than one
    /// combined heading. Taking just the first line as-is (the previous
    /// behavior) surfaces the unhelpful, repeats-every-chapter "CHAPTER ONE"
    /// / "CHAPTER TWO" label instead of the title a reader would actually
    /// recognize. This folds the two together when the first line looks like
    /// a bare label (short, no lowercase letters — i.e. not a real sentence)
    /// and the next line still reads like a heading rather than the chapter's
    /// opening sentence of body text.
    private static func deriveTitle(fromParagraphs paragraphs: [String]) -> String? {
        guard let first = paragraphs.first?.trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty else {
            return nil
        }
        let looksLikeBareLabel = first.count <= 30 && first.rangeOfCharacter(from: .lowercaseLetters) == nil
        guard looksLikeBareLabel, paragraphs.count > 1 else {
            return String(first.prefix(60))
        }
        let second = paragraphs[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !second.isEmpty, second.count <= 80, !second.hasSuffix(".") else {
            return String(first.prefix(60))
        }
        return String("\(first): \(second)".prefix(80))
    }

    // MARK: - HTML sanitization

    /// Prepares a chapter's raw markup to be loaded directly into a
    /// WKWebView: strips anything that could run code or reach the network,
    /// strips publisher styling so it doesn't fight the app's own theme CSS,
    /// and inlines local images as base64 data URIs so nothing needs a
    /// custom URL scheme handler to resolve. Structural tags (`<table>`,
    /// `<ul>`/`<li>`, `<blockquote>`, headings) are left completely alone —
    /// they're what this whole change exists to preserve.
    ///
    /// Regex-based rather than a full DOM parse, matching the rest of this
    /// file's "parse just enough, deliberately" approach — EPUB chapter
    /// markup is XHTML in practice, so element/attribute shapes are regular
    /// enough for this to be reliable without pulling in a parsing library.
    private static func sanitizeChapterHTML(_ rawHTML: String, zip: MinimalZip, chapterPath: String) -> String {
        var html = rawHTML

        // 1. Strip <script>...</script> entirely — no reason a book needs to
        //    run code, and this closes off a real injection risk once we're
        //    rendering live HTML.
        html = html.replacingOccurrences(of: "(?is)<script\\b[^>]*>.*?</script>", with: "", options: .regularExpression)

        // 2. Strip <style>...</style> blocks and stylesheet <link> tags — the
        //    reader injects its own theme CSS, so publisher styling
        //    shouldn't fight the app's dark/light palette. Table/list/
        //    blockquote structure comes from the tags themselves, not the
        //    CSS, so nothing structural is lost here.
        html = html.replacingOccurrences(of: "(?is)<style\\b[^>]*>.*?</style>", with: "", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?i)<link\\b[^>]*rel\\s*=\\s*[\"']?stylesheet[\"']?[^>]*/?>", with: "", options: .regularExpression)

        // 3. Inline local images as base64 data URIs, pulled straight out of
        //    the EPUB's zip — avoids needing a custom WKURLSchemeHandler
        //    just to serve images.
        html = inlineImages(in: html, zip: zip, chapterPath: chapterPath)

        // 4. Neutralize anything still pointing at an external http(s)://
        //    resource (fonts, tracking pixels, whatever's left) — a WKWebView
        //    loaded from a string will otherwise happily try to hit the
        //    network, which is a privacy risk (a malicious EPUB could phone
        //    home) and a performance one (no reason to wait on it).
        html = html.replacingOccurrences(of: "(?i)\\b(href|src)\\s*=\\s*\"https?:[^\"]*\"", with: "$1=\"#\"", options: .regularExpression)

        // 5. Strip inline event-handler attributes (onload=, onerror=,
        //    onclick=, ...) and neutralize javascript: URIs. `<script>` tags
        //    are already gone (step 1), but the reading engine keeps
        //    JavaScript enabled in its WKWebView (the selection menu needs
        //    `window.getSelection()`), which makes these just as live a
        //    code-execution path as a `<script>` tag would have been —
        //    stripping the tag alone isn't enough once JS itself can run.
        html = html.replacingOccurrences(of: "(?i)\\son[a-z]+\\s*=\\s*\"[^\"]*\"", with: "", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?i)\\son[a-z]+\\s*=\\s*'[^']*'", with: "", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?i)\\b(href|src)\\s*=\\s*\"javascript:[^\"]*\"", with: "$1=\"#\"", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?i)\\b(href|src)\\s*=\\s*'javascript:[^']*'", with: "$1=\"#\"", options: .regularExpression)

        return html
    }

    /// Finds every `<img ...src="...">` tag and, for any local (non-http,
    /// non-data-URI) source, replaces the `src` with a base64 `data:` URI
    /// built from the actual image bytes in the EPUB's zip. Any `<img>` the
    /// source image can't be resolved for is left as-is — a broken image is
    /// a much smaller problem than a crashed import.
    private static func inlineImages(in html: String, zip: MinimalZip, chapterPath: String) -> String {
        guard let imgRegex = try? NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive]),
              let srcRegex = try? NSRegularExpression(pattern: "src\\s*=\\s*\"([^\"]*)\"", options: [.caseInsensitive]) else {
            return html
        }

        let mutable = NSMutableString(string: html)
        let matches = imgRegex.matches(in: mutable as String, options: [], range: NSRange(location: 0, length: mutable.length))

        // Walk matches back-to-front so replacing one tag's range doesn't
        // shift the ranges of the ones still to come.
        for match in matches.reversed() {
            let tag = mutable.substring(with: match.range) as NSString
            guard let srcMatch = srcRegex.firstMatch(in: tag as String, options: [], range: NSRange(location: 0, length: tag.length)),
                  srcMatch.numberOfRanges > 1 else { continue }

            let path = tag.substring(with: srcMatch.range(at: 1))
            guard !path.lowercased().hasPrefix("http"), !path.lowercased().hasPrefix("data:") else { continue }

            let resolvedPath = resolveRelativePath(path, relativeTo: chapterPath)
            guard let imageData = try? zip.contents(of: resolvedPath) else { continue }
            let mime = mimeType(forExtension: (resolvedPath as NSString).pathExtension)
            let dataURI = "data:\(mime);base64,\(imageData.base64EncodedString())"

            let newTag = tag.replacingCharacters(in: srcMatch.range(at: 0), with: "src=\"\(dataURI)\"")
            mutable.replaceCharacters(in: match.range, with: newTag)
        }

        return mutable as String
    }

    /// Resolves an image's relative `src` (e.g. `"../images/cover.jpg"`)
    /// against the zip path of the chapter that references it, producing a
    /// path `MinimalZip.contents(of:)` can look up directly. Walks path
    /// components by hand rather than using `NSString`'s path-standardizing
    /// helpers, since those assume a real filesystem root and a zip entry
    /// path isn't one.
    private static func resolveRelativePath(_ relative: String, relativeTo chapterPath: String) -> String {
        let cleaned = relative.components(separatedBy: "#").first ?? relative
        let baseDir = (chapterPath as NSString).deletingLastPathComponent
        let combined = baseDir.isEmpty ? cleaned : "\(baseDir)/\(cleaned)"

        var stack: [String] = []
        for component in combined.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                if !stack.isEmpty { stack.removeLast() }
            } else {
                stack.append(String(component))
            }
        }
        return stack.joined(separator: "/")
    }

    private static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }

    #if canImport(UIKit)
    private static func htmlToPlainText(_ data: Data) throws -> [String] {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            throw DocumentImportError.unreadable("Couldn't parse a chapter in this EPUB.")
        }
        // NSAttributedString's HTML conversion preserves block boundaries
        // (<p>, <div>, <li>, headings, ...) as line breaks in `.string`, but
        // often as a single "\n" between blocks rather than a blank line.
        // Every paragraph splitter downstream (`Scroll.paragraphs`,
        // `Book.from`, `DocumentSplitter`) looks for a blank line ("\n\n") to
        // tell paragraphs apart, so a single-"\n"-separated chapter reads as
        // one giant run-together paragraph instead of many. `.byParagraphs`
        // enumeration treats any line break as a paragraph boundary
        // regardless of whether it's single or double, so re-joining what it
        // finds with a guaranteed blank line restores real paragraph shape
        // before the text ever reaches that shared convention.
        let full = attributed.string
        var paragraphs: [String] = []
        full.enumerateSubstrings(in: full.startIndex..<full.endIndex, options: .byParagraphs) { substring, _, _, _ in
            guard let substring else { return }
            let trimmed = substring.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { paragraphs.append(trimmed) }
        }
        return paragraphs
    }
    #else
    private static func htmlToPlainText(_ data: Data) throws -> [String] {
        throw DocumentImportError.unsupportedFileType
    }
    #endif
}

private final class ContainerXMLDelegate: NSObject, XMLParserDelegate {
    var opfPath: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName.hasSuffix("rootfile"), let path = attributeDict["full-path"] {
            opfPath = path
        }
    }
}

private final class OPFDelegate: NSObject, XMLParserDelegate {
    var manifest: [String: String] = [:] // item id -> href
    var spine: [String] = []             // ordered idrefs
    /// The book's title, from <metadata><dc:title>. Only the first such
    /// element is kept — some OPFs list additional title-type metadata
    /// (subtitles, series names via opf:title-type refinements), and the
    /// first <dc:title> in document order is the main title in practice.
    var title: String?

    private var isInTitle = false
    private var titleBuffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName.hasSuffix("itemref") {
            if let idref = attributeDict["idref"] { spine.append(idref) }
        } else if elementName.hasSuffix("item") {
            if let id = attributeDict["id"], let href = attributeDict["href"] { manifest[id] = href }
        } else if title == nil, elementName == "title" || elementName.hasSuffix(":title") {
            isInTitle = true
            titleBuffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInTitle { titleBuffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard isInTitle, elementName == "title" || elementName.hasSuffix(":title") else { return }
        isInTitle = false
        let trimmed = titleBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { title = trimmed }
    }
}

// MARK: - Minimal ZIP reader

/// EPUB containers are plain ZIP archives, and iOS has no public API for
/// reading them. This parses just enough of the ZIP format (End-Of-Central-
/// Directory + Central Directory + local file headers) to pull named entries
/// out by path, and decompresses "stored" and "deflate" entries — the only
/// two methods EPUB tooling produces — via the system Compression framework.
/// No third-party dependency required.
struct MinimalZip {
    private let data: [UInt8]
    private let entries: [String: MinimalZipEntry]

    init(data: Data) throws {
        self.data = [UInt8](data)
        self.entries = try MinimalZip.parseCentralDirectory(self.data)
    }

    func contents(of name: String) throws -> Data {
        guard let entry = entries[name] else { throw MinimalZipError.entryNotFound(name) }
        return try MinimalZip.extract(entry, from: data)
    }

    private static func parseCentralDirectory(_ bytes: [UInt8]) throws -> [String: MinimalZipEntry] {
        guard bytes.count >= 22 else { throw MinimalZipError.notAZip }
        let eocdSig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        // A trailing zip comment (up to 65535 bytes) can sit after the EOCD
        // record, so scan backward through the tail rather than assuming
        // it's exactly the last 22 bytes.
        let searchWindow = min(bytes.count, 65536 + 22)
        let tailStart = bytes.count - searchWindow

        var eocdOffset: Int?
        var i = bytes.count - 22
        while i >= tailStart {
            if Array(bytes[i..<i + 4]) == eocdSig {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard let eocd = eocdOffset else { throw MinimalZipError.notAZip }

        func u16(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
        }

        let cdEntryCount = Int(u16(eocd + 10))
        let cdOffset = Int(u32(eocd + 16))

        var result: [String: MinimalZipEntry] = [:]
        var cursor = cdOffset
        for _ in 0..<cdEntryCount {
            guard cursor + 46 <= bytes.count,
                  Array(bytes[cursor..<cursor + 4]) == [0x50, 0x4B, 0x01, 0x02] else {
                throw MinimalZipError.truncated
            }
            let method = u16(cursor + 10)
            let compSize = u32(cursor + 20)
            let uncompSize = u32(cursor + 24)
            let nameLen = Int(u16(cursor + 28))
            let extraLen = Int(u16(cursor + 30))
            let commentLen = Int(u16(cursor + 32))
            let localOffset = u32(cursor + 42)
            let nameStart = cursor + 46
            guard nameStart + nameLen <= bytes.count else { throw MinimalZipError.truncated }
            let name = String(decoding: bytes[nameStart..<nameStart + nameLen], as: UTF8.self)

            result[name] = MinimalZipEntry(
                name: name, compressionMethod: method,
                compressedSize: compSize, uncompressedSize: uncompSize,
                localHeaderOffset: localOffset
            )
            cursor = nameStart + nameLen + extraLen + commentLen
        }
        return result
    }

    private static func extract(_ entry: MinimalZipEntry, from bytes: [UInt8]) throws -> Data {
        let off = Int(entry.localHeaderOffset)
        guard off + 30 <= bytes.count,
              Array(bytes[off..<off + 4]) == [0x50, 0x4B, 0x03, 0x04] else {
            throw MinimalZipError.truncated
        }
        func u16(_ o: Int) -> UInt16 { UInt16(bytes[o]) | (UInt16(bytes[o + 1]) << 8) }
        let nameLen = Int(u16(off + 26))
        let extraLen = Int(u16(off + 28))
        let dataStart = off + 30 + nameLen + extraLen
        let dataEnd = dataStart + Int(entry.compressedSize)
        guard dataEnd <= bytes.count else { throw MinimalZipError.truncated }
        let raw = Data(bytes[dataStart..<dataEnd])

        switch entry.compressionMethod {
        case 0: // stored
            return raw
        case 8: // deflate
            #if canImport(Compression)
            return try inflate(raw, expectedSize: Int(entry.uncompressedSize))
            #else
            throw MinimalZipError.unsupportedCompression(entry.compressionMethod)
            #endif
        default:
            throw MinimalZipError.unsupportedCompression(entry.compressionMethod)
        }
    }

    #if canImport(Compression)
    private static func inflate(_ input: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let resultSize = output.withUnsafeMutableBytes { dst -> Int in
            input.withUnsafeBytes { src -> Int in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard resultSize == expectedSize else { throw MinimalZipError.truncated }
        return output
    }
    #endif
}

private struct MinimalZipEntry {
    let name: String
    let compressionMethod: UInt16
    let compressedSize: UInt32
    let uncompressedSize: UInt32
    let localHeaderOffset: UInt32
}

enum MinimalZipError: LocalizedError {
    case notAZip
    case truncated
    case unsupportedCompression(UInt16)
    case entryNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notAZip: return "This file isn't a valid EPUB (not a zip archive)."
        case .truncated: return "This EPUB appears to be corrupted or incomplete."
        case .unsupportedCompression: return "This EPUB uses an unsupported compression method."
        case .entryNotFound(let name): return "Couldn't find '\(name)' inside this EPUB."
        }
    }
}

// MARK: - Splitting into scroll-sized chunks

enum DocumentSplitter {
    /// Groups an ordered list of natural chunks (EPUB chapters, or PDF pages)
    /// into exactly `bucketCount` buckets, preserving order and never
    /// splitting one chunk across two buckets — only the boundaries between
    /// chunks move. Buckets are balanced by word count so they come out
    /// roughly even rather than just dividing the chunk count evenly.
    static func distribute(_ chunks: [String], into bucketCount: Int) -> [String] {
        guard bucketCount > 0 else { return [] }
        guard chunks.count > bucketCount else {
            // Fewer natural chunks than requested scrolls — fall back to
            // splitting the concatenated text evenly by paragraph instead.
            return splitByParagraphs(chunks.joined(separator: "\n\n"), into: bucketCount)
        }

        let counts = chunks.map { $0.split(separator: " ").count }
        let total = counts.reduce(0, +)
        let target = max(1, total / bucketCount)

        var buckets: [[String]] = []
        var current: [String] = []
        var currentCount = 0
        for (chunk, count) in zip(chunks, counts) {
            current.append(chunk)
            currentCount += count
            if currentCount >= target && buckets.count < bucketCount - 1 {
                buckets.append(current)
                current = []
                currentCount = 0
            }
        }
        buckets.append(current) // remainder goes in the last bucket
        while buckets.count < bucketCount { buckets.append([]) }
        return buckets.map { $0.joined(separator: "\n\n") }
    }

    /// Splits one continuous text into `bucketCount` roughly-equal pieces,
    /// breaking only at paragraph boundaries (blank lines) so a scroll never
    /// starts or ends mid-sentence.
    static func splitByParagraphs(_ text: String, into bucketCount: Int) -> [String] {
        guard bucketCount > 0 else { return [] }
        let paragraphs = Scroll.normalizedNotes(text)
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { return Array(repeating: "", count: bucketCount) }
        guard paragraphs.count > bucketCount else {
            // Fewer paragraphs than requested scrolls — pad with empty
            // entries rather than pretend we can split further.
            return paragraphs + Array(repeating: "", count: max(0, bucketCount - paragraphs.count))
        }

        let counts = paragraphs.map { $0.split(separator: " ").count }
        let total = counts.reduce(0, +)
        let target = max(1, total / bucketCount)

        var buckets: [[String]] = []
        var current: [String] = []
        var currentCount = 0
        for (para, count) in zip(paragraphs, counts) {
            current.append(para)
            currentCount += count
            if currentCount >= target && buckets.count < bucketCount - 1 {
                buckets.append(current)
                current = []
                currentCount = 0
            }
        }
        buckets.append(current)
        while buckets.count < bucketCount { buckets.append([]) }
        return buckets.map { $0.joined(separator: "\n\n") }
    }
}
