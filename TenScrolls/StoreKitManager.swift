import Foundation
import StoreKit

/// Wraps StoreKit 2's purchase flow for the TenScrolls Plus subscription.
///
/// The 10-day trial is handled entirely server-side (see
/// `SupabaseSubscription.startTrial()` / the `start_trial` RPC) and never
/// touches StoreKit at all — this manager is only exercised at the paid-
/// conversion moment (the Day 30 paywall, or an early upgrade from the
/// Caravan's partial-reveal leaderboard card), where a real purchase has to
/// clear before `AppStore.activateSubscription()` is allowed to flip the
/// server-side `subscription_status` to `active`.
actor StoreKitManager {
    static let shared = StoreKitManager()

    /// Must match the subscription product's Product ID configured in App
    /// Store Connect (and in a local `Configuration.storekit` file for
    /// simulator/sandbox testing) exactly, or `loadProducts()` returns empty.
    static let subscriptionProductID = "ekme.TenScrolls.plus.monthly"

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

    /// Fetches the subscription product from the App Store. Cheap to call
    /// repeatedly — a no-op once `products` is already populated, and safe
    /// to retry if an earlier attempt failed (e.g. no network at launch).
    func loadProducts() async throws {
        guard products.isEmpty else { return }
        products = try await Product.products(for: [Self.subscriptionProductID])
    }

    /// The subscription's localized price/period (e.g. "$4.99/mo"), for
    /// display in the paywall in place of the hardcoded "$4.99/month" text.
    /// `nil` until a product fetch has succeeded at least once.
    func displayPrice() async -> String? {
        if products.isEmpty { try? await loadProducts() }
        return products.first?.displayPrice
    }

    /// Runs the actual App Store purchase sheet and verifies the result
    /// *locally* (StoreKit's on-device check against Apple's signature).
    /// Returns the transaction's signed JWS on success — callers must send
    /// this to `SupabaseSubscription.activateSubscription(signedTransaction:)`,
    /// which re-verifies it server-side before flipping
    /// `subscription_status` to `active`. Local verification alone is not
    /// sufficient to activate anything: it proves the purchase to this
    /// device, not to the server. Returns `.userCancelledOrPending` for a
    /// user cancellation or a pending purchase (e.g. Ask to Buy) — neither
    /// is an error, there's just nothing to activate yet.
    @discardableResult
    func purchase() async throws -> PurchaseOutcome {
        // Already entitled — hand back that transaction's JWS instead of
        // calling product.purchase() again, which is exactly what triggers
        // StoreKit's "You're currently subscribed to this" system alert and
        // then never resolves through the .success branch below.
        if let existingJWS = await currentEntitlementJWS() {
            return .success(signedTransaction: existingJWS)
        }

        if products.isEmpty { try await loadProducts() }
        guard let product = products.first else {
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

    /// Whether the App Store already reports an active entitlement for this
    /// product on this Apple ID — lets a reinstall, or a purchase completed
    /// on another device signed into the same account, reconcile without the
    /// user having to tap "Upgrade" again. Doesn't itself call
    /// `activateSubscription()`; callers decide what to do with the result.
    func hasActiveEntitlement() async -> Bool {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.subscriptionProductID,
                  transaction.revocationDate == nil else { continue }
            return true
        }
        return false
    }

    /// Like `hasActiveEntitlement()`, but returns the transaction's signed
    /// JWS instead of a bare `Bool`, so callers can activate against it the
    /// same way a fresh purchase would. Covers reinstalls, restores, and —
    /// critically — the case where StoreKit already considers this Apple ID
    /// subscribed (e.g. a previous purchase finished on-device but never
    /// activated server-side, or an active entitlement carried over from an
    /// earlier test run) and intercepts `product.purchase()` with its own
    /// "You're currently subscribed to this" system alert before the
    /// purchase can ever resolve through `.success` below.
    func currentEntitlementJWS() async -> String? {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.subscriptionProductID,
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
    /// Only fires `onEntitlementChange` for verified updates concerning our
    /// own product. Unverified transactions are skipped without being
    /// finished, matching Apple's guidance not to treat failed verification
    /// as a legitimate transaction to acknowledge.
    func observeTransactionUpdates(onEntitlementChange: @escaping @Sendable (Bool) async -> Void) async {
        for await result in Transaction.updates {
            guard case .verified(let transaction) = result else { continue }
            await transaction.finish()
            guard transaction.productID == Self.subscriptionProductID else { continue }
            let stillActive = await hasActiveEntitlement()
            await onEntitlementChange(stillActive)
        }
    }
}
