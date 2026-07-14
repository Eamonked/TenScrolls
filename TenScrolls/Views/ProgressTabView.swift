import SwiftUI

struct ProgressTabView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.displayScale) var displayScale
    @State private var showResetConfirm = false
    #if canImport(UIKit)
    @State private var exportURL: URL?
    @State private var exportError = false
    @State private var shareImage: Image?
    @State private var showExportSheet = false
    #endif

    var theme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    var heatCells: [(key: String, count: Int)] {
        (0..<70).map { i in
            let key = DateKey.add(-(69 - i), to: DateKey.today())
            let count = store.state.log[key]?.sessionCount ?? 0
            return (key, count)
        }
    }

    private var recentSkips: [(date: String, reason: String)] {
        Array(store.state.skipReasons().prefix(5))
    }

    func heatColor(_ count: Int) -> Color {
        switch count {
        case 0: return Palette.ink3
        case 1: return theme.brassDim
        case 2: return theme.brass
        default: return theme.glow
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("THE JOURNEY").font(AppFont.mono(11)).tracking(1.4).foregroundColor(theme.brass)
                    Text("Progress").font(AppFont.display(28)).foregroundColor(Palette.text)
                }

                RankBar(info: store.state.levelInfo(), brass: theme.brass, brassDim: theme.brassDim, glow: theme.glow)

                overallCard
                heatmapCard
                badgesCard
                achievementsCard
                appearanceSettings
                sealShop
                #if canImport(UIKit)
                exportCard
                #endif

                Button {
                    showResetConfirm = true
                } label: {
                    Label("Reset all progress", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(GhostButtonStyle())
                .padding(.top, 4)

                Color.clear.frame(height: 10)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }
        .background(Palette.background)
        // Confirmation makes the cost of resetting concrete (the actual streak
        // number) instead of an abstract "tap again" — much harder to fat-finger
        // away a 40+ day streak by accident.
        .confirmationDialog(
            resetConfirmTitle,
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset everything", role: .destructive) {
                store.resetAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. Your scroll badges, achievements, and seals will be lost too.")
        }
        #if canImport(UIKit)
        .sheet(isPresented: $showExportSheet) {
            ProgressExportSheet(
                store: store,
                shareImage: $shareImage,
                exportURL: $exportURL,
                exportError: $exportError,
                theme: theme
            )
        }
        .sheet(item: $exportURL) { url in
            ShareSheet(items: [url])
        }
        .alert("Nothing to export yet", isPresented: $exportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Transcribe some scroll notes or write a journal entry first — that's what fills the book.")
        }
        #endif
    }

    private var resetConfirmTitle: String {
        let streak = store.state.currentStreak
        if streak > 0 {
            return "Reset progress? You'll lose your \(streak)-day streak."
        }
        return "Reset all progress?"
    }

    #if canImport(UIKit)
    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Export & Share")
            CardView {
                Text("Share a snapshot of your streak, or export a full PDF of your Commonplace Book.")
                    .font(.system(size: 13)).foregroundColor(Palette.textDim)
                    .padding(.bottom, 14)
                Button {
                    showExportSheet = true
                } label: {
                    Label("View Export Options", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PrimaryButtonStyle(brass: theme.brass, glow: theme.glow))
            }
        }
        .onAppear { renderShareImage() }
    }

    @MainActor
    private func renderShareImage() {
        let card = StreakShareCard(
            streak: store.state.currentStreak,
            totalDays: store.state.totalDaysCompleted,
            masteredCount: store.state.scrolls.filter { $0.status == .mastered }.count,
            heatCells: heatCells,
            theme: theme
        )
        let renderer = ImageRenderer(content: card)
        renderer.scale = displayScale
        if let uiImage = renderer.uiImage {
            shareImage = Image(uiImage: uiImage)
        }
    }
    #endif

    private var overallCard: some View {
        let s = store.state
        let mastered = s.scrolls.filter { $0.status == .mastered }.count
        return CardView {
            Text("OVERALL").font(AppFont.mono(10)).tracking(1.4).foregroundColor(Palette.textFaint)
            Text("\(s.totalDaysCompleted) of 300 days").font(AppFont.display(19)).foregroundColor(Palette.text).padding(.top, 2)
            ProgressTrack(pct: min(100, Double(s.totalDaysCompleted) / 300 * 100), brassDim: Palette.green, glow: Palette.greenGlow, height: 8)
                .padding(.top, 12)
            Text("\(s.currentStreak) day streak · \(s.shieldsAvailable) shield\(s.shieldsAvailable == 1 ? "" : "s") · \(mastered) of 10 scrolls mastered")
                .font(AppFont.mono(11)).foregroundColor(Palette.textFaint).padding(.top, 7)
            if let reread = s.rereadScroll, let cs = s.cycleState {
                Text("Cycle \(cs.cycle) · revisiting Scroll \(reread.roman)")
                    .font(AppFont.mono(11)).foregroundColor(theme.brass).padding(.top, 3)
            }
        }
    }

    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Last 70 Days")
            CardView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 10), spacing: 4) {
                    ForEach(heatCells, id: \.key) { cell in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(heatColor(cell.count))
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
                Text("Each square is a day · brighter means more sessions read")
                    .font(AppFont.mono(11)).foregroundColor(Palette.textFaint).padding(.top, 8)

                let skips = recentSkips
                if !skips.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("RECENT MISSES").font(AppFont.mono(10)).tracking(1.4).foregroundColor(Palette.textFaint)
                        ForEach(skips, id: \.date) { skip in
                            HStack(alignment: .top, spacing: 6) {
                                Text(DateKey.short(skip.date)).font(AppFont.mono(10)).foregroundColor(Palette.textFaint).frame(width: 50, alignment: .leading)
                                Text(skip.reason).font(.system(size: 13)).italic().foregroundColor(Palette.textDim)
                            }
                        }
                    }
                    .padding(.top, 16)
                }
            }
        }
    }

    private var badgesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Scroll Badges")
            CardView {
                FlowLayout(spacing: 8) {
                    ForEach(store.state.scrolls) { s in
                        HStack(spacing: 5) {
                            Image(systemName: "rosette").font(.system(size: 11))
                            Text("Scroll \(s.roman)").font(.system(size: 11.5))
                        }
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Palette.ink3)
                        .foregroundColor(s.status == .mastered ? theme.brass : Palette.textDim)
                        .overlay(Capsule().stroke(s.status == .mastered ? theme.brassDim : Palette.inkLine, lineWidth: 1))
                        .clipShape(Capsule())
                    }
                }
            }
        }
    }

    private var achievementsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Achievements")
            CardView {
                VStack(spacing: 0) {
                    ForEach(Array(store.state.achievements.enumerated()), id: \.element.def.id) { idx, item in
                        VStack(spacing: 0) {
                            HStack(spacing: 11) {
                                ZStack {
                                    Circle().fill(item.earned ? theme.brass : Palette.ink3).frame(width: 30, height: 30)
                                    Image(systemName: "rosette").font(.system(size: 13))
                                        .foregroundColor(item.earned ? Color(hex: "1A1207") : Palette.textFaint)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.def.name).font(.system(size: 12.5, weight: .semibold)).foregroundColor(Palette.text)
                                    Text(item.def.desc).font(.system(size: 11)).foregroundColor(Palette.textFaint)
                                }
                                Spacer()
                                if item.earned {
                                    Image(systemName: "checkmark").font(.system(size: 12)).foregroundColor(Palette.green)
                                }
                            }
                            .opacity(item.earned ? 1 : 0.42)
                            .padding(.vertical, 9)
                            if idx != store.state.achievements.count - 1 {
                                Divider().background(Palette.ink3)
                            }
                        }
                    }
                }
            }
        }
    }

    private var appearanceSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Appearance")
            CardView {
                HStack(spacing: 12) {
                    Image(systemName: store.state.appearanceMode == .light ? "sun.max.fill" : "moon.fill")
                        .font(.system(size: 18))
                        .foregroundColor(theme.brass)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Theme Mode")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Palette.text)
                        Text(store.state.appearanceMode == .light ? "Light" : "Dark")
                            .font(.system(size: 11))
                            .foregroundColor(Palette.textDim)
                    }
                    
                    Spacer()
                    
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            store.setAppearanceMode(store.state.appearanceMode == .dark ? .light : .dark)
                        }
                    } label: {
                        Text("Switch")
                            .font(AppFont.mono(10.5))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Palette.ink2)
                            .foregroundColor(theme.brass)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.inkLine, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private var sealShop: some View {
        let seals = store.state.sealsAvailable
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Seal Rewards", trailing: "\(seals) available")
            CardView {
                VStack(spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Streak Shield").font(.system(size: 14, weight: .medium)).foregroundColor(Palette.text)
                            Text("Protects your streak if you miss a day.").font(.system(size: 11)).foregroundColor(Palette.textDim)
                        }
                        Spacer()
                        Button {
                            _ = store.buyShield(cost: 30)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "diamond").font(.system(size: 10))
                                Text("30")
                            }
                            .font(AppFont.mono(10.5))
                        }
                        .disabled(seals < 30)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Palette.ink2)
                        .foregroundColor(theme.brass)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.inkLine, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .opacity(seals >= 30 ? 1 : 0.4)
                    }

                    Divider().background(Palette.ink3)

                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(Palette.themes) { t in
                            let unlocked = store.state.unlockedThemeIds.contains(t.id)
                            let equipped = store.state.activeThemeId == t.id
                            let canAfford = seals >= t.cost
                            VStack(spacing: 7) {
                                Circle().fill(t.glow).overlay(Circle().stroke(t.brass, lineWidth: 2)).frame(width: 34, height: 34)
                                Text(t.name).font(.system(size: 11)).foregroundColor(Palette.textDim)
                                if equipped {
                                    Text("Equipped").font(AppFont.mono(10)).foregroundColor(Palette.green)
                                } else if unlocked {
                                    Button("Equip") { store.equipTheme(t.id) }
                                        .font(AppFont.mono(10.5))
                                        .padding(.horizontal, 9).padding(.vertical, 5)
                                        .background(Palette.ink2)
                                        .foregroundColor(theme.brass)
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.inkLine, lineWidth: 1))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    Button {
                                        store.unlockTheme(t.id)
                                    } label: {
                                        HStack(spacing: 3) {
                                            Image(systemName: "diamond").font(.system(size: 10))
                                            Text("\(t.cost)")
                                        }
                                        .font(AppFont.mono(10.5))
                                    }
                                    .disabled(!canAfford)
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(Palette.ink2)
                                    .foregroundColor(theme.brass)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.inkLine, lineWidth: 1))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .opacity(canAfford ? 1 : 0.4)
                                }
                            }
                            .padding(.vertical, 12).padding(.horizontal, 6)
                            .background(Palette.ink3)
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.inkLine, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
            }
        }
    }
}

