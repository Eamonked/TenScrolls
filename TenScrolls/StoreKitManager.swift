import Foundation
import StoreKit

/// Wraps StoreKit 2's purchase flow for the TenScrolls Plus subscription.
///
/// The free trial (length controlled by the `pricing_config` table — see
/// `PricingConfigStore`) is handled entirely server-side (see
/// `SupabaseSubscription.startTrial()` / the `start_trial` RPC) and never
/// touches StoreKit at all — this manager is only exercised at the paid-
/// conversion moment (the Day 30 paywall, or an early upgrade from the
/// Caravan's partial-reveal leaderboard card), where a real purchase has to
/// clear before `AppStore.activateSubscription()` is allowed to flip the
/// server-side `subscription_status` to `active`.
actor StoreKitManager {
    static let shared = StoreKitManager()

    /// The monthly product's ID — kept as a named fallback for any call
    /// site that hasn't been updated to think in terms of multiple plans
    /// yet (e.g. `hasActiveEntitlement()`'s reconciliation logic, which
    /// checks "is *any* Plus product active" and doesn't care which one).
    /// Must match a Product ID configured in App Store Connect (and in
    /// `Configuration.storekit` for simulator/sandbox testing) exactly.
    /// The actual set of products offered to a given reader now comes from
    /// `PricingConfigStore`/the `pricing_config` table — see
    /// `loadProducts(ids:)`.
    static let subscriptionProductID = "ekme.TenScrolls.plus.monthly"

    /// Every product ID this app could ever charge for — monthly, annual,
    /// lifetime. `hasActiveEntitlement()`/`currentEntitlementJWS()` check
    /// against all of these (a reader who bought annual is just as "Plus"
    /// as one who bought monthly), independent of which subset
    /// `pricing_config.active_product_ids` currently offers to new
    /// signups. A product removed from the offered set later must still be
    /// recognized here, or an existing subscriber on that plan would stop
    /// being recognized as entitled.
    static let allProductIDs = [
        "ekme.TenScrolls.plus.monthly",
        "ekme.TenScrolls.plus.annual",
        "ekme.TenScrolls.plus.lifetime",
    ]

    private var products: [Product] = []

    private init() {}
    enum StoreError: Error {
        case productNotFound
        case failedVerification
    }

    /// Outcome of `purchase()`. `.success` carries the transaction's raw
    /// signed JWS (`Transaction.jwsRepresentation`) — the payload
    /// `verify-purchase` needs to independently re-verify the purchase
    /// against Apple's own certificates server-side. `VerificationResult`
    /// having already checked out locally proves the transaction is
    /// genuine to *this device*, but the server can't trust a bare `Bool`
    /// over the wire — it has to see (and verify) the signed payload itself.
    enum PurchaseOutcome {
        case success(signedTransaction: String)
        case userCancelledOrPending
    }

    /// Fetches every product in `allProductIDs` from the App Store in one
    /// call, regardless of which ones `subscription_plans` currently marks
    /// `active` — cheap (one StoreKit round trip either way) and means
    /// `hasActiveEntitlement()` can recognize a subscriber on a plan that's
    /// since been deactivated for new signups. Safe to call repeatedly — a
    /// no-op once `products` is already populated, and safe to retry if an
    /// earlier attempt failed (e.g. no network at launch).
    func loadProducts() async throws {
        guard products.isEmpty else { return }
        products = try await Product.products(for: Self.allProductIDs)
    }

    /// Fetches only the products in `ids` — the "offered" subset
    /// `PricingConfigStore` currently marks active, rather than every
    /// product this app could ever charge for. Paywall views that want to
    /// render a specific plan list should call this (or just go straight to
    /// `displayPrice(for:)`/`product(for:)`, which lazily call
    /// `loadProducts()` — the *all-products* fetch — if `products` is still
    /// empty, so this isn't strictly required before them).
    ///
    /// Merges into the same `products` cache `loadProducts()` populates —
    /// `hasActiveEntitlement()`/`currentEntitlementJWS()` (which check
    /// against `allProductIDs` regardless of what's currently offered) keep
    /// working correctly no matter which method populated the cache first.
    /// Only fetches ids not already present, so calling this repeatedly
    /// with an overlapping set is cheap.
    func loadProducts(ids: [String]) async throws {
        let missing = ids.filter { id in !products.contains(where: { $0.id == id }) }
        guard !missing.isEmpty else { return }
        let fetched = try await Product.products(for: missing)
        products.append(contentsOf: fetched)
    }

    /// The subscription's localized price/period (e.g. "$4.99/mo"), for
    /// display in the paywall in place of the hardcoded "$4.99/month" text.
    /// `nil` until a product fetch has succeeded at least once. Defaults to
    /// the monthly product for any call site not yet updated to ask for a
    /// specific plan — see `displayPrice(for:)`.
    func displayPrice() async -> String? {
        await displayPrice(for: Self.subscriptionProductID)
    }

    /// Per-plan localized price/period, e.g. `displayPrice(for:
    /// "ekme.TenScrolls.plus.annual")` → "$39.99/yr". Backs the paywall's
    /// plan list (see `Day30PaywallView`) so every price shown is always
    /// Apple's own live-fetched figure, never a hardcoded string that could
    /// drift from what's actually charged.
    func displayPrice(for productId: String) async -> String? {
        if products.isEmpty { try? await loadProducts() }
        return products.first(where: { $0.id == productId })?.displayPrice
    }

    /// The full `Product` for a given id, e.g. for a paywall that wants the
    /// subscription period, introductory offer, or other StoreKit metadata
    /// beyond just the display string.
    func product(for productId: String) async -> Product? {
        if products.isEmpty { try? await loadProducts() }
        return products.first(where: { $0.id == productId })
    }

    /// Runs the actual App Store purchase sheet for `productId` and
    /// verifies the result *locally* (StoreKit's on-device check against
    /// Apple's signature). Returns the transaction's signed JWS on success
    /// — callers must send this to
    /// `SupabaseSubscription.activateSubscription(signedTransaction:)`,
    /// which re-verifies it server-side before flipping
    /// `subscription_status` to `active`. Local verification alone is not
    /// sufficient to activate anything: it proves the purchase to this
    /// device, not to the server. Returns `.userCancelledOrPending` for a
    /// user cancellation or a pending purchase (e.g. Ask to Buy) — neither
    /// is an error, there's just nothing to activate yet.
    @discardableResult
    func purchase(productId: String = StoreKitManager.subscriptionProductID) async throws -> PurchaseOutcome {
        // Already entitled on *some* Plus product — hand back that
        // transaction's JWS instead of calling product.purchase() again,
        // which is exactly what triggers StoreKit's "You're currently
        // subscribed to this" system alert and then never resolves through
        // the .success branch below. Deliberately checks any product, not
        // just `productId`: someone who already owns annual shouldn't hit
        // that alert just because the paywall's selection defaulted to
        // monthly.
        if let existingJWS = await currentEntitlementJWS() {
            return .success(signedTransaction: existingJWS)
        }

        if products.isEmpty { try await loadProducts() }
        guard let product = products.first(where: { $0.id == productId }) else {
            throw StoreError.productNotFound
        }

        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            let jws = verification.jwsRepresentation
            await transaction.finish()
            return .success(signedTransaction: jws)
        case .userCancelled, .pending:
            return .userCancelledOrPending
        @unknown default:
            return .userCancelledOrPending
        }
    }

    /// Whether the App Store already reports an active entitlement for
    /// *any* Plus product (monthly, annual, or lifetime) on this Apple ID —
    /// lets a reinstall, or a purchase completed on another device signed
    /// into the same account, reconcile without the user having to tap
    /// "Upgrade" again, regardless of which plan they're actually on.
    /// Doesn't itself call `activateSubscription()`; callers decide what to
    /// do with the result.
    func hasActiveEntitlement() async -> Bool {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.allProductIDs.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            return true
        }
        return false
    }

    /// Like `hasActiveEntitlement()`, but returns the transaction's signed
    /// JWS instead of a bare `Bool`, so callers can activate against it the
    /// same way a fresh purchase would. Covers reinstalls, restores, and —
    /// critically — the case where StoreKit already considers this Apple ID
    /// subscribed on *any* Plus product (e.g. a previous purchase finished
    /// on-device but never activated server-side, or an active entitlement
    /// carried over from an earlier test run) and intercepts
    /// `product.purchase()` with its own "You're currently subscribed to
    /// this" system alert before the purchase can ever resolve through
    /// `.success` below.
    func currentEntitlementJWS() async -> String? {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.allProductIDs.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            return result.jwsRepresentation
        }
        return nil
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }

    /// Long-lived listener for StoreKit transaction updates — renewals,
    /// revocations, refunds, Ask to Buy resolutions — for as long as this
    /// runs. Meant to be started once as a detached, non-awaited `Task` for
    /// the app's lifetime (see `AppStore.init`), not called inline.
    ///
    /// This is the event-driven half of entitlement reconciliation; the
    /// other half is the poll on foreground in `AppStore.refreshSubscriptionStatus()`,
    /// which calls `hasActiveEntitlement()` directly. Between the two, a
    /// revocation is caught either the moment StoreKit reports it (if the
    /// app happens to be open) or, at the latest, the next time the app is
    /// foregrounded — there's no path where `subscription_status` can drift
    /// from actual entitlement indefinitely.
    ///
    /// Only fires `onEntitlementChange` for verified updates concerning any
    /// of our own products (`allProductIDs`) — not just monthly, so a
    /// renewal/revocation/refund on the annual or lifetime plan is caught
    /// too, not silently ignored. Unverified transactions are skipped
    /// without being finished, matching Apple's guidance not to treat
    /// failed verification as a legitimate transaction to acknowledge.
    func observeTransactionUpdates(onEntitlementChange: @escaping @Sendable (Bool) async -> Void) async {
        for await result in Transaction.updates {
            guard case .verified(let transaction) = result else { continue }
            await transaction.finish()
            guard Self.allProductIDs.contains(transaction.productID) else { continue }
            let stillActive = await hasActiveEntitlement()
            await onEntitlementChange(stillActive)
        }
    }
}
