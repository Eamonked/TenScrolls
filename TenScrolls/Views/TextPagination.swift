import SwiftUI
import UIKit

/// Pure pagination math shared between the Library reader and the Scroll
/// reading view, so both paginate text with the same measurement approach
/// and the same page geometry — the two readers are meant to look and
/// behave like the same book, not two different reading experiences.
///
/// Never renders anything itself: it measures (via `NSAttributedString`
/// bounding-rect, never a real render pass) how many paragraphs fit on a
/// screen-sized page at the current font scale, and hands back which
/// paragraph indices belong on each page. Each caller wraps the resulting
/// pages in its own `TabView` and page content — see `LibraryReaderView`
/// and `ScrollEditorSheet`.
///
/// This never splits a single paragraph across two pages — a page can end
/// up with a little empty space at the bottom rather than text running
/// exactly to the edge, the same trade-off most reflowable e-readers make
/// in exchange for not needing a full line-by-line layout engine.
enum TextPaginator {
    static let paragraphSpacing: CGFloat = 22
    static let horizontalPadding: CGFloat = 28 * 2
    static let topPadding: CGFloat = 20
    static let bottomPadding: CGFloat = 8
    /// Rough allowance for the bottom progress bar overlay, plus a little
    /// breathing room. Deliberately approximate — every page's content sits
    /// in a `ScrollView` as a safety net for exactly this kind of estimate
    /// being slightly off (see the `pageContent` wrappers in both readers).
    static let bottomChromeAllowance: CGFloat = 64

    /// The paragraph indices (into `paragraphs`) that fit on each page.
    /// `firstPageHeaderHeight` reserves extra space on page one only, for
    /// callers with page-one-only chrome (a chapter title, or the Scroll's
    /// full ornamental header) — pass 0 for none.
    static func chunk(
        paragraphs: [String],
        fontScale: CGFloat,
        contentWidth: CGFloat,
        pageHeight: CGFloat,
        firstPageHeaderHeight: CGFloat
    ) -> [[Int]] {
        var pages: [[Int]] = []
        var current: [Int] = []
        var currentHeight: CGFloat = 0

        for (index, paragraph) in paragraphs.enumerated() {
            let isFirstPage = pages.isEmpty
            let available = isFirstPage ? pageHeight - firstPageHeaderHeight : pageHeight
            let height = measuredHeight(for: paragraph, width: contentWidth, fontScale: fontScale)
            let addition = current.isEmpty ? height : height + paragraphSpacing

            if !current.isEmpty && currentHeight + addition > available {
                pages.append(current)
                current = [index]
                currentHeight = height
            } else {
                current.append(index)
                currentHeight += addition
            }
        }
        if !current.isEmpty { pages.append(current) }
        return pages
    }

    /// Usable content width/height for a page, given the reading view's
    /// full available size. Both readers derive their page geometry from
    /// this so neither silently drifts out of sync with the other.
    static func pageGeometry(for size: CGSize) -> (width: CGFloat, height: CGFloat) {
        let width = max(0, size.width - horizontalPadding)
        let height = max(0, size.height - topPadding - bottomPadding - bottomChromeAllowance)
        return (width, height)
    }

    /// Mirrors the exact styling `SelectableParagraphView` applies (serif
    /// font, justified, hyphenated, 7pt line spacing) so the estimate
    /// matches what actually renders as closely as possible.
    static func measuredHeight(for text: String, width: CGFloat, fontScale: CGFloat) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 7
        style.alignment = .justified
        style.hyphenationFactor = 1.0
        let font = serifFont(size: 16 * fontScale)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .paragraphStyle: style
        ])
        let bounds = attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return ceil(bounds.height)
    }

    static func serifFont(size: CGFloat) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: .regular)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
