import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// $500 Club rebuild of the Scrolls (timeline) screen. Same public surface
/// as before (`onOpenScroll`, `openLibrary`), same share-sheet plumbing.
struct ScrollsView: View {
    @EnvironmentObject var store: AppStore
    var onOpenScroll: (Int) -> Void
    var openLibrary: () -> Void = {}

    #if canImport(UIKit)
    @State private var shareImage: UIImage?
    @State private var showShare = false
    #endif
    @State private var shareScrollTarget: Scroll?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                LuxScreenHeader(eyebrow: "THE PRACTICE", title: "Scrolls")
                Text("Three readings a day. Thirty days a scroll.")
                    .font(LuxFont.sans(13))
                    .italic()
                    .foregroundColor(LuxColor.textSecondary)

                timeline

                libraryEntryRow
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 120)
        }
        .background(LuxColor.bg.ignoresSafeArea())
        #if canImport(UIKit)
        .sheet(isPresented: $showShare) {
            if let shareImage {
                ActivityShareSheet(items: [shareImage])
            }
        }
        #endif
        .sheet(item: $shareScrollTarget) { scroll in
            ShareScrollSheet(scroll: scroll)
        }
    }

    // MARK: - Timeline

    private var timeline: some View {
        ZStack(alignment: .topLeading) {
            // The vertical gold hairline threading every node together.
            Rectangle()
                .fill(LuxColor.gold.opacity(0.35))
                .frame(width: 0.5)
                .padding(.leading, 20)
                .padding(.vertical, 20)

            VStack(spacing: 14) {
                ForEach(store.state.scrolls) { scroll in
                    row(for: scroll)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for scroll: Scroll) -> some View {
        let days = store.state.scrollDaysCompleted(scroll.id)
        HStack(alignment: .top, spacing: 16) {
            node(for: scroll)
            Group {
                if scroll.status == .locked {
                    lockedCard(scroll)
                } else if scroll.status == .active {
                    activeCard(scroll, days: days)
                } else {
                    masteredRow(scroll)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contextMenu {
            // Both share actions surface (or transmit) a scroll's actual
            // content/title, gated by AppFeature.scrollSharing — see
            // ContentView.attemptOpenScroll for the equivalent gate on
            // opening a scroll to read it. A free reader tapping either
            // just lands on the same paywall rather than silently getting
            // content they can't otherwise see.
            if scroll.status != .locked {
                #if canImport(UIKit)
                Button {
                    if store.isAccessible(.scrollSharing) {
                        shareScroll(scroll)
                    } else {
                        store.shouldShowDay30Paywall = true
                    }
                } label: {
                    Label("Share what I'm reading", systemImage: "square.and.arrow.up")
                }
                #endif
                Button {
                    if store.isAccessible(.scrollSharing) {
                        shareScrollTarget = scroll
                    } else {
                        store.shouldShowDay30Paywall = true
                    }
                } label: {
                    Label("Share this scroll", systemImage: "person.2")
                }
            }
        }
    }

    private func node(for scroll: Scroll) -> some View {
        ZStack {
            Circle()
                .fill(scroll.status == .active ? LuxColor.gold : LuxColor.bg)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(LuxColor.gold.opacity(scroll.status == .locked ? 0.3 : 0.9), lineWidth: 1))
        }
        .frame(width: 40, height: 40)
    }

    private func activeCard(_ scroll: Scroll, days: Int) -> some View {
        Button { onOpenScroll(scroll.id) } label: {
            LuxCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("DAY \(Roman.from(max(1, days)))")
                        .luxEyebrow()
                    Text("Scroll \(scroll.roman)\(scroll.title.isEmpty ? "" : " \u{2014} \(scroll.title)")")
                        .font(LuxFont.serif(20))
                        .foregroundColor(LuxColor.textPrimary)
                    if !scroll.theme.isEmpty {
                        Text(scroll.theme)
                            .font(LuxFont.sans(13))
                            .italic()
                            .foregroundColor(LuxColor.goldMuted)
                    }
                    let entry = store.state.log[DateKey.today()]
                    HStack(spacing: 14) {
                        ForEach(Session.allCases) { session in
                            HStack(spacing: 4) {
                                Image(systemName: (entry?.isCompleted(for: session) ?? false) ? "checkmark" : "circle")
                                    .font(.system(size: 9, weight: .light))
                                Text(session.label.uppercased())
                                    .font(LuxFont.sans(8, weight: .medium))
                                    .tracking(1)
                            }
                            .foregroundColor((entry?.isCompleted(for: session) ?? false) ? LuxColor.gold : LuxColor.textMuted)
                        }
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private func masteredRow(_ scroll: Scroll) -> some View {
        Button { onOpenScroll(scroll.id) } label: {
            LuxRowCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scroll \(scroll.roman)\(scroll.title.isEmpty ? "" : " \u{2014} \(scroll.title)")")
                            .font(LuxFont.sans(14, weight: .medium))
                            .foregroundColor(LuxColor.textPrimary)
                        Text("MASTERED")
                            .font(LuxFont.sans(9, weight: .medium))
                            .tracking(1.2)
                            .foregroundColor(LuxColor.goldMuted)
                    }
                    Spacer()
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 14, weight: .light))
                        .foregroundColor(LuxColor.gold)
                }
                .padding(14)
            }
        }
        .buttonStyle(.plain)
    }

    private func lockedCard(_ scroll: Scroll) -> some View {
        Button {
            onOpenScroll(scroll.id) // presents the preview via ContentView's paywall/lock gate
        } label: {
            LuxRowCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scroll \(scroll.roman)")
                            .font(LuxFont.sans(14, weight: .medium))
                            .foregroundColor(LuxColor.textSecondary)
                            .blur(radius: 2)
                        Text("UNLOCKS LATER")
                            .font(LuxFont.sans(9, weight: .medium))
                            .tracking(1.2)
                            .foregroundColor(LuxColor.textMuted)
                    }
                    Spacer()
                }
                .padding(14)
            }
            .opacity(0.5)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Library entry

    private var libraryEntryRow: some View {
        let bookCount = store.state.libraryBooks.count
        return Button(action: openLibrary) {
            LuxRowCard {
                HStack(spacing: 13) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 15, weight: .light))
                        .foregroundColor(LuxColor.gold)
                        .frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Library")
                            .font(LuxFont.sans(14, weight: .medium))
                            .foregroundColor(LuxColor.textPrimary)
                        Text((bookCount == 0 ? "Full books alongside your scrolls" : "\(bookCount) book\(bookCount == 1 ? "" : "s")").uppercased())
                            .font(LuxFont.sans(9, weight: .medium))
                            .tracking(1)
                            .foregroundColor(LuxColor.textMuted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .light))
                        .foregroundColor(LuxColor.textMuted)
                }
                .padding(14)
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    #if canImport(UIKit)
    private func shareScroll(_ scroll: Scroll) {
        let subject = ReadingShareSubject.scroll(
            roman: scroll.roman,
            title: scroll.title,
            day: store.state.scrollDaysCompleted(scroll.id),
            totalDays: 30
        )
        let theme = Palette.theme(for: store.state.activeThemeId)
        shareImage = NowReadingCard.renderImage(subject: subject, traderName: store.state.traderName, theme: theme)
        showShare = shareImage != nil
    }
    #endif
}
