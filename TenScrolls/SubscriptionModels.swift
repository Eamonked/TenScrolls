import Foundation

/// Subscription status for the user
enum SubscriptionStatus: String, Codable, Equatable, Sendable {
    case free = "free"
    case trialing = "trialing"
    case active = "active"
    case lapsed = "lapsed"
    
    /// Whether the user has Plus access (full leaderboard, no content gates)
    var hasAccess: Bool {
        self == .active || self == .trialing
    }
    
    /// Display label for UI
    var displayLabel: String {
        switch self {
        case .free: return "Free"
        case .trialing: return "Trial"
        case .active: return "Plus"
        case .lapsed: return "Trial Expired"
        }
    }
}

/// User's subscription information
struct SubscriptionInfo: Codable, Equatable, Sendable {
    let subscriptionStatus: SubscriptionStatus
    let trialStartDate: Date?
    let trialEndDate: Date?
    let plusSince: Date?
    let daysUntilTrialEnd: Int
    let isTrialActive: Bool
    
    var hasAccess: Bool {
        subscriptionStatus.hasAccess
    }
    
    /// Whether the user is eligible to start a trial
    var canStartTrial: Bool {
        subscriptionStatus == .free && trialStartDate == nil
    }
    
    private enum CodingKeys: String, CodingKey {
        case subscriptionStatus = "subscription_status"
        case trialStartDate = "trial_start_date"
        case trialEndDate = "trial_end_date"
        case plusSince = "plus_since"
        case daysUntilTrialEnd = "days_until_trial_end"
        case isTrialActive = "is_trial_active"
    }
}

/// Result from starting a trial
struct TrialStartResult: Decodable {
    let success: Bool
    let error: String?
    let message: String?
    let trialStartDate: Date?
    let trialEndDate: Date?
    let trialDays: Int?
    
    private enum CodingKeys: String, CodingKey {
        case success
        case error
        case message
        case trialStartDate = "trial_start_date"
        case trialEndDate = "trial_end_date"
        case trialDays = "trial_days"
    }
}

/// Result from activating subscription
struct SubscriptionActivationResult: Decodable {
    let success: Bool
    let plusSince: Date?
    
    private enum CodingKeys: String, CodingKey {
        case success
        case plusSince = "plus_since"
    }
}

/// Result from checking trial expiry
struct TrialExpiryCheckResult: Decodable {
    let success: Bool
    let expired: Bool
    let newStatus: String?
    let status: String?
    
    private enum CodingKeys: String, CodingKey {
        case success
        case expired
        case newStatus = "new_status"
        case status
    }
}

/// Tiered leaderboard entry - includes different fields based on subscription status
struct TieredLeaderboardEntry: Decodable, Equatable, Sendable {
    let traderCode: String?
    let traderName: String?
    let level: Int?
    let xp: Int?
    let currentStreak: Int?
    let bestStreak: Int?
    let totalDays: Int?
    let scrollsMastered: Int?
    let lastActive: Date?
    let rank: Int?
    let isLocked: Bool
    let percentile: Int?
    let populationCount: Int?
    
    /// Whether this is the limited view for free users
    var isPartialReveal: Bool {
        isLocked
    }
    
    private enum CodingKeys: String, CodingKey {
        case traderCode = "trader_code"
        case traderName = "trader_name"
        case level
        case xp
        case currentStreak = "current_streak"
        case bestStreak = "best_streak"
        case totalDays = "total_days"
        case scrollsMastered = "scrolls_mastered"
        case lastActive = "last_active"
        case rank
        case isLocked = "is_locked"
        case percentile
        case populationCount = "population_count"
    }
}

/// Engagement milestone that triggers trial offer (Day 3)
struct EngagementMilestone: Equatable {
    let consecutiveDays: Int
    let shouldOfferTrial: Bool
    
    static func check(from log: [String: DayEntry]) -> EngagementMilestone {
        let consecutiveDays = calculateConsecutiveDays(log: log)
        let shouldOfferTrial = consecutiveDays >= 3
        return EngagementMilestone(
            consecutiveDays: consecutiveDays,
            shouldOfferTrial: shouldOfferTrial
        )
    }
    
    private static func calculateConsecutiveDays(log: [String: DayEntry]) -> Int {
        var count = 0
        var currentDate = DateKey.today()
        
        // Count backwards from today
        for _ in 0..<365 { // Safety limit
            if let entry = log[currentDate], entry.allComplete {
                count += 1
                currentDate = DateKey.add(-1, to: currentDate)
            } else {
                break
            }
        }
        
        return count
    }
}

/// Scroll access information based on subscription and progress
struct ScrollAccess: Equatable {
    let scrollId: Int
    let isAccessible: Bool
    let reason: AccessReason?
    
    enum AccessReason: Equatable {
        case subscriptionRequired(daysCompleted: Int)
        case trialActive
        case unlocked
    }
}

