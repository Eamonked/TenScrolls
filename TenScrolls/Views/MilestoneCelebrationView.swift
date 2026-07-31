import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Full-screen celebration shown the moment a streak milestone (7/14/30/60/
/// 100 days) is newly reached — see `AppStore.milestoneReached`. Offers the
/// Streak Seal share action right at the moment it's most likely to be used,
/// rather than only tucked away in the Caravan tab or weekly recap.
struct MilestoneCelebrationView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.appearanceMode) var appearanceMode
    @Environment(\.dismiss) private var dismiss

    let milestone: Int

    var theme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    #if canImport(UIKit)
    @State private var shareImage: UIImage?
    @State private var showShare = false
    #endif

    var body: some View {
        let colors = AdaptivePalette(mode: appearanceMode)
        ZStack {
            colors.background.ignoresSafeArea()

            VStack(spacing: 26) {
                Spacer()

                Image(systemName: "flame.fill")
                    .font(.system(size: 54))
                    .foregroundColor(theme.brass)
                    .shadow(color: theme.glow.opacity(0.6), radius: 20)

                VStack(spacing: 8) {
                    Text("\(milestone)-DAY STREAK")
                        .font(AppFont.mono(13))
                        .tracking(3)
                        .foregroundColor(theme.brass)
                    Text(milestoneLine)
                        .font(AppFont.display(28))
                        .foregroundColor(colors.text)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }

                Spacer()

                #if canImport(UIKit)
                Button {
                    shareImage = ShareCard.renderImage(
                        traderName: store.state.traderName,
                        streak: store.state.currentStreak,
                        level: store.state.levelInfo().level,
                        rank: store.state.levelInfo().rank,
                        theme: theme
                    )
                    showShare = shareImage != nil
                } label: {
                    Label("Share your streak", systemImage: "square.and.arrow.up.on.square")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(colors.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(theme.brass)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 24)
                #endif

                Button("Continue") { dismiss() }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(colors.textDim)
                    .padding(.bottom, 20)
            }
        }
        #if canImport(UIKit)
        .sheet(isPresented: $showShare) {
            if let shareImage {
                ActivityShareSheet(items: [shareImage])
            }
        }
        #endif
    }

    private var milestoneLine: String {
        switch milestone {
        case 7: return "One full week of showing up."
        case 14: return "Two weeks deep. This is becoming who you are."
        case 30: return "A month of discipline. Iron Will earned."
        case 60: return "Sixty days. Most people never make it here."
        case 100: return "The century mark. Legendary Trader."
        default: return "\(milestone) days and counting."
        }
    }
}
