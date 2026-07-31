import Foundation

/// Phase 1 — Architecture & Format Routing.
///
/// Sniffs a document's actual bytes rather than trusting its file extension
/// (or the UTType `fileImporter` reports, which is itself usually derived
/// from the extension). A renamed or extension-less file — or one a share
/// sheet hands over with a generic `public.data` type — previously fell
/// through to whatever `url.pathExtension.lowercased()` said, silently
/// misrouting a PDF into the EPUB parser (or vice versa) instead of failing
/// clearly. Detection reads only the first few bytes of the file, so it's
/// cheap even for a large book.
enum DetectedFileType: Equatable {
    case pdf
    case epub
    case unknown

    /// Sniffs `url`'s contents. Falls back to the file extension only when
    /// the byte-level signatures are inconclusive (e.g. a truncated/empty
    /// file) — never as the primary signal.
    static func detect(url: URL) -> DetectedFileType {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return detectByExtension(url)
        }
        defer { try? handle.close() }

        // PDFs always open with the literal ASCII header "%PDF-" (spec-
        // mandated, §7.5.2 of ISO 32000), optionally preceded by a few bytes
        // of junk some generators prepend — scanning the first 1024 bytes
        // covers every PDF producer seen in practice.
        guard let header = try? handle.read(upToCount: 1024), !header.isEmpty else {
            return detectByExtension(url)
        }
        if header.range(of: Data("%PDF-".utf8)) != nil {
            return .pdf
        }

        // An EPUB is a zip archive whose very first local file header must
        // be an uncompressed entry named exactly "mimetype" containing
        // "application/epub+zip" (OCF §3.3 — this is what lets a plain
        // unzip/file(1) identify an EPUB without reading the rest of the
        // archive). Checking for this exact layout is far more reliable
        // than checking "is this a zip" — plenty of non-EPUB zips exist.
        let zipLocalHeaderSig: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        guard header.starts(with: zipLocalHeaderSig), header.count >= 30 else {
            return detectByExtension(url)
        }
        let bytes = [UInt8](header)
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8) }
        let nameLen = u16(26)
        let extraLen = u16(28)
        guard 30 + nameLen <= bytes.count else { return detectByExtension(url) }
        let name = String(decoding: bytes[30..<(30 + nameLen)], as: UTF8.self)
        guard name == "mimetype" else { return detectByExtension(url) }
        let dataStart = 30 + nameLen + extraLen
        guard dataStart <= bytes.count else { return detectByExtension(url) }
        let declaredMime = String(decoding: bytes[dataStart...], as: UTF8.self)
        return declaredMime.hasPrefix("application/epub+zip") ? .epub : .unknown
    }

    /// Last-resort fallback for a file whose contents couldn't be sniffed
    /// (empty, unreadable, or genuinely truncated) — extension is better
    /// than nothing, but is never trusted over an actual byte match above.
    private static func detectByExtension(_ url: URL) -> DetectedFileType {
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf
        case "epub": return .epub
        default: return .unknown
        }
    }
}
