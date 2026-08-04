import SwiftUI

/// The "one-way mirror" - shows free users their percentile and cheer count
/// but not exact rank or other traders' identities. Updates live as the
/// population shifts, creating awareness without full access.
struct PartialRevealLeaderboardCard: View {
    let percentile: Int
    let populationCount: Int
    let cheerCount: Int
    let onUpgrade: () -> Void
    /// Themed accent, matching whichever theme the reader has equipped
    /// elsewhere in the app (see `Palette.theme(for:).brass`). Defaults to
    /// the default Brass theme so the view still previews standalone.
    var brass: Color = Palette.themes[0].brass
    /// Established "text on brass" color used by `PrimaryButtonStyle` in
    /// Components.swift, reused here for the upgrade button's label.
    private let onBrass = Color(hex: "1A1207")
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Caravan Leaderboard")
                        .font(.headline)
                    
                    // Deliberately no headcount here — the total number of
                    // traders on the leaderboard is itself part of what's
                    // locked behind Plus, not just identities/exact ranks.
                    Text("Locked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.ultraThinMaterial)
            
            Divider()
            
            // Percentile display
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Text("Top \(100 - percentile)%")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(brass)
                    
                    Text("You're doing better than \(percentile)% of traders")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 24)
                
                // Cheers received
                if cheerCount > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "hands.clap.fill")
                            .foregroundStyle(brass)
                        
                        Text("\(cheerCount) cheers received")
                            .font(.subheadline)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background {
                        Capsule()
                            .fill(brass.opacity(0.1))
                    }
                }
                
                // Upgrade prompt
                VStack(spacing: 12) {
                    Text("Unlock Plus to see your exact rank")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button {
                        onUpgrade()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.caption)
                            Text("Upgrade to Plus")
                                .font(.subheadline.bold())
                        }
                        .foregroundStyle(onBrass)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background {
                            Capsule()
                                .fill(brass)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .padding(.horizontal)
            .frame(maxWidth: .infinity)
        }
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.background)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(brass.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
    }
}

#Preview {
    VStack {
        PartialRevealLeaderboardCard(
            percentile: 72,
            populationCount: 156,
            cheerCount: 3,
            onUpgrade: {}
        )
        .padding()
    }
    .preferredColorScheme(.dark)
}

