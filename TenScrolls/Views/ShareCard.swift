import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The "Streak Seal" — a shareable brass/ink-themed card for social posts,
/// rendered off-screen via `ImageRenderer` and handed to the system share
/// sheet. See CARAVAN_SOCIAL_SCOPE.md, workstream D.
struct ShareCard: View {
    let traderName: String
    let streak: Int
    let level: Int
    let rank: String
    let theme: ThemeOption

    /// Fixed, unscaled point size the card is laid out at. `ImageRenderer`
    /// exports this at a higher pixel scale (see `renderImage`) rather than
    /// this view itself getting bigger, so text and stroke widths stay crisp
    /// and proportional regardless of export resolution.
    static let size = CGSize(width: 400, height: 500)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "05070A"), Color(hex: "12161B")],
                startPoint: .top, endPoint: .bottom
            )

            VStack(spacing: 0) {
                Spacer(minLength: 36)

                Text("TEN SCROLLS")
                    .font(AppFont.mono(12))
                    .tracking(3.5)
                    .foregroundColor(theme.brass)

                Rectangle()
                    .fill(theme.brassDim)
                    .frame(width: 40, height: 1.5)
                    .padding(.top, 10)

                Spacer(minLength: 28)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 34))
                        .foregroundColor(theme.brass)
                    Text("\(streak)")
                        .font(AppFont.display(76, weight: .bold))
                        .foregroundColor(Palette.text)
                }
                Text(streak == 1 ? "DAY STREAK" : "DAY STREAK")
                    .font(AppFont.mono(13))
                    .tracking(2.5)
                    .foregroundColor(Palette.textDim)
                    .padding(.top, 4)

                Spacer(minLength: 30)

                VStack(spacing: 6) {
                    Text("LEVEL \(level) · \(rank.uppercased())")
                        .font(AppFont.mono(11))
                        .tracking(1.2)
                        .foregroundColor(theme.brass)
                    Text(traderName)
                        .font(AppFont.display(20))
                        .foregroundColor(Palette.text)
                }

                Spacer(minLength: 36)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28).stroke(theme.brassDim, lineWidth: 1.5)
        )
    }

    #if canImport(UIKit)
    /// Renders the card to a `UIImage` at 3x scale for crisp social-share
    /// quality regardless of the exporting device's own screen scale.
    @MainActor
    static func renderImage(traderName: String, streak: Int, level: Int, rank: String, theme: ThemeOption) -> UIImage? {
        let card = ShareCard(
            traderName: traderName.isEmpty ? "Trader" : traderName,
            streak: streak, level: level, rank: rank, theme: theme
        )
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3.0
        return renderer.uiImage
    }
    #endif
}

#if canImport(UIKit)
/// Wraps `UIActivityViewController` so the streak seal (a rendered image,
/// not a `Transferable`-friendly URL/string) can go through `.sheet` like any
/// other SwiftUI presentation. The invite link uses `ShareLink` directly
/// instead, since `URL` is natively `Transferable`.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

// MARK: - "Now Reading" share card

/// What the reader is currently reading — a scroll or a library book —
/// with just enough metadata for the share card's subtitle line.
enum ReadingShareSubject {
    /// A scroll from the ten-scroll practice.
    case scroll(roman: String, title: String, day: Int, totalDays: Int)
    /// A library book imported outside the scrolls.
    case book(title: String, author: String, chapter: Int, chapterCount: Int)

    var headline: String {
        switch self {
        case .scroll(let roman, let title, _, _):
            return title.isEmpty ? "Scroll \(roman)" : title
        case .book(let title, _, _, _):
            return title
        }
    }

    var subtitle: String {
        switch self {
        case .scroll(let roman, _, let day, let totalDays):
            return "Scroll \(roman) · Day \(day) of \(totalDays)"
        case .book(_, let author, let chapter, let chapterCount):
            if chapter > 0 {
                return "\(author) · Ch. \(chapter) of \(chapterCount)"
            }
            return author
        }
    }
}

/// A shareable "Now Reading" card — styled to match the brass/ink theme
/// of `ShareCard` but focused on what the reader is currently reading
/// rather than their streak stats.
struct NowReadingCard: View {
    let subject: ReadingShareSubject
    let traderName: String
    let theme: ThemeOption

    static let size = CGSize(width: 400, height: 500)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "05070A"), Color(hex: "12161B")],
                startPoint: .top, endPoint: .bottom
            )

            VStack(spacing: 0) {
                Spacer(minLength: 36)

                Text("NOW READING")
                    .font(AppFont.mono(12))
                    .tracking(3.5)
                    .foregroundColor(theme.brass)

                Rectangle()
                    .fill(theme.brassDim)
                    .frame(width: 40, height: 1.5)
                    .padding(.top, 10)

                Spacer(minLength: 28)

                Image(systemName: "book.fill")
                    .font(.system(size: 38))
                    .foregroundColor(theme.brass)

                Text(subject.headline)
                    .font(AppFont.display(26, weight: .bold))
                    .foregroundColor(Palette.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 30)
                    .padding(.top, 14)

                Text(subject.subtitle)
                    .font(AppFont.mono(12))
                    .tracking(1.2)
                    .foregroundColor(Palette.textDim)
                    .padding(.top, 8)

                Spacer(minLength: 30)

                VStack(spacing: 6) {
                    Text("TEN SCROLLS")
                        .font(AppFont.mono(11))
                        .tracking(1.2)
                        .foregroundColor(theme.brass)
                    Text(traderName)
                        .font(AppFont.display(20))
                        .foregroundColor(Palette.text)
                }

                Spacer(minLength: 36)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28).stroke(theme.brassDim, lineWidth: 1.5)
        )
    }

    #if canImport(UIKit)
    @MainActor
    static func renderImage(subject: ReadingShareSubject, traderName: String, theme: ThemeOption) -> UIImage? {
        let card = NowReadingCard(
            subject: subject,
            traderName: traderName.isEmpty ? "Trader" : traderName,
            theme: theme
        )
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3.0
        return renderer.uiImage
    }
    #endif
}
