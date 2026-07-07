import SwiftUI

struct ScrollsView: View {
    @EnvironmentObject var store: AppStore
    var onOpenScroll: (Int) -> Void

    var theme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("THE PRACTICE").font(AppFont.mono(11)).tracking(1.4).foregroundColor(theme.brass)
                    Text("Scrolls").font(AppFont.display(28)).foregroundColor(Palette.text)
                }
                Text("Read your notes for the active scroll three times a day — dawn, midday, and dusk — for 30 days before the next one unlocks. Mastering a scroll awards 200 XP and 20 seals.")
                    .font(.system(size: 13)).foregroundColor(Palette.textDim)
                    .padding(.bottom, 8)

                ForEach(store.state.scrolls) { scroll in
                    ScrollRow(scroll: scroll, days: store.state.scrollDaysCompleted(scroll.id), theme: theme)
                        .onTapGesture {
                            onOpenScroll(scroll.id)
                        }
                }
                Color.clear.frame(height: 10)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }
        .background(Palette.background)
    }
}

private struct ScrollRow: View {
    let scroll: Scroll
    let days: Int
    let theme: ThemeOption

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
                    .fill(scroll.status == .mastered ? Palette.green : Palette.ink2)
                    .overlay(Circle().stroke(scroll.status == .active ? theme.brass : Palette.inkLine, lineWidth: 1.5))
                    .frame(width: 42, height: 42)
                switch scroll.status {
                case .locked: Image(systemName: "lock.fill").font(.system(size: 14)).foregroundColor(Palette.textDim)
                case .mastered: Image(systemName: "rosette").font(.system(size: 15)).foregroundColor(.white)
                case .active: Text(scroll.roman).font(AppFont.display(15)).foregroundColor(theme.brass)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Scroll \(scroll.roman)\(scroll.title.isEmpty ? "" : " — \(scroll.title)")")
                    .font(.system(size: 14.5, weight: .semibold)).foregroundColor(Palette.text)
                Text(statusLabel.uppercased())
                    .font(AppFont.mono(10.5)).foregroundColor(Palette.textFaint)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(Palette.textFaint)
        }
        .padding(14)
        .background(Palette.ink2)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.inkLine, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .opacity(scroll.status == .locked ? 0.7 : 1)
    }
}
