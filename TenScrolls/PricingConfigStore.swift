import Foundation
import Supabase

/// Immutable snapshot of the `pricing_config` table — mirrored into
/// `AppStore.pricingConfigSnapshot` (via `PricingConfigStore.snapshot()`)
/// so paywall views can read it synchronously without an actor hop, same
/// pattern as `FeatureGateStore`/`AppStore.featureGateOverrides`.
///
/// Deliberately doesn't carry price *amounts* — those only ever come from
/// StoreKit itself (`StoreKitManager.displayPrice(for:)`), since Apple's
/// platform locks the actual charged price to what's configured in App
/// Store Connect. This controls everything else about how pricing is
/// presented: trial length, which plan is pre-selected, marketing badges,
/// and which of the three products (see `StoreKitManager.allProductIDs`)
/// are actually offered right now.
struct PricingConfig: Codable, Equatable, Sendable {
    let trialDays: Int
    let featuredProductId: String
    let activeProductIds: [String]
    let badges: [String: String]

    /// Compiled-in fallback for a fresh install that hasn't reached the
    /// network yet, or is offline at launch with no previous cache. Must
    /// stay in sync with the seeded row in `009_pricing_config.sql` — the
    /// live table is what actually governs behavior once reachable, same
    /// "table always wins once it's reachable" rule as
    /// `AppFeature.defaultRequiresPlus`.
    static let compiledDefault = PricingConfig(
        trialDays: 10,
        featuredProductId: "ekme.TenScrolls.plus.annual",
        activeProductIds: StoreKitManager.allProductIDs,
        badges: ["ekme.TenScrolls.plus.annual": "BEST VALUE"]
    )

    /// Badge text for `productId`, or `nil` if this plan has none — most
    /// won't. See `product_badges` in the migration.
    func badge(for productId: String) -> String? {
        badges[productId]
    }
}

/// Loads and caches the `pricing_config` table — the live,
/// Eamon-editable control center for trial length, the featured plan, plan
/// badges, and which products are currently offered. Three-layer
/// fallback, cheapest/most-reliable first, identical in shape to
/// `FeatureGateStore`:
///
///   1. In-memory `config` from the most recent successful fetch this
///      launch.
///   2. `UserDefaults`-cached copy of the last successful fetch from any
///      previous launch — survives being offline at launch.
///   3. `PricingConfig.compiledDefault` — the compiled-in fallback, used
///      only when neither of the above exists yet (a totally fresh
///      install that has never reached the network).
///
/// Deliberately synchronous-feeling reads via `snapshot()` so call sites
/// never block on a network round trip mid-UI-interaction — `refresh()` is
/// what does the actual fetching, called from `AppStore.init` and
/// `AppStore.onAppForeground()`, same cadence as `FeatureGateStore.refresh()`.
actor PricingConfigStore {
    private static let cacheKey = "pricing-config-cache-v1"

    private var config: PricingConfig

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(PricingConfig.self, from: data) {
            config = cached
        } else {
            config = .compiledDefault
        }
    }

    /// Fetches the live table via `get_pricing_config()` and updates both
    /// the in-memory and on-disk cache. Best-effort — a failure here just
    /// means callers keep using whatever's already cached (or the compiled
    /// default), same "stale is fine, never block" pattern as
    /// `FeatureGateStore.refresh()`.
    func refresh() async {
        struct Row: Decodable {
            let trial_days: Int
            let featured_product_id: String
            let active_product_ids: [String]
            let product_badges: [String: String]
        }
        do {
            let rows: [Row] = try await SupabaseConfig.client
                .rpc("get_pricing_config")
                .execute()
                .value
            guard let row = rows.first else { return }
            let next = PricingConfig(
                trialDays: row.trial_days,
                featuredProductId: row.featured_product_id,
                activeProductIds: row.active_product_ids,
                badges: row.product_badges
            )
            config = next
            if let encoded = try? JSONEncoder().encode(next) {
                UserDefaults.standard.set(encoded, forKey: Self.cacheKey)
            }
        } catch {
            // Best effort — keep whatever's cached.
        }
    }

    /// Current snapshot — see `AppStore.pricingConfigSnapshot`, the
    /// `@Published` mirror views actually read from.
    func snapshot() -> PricingConfig {
        config
    }
}
