import SwiftUI

/// $500 Club rebuild of the Progress screen — "The Journey." Sacred-now:
/// level, overall progress, the 70-day heatmap + milestone road, mastered
/// scroll badges, and achievements. Appearance, Import, the seal shop
/// (Atelier), Export, and Reset all moved to `SettingsView`, reached via
/// the gear icon in the header — see that file for those sections. Every
/// `store.state` call below is unchanged from the previous implementation;
/// only the presentation moved to the Lux design system.
struct ProgressTabView: View {
    @EnvironmentObject var store: AppStore
    @State private var showSettings = false

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                levelCard
                overallCard
                heatmapCard
                badgesCard
                achievementsCard
                Color.clear.frame(height: 10)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 120)
        }
        .background(LuxColor.bg.ignoresSafeArea())
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("THE JOURNEY").luxEyebrow()
                Text("Progress")
                    .font(LuxFont.serif(32))
                    .tracking(-0.3)
                    .foregroundColor(LuxColor.textPrimary)
            }
            Spacer()
            LuxIconButton(systemImage: "gearshape") {
                showSettings = true
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Level

    private var levelCard: some View {
        let info = store.state.levelInfo()
        return LuxCard {
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(LuxColor.gold)
                    Text(Roman.from(max(1, info.level)))
                        .font(LuxFont.mono(18, weight: .regular))
                        .foregroundColor(.black)
                }
                .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 8) {
                    Text(info.rank)
                        .font(LuxFont.serif(16))
                        .foregroundColor(LuxColor.textPrimary)
                    LuxProgressBar(pct: info.need > 0 ? Double(info.into) / Double(info.need) : 0)
                    Text("\(Roman.from(max(1, info.level))) \u{2022} \(info.into)/\(info.need) TO NEXT LEVEL")
                        .font(LuxFont.mono(10))
                        .tracking(0.4)
                        .foregroundColor(LuxColor.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Overall

    private var overallCard: some View {
        let s = store.state
        let mastered = s.scrolls.filter { $0.status == .mastered }.count
        return VStack(alignment: .leading, spacing: 10) {
            Text("OVERALL").luxEyebrow()
            LuxCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(s.totalDaysCompleted) of 300 days")
                        .font(LuxFont.serif(20))
                        .foregroundColor(LuxColor.textPrimary)
                    LuxProgressBar(pct: Double(s.totalDaysCompleted) / 300)
                    Text("\(Roman.from(max(0, s.currentStreak))) day streak \u{2022} \(Roman.from(max(0, s.shieldsAvailable))) shield\(s.shieldsAvailable == 1 ? "" : "s") \u{2022} \(mastered) of 10 scrolls mastered")
                        .font(LuxFont.mono(11))
                        .tracking(0.3)
                        .foregroundColor(LuxColor.textSecondary)
                    if let reread = s.rereadScroll, let cs = s.cycleState {
                        Text("Cycle \(cs.cycle) \u{00B7} revisiting Scroll \(reread.roman)")
                            .font(LuxFont.mono(11))
                            .foregroundColor(LuxColor.gold)
                    }
                }
            }
        }
    }

    // MARK: - Heatmap + milestone road

    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LAST 70 DAYS").luxEyebrow()
            LuxCard {
                VStack(alignment: .leading, spacing: 18) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 10), spacing: 6) {
                        ForEach(heatCells, id: \.key) { cell in
                            RoundedRectangle(cornerRadius: 6)
                                .fill(cell.count > 0 ? LuxColor.gold : LuxColor.cardBorder)
                                .aspectRatio(1, contentMode: .fit)
                        }
                    }
                    Text("Each square is a day")
                        .font(LuxFont.mono(10))
                        .tracking(0.5)
                        .foregroundColor(LuxColor.textMuted)

                    LuxDivider()

                    milestoneRoad

                    let skips = recentSkips
                    if !skips.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("RECENT MISSES").luxEyebrow(tracking: 1.2)
                            ForEach(skips, id: \.date) { skip in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(DateKey.short(skip.date))
                                        .font(LuxFont.mono(10))
                                        .foregroundColor(LuxColor.textMuted)
                                        .frame(width: 50, alignment: .leading)
                                    Text(skip.reason)
                                        .font(LuxFont.sans(12))
                                        .italic()
                                        .foregroundColor(LuxColor.textSecondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Five nodes at `Constants.milestones` (7 / 14 / 30 / 60 / 100 days),
    /// connected by a hairline — gold-filled once the reader's best-ever
    /// streak has reached that threshold, outlined for milestones still
    /// ahead. Mirrors the same `bestStreak` comparison the week/month-streak
    /// achievements already use.
    private var milestoneRoad: some View {
        let milestones = Constants.milestones
        let best = store.state.bestStreak
        return HStack(alignment: .top, spacing: 0) {
            ForEach(Array(milestones.enumerated()), id: \.offset) { idx, milestone in
                let achieved = best >= milestone
                VStack(spacing: 6) {
                    Circle()
                        .fill(achieved ? LuxColor.gold : Color.clear)
                        .overlay(Circle().stroke(achieved ? Color.clear : LuxColor.textMuted, lineWidth: 0.5))
                        .frame(width: 10, height: 10)
                    Text(Roman.from(milestone))
                        .font(LuxFont.mono(9))
                        .foregroundColor(achieved ? LuxColor.gold : LuxColor.textMuted)
                }
                if idx != milestones.count - 1 {
                    Rectangle()
                        .fill(achieved ? LuxColor.gold.opacity(0.5) : LuxColor.cardBorder)
                        .frame(height: 0.5)
                        .padding(.top, 5)
                        .padding(.bottom, 15)
                }
            }
        }
    }

    // MARK: - Scroll badges (mastered only)

    private var badgesCard: some View {
        let mastered = store.state.scrolls.filter { $0.status == .mastered }
        return VStack(alignment: .leading, spacing: 10) {
            Text("SCROLL BADGES").luxEyebrow()
            if mastered.isEmpty {
                let daysUntilFirst = max(0, 30 - store.state.totalDaysCompleted)
                LuxEmptyLine(text: "No scrolls mastered yet. \(Roman.from(max(1, daysUntilFirst))) days until Scroll I", height: 80)
            } else {
                LuxCard {
                    FlowLayout(spacing: 8) {
                        ForEach(mastered) { s in
                            HStack(spacing: 6) {
                                Image(systemName: "seal").font(.system(size: 11, weight: .light))
                                Text("SCROLL \(s.roman)").font(LuxFont.mono(10)).tracking(0.6)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundColor(LuxColor.gold)
                            .overlay(Capsule().stroke(LuxColor.gold.opacity(0.5), lineWidth: 0.5))
                            .clipShape(Capsule())
                        }
                    }
                }
            }
        }
    }

    // MARK: - Achievements

    private var achievementsCard: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        return VStack(alignment: .leading, spacing: 10) {
            Text("ACHIEVEMENTS").luxEyebrow()
            LuxCard {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(Array(store.state.achievements.enumerated()), id: \.offset) { _, item in
                        AchievementStamp(name: item.def.name, desc: item.def.desc, earned: item.earned)
                    }
                }
            }
        }
    }
}

