import SwiftUI

/// Full-screen celebration shown the instant all three sessions (dawn,
/// midday, dusk) are completed for the day — see `AppStore.dayComplete`.
/// The teardown's "Day 16 of 30 sealed" moment: bigger than a `+20 XP`
/// toast, and the one place the System layer (XP) is allowed to show up
/// inside what is otherwise a celebration of the ritual, not the points.
struct DayCompleteView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.appearanceMode) var appearanceMode
    @Environment(\.dismiss) private var dismiss

    var theme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    /// XP earned purely from today's three sessions (10 each + the 20
    /// all-complete bonus) — mirrors `AppState.totalXP`'s per-day math
    /// without re-deriving the reader's lifetime total here.
    private var todaysSessionXP: Int { 3 * 10 + 20 }

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        ZStack {
            colors.background.ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [theme.glow, theme.brass], center: .init(x: 0.35, y: 0.3), startRadius: 4, endRadius: 60))
                        .frame(width: 108, height: 108)
                        .shadow(color: theme.glow.opacity(0.5), radius: 24)
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 40))
                        .foregroundColor(Color(hex: "1A1207"))
                }

                VStack(spacing: 8) {
                    Text("DAY \(min(store.state.totalDaysCompleted, 300)) SEALED")
                        .font(AppFont.mono(13))
                        .tracking(3)
                        .foregroundColor(theme.brass)
                    Text("The caravan rests.")
                        .font(AppFont.display(28))
                        .foregroundColor(colors.text)
                    Text("Dawn, midday, and dusk — all three kept. Tomorrow the journey continues.")
                        .font(.system(size: 14))
                        .foregroundColor(colors.textDim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 34)
                }

                HStack(spacing: 0) {
                    metric("\(store.state.currentStreak)", "day streak")
                    metric("+\(todaysSessionXP)", "XP earned")
                }
                .padding(.top, 6)

                Spacer()

                Button("Continue") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle(brass: theme.brass, glow: theme.glow))
                    .padding(.horizontal, 40)
                    .padding(.bottom, 24)
            }
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        return VStack(spacing: 2) {
            Text(value).font(AppFont.display(20)).foregroundColor(colors.text)
            Text(label.uppercased()).font(AppFont.mono(10)).tracking(1).foregroundColor(colors.textFaint)
        }
        .frame(maxWidth: .infinity)
    }
}
