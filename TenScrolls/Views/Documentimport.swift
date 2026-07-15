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
    /// Extracts each spine chapter as plain text, in reading order. A rough
    /// title is derived from each chapter's first line, since chapter titles
    /// live in the (frequently EPUB2-vs-3-inconsistent) nav/NCX document,
    /// which this deliberately doesn't parse to keep scope contained.
    static func extractChapters(from url: URL) throws -> [(title: String?, text: String)] {
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

        let opfBase = (opfPath as NSString).deletingLastPathComponent

        var chapters: [(title: String?, text: String)] = []
        for id in opfDelegate.spine {
            guard let href = opfDelegate.manifest[id] else { continue }
            let path = opfBase.isEmpty ? href : "\(opfBase)/\(href)"
            guard let htmlData = try? zip.contents(of: path),
                  let text = try? htmlToPlainText(htmlData) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let title = trimmed.components(separatedBy: .newlines).first.map { String($0.prefix(60)) }
            chapters.append((title, trimmed))
        }

        guard !chapters.isEmpty else {
            throw DocumentImportError.unreadable("No readable chapters were found in this EPUB.")
        }
        return chapters
    }

    #if canImport(UIKit)
    private static func htmlToPlainText(_ data: Data) throws -> String {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            throw DocumentImportError.unreadable("Couldn't parse a chapter in this EPUB.")
        }
        return attributed.string
    }
    #else
    private static func htmlToPlainText(_ data: Data) throws -> String {
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

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName.hasSuffix("itemref") {
            if let idref = attributeDict["idref"] { spine.append(idref) }
        } else if elementName.hasSuffix("item") {
            if let id = attributeDict["id"], let href = attributeDict["href"] { manifest[id] = href }
        }
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