// MARK: - Level / overall progress bar

/// A thin 2pt gold progress line shared by the Level and Overall cards.
private struct LuxProgressBar: View {
    let pct: Double
    var height: CGFloat = 2
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(LuxColor.cardBorder).frame(height: height)
                Rectangle().fill(LuxColor.gold).frame(width: geo.size.width * max(0, min(1, pct)), height: height)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Achievement stamp

/// A single achievement in the 3-column grid: a gold-foil filled seal when
/// earned, a blind-debossed hairline outline when not — no green checkmarks.
private struct AchievementStamp: View {
    let name: String
    let desc: String
    let earned: Bool
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(earned ? LuxColor.gold : Color.clear)
                    .overlay(Circle().stroke(earned ? Color.clear : LuxColor.cardBorder, lineWidth: 0.5))
                Image(systemName: "seal")
                    .font(.system(size: 16, weight: .light))
                    .foregroundColor(earned ? .black : LuxColor.textMuted)
            }
            .frame(width: 44, height: 44)
            Text(name)
                .font(LuxFont.serif(12))
                .foregroundColor(LuxColor.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(desc)
                .font(LuxFont.sans(9))
                .foregroundColor(LuxColor.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .top)
        .opacity(earned ? 1 : 0.42)
    }
}

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

// MARK: - Previews

#Preview {
    let store = AppStore()
    store.state.bestStreak = 16
    return ProgressTabView().environmentObject(store)
}
