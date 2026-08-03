import SwiftUI

/// Day 30 paywall - blocks access to Scroll II and beyond for free users.
/// Copy anchored to accumulated stats and percentile to create FOMO.
struct Day30PaywallView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var isActivating = false
    @State private var percentile: Int? = nil
    /// Localized price from StoreKit (e.g. "$4.99/mo"), replacing the
    /// hardcoded "$4.99/month" once the product has loaded. Falls back to
    /// the hardcoded string while `nil`, so the paywall never shows a blank.
    @State private var storePrice: String? = nil

    private var theme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }

    var body: some View {
        ZStack {
            // Background
            Color.black.opacity(0.8)
                .ignoresSafeArea()
            
            // Card
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "lock.seal.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(theme.brass)
                    
                    Text("You've reached Day 30")
                        .font(.title.bold())
                    
                    if let percentile {
                        Text("You're in the top \(100 - percentile)%")
                            .font(.title3.bold())
                            .foregroundStyle(theme.brass)
                    }
                }
                .padding(.top, 40)
                .padding(.bottom, 24)
                
                Divider()
                    .padding(.horizontal)
                
                // Stats
                VStack(spacing: 16) {
                    StatRow(label: "Streak", value: "\(store.state.currentStreak) days")
                    StatRow(label: "Total XP", value: "\(store.state.totalXP)")
                    StatRow(label: "Level", value: store.state.levelInfo().rank)
                    
                    if let percentile {
                        StatRow(label: "Rank", value: "Top \(100 - percentile)%")
                    }
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 32)
                
                Divider()
                    .padding(.horizontal)
                
                // Message
                VStack(spacing: 8) {
                    Text("Unlock Plus to see where you really stand")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    
                    Text("Continue to Scroll II and see your exact rank on the leaderboard")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 24)
                
                // Pricing
                Text(storePrice ?? "$4.99/month")
                    .font(.title2.bold())
                
                Text("Cancel anytime")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 24)
                
                // Actions
                VStack(spacing: 12) {
                    Button {
                        upgradeToPlus()
                    } label: {
                        if isActivating {
                            ProgressView()
                        } else {
                            Text("Upgrade to Plus")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(brass: theme.brass, glow: theme.glow, disabled: isActivating))
                    .disabled(isActivating)
                    
                    Button("Not now") {
                        dismiss()
                        store.dismissDay30Paywall()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .frame(maxWidth: 420)
            .background {
                RoundedRectangle(cornerRadius: 20)
                    .fill(.background)
                    .shadow(radius: 24)
            }
            .padding(.horizontal, 32)
        }
        .task {
            await fetchPercentile()
            storePrice = await StoreKitManager.shared.displayPrice()
        }
    }
    
    private func fetchPercentile() async {
        // Try to get user's percentile from tiered leaderboard
        do {
            let entries = try await store.subscription.fetchTieredLeaderboard(limit: 1)
            if let entry = entries.first, entry.isPartialReveal {
                percentile = entry.percentile
            }
        } catch {
            // Ignore error, just don't show percentile
        }
    }
    
    /// Runs the real App Store purchase sheet via `StoreKitManager`, then
    /// only calls `AppStore.activateSubscription()` (which flips the
    /// server-side `subscription_status` to `active`) once StoreKit confirms
    /// a verified purchase — a cancelled or pending purchase leaves the paywall
    /// open with no state change, same as tapping "Not now" would, since
    /// there's nothing to activate yet.
    private func upgradeToPlus() {
        isActivating = true
        Task {
            do {
                let outcome = try await StoreKitManager.shared.purchase()
                if case .success(let signedTransaction) = outcome {
                    let success = await store.activateSubscription(signedTransaction: signedTransaction)
                    if success {
                        dismiss()
                    }
                }
            } catch {
                store.showToast("Purchase failed. Please try again.")
            }
            isActivating = false
        }
    }
}

struct StatRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Text(value)
                .font(.body.bold())
        }
    }
}

#Preview {
    Day30PaywallView()
        .environmentObject(AppStore())
}

