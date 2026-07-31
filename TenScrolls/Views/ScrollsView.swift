import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ScrollsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.appearanceMode) var appearanceMode
    var onOpenScroll: (Int) -> Void
    var openLibrary: () -> Void = {}

    #if canImport(UIKit)
    @State private var shareImage: UIImage?
    @State private var showShare = false
    #endif
    @State private var shareScrollTarget: Scroll?

    var theme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("THE PRACTICE").font(AppFont.mono(11)).tracking(1.4).foregroundColor(theme.brass)
                    Text("Scrolls").font(AppFont.display(28)).foregroundColor(colors.text)
                }
                Text("Read your notes for the active scroll three times a day — dawn, midday, and dusk — for 30 days before the next one unlocks. Mastering a scroll awards 200 XP and 20 seals.")
                    .font(.system(size: 13)).foregroundColor(colors.textDim)
                    .padding(.bottom, 8)

                ForEach(store.state.scrolls) { scroll in
                    ScrollRow(scroll: scroll, days: store.state.scrollDaysCompleted(scroll.id), theme: theme, colors: colors)
                        .onTapGesture {
                            onOpenScroll(scroll.id)
                        }
                        .contextMenu {
                            if scroll.status != .locked {
                                Button {
                                    shareScroll(scroll)
                                } label: {
                                    Label("Share what I'm reading", systemImage: "square.and.arrow.up")
                                }
                                Button {
                                    shareScrollTarget = scroll
                                } label: {
                                    Label("Share this scroll", systemImage: "person.2")
                                }
                            }
                        }
                }

                LibraryEntryRow(bookCount: store.state.libraryBooks.count, theme: theme, colors: colors)
                    .padding(.top, 4)
                    .onTapGesture { openLibrary() }

                Color.clear.frame(height: 10)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }
        .background(colors.background)
        #if canImport(UIKit)
        .sheet(isPresented: $showShare) {
            if let shareImage {
                ActivityShareSheet(items: [shareImage])
            }
        }
        #endif
        .sheet(item: $shareScrollTarget) { scroll in
            ShareScrollSheet(scroll: scroll)
                .environment(\.appearanceMode, appearanceMode)
        }
    }

    #if canImport(UIKit)
    private func shareScroll(_ scroll: Scroll) {
        let subject = ReadingShareSubject.scroll(
            roman: scroll.roman,
            title: scroll.title,
            day: store.state.scrollDaysCompleted(scroll.id),
            totalDays: 30
        )
        shareImage = NowReadingCard.renderImage(subject: subject, traderName: store.state.traderName, theme: theme)
        showShare = shareImage != nil
    }
    #endif
}

/// Entry point into the Library — kept visually distinct from the ScrollRows
/// above it (no roman numeral, book icon instead) so it reads as "a
/// different shelf," not an eleventh scroll.
private struct LibraryEntryRow: View {
    let bookCount: Int
    let theme: ThemeOption
    let colors: AdaptivePalette

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(colors.ink2)
                    .overlay(Circle().stroke(colors.inkLine, lineWidth: 1.5))
                    .frame(width: 42, height: 42)
                Image(systemName: "books.vertical")
                    .font(.system(size: 15))
                    .foregroundColor(theme.brass)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Library").font(.system(size: 14.5, weight: .semibold)).foregroundColor(colors.text)
                Text((bookCount == 0 ? "Full books to read alongside your scrolls" : "\(bookCount) book\(bookCount == 1 ? "" : "s")").uppercased())
                    .font(AppFont.mono(10.5)).foregroundColor(colors.textFaint)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(colors.textFaint)
        }
        .padding(14)
        .background(colors.ink2)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(colors.inkLine, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct ScrollRow: View {
    let scroll: Scroll
    let days: Int
    let theme: ThemeOption
    let colors: AdaptivePalette

    var statusLabel: String {
        switch scroll.status {
        case .locked: return "Locked"
        case .mastered: return "Mastered · 30/30"
        case .active: return "Day \(days) of 30"
        }
    }

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(scroll.status == .mastered ? colors.green : colors.ink2)
                    .overlay(Circle().stroke(scroll.status == .active ? theme.brass : colors.inkLine, lineWidth: 1.5))
                    .frame(width: 42, height: 42)
                switch scroll.status {
                case .locked: Image(systemName: "lock.fill").font(.system(size: 14)).foregroundColor(colors.textDim)
                case .mastered: Image(systemName: "rosette").font(.system(size: 15)).foregroundColor(.white)
                case .active: Text(scroll.roman).font(AppFont.display(15)).foregroundColor(theme.brass)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Scroll \(scroll.roman)\(scroll.title.isEmpty ? "" : " — \(scroll.title)")")
                    .font(.system(size: 14.5, weight: .semibold)).foregroundColor(colors.text)
                Text(statusLabel.uppercased())
                    .font(AppFont.mono(10.5)).foregroundColor(colors.textFaint)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(colors.textFaint)
        }
        .padding(14)
        .background(colors.ink2)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(colors.inkLine, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .opacity(scroll.status == .locked ? 0.7 : 1)
    }
}
