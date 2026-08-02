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
    
    /// Activates a Plus subscription (called after successful IAP purchase)
    func activateSubscription() async throws -> SubscriptionActivationResult {
        try await ensureSignedIn()
        
        let result: SubscriptionActivationResult = try await SupabaseConfig.client
            .rpc("activate_subscription")
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

