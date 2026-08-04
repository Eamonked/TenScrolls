import Foundation
import Supabase

/// Manages subscription state and Plus feature access via Supabase backend.
/// Handles trial activation, subscription status checking, and tiered
/// leaderboard access based on subscription level.
actor SupabaseSubscription {
    init() {}
    
    private func ensureSignedIn() async throws {
        try await SupabaseAuth.shared.ensureSignedIn()
    }
    
    // MARK: - Subscription Status
    
    /// Fetches the current user's subscription status from the server
    func fetchSubscriptionStatus() async throws -> SubscriptionInfo {
        try await ensureSignedIn()
        
        let results: [SubscriptionInfo] = try await SupabaseConfig.client
            .rpc("get_subscription_status")
            .execute()
            .value
        
        guard let info = results.first else {
            // Default to free if no record found
            return SubscriptionInfo(
                subscriptionStatus: .free,
                trialStartDate: nil,
                trialEndDate: nil,
                plusSince: nil,
                daysUntilTrialEnd: 0,
                isTrialActive: false
            )
        }
        
        return info
    }
    
    /// Checks if the trial has expired and updates status if needed
    @discardableResult
    func checkTrialExpiry() async throws -> TrialExpiryCheckResult {
        try await ensureSignedIn()
        
        let result: TrialExpiryCheckResult = try await SupabaseConfig.client
            .rpc("check_trial_expiry")
            .execute()
            .value
        
        return result
    }
    
    // MARK: - Trial Management
    
    /// Starts a free trial for the current user
    func startTrial() async throws -> TrialStartResult {
        try await ensureSignedIn()
        
        let result: TrialStartResult = try await SupabaseConfig.client
            .rpc("start_trial")
            .execute()
            .value
        
        return result
    }
    
    // MARK: - Subscription Activation

    /// Activates a Plus subscription after a successful IAP purchase.
    ///
    /// Does NOT call the `activate_subscription` RPC directly — that RPC is
    /// now locked to `service_role` only (see migration 006) because it did
    /// zero verification and was callable by any authenticated/anon client,
    /// letting anyone grant themselves Plus for free. Instead this sends
    /// `signedTransaction` (StoreKit's `jwsRepresentation` for the completed
    /// purchase — see `StoreKitManager.purchase()`) to the `verify-purchase`
    /// Edge Function, which independently verifies it against Apple's own
    /// certificates before activating anything server-side.
    func activateSubscription(signedTransaction: String) async throws -> SubscriptionActivationResult {
        try await ensureSignedIn()

        // Postgres timestamptz -> JSON often includes fractional seconds
        // (e.g. "2026-08-02T10:15:30.123456+00:00"), which the plain
        // `.iso8601` strategy's formatter (no fractional-seconds option)
        // fails to parse. Try both, since the exact format depends on
        // Postgres's json_build_object formatting. Formatters are created
        // fresh inside the closure rather than captured from outside —
        // `ISO8601DateFormatter` isn't `Sendable`, and this closure has to
        // be `@Sendable` to satisfy `dateDecodingStrategy`'s signature.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            let isoWithFractional = ISO8601DateFormatter()
            isoWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoPlain = ISO8601DateFormatter()
            isoPlain.formatOptions = [.withInternetDateTime]
            if let date = isoWithFractional.date(from: dateString) ?? isoPlain.date(from: dateString) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date format: \(dateString)")
        }

        let response = try await SupabaseConfig.client.functions
            .invoke(
                "verify-purchase",
                options: .init(body: ["signedTransaction": signedTransaction])
            ) { data, _ in
                try decoder.decode(SubscriptionActivationResult.self, from: data)
            }

        return response
    }

    /// Reconciliation counterpart to `activateSubscription()`. Called after
    /// the client cross-checks StoreKit's own entitlement truth
    /// (`StoreKitManager.hasActiveEntitlement()`) and finds no active
    /// entitlement despite the server still reporting `active` — covers
    /// cancellation, refund, and failed-renewal cases, none of which push
    /// a webhook to this backend today. No-ops server-side if the account
    /// wasn't `active` to begin with.
    func deactivateSubscription() async throws -> SubscriptionDeactivationResult {
        try await ensureSignedIn()

        let result: SubscriptionDeactivationResult = try await SupabaseConfig.client
            .rpc("deactivate_subscription")
            .execute()
            .value

        return result
    }
    
    // MARK: - Tiered Leaderboard Access
    
    /// Fetches the leaderboard with tier-appropriate data.
    /// Plus users get full leaderboard, free users get percentile only.
    func fetchTieredLeaderboard(limit: Int = 50) async throws -> [TieredLeaderboardEntry] {
        try await ensureSignedIn()
        
        let entries: [TieredLeaderboardEntry] = try await SupabaseConfig.client
            .rpc("get_leaderboard_tiered", params: ["p_limit": limit])
            .execute()
            .value
        
        return entries
    }
    
    // MARK: - Content Access Gates
    
    /// Checks if the user can access Scroll II (Day 30 paywall)
    func canAccessScrollTwo() async throws -> Bool {
        try await ensureSignedIn()
        
        let result: Bool = try await SupabaseConfig.client
            .rpc("can_access_scroll_two")
            .execute()
            .value
        
        return result
    }
    
    // MARK: - Caravan Tracking
    
    /// Marks that the user has joined the Caravan (opted into social features)
    func markCaravanJoined() async throws {
        try await ensureSignedIn()
        
        try await SupabaseConfig.client
            .rpc("mark_caravan_joined")
            .execute()
    }
}

