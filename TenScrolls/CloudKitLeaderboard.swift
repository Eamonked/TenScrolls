import Foundation

/// Backs "The Caravan" tab: a public leaderboard, friend lookups by trader code,
/// and a lightweight cheer counter.
///
/// **Note:** CloudKit operations have been temporarily commented out and stubbed
/// to prevent launch crashes in environments without iCloud entitlements.
actor CloudKitLeaderboard {
    init() {
        // CloudKit initialization commented out to prevent startup crashes.
    }

    // MARK: - Publish own snapshot

    func publish(code: String, snapshot: FriendSnapshot) async {
        // Stubbed out for next phase migration (Supabase)
    }

    // MARK: - Fetch leaderboard

    func fetchLeaderboard(limit: Int = 50) async throws -> [LeaderboardEntry] {
        // Stubbed out for next phase migration (Supabase)
        return []
    }

    // MARK: - Fetch a single friend by trader code

    func fetchFriend(code: String) async -> FriendSnapshot? {
        // Stubbed out for next phase migration (Supabase)
        return nil
    }

    // MARK: - Cheers

    func sendCheer(code: String) async {
        // Stubbed out for next phase migration (Supabase)
    }

    func fetchCheerCount(code: String) async -> Int {
        // Stubbed out for next phase migration (Supabase)
        return 0
    }
}
