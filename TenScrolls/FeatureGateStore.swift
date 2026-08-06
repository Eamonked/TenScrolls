import Foundation
import Supabase

/// Loads and caches the `feature_gates` table — the live, Eamon-editable
/// override of `AppFeature.defaultRequiresPlus`. Three-layer fallback,
/// cheapest/most-reliable first:
///
///   1. In-memory `overrides` from the most recent successful fetch this
///      launch.
///   2. `UserDefaults`-cached copy of the last successful fetch from any
///      previous launch — survives being offline at launch.
///   3. `AppFeature.defaultRequiresPlus` — the compiled-in fallback, used
///      for any key missing from both of the above (a brand new feature
///      added to the app before its row exists in Supabase, or a totally
///      fresh install that has never reached the network).
///
/// Deliberately synchronous reads (`requiresPlus(_:)`) so call sites never
/// block on a network round trip mid-UI-interaction — `refresh()` is what
/// does the actual fetching, called from `AppStore.onAppForeground()` and
/// once at launch, same cadence as subscription status.
actor FeatureGateStore {
    private static let cacheKey = "feature-gates-cache-v1"

    private var overrides: [String: Bool] = [:]

    init() {
        if let cached = UserDefaults.standard.dictionary(forKey: Self.cacheKey) as? [String: Bool] {
            overrides = cached
        }
    }

    /// Fetches the live table via `get_feature_gates()` and updates both
    /// the in-memory and on-disk cache. Best-effort — a failure here just
    /// means callers keep using whatever's already cached (or the compiled
    /// defaults), same "stale is fine, never block" pattern as
    /// `refreshSubscriptionStatus()`.
    func refresh() async {
        struct Row: Decodable {
            let feature_key: String
            let requires_plus: Bool
        }
        do {
            let rows: [Row] = try await SupabaseConfig.client
                .rpc("get_feature_gates")
                .execute()
                .value
            var next: [String: Bool] = [:]
            for row in rows { next[row.feature_key] = row.requires_plus }
            overrides = next
            UserDefaults.standard.set(next, forKey: Self.cacheKey)
        } catch {
            // Best effort — keep whatever's cached.
        }
    }

    /// Whether `feature` currently requires Plus, per the live table if
    /// it's been fetched (this launch or a previous one), else the
    /// compiled-in default. This alone doesn't grant or deny access — see
    /// `AppStore.isAccessible(_:)`, which ANDs this against the reader's
    /// actual subscription status.
    func requiresPlus(_ feature: AppFeature) -> Bool {
        overrides[feature.rawValue] ?? feature.defaultRequiresPlus
    }

    /// Full snapshot for a debug/admin display — see any future settings
    /// screen that wants to show current gating state without exposing
    /// write access (writes stay dashboard-only; see the migration).
    func allGates() -> [(feature: AppFeature, requiresPlus: Bool)] {
        AppFeature.allCases.map { ($0, requiresPlus($0)) }
    }

    /// Dictionary form of `allGates()`, keyed by `AppFeature.rawValue` —
    /// what `AppStore` mirrors into its own `@Published` cache so views can
    /// read gate state synchronously. See `AppStore.refreshFeatureGates()`.
    func snapshot() -> [String: Bool] {
        var result: [String: Bool] = [:]
        for feature in AppFeature.allCases {
            result[feature.rawValue] = requiresPlus(feature)
        }
        return result
    }
}
