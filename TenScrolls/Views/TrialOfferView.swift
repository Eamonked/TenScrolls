import SwiftUI

/// Day 3 trial offer - presented after 3 consecutive days completed.
/// Framed as "joining the Caravan" rather than a traditional upsell,
/// matching the book's tone and the app's calm aesthetic.
struct TrialOfferView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var isStarting = false

    private var theme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    var body: some View {
        ZStack {
            // Background
            Color.black.opacity(0.6)
                .ignoresSafeArea()
            
            // Card
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "figure.walk.motion")
                        .font(.system(size: 48))
                        .foregroundStyle(theme.brass)
                    
                    Text("Join the Caravan")
                        .font(.title2.bold())
                    
                    Text("You've completed 3 days in a row")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 32)
                .padding(.bottom, 24)
                
                Divider()
                    .padding(.horizontal)
                
                // Benefits
                VStack(alignment: .leading, spacing: 16) {
                    BenefitRow(
                        icon: "chart.bar.fill",
                        title: "See where you stand",
                        description: "Full leaderboard access and exact rank",
                        brass: theme.brass
                    )
                    
                    BenefitRow(
                        icon: "scroll.fill",
                        title: "Unlock all scrolls",
                        description: "Continue past Scroll I without limits",
                        brass: theme.brass
                    )
                    
                    BenefitRow(
                        icon: "person.2.fill",
                        title: "Connect with traders",
                        description: "Full access to friends and reading groups",
                        brass: theme.brass
                    )
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 24)
                
                Divider()
                    .padding(.horizontal)
                
                // Trial info
                Text("Try Plus free for 10 days")
                    .font(.subheadline.bold())
                    .padding(.top, 16)
                
                Text("Then $4.99/month. Cancel anytime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 24)
                
                // Actions
                VStack(spacing: 12) {
                    Button {
                        startTrial()
                    } label: {
                        if isStarting {
                            ProgressView()
                        } else {
                            Text("Start Free Trial")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(brass: theme.brass, glow: theme.glow, disabled: isStarting))
                    .disabled(isStarting)
                    
                    Button("Maybe later") {
                        dismiss()
                        store.dismissTrialOffer()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: 400)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.background)
                    .shadow(radius: 20)
            }
            .padding(.horizontal, 32)
        }
    }
    
    private func startTrial() {
        isStarting = true
        Task {
            let success = await store.startTrial()
            isStarting = false
            if success {
                dismiss()
            }
        }
    }
}

struct BenefitRow: View {
    let icon: String
    let title: String
    let description: String
    /// Themed accent for the icon. Defaults to the Brass theme so this
    /// still previews standalone without a `theme` in scope.
    var brass: Color = Palette.themes[0].brass
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(brass)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer(minLength: 0)
        }
    }
}

#Preview {
    TrialOfferView()
        .environmentObject(AppStore())
}