#if canImport(UIKit)
/// Standalone view rendered off-screen (via ImageRenderer) to produce the
/// shareable streak image. Kept intentionally simple/static — no CardView
/// chrome dependency — since it needs to look right cropped out of app context.
private struct StreakShareCard: View {
    let streak: Int
    let totalDays: Int
    let masteredCount: Int
    let heatCells: [(key: String, count: Int)]
    let theme: ThemeOption

    private func heatColor(_ count: Int) -> Color {
        switch count {
        case 0: return Palette.ink3
        case 1: return theme.brassDim
        case 2: return theme.brass
        default: return theme.glow
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("TEN SCROLLS").font(AppFont.mono(11)).tracking(1.6).foregroundColor(theme.brass)
            Text("\(streak) day streak").font(AppFont.display(30)).foregroundColor(Palette.text)
            Text("\(totalDays) of 300 days · \(masteredCount) of 10 scrolls mastered")
                .font(AppFont.mono(12)).foregroundColor(Palette.textFaint)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 10), spacing: 4) {
                ForEach(heatCells, id: \.key) { cell in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(heatColor(cell.count))
                        .aspectRatio(1, contentMode: .fit)
                }
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(Palette.background)
    }
}
#endif

/// Minimal wrapping flow layout for the badge row.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#if canImport(UIKit)
struct ProgressExportSheet: View {
    @ObservedObject var store: AppStore
    @Binding var shareImage: Image?
    @Binding var exportURL: URL?
    @Binding var exportError: Bool
    let theme: ThemeOption

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Share Streak")) {
                    if let shareImage {
                        VStack(alignment: .center, spacing: 16) {
                            shareImage
                                .resizable()
                                .scaledToFit()
                                .frame(height: 200)
                                .cornerRadius(12)
                                .shadow(color: Color.black.opacity(0.1), radius: 5, x: 0, y: 2)
                            
                            ShareLink(
                                item: shareImage,
                                preview: SharePreview("My Ten Scrolls streak", image: shareImage)
                            ) {
                                Label("Share Image", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(theme.brass)
                        }
                        .padding(.vertical, 8)
                    } else {
                        Text("Generating image...")
                            .foregroundColor(.secondary)
                    }
                }
                
                Section(header: Text("Commonplace Book"), footer: Text("A keepsake of the year's practice you can keep or print.")) {
                    Button {
                        if let url = CommonplaceBook.makePDF(state: store.state, themeColor: theme.brass) {
                            exportURL = url
                        } else {
                            exportError = true
                        }
                    } label: {
                        Label("Export PDF", systemImage: "doc.text")
                    }
                    .foregroundColor(theme.brass)
                }
            }
            .navigationTitle("Export & Share")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
