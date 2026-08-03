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
///
/// **Read path note:** reads go through `get_leaderboard` / `get_trader_by_code`
/// (SECURITY DEFINER RPCs), not a direct table SELECT — see
/// 002_leaderboard_gating.sql. The table's old public-SELECT policy let any
/// client query it with arbitrary filters/order; these RPCs are also where
/// free/Plus leaderboard tiering will be added later.
actor SupabaseLeaderboard {
    init() {}

    // MARK: - Auth

    /// Ensures we have an anonymous Supabase session. Delegates to the shared
    /// `SupabaseAuth` actor so this and `SupabaseSharing` never race each
    /// other into minting two separate anonymous sessions.
    private func ensureSignedIn() async throws {
        try await SupabaseAuth.shared.ensureSignedIn()
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
                    // Trust the server's persisted code, not the local candidate —
                    // a stale row (e.g. after a local reset regenerated a new
                    // preferred code while the old anonymous session/users row
                    // was still around) can return success without actually
                    // taking the new code. See claim_identity's `ON CONFLICT (id)
                    // DO UPDATE` — it now updates trader_code too, but this guards
                    // against ever silently drifting out of sync with the server again.
                    return response.trader_code ?? candidate
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

    /// Reads via `get_leaderboard`, a SECURITY DEFINER RPC — the table's
    /// direct-SELECT policy was removed (see 002_leaderboard_gating.sql)
    /// because it let any client query `leaderboard_snapshots` with
    /// arbitrary filters/order, independent of what this call asks for.
    /// Rank is now computed server-side; this is also the single choke
    /// point where free/Plus tiering will be added later.
    func fetchLeaderboard(limit: Int = 50) async throws -> [LeaderboardEntry] {
        try await ensureSignedIn()
        let rows: [SnapshotRowDecoded] = try await SupabaseConfig.client
            .rpc("get_leaderboard", params: ["p_limit": limit])
            .execute()
            .value
        return rows.map(toEntry)
    }

    // MARK: - Fetch a single friend by trader code

    /// Reads via `get_trader_by_code`, for the same reason as
    /// `fetchLeaderboard` above — no more direct table SELECT.
    func fetchFriend(code: String) async -> FriendSnapshot? {
        do {
            try await ensureSignedIn()
            let rows: [SnapshotRowDecoded] = try await SupabaseConfig.client
                .rpc("get_trader_by_code", params: ["p_code": code])
                .execute()
                .value
            return rows.first.map(toEntry)?.snapshot
        } catch {
            return nil
        }
    }

    // MARK: - Cheers

    /// Result of `send_cheer` — decoded so callers can distinguish
    /// `plus_required` (stale local `hasPlusAccess`, e.g. a trial expired
    /// server-side mid-session) from a plain network/auth failure, which
    /// still comes back as `nil` via the catch below.
    struct SendCheerResult: Decodable {
        let success: Bool
        let error: String?
        let alreadySent: Bool?

        private enum CodingKeys: String, CodingKey {
            case success, error
            case alreadySent = "already_sent"
        }
    }

    @discardableResult
    func sendCheer(code: String) async -> SendCheerResult? {
        do {
            try await ensureSignedIn()
            let result: SendCheerResult = try await SupabaseConfig.client
                .rpc("send_cheer", params: ["p_to_code": code])
                .execute()
                .value
            return result
        } catch {
            // Network/auth failure — distinct from a decoded plus_required.
            return nil
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

    // MARK: - Push notifications for cheers

    /// Uploads (or refreshes) this device's APNs token so cheers sent to this
    /// user can be delivered as a real push, not just an in-app poll.
    func registerPushToken(_ token: String, environment: String) async {
        do {
            try await ensureSignedIn()
            try await SupabaseConfig.client
                .rpc("register_push_token", params: ["p_token": token, "p_environment": environment])
                .execute()
        } catch {
            // Best-effort — in-app polling still covers delivery.
        }
    }

    /// Marks a cheer as received. Called either from the "Got it" notification
    /// action, or from the in-app fallback banner if the push was missed.
    @discardableResult
    func acknowledgeCheer(id: UUID) async -> Bool {
        do {
            try await ensureSignedIn()
            struct Ack: Decodable { let success: Bool; let updated: Bool? }
            let response: Ack = try await SupabaseConfig.client
                .rpc("acknowledge_cheer", params: ["p_cheer_id": id.uuidString])
                .execute()
                .value
            return response.success
        } catch {
            return false
        }
    }

    /// Cheers sent to this user that haven't been acknowledged yet — the
    /// in-app fallback surface for when a push was missed or not tapped.
    func fetchUnacknowledgedCheers() async -> [PendingCheer] {
        do {
            try await ensureSignedIn()
            let rows: [PendingCheer] = try await SupabaseConfig.client
                .rpc("fetch_unacknowledged_cheers")
                .execute()
                .value
            return rows
        } catch {
            return []
        }
    }

    /// Whether the last cheer *I* sent to `code` has been seen — drives a
    /// "seen" checkmark on the sender's side of the duel card.
    func fetchCheerAckStatus(code: String) async -> CheerAckStatus {
        do {
            try await ensureSignedIn()
            let status: CheerAckStatus = try await SupabaseConfig.client
                .rpc("fetch_cheer_ack_status", params: ["p_to_code": code])
                .execute()
                .value
            return status
        } catch {
            return CheerAckStatus(sent: false, acknowledged: nil, sent_at: nil, acknowledged_at: nil)
        }
    }
}
