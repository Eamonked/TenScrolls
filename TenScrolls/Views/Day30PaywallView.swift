import SwiftUI

/// Plus paywall — blocks scroll view/read/edit access for free users.
/// Presented both the moment a free reader tries to open *any* scroll
/// (`ContentView.attemptOpenScroll`, from Day 1 — scroll content is
/// prefilled/curated, not reader-authored) and, for readers who crossed 30
/// days before this policy, the legacy Day 30 trigger
/// (`AppState.shouldShowDay30Paywall`). Copy adapts to whichever applies:
/// stats-and-percentile FOMO once there's real progress to show, a plainer
/// "unlock to start reading" framing before then.
struct Day30PaywallView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var isActivating = false
    @State private var percentile: Int? = nil
    /// Localized price per plan (e.g. `"ekme.TenScrolls.plus.annual":
    /// "$39.99/yr"`), keyed by product id, replacing the old single
    /// hardcoded "$4.99/month" string now that the paywall offers every
    /// plan in `pricingConfigSnapshot.activeProductIds`, not just monthly.
    /// A missing entry (still loading) shows an ellipsis placeholder rather
    /// than a blank row.
    @State private var planPrices: [String: String] = [:]
    /// Which plan is currently chosen — defaults to
    /// `pricingConfigSnapshot.featuredProductId` once that's loaded (see
    /// `.task` below), so the paywall opens with the plan Eamon wants
    /// highlighted already selected rather than requiring a tap.
    @State private var selectedProductId: String? = nil

    private var theme: ThemeOption { Palette.theme(for: store.state.activeThemeId) }
    /// Whether there's any accumulated progress worth anchoring FOMO copy
    /// to. False for a reader hitting this paywall on Day 1 by trying to
    /// open a scroll before ever completing a day.
    private var hasProgress: Bool { store.state.totalDaysCompleted > 0 }

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
                    
                    Text(hasProgress ? "You've reached Day 30" : "Ten Scrolls is a Plus experience")
                        .font(.title.bold())
                    
                    if let percentile, hasProgress {
                        Text("You're in the top \(100 - percentile)%")
                            .font(.title3.bold())
                            .foregroundStyle(theme.brass)
                    }
                }
                .padding(.top, 40)
                .padding(.bottom, 24)
                
                Divider()
                    .padding(.horizontal)
                
                // Stats — only shown once there's real progress to anchor them
                // to; a Day 1 reader has nothing here worth showing yet.
                if hasProgress {
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
                }
                
                // Message
                VStack(spacing: 8) {
                    Text(hasProgress ? "Unlock Plus to see where you really stand" : "Every scroll is written and curated — not something you fill in yourself")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    
                    Text(hasProgress ? "Continue to Scroll II and see your exact rank on the leaderboard" : "Subscribe to read, and see your rank on the Caravan leaderboard")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 24)
                
                // Pricing — one row per plan currently offered
                // (`pricingConfigSnapshot.activeProductIds`), each showing
                // StoreKit's own live price and, for the featured plan,
                // its badge (e.g. "BEST VALUE") from `pricingConfigSnapshot`.
                VStack(spacing: 10) {
                    ForEach(store.pricingConfigSnapshot.activeProductIds, id: \.self) { productId in
                        planRow(productId)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)

                Text("Cancel anytime")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
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
            let offered = store.pricingConfigSnapshot.activeProductIds
            selectedProductId = offered.contains(store.pricingConfigSnapshot.featuredProductId)
                ? store.pricingConfigSnapshot.featuredProductId
                : offered.first
            for productId in offered {
                planPrices[productId] = await StoreKitManager.shared.displayPrice(for: productId)
            }
        }
    }

    /// One selectable plan row: label ("Monthly"/"Annual"/"Lifetime"),
    /// StoreKit's live price, and an optional badge from
    /// `pricingConfigSnapshot.badges`. Tapping selects it for
    /// `upgradeToPlus()`; the current selection is highlighted with the
    /// theme's brass accent.
    private func planRow(_ productId: String) -> some View {
        let isSelected = selectedProductId == productId
        return Button {
            selectedProductId = productId
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(planLabel(for: productId))
                            .font(.subheadline.bold())
                        if let badge = store.pricingConfigSnapshot.badge(for: productId) {
                            Text(badge)
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(theme.brass.opacity(0.18))
                                .foregroundStyle(theme.brass)
                                .clipShape(Capsule())
                        }
                    }
                    Text(planPrices[productId] ?? "\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? theme.brass : Color.secondary)
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? theme.brass : Color.secondary.opacity(0.3), lineWidth: isSelected ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
    }

    /// Human-readable label derived from the product id's suffix — every
    /// id in `StoreKitManager.allProductIDs` ends in one of these three.
    private func planLabel(for productId: String) -> String {
        if productId.hasSuffix(".monthly") { return "Monthly" }
        if productId.hasSuffix(".annual") { return "Annual" }
        if productId.hasSuffix(".lifetime") { return "Lifetime" }
        return "Plus"
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
                let productId = selectedProductId ?? StoreKitManager.subscriptionProductID
                let outcome = try await StoreKitManager.shared.purchase(productId: productId)
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

