import Foundation
import Supabase

/// Handles two things introduced by migration 007:
///
/// 1. Syncing the local add-friend/remove-friend action (see
///    `AppStore.addFriend`/`removeFriend`) to the server as a directional
///    `friend_links` edge. `state.friendCodes` stays the source of truth for
///    what `CaravanView` shows — this is purely so the server can tell
///    whether a pair is *mutual*, which is what gates DMs.
/// 2. Sending/reading 1:1 direct messages, which the server only allows
///    between mutual friends (both edges present).
actor SupabaseMessaging {
    init() {}

    private func ensureSignedIn() async throws {
        try await SupabaseAuth.shared.ensureSignedIn()
    }

    // MARK: - Friend links

    private struct FriendLinkResponse: Decodable {
        let success: Bool
        let error: String?
        let mutual: Bool?
    }

    /// Syncs an add-friend action to the server. Returns whether the pair is
    /// now mutual (both sides have added each other) — `nil` on failure, so
    /// callers can tell "not mutual yet" (`false`) apart from "couldn't
    /// reach the server" (`nil`) if that distinction matters later.
    @discardableResult
    func addFriendLink(code: String) async -> Bool? {
        do {
            try await ensureSignedIn()
            let response: FriendLinkResponse = try await SupabaseConfig.client
                .rpc("add_friend_link", params: ["p_friend_code": code])
                .execute()
                .value
            if !response.success {
                print("⚠️ addFriendLink(\(code)) failed: \(response.error ?? "unknown_error")")
                return nil
            }
            return response.mutual ?? false
        } catch {
            print("⚠️ addFriendLink(\(code)) failed: \(error)")
            return nil
        }
    }

    /// Syncs a remove-friend action to the server. Best-effort, same as
    /// `SupabaseSharing.resolveShare` — the local `friendCodes` removal
    /// already reflects the user's intent regardless of whether this lands.
    func removeFriendLink(code: String) async {
        do {
            try await ensureSignedIn()
            try await SupabaseConfig.client
                .rpc("remove_friend_link", params: ["p_friend_code": code])
                .execute()
        } catch {
            // Best-effort.
        }
    }

    // MARK: - Direct messages

    private struct SendDMParams: Encodable {
        let p_to_code: String
        let p_body: String
    }

    private struct SendDMResponse: Decodable {
        let success: Bool
        let error: String?
    }

    /// Sends a DM. Returns the server's error code (e.g.
    /// `"not_mutual_friends"`, `"message_too_long"`) on failure so the UI
    /// can show something more specific than a generic "couldn't send"
    /// toast, or `nil` on success.
    func sendDirectMessage(toCode: String, body: String) async -> String? {
        do {
            try await ensureSignedIn()
            let params = SendDMParams(p_to_code: toCode, p_body: body)
            let response: SendDMResponse = try await SupabaseConfig.client
                .rpc("send_direct_message", params: params)
                .execute()
                .value
            if !response.success {
                print("⚠️ sendDirectMessage(toCode: \(toCode)) failed: \(response.error ?? "unknown_error")")
            }
            return response.success ? nil : (response.error ?? "unknown_error")
        } catch {
            print("⚠️ sendDirectMessage(toCode: \(toCode)) failed: \(error)")
            return "network_error"
        }
    }

    private struct FetchDMParams: Encodable {
        let p_with_code: String
        let p_limit: Int
        let p_before: Date?
    }

    /// Fetches a page of a conversation, newest first. Pass `before` (the
    /// oldest `sent_at` already loaded) to page further back in history.
    /// Returns an empty array if the pair isn't (or is no longer) mutual —
    /// the RPC itself returns no rows in that case rather than erroring.
    func fetchDirectMessages(withCode: String, before: Date? = nil, limit: Int = 50) async -> [DirectMessage] {
        do {
            try await ensureSignedIn()
            let params = FetchDMParams(p_with_code: withCode, p_limit: limit, p_before: before)
            let messages: [DirectMessage] = try await SupabaseConfig.client
                .rpc("fetch_direct_messages", params: params)
                .execute()
                .value
            return messages
        } catch {
            return []
        }
    }

    /// One row per mutual friend, most recent activity first — the Caravan
    /// tab's DM inbox list.
    func fetchDMThreads() async -> [DMThreadSummary] {
        do {
            try await ensureSignedIn()
            let threads: [DMThreadSummary] = try await SupabaseConfig.client
                .rpc("fetch_dm_threads")
                .execute()
                .value
            return threads
        } catch {
            return []
        }
    }

    /// Marks a thread read. Best-effort, same pattern as `resolveShare`.
    func markRead(withCode: String) async {
        do {
            try await ensureSignedIn()
            try await SupabaseConfig.client
                .rpc("mark_dm_read", params: ["p_with_code": withCode])
                .execute()
        } catch {
            // Best-effort.
        }
    }
}
