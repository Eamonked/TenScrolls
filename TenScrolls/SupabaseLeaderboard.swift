import Foundation
import Supabase

/// Backs "The Caravan" tab: a public leaderboard, friend lookups by trader code,
/// and a lightweight cheer counter. Backed by a real Supabase project (see
/// `SupabaseConfig`) using anonymous auth — each device signs in anonymously
/// once, then claims a `trader_code` server-side (retrying on collision)
/// before publishing or reading anything.
///
/// **Trust model note:** `leaderboard_snapshots` rows are still client-reported
/// (xp/streak/etc. come straight from local `AppState`), not recomputed from
/// server-validated session data. A modified client could publish inflated
/// stats. Closing that gap means deriving these fields from
/// `session_completions` server-side instead of trusting `publish()`'s
/// payload — see CARAVAN_SOCIAL_SCOPE.md, workstream E, for the follow-up
/// plan. Cheers are already fully server-enforced (one per sender/recipient/
/// day, via the `send_cheer` RPC), since those don't depend on session data.
actor SupabaseLeaderboard {
    private var signInTask: Task<Void, Error>?

    init() {}

    // MARK: - Auth

    /// Ensures we have an anonymous Supabase session. Safe to call repeatedly —
    /// concurrent callers await the same in-flight sign-in instead of racing.
    private func ensureSignedIn() async throws {
        if let task = signInTask {
            return try await task.value
        }
        let task = Task {
            if SupabaseConfig.client.auth.currentSession == nil {
                _ = try await SupabaseConfig.client.auth.signInAnonymously()
            }
        }
        signInTask = task
        try await task.value
    }

    // MARK: - Identity claim (with collision retry)

    private struct ClaimResult: Decodable {
        let success: Bool
        let error: String?
        let trader_code: String?
    }

    /// Claims `preferredCode` as this device's trader code server-side. If
    /// another device already holds it, generates a fresh one and retries
    /// (bounded). Returns the trader code that actually ended up claimed —
    /// callers should persist this back into local state if it differs from
    /// what was passed in. Falls back to `preferredCode` unchanged if the
    /// network/auth call fails outright, so the app keeps working offline.
    func claimIdentity(preferredCode: String, name: String) async -> String {
        do {
            try await ensureSignedIn()
        } catch {
            return preferredCode
        }

        var candidate = preferredCode
        for attempt in 0..<5 {
            do {
                let response: ClaimResult = try await SupabaseConfig.client
                    .rpc("claim_identity", params: ["p_trader_code": candidate, "p_trader_name": name])
                    .execute()
                    .value
                if response.success {
                    return candidate
                }
                if response.error == "code_taken" {
                    candidate = Self.generateCode()
                    continue
                }
                return preferredCode
            } catch {
                return attempt == 0 ? preferredCode : candidate
            }
        }
        return candidate
    }

    private static func generateCode() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).compactMap { _ in chars.randomElement() })
    }

    // MARK: - Publish own snapshot

    private struct SnapshotRow: Encodable {
        let user_id: UUID
        let trader_code: String
        let trader_name: String
        let level: Int
        let xp: Int
        let current_streak: Int
        let best_streak: Int
        let total_days: Int
        let scrolls_mastered: Int
        let last_active: Date
    }

    func publish(code: String, snapshot: FriendSnapshot) async {
        do {
            try await ensureSignedIn()
            guard let uid = SupabaseConfig.client.auth.currentSession?.user.id else { return }
            let row = SnapshotRow(
                user_id: uid,
                trader_code: code,
                trader_name: snapshot.name,
                level: snapshot.level,
                xp: snapshot.xp,
                current_streak: snapshot.streak,
                best_streak: snapshot.bestStreak,
                total_days: snapshot.totalDays,
                scrolls_mastered: snapshot.mastered,
                last_active: snapshot.lastActive
            )
            try await SupabaseConfig.client
                .from("leaderboard_snapshots")
                .upsert(row, onConflict: "user_id")
                .execute()
        } catch {
            // Best-effort: local play continues even if the network publish fails.
        }
    }

    // MARK: - Fetch leaderboard

    private struct SnapshotRowDecoded: Decodable {
        let trader_code: String
        let trader_name: String
        let level: Int
        let xp: Int
        let current_streak: Int
        let best_streak: Int
        let total_days: Int
        let scrolls_mastered: Int
        let last_active: Date
    }

    private func toEntry(_ row: SnapshotRowDecoded) -> LeaderboardEntry {
        LeaderboardEntry(code: row.trader_code, snapshot: FriendSnapshot(
            name: row.trader_name,
            level: row.level,
            xp: row.xp,
            streak: row.current_streak,
            bestStreak: row.best_streak,
            totalDays: row.total_days,
            mastered: row.scrolls_mastered,
            lastActive: row.last_active
        ))
    }

    func fetchLeaderboard(limit: Int = 50) async throws -> [LeaderboardEntry] {
        try await ensureSignedIn()
        let rows: [SnapshotRowDecoded] = try await SupabaseConfig.client
            .from("leaderboard_snapshots")
            .select()
            .order("xp", ascending: false)
            .limit(limit)
            .execute()
            .value
        return rows.map(toEntry)
    }

    // MARK: - Fetch a single friend by trader code

    func fetchFriend(code: String) async -> FriendSnapshot? {
        do {
            try await ensureSignedIn()
            let rows: [SnapshotRowDecoded] = try await SupabaseConfig.client
                .from("leaderboard_snapshots")
                .select()
                .eq("trader_code", value: code)
                .limit(1)
                .execute()
                .value
            return rows.first.map(toEntry)?.snapshot
        } catch {
            return nil
        }
    }

    // MARK: - Cheers

    func sendCheer(code: String) async {
        do {
            try await ensureSignedIn()
            try await SupabaseConfig.client
                .rpc("send_cheer", params: ["p_to_code": code])
                .execute()
        } catch {
            // Best-effort.
        }
    }

    func fetchCheerCount(code: String) async -> Int {
        do {
            try await ensureSignedIn()
            let count: Int = try await SupabaseConfig.client
                .rpc("fetch_cheer_count", params: ["p_code": code])
                .execute()
                .value
            return count
        } catch {
            return 0
        }
    }
}
