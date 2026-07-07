import SwiftUI

#if canImport(UIKit)
import UIKit
import CoreText

/// Renders the year's work — every scroll's transcribed notes plus the full
/// journal — into a laid-out, paper-toned PDF keepsake. This is the "commonplace
/// book": the artifact the practice produces, independent of the app.
enum CommonplaceBook {

    // Page geometry (US Letter, points).
    private static let pageSize = CGSize(width: 612, height: 792)
    private static let margin: CGFloat = 64

    // Paper-toned palette — a keepsake to print, not the app's dark theme.
    private static let paper = UIColor(red: 0.984, green: 0.969, blue: 0.937, alpha: 1)   // #FBF7EF
    private static let inkColor = UIColor(red: 0.102, green: 0.071, blue: 0.027, alpha: 1) // #1A1207
    private static let dimColor = UIColor(red: 0.35, green: 0.31, blue: 0.24, alpha: 1)

    /// Builds the PDF and writes it to a temporary file. Returns the file URL,
    /// or nil if there was nothing to export. Safe to call on the main thread
    /// for typical amounts of content.
    static func makePDF(state: AppState, themeColor: Color) -> URL? {
        let accent = UIColor(themeColor)
        let body = attributedBody(state: state, accent: accent)
        guard body.length > 0 else { return nil }

        let textRect = CGRect(x: margin, y: margin,
                              width: pageSize.width - margin * 2,
                              height: pageSize.height - margin * 2)

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "Ten Scrolls — A Commonplace Book",
            kCGPDFContextAuthor as String: state.traderName.isEmpty ? "A Trader" : state.traderName,
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize), format: format)

        let data = renderer.pdfData { ctx in
            // Cover page (drawn in UIKit's top-left coordinate space).
            ctx.beginPage()
            fillPaper(ctx.cgContext)
            drawCover(state: state, accent: accent)

            // Body pages, flowed with Core Text across as many pages as needed.
            let framesetter = CTFramesetterCreateWithAttributedString(body)
            var charIndex = 0
            let total = body.length

            while charIndex < total {
                ctx.beginPage()
                fillPaper(ctx.cgContext)

                let c = ctx.cgContext
                c.saveGState()
                // Core Text draws bottom-up; flip into a standard coordinate space.
                c.textMatrix = .identity
                c.translateBy(x: 0, y: pageSize.height)
                c.scaleBy(x: 1, y: -1)

                let path = CGPath(rect: textRect, transform: nil)
                let frame = CTFramesetterCreateFrame(
                    framesetter, CFRange(location: charIndex, length: 0), path, nil)
                CTFrameDraw(frame, c)

                let visible = CTFrameGetVisibleStringRange(frame)
                c.restoreGState()

                if visible.length <= 0 { break } // safety against an unadvancing frame
                charIndex += visible.length
            }
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ten Scrolls — Commonplace Book.pdf")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Drawing

    private static func fillPaper(_ c: CGContext) {
        c.setFillColor(paper.cgColor)
        c.fill(CGRect(origin: .zero, size: pageSize))
    }

    private static func drawCover(state: AppState, accent: UIColor) {
        let center = NSMutableParagraphStyle()
        center.alignment = .center

        func draw(_ s: NSAttributedString, atY y: CGFloat) {
            let bounds = s.boundingRect(
                with: CGSize(width: pageSize.width - margin * 2, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            s.draw(with: CGRect(x: margin, y: y, width: pageSize.width - margin * 2, height: bounds.height),
                   options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }

        draw(NSAttributedString(string: "⟐", attributes: [
            .font: serif(34), .foregroundColor: accent, .paragraphStyle: center]), atY: 210)

        draw(NSAttributedString(string: "TEN SCROLLS", attributes: [
            .font: mono(15), .foregroundColor: accent,
            .kern: 6, .paragraphStyle: center]), atY: 270)

        draw(NSAttributedString(string: "A Commonplace Book", attributes: [
            .font: serif(30, weight: .bold), .foregroundColor: inkColor,
            .paragraphStyle: center]), atY: 300)

        let name = state.traderName.isEmpty ? "A Trader" : state.traderName
        draw(NSAttributedString(string: "kept by \(name)", attributes: [
            .font: serif(15, italic: true), .foregroundColor: dimColor,
            .paragraphStyle: center]), atY: 350)

        let mastered = state.scrolls.filter { $0.status == .mastered }.count
        let stats = "\(state.totalDaysCompleted) days of practice  ·  \(mastered) of 10 scrolls mastered  ·  \(state.journal.count) reflections"
        draw(NSAttributedString(string: stats, attributes: [
            .font: mono(10.5), .foregroundColor: dimColor,
            .kern: 0.5, .paragraphStyle: center]), atY: 560)

        draw(NSAttributedString(string: longDate(DateKey.today()), attributes: [
            .font: mono(10.5), .foregroundColor: dimColor,
            .kern: 1, .paragraphStyle: center]), atY: 585)
    }

    // MARK: - Body content

    private static func attributedBody(state: AppState, accent: UIColor) -> NSAttributedString {
        let out = NSMutableAttributedString()

        // The scrolls, in order, skipping any left blank.
        let scrolls = state.scrolls.sorted { $0.id < $1.id }
            .filter { !$0.title.isEmpty || !$0.notes.isEmpty || !$0.theme.isEmpty }

        if !scrolls.isEmpty {
            out.append(sectionHeading("The Scrolls", accent: accent))
            for scroll in scrolls {
                out.append(heading("Scroll \(scroll.roman)\(scroll.title.isEmpty ? "" : " — \(scroll.title)")"))
                if !scroll.theme.isEmpty {
                    out.append(themeLine(scroll.theme, accent: accent))
                }
                if !scroll.notes.isEmpty {
                    out.append(bodyText(scroll.notes))
                }
                out.append(spacer(18))
            }
        }

        // The journal, oldest first, so it reads as a chronicle.
        let entries = state.journal
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.date < $1.date }
        if !entries.isEmpty {
            out.append(sectionHeading("The Journal", accent: accent))
            for entry in entries {
                let scroll = state.scrolls.first { $0.id == entry.scrollId }
                let label = "\(longDate(entry.date))\(scroll.map { "  ·  Scroll \($0.roman)" } ?? "")"
                out.append(entryLabel(label, accent: accent))
                out.append(bodyText(entry.text))
                out.append(spacer(14))
            }
        }

        return out
    }

    // MARK: - Attributed-string builders

    private static func sectionHeading(_ text: String, accent: UIColor) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 26
        p.paragraphSpacing = 14
        return NSAttributedString(string: text.uppercased() + "\n", attributes: [
            .font: mono(13), .foregroundColor: accent, .kern: 3, .paragraphStyle: p])
    }

    private static func heading(_ text: String) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 16
        p.paragraphSpacing = 4
        return NSAttributedString(string: text + "\n", attributes: [
            .font: serif(19, weight: .bold), .foregroundColor: inkColor, .paragraphStyle: p])
    }

    private static func themeLine(_ text: String, accent: UIColor) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = 8
        return NSAttributedString(string: text + "\n", attributes: [
            .font: serif(14, italic: true), .foregroundColor: accent, .paragraphStyle: p])
    }

    private static func entryLabel(_ text: String, accent: UIColor) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 12
        p.paragraphSpacing = 4
        return NSAttributedString(string: text + "\n", attributes: [
            .font: mono(10.5), .foregroundColor: accent, .kern: 0.5, .paragraphStyle: p])
    }

    private static func bodyText(_ text: String) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4
        p.paragraphSpacing = 6
        return NSAttributedString(string: text + "\n", attributes: [
            .font: serif(12.5), .foregroundColor: inkColor, .paragraphStyle: p])
    }

    private static func spacer(_ height: CGFloat) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: [.font: UIFont.systemFont(ofSize: height)])
    }

    // MARK: - Fonts & dates

    private static func serif(_ size: CGFloat, weight: UIFont.Weight = .regular, italic: Bool = false) -> UIFont {
        let name = italic ? "Georgia-Italic" : (weight == .bold ? "Georgia-Bold" : "Georgia")
        if let f = UIFont(name: name, size: size) { return f }
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        if italic, let d = base.fontDescriptor.withSymbolicTraits(.traitItalic) {
            return UIFont(descriptor: d, size: size)
        }
        return base
    }

    private static func mono(_ size: CGFloat) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: .medium)
    }

    private static func longDate(_ key: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMMM d, yyyy"
        return f.string(from: DateKey.date(from: key))
    }
}

/// Lets a `URL` drive `.sheet(item:)` for the export share sheet.
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Wraps UIActivityViewController so a generated PDF can be shared or saved.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
