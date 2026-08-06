import SwiftUI
import StoreKit

// MARK: - Settings View

/// Sheet presented from the Progress tab's gear toolbar icon.
/// Contains Appearance, Library import, Atelier (seal shop + palettes),
/// Export, and Danger Zone — everything stripped from ProgressTabView.
struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) var displayScale
    @Environment(\.colorScheme) private var colorScheme

    @State private var showDocumentImport = false
    @State private var showResetConfirm = false
    @State private var resetTyped = ""
    @State private var showManageSubscriptions = false
    #if canImport(UIKit)
    @State private var exportURL: URL?
    @State private var exportError = false
    @State private var shareImage: Image?
    @State private var showExportOptions = false
    #endif

    var body: some View {
        NavigationStack {
            ZStack {
                LuxColor.bg.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        appearanceSection
                        librarySection
                        atelierSection
                        membershipSection
                        archiveSection
                        dangerSection
                        versionFooter
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 60)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(LuxColor.bg, for: .navigationBar)
            .toolbarColorScheme(colorScheme, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(LuxColor.textSecondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text("SETTINGS")
                            .font(LuxFont.sans(10, weight: .medium))
                            .tracking(1.8)
                            .foregroundColor(LuxColor.textSecondary)
                        Text("Atelier")
                            .font(LuxFont.serif(20))
                            .foregroundColor(LuxColor.textPrimary)
                    }
                }
            }
        }
        .sheet(isPresented: $showDocumentImport) {
            DocumentImportSheet()
        }
        .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
        #if canImport(UIKit)
        .confirmationDialog(
            "Export your journey",
            isPresented: $showExportOptions,
            titleVisibility: .visible
        ) {
            Button("Streak Snapshot") { renderAndShareSnapshot() }
            Button("Commonplace Book PDF") { exportCommonplace() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $exportURL) { url in
            ShareSheet(items: [url])
        }
        .alert("Nothing to export yet", isPresented: $exportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Transcribe some scroll notes or write a journal entry first.")
        }
        #endif
        .confirmationDialog(
            resetConfirmTitle,
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset everything", role: .destructive) { store.resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. Streaks, badges, seals, and journal entries will all be lost.")
        }
        .onAppear {
            #if canImport(UIKit)
            renderShareImage()
            #endif
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionEyebrow("APPEARANCE")
            LuxCard {
                ThemeSelectorView()
            }
        }
    }

    // MARK: - Library

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionEyebrow("LIBRARY")
            LuxCard {
                HStack(spacing: 14) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 18, weight: .light))
                        .foregroundColor(LuxColor.textSecondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Import Document")
                            .font(LuxFont.sans(14))
                            .foregroundColor(LuxColor.textPrimary)
                        Text("PDF or EPUB — one scroll or spread across all ten")
                            .font(LuxFont.sans(12))
                            .foregroundColor(LuxColor.textSecondary)
                    }
                    Spacer()
                    Button {
                        showDocumentImport = true
                    } label: {
                        Text("Import")
                            .font(LuxFont.sans(10, weight: .medium))
                            .tracking(1.2)
                            .textCase(.uppercase)
                            .foregroundColor(LuxColor.goldMuted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(LuxColor.cardBorder, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Atelier (seal shop)

    private var atelierSection: some View {
        let seals = store.state.sealsAvailable
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionEyebrow("ATELIER")
                Spacer()
                Text("\(seals) SEALS")
                    .font(LuxFont.mono(10))
                    .tracking(0.8)
                    .foregroundColor(LuxColor.gold)
            }

            // Shield row
            LuxCard {
                HStack(spacing: 14) {
                    Image(systemName: "shield")
                        .font(.system(size: 18, weight: .light))
                        .foregroundColor(LuxColor.textSecondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Streak Shield")
                            .font(LuxFont.serif(14))
                            .foregroundColor(LuxColor.textPrimary)
                        let shields = store.state.shieldsAvailable
                        Text("Protects your streak for one missed day  \u{00B7}  \(Roman.from(max(0, shields)))/III available")
                            .font(LuxFont.sans(12))
                            .foregroundColor(LuxColor.textSecondary)
                    }
                    Spacer()
                    Button {
                        _ = store.buyShield(cost: 30)
                    } label: {
                        Text("30 SEALS")
                            .font(LuxFont.sans(10, weight: .medium))
                            .tracking(1.2)
                            .foregroundColor(seals >= 30 ? LuxColor.gold : LuxColor.textMuted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(seals >= 30 ? LuxColor.gold.opacity(0.5) : LuxColor.cardBorder, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(seals < 30)
                    .opacity(seals >= 30 ? 1 : 0.4)
                }
            }

            // Palette grid — 3 columns per spec
            LuxCard {
                let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(luxPalettes) { palette in
                        PaletteSwatchView(palette: palette, sealsAvailable: seals)
                    }
                }
            }
        }
    }

    // MARK: - Membership

    /// Only shown once the reader actually has Plus (trial or paid) — free
    /// readers have nothing to manage. Routes to Apple's native sheet via
    /// `manageSubscriptionsSheet`, so cancellation always reflects the real
    /// App Store state instead of us tracking it ourselves.
    @ViewBuilder
    private var membershipSection: some View {
        if store.state.hasPlusAccess {
            VStack(alignment: .leading, spacing: 12) {
                sectionEyebrow("MEMBERSHIP")
                LuxCard {
                    HStack(spacing: 14) {
                        Image(systemName: "crown")
                            .font(.system(size: 18, weight: .light))
                            .foregroundColor(LuxColor.textSecondary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(planStatusSuffix ?? "Plus")
                                .font(LuxFont.serif(14))
                                .foregroundColor(LuxColor.textPrimary)
                            Text("Manage or cancel anytime in the App Store")
                                .font(LuxFont.sans(12))
                                .foregroundColor(LuxColor.textSecondary)
                        }
                        Spacer()
                        Button {
                            showManageSubscriptions = true
                        } label: {
                            Text("Manage")
                                .font(LuxFont.sans(10, weight: .medium))
                                .tracking(1.2)
                                .textCase(.uppercase)
                                .foregroundColor(LuxColor.goldMuted)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(LuxColor.cardBorder, lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Archive / Export

    private var archiveSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionEyebrow("ARCHIVE")
            LuxCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Preserve your journey.")
                        .font(LuxFont.serif(14))
                        .foregroundColor(LuxColor.textPrimary)
                    Text("Share a snapshot of your streak or export the full Commonplace Book as a PDF keepsake.")
                        .font(LuxFont.sans(12))
                        .foregroundColor(LuxColor.textSecondary)
                    #if canImport(UIKit)
                    Button {
                        showExportOptions = true
                    } label: {
                        Text("View Export Options")
                    }
                    .buttonStyle(LuxPrimaryButtonStyle())
                    #endif
                }
            }
        }
    }

    // MARK: - Danger Zone

    private var dangerSection: some View {
        VStack(spacing: 16) {
            Button {
                showResetConfirm = true
            } label: {
                Text("Reset all progress")
                    .font(LuxFont.sans(13))
                    .foregroundColor(LuxColor.textSecondary)
                    .opacity(0.5)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Version footer

    /// "Plus", "Plus Trial", or "Plus · Annual"/"Monthly"/"Lifetime" once a
    /// plan is known (see `AppStore.purchasedPlanLabel`) — `nil` for a free
    /// reader, so the footer stays exactly as it was for them.
    private var planStatusSuffix: String? {
        guard store.state.hasPlusAccess else { return nil }
        if store.state.cachedSubscriptionStatus == .trialing {
            return "Plus Trial"
        }
        if let label = store.purchasedPlanLabel {
            return "Plus \u{00B7} \(label)"
        }
        return "Plus"
    }

    private var versionFooter: some View {
        let code = store.state.traderCode
        let days = store.state.totalDaysCompleted
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        var line = "Version \(version) \u{00B7} \(days) of 300 days \u{00B7} \(code)"
        if let plan = planStatusSuffix {
            line += " \u{00B7} \(plan)"
        }
        return Text(line)
            .font(LuxFont.mono(10))
            .tracking(0.5)
            .foregroundColor(LuxColor.textMuted)
            .opacity(0.3)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
    }

    // MARK: - Helpers

    private func sectionEyebrow(_ text: String) -> some View {
        Text(text)
            .luxEyebrow()
    }

    private var resetConfirmTitle: String {
        let streak = store.state.currentStreak
        return streak > 0
            ? "Reset progress? You'll lose your \(streak)-day streak."
            : "Reset all progress?"
    }

    // MARK: - Lux palette definitions (renamed per spec)
    // Brass / Ink / Parchment / Onyx / Lichen — replaces old Jade/Crimson/Silver/Violet

    private var luxPalettes: [LuxPalette] {
        [
            LuxPalette(id: "brass",   name: "Brass",    swatch: Color(hex: "D4AF37"), cost: 0),
            LuxPalette(id: "ink",     name: "Ink",      swatch: Color(hex: "1A1E28"), cost: 20),
            LuxPalette(id: "parchment", name: "Parchment", swatch: Color(hex: "F5F2ED"), cost: 35),
            LuxPalette(id: "onyx",    name: "Onyx",     swatch: Color(hex: "0A0D12"), cost: 50),
            LuxPalette(id: "lichen",  name: "Lichen",   swatch: Color(hex: "8A9A7B"), cost: 70),
        ]
    }

    // MARK: - Export helpers

    #if canImport(UIKit)
    @MainActor
    private func renderShareImage() {
        let heatCells = (0..<70).map { i -> (key: String, count: Int) in
            let key = DateKey.add(-(69 - i), to: DateKey.today())
            let count = store.state.log[key]?.sessionCount ?? 0
            return (key, count)
        }
        let card = StreakShareCard(
            streak: store.state.currentStreak,
            totalDays: store.state.totalDaysCompleted,
            masteredCount: store.state.scrolls.filter { $0.status == .mastered }.count,
            heatCells: heatCells
        )
        let renderer = ImageRenderer(content: card)
        renderer.scale = displayScale
        if let ui = renderer.uiImage {
            shareImage = Image(uiImage: ui)
        }
    }

    private func renderAndShareSnapshot() {
        guard let img = shareImage else { return }
        // ShareLink needs to be in a view; fall back to UIActivityViewController
        let renderer = ImageRenderer(content: img)
        renderer.scale = displayScale
        guard let ui = renderer.uiImage else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TenScrolls_Streak.png")
        try? ui.pngData()?.write(to: url)
        exportURL = url
    }

    /// The Commonplace Book PDF is a full transcript of every scroll's
    /// notes (see `CommonplaceBook`'s doc comment) — the same Plus-gated
    /// scroll content as reading a scroll in-app, just exported. Gated via
    /// AppFeature.commonplaceExport, same as opening a scroll
    /// (`ContentView.attemptOpenScroll`) so it can't be used to route
    /// around that gate.
    private func exportCommonplace() {
        guard store.isAccessible(.commonplaceExport) else {
            store.shouldShowDay30Paywall = true
            return
        }
        if let url = CommonplaceBook.makePDF(state: store.state, themeColor: LuxColor.gold) {
            exportURL = url
        } else {
            exportError = true
        }
    }
    #endif
}

// MARK: - Theme Selector (Appearance segmented control)

/// Custom 3-option pill for Light / Dark / System — replaces the old HStack
/// of buttons; gold fill on active, `#1C212E` bg on inactive.
private struct ThemeSelectorView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                let selected = store.state.appearanceMode == mode
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        store.setAppearanceMode(mode)
                    }
                } label: {
                    Text(mode.label)
                        .font(LuxFont.sans(10, weight: selected ? .semibold : .regular))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(selected ? LuxColor.gold : LuxColor.cardBorder)
                        .foregroundColor(selected ? .black : LuxColor.textSecondary)
                }
                .buttonStyle(.plain)
                if mode != AppearanceMode.allCases.last {
                    Rectangle()
                        .fill(LuxColor.cardBorder)
                        .frame(width: 0.5)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(LuxColor.cardBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - Palette Swatch

struct LuxPalette: Identifiable {
    let id: String
    let name: String
    let swatch: Color
    let cost: Int
}

private struct PaletteSwatchView: View {
    @EnvironmentObject var store: AppStore
    let palette: LuxPalette
    let sealsAvailable: Int

    private var isEquipped: Bool { store.state.activeThemeId == palette.id }
    private var isOwned: Bool { store.state.unlockedThemeIds.contains(palette.id) || palette.cost == 0 }
    private var canAfford: Bool { sealsAvailable >= palette.cost }

    var body: some View {
        VStack(spacing: 8) {
            // Swatch
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.swatch)
                .frame(height: 52)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isEquipped ? LuxColor.gold : LuxColor.cardBorder, lineWidth: isEquipped ? 1 : 0.5)
                )

            Text(palette.name)
                .font(LuxFont.serif(12))
                .foregroundColor(LuxColor.textPrimary)

            // Status label
            Group {
                if isEquipped {
                    Text("EQUIPPED")
                        .foregroundColor(LuxColor.gold)
                } else if isOwned {
                    Button("Equip") { store.equipTheme(palette.id) }
                        .foregroundColor(LuxColor.goldMuted)
                } else {
                    Button {
                        store.unlockTheme(palette.id)
                    } label: {
                        Text("\(palette.cost) SEALS")
                            .foregroundColor(canAfford ? LuxColor.gold : LuxColor.textMuted)
                    }
                    .disabled(!canAfford)
                    .opacity(canAfford ? 1 : 0.4)
                }
            }
            .font(LuxFont.mono(10))
            .tracking(0.5)
        }
    }
}

// MARK: - Streak share card (Lux dark palette)

#if canImport(UIKit)
private struct StreakShareCard: View {
    let streak: Int
    let totalDays: Int
    let masteredCount: Int
    let heatCells: [(key: String, count: Int)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("TEN SCROLLS")
                .font(LuxFont.sans(11, weight: .medium))
                .tracking(1.8)
                .foregroundColor(LuxColor.goldMuted)
            Text("\(streak) day streak")
                .font(LuxFont.serif(30))
                .foregroundColor(LuxColor.textPrimary)
            Text("\(totalDays) of 300 days \u{00B7} \(masteredCount) of 10 mastered")
                .font(LuxFont.mono(11))
                .foregroundColor(LuxColor.textSecondary)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 10),
                spacing: 4
            ) {
                ForEach(heatCells, id: \.key) { cell in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(cell.count > 0 ? LuxColor.gold : LuxColor.cardBorder)
                        .aspectRatio(1, contentMode: .fit)
                }
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(LuxColor.bg)
    }
}
#endif

// MARK: - Preview

#Preview {
    SettingsView()
        .environmentObject(AppStore())
}
