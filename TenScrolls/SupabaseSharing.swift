import Foundation
import Supabase

/// Handles group creation/joining and sharing scrolls between traders or groups.
actor SupabaseSharing {
    init() {}

    private func ensureSignedIn() async throws {
        try await SupabaseAuth.shared.ensureSignedIn()
    }

    // MARK: - Reading Groups

    private struct CreateGroupResponse: Decodable {
        let success: Bool
        let error: String?
        let group_id: UUID?
        let group_code: String?
        let name: String?
    }

    private struct JoinGroupResponse: Decodable {
        let success: Bool
        let error: String?
        let group_id: UUID?
        let name: String?
    }

    func createGroup(name: String) async -> GroupOperationResult {
        do {
            try await ensureSignedIn()
            let response: CreateGroupResponse = try await SupabaseConfig.client
                .rpc("create_reading_group", params: ["p_name": name])
                .execute()
                .value
            if response.success, let id = response.group_id, let code = response.group_code {
                return .created(id: id, code: code, name: response.name ?? name)
            } else {
                return .failure(response.error ?? "create_failed")
            }
        } catch {
            return .failure("network_error")
        }
    }

    func joinGroup(code: String) async -> GroupOperationResult {
        do {
            try await ensureSignedIn()
            let response: JoinGroupResponse = try await SupabaseConfig.client
                .rpc("join_reading_group", params: ["p_code": code])
                .execute()
                .value
            if response.success, let id = response.group_id, let groupName = response.name {
                return .joined(id: id, name: groupName)
            } else {
                return .failure(response.error ?? "join_failed")
            }
        } catch {
            return .failure("network_error")
        }
    }

    func fetchMyGroups() async -> [ReadingGroupSummary] {
        do {
            try await ensureSignedIn()
            // NB: the RPC is named `list_my_reading_groups` server-side, not
            // `fetch_my_reading_groups` — mismatched names here silently
            // made this call fail every time (PostgREST 404s on an unknown
            // function), which this actor's do/catch then swallowed into an
            // empty array. Groups could still be created/joined via the
            // (correctly-named) create/join RPCs, they just could never be
            // listed back, so the Caravan tab always looked empty.
            let groups: [ReadingGroupSummary] = try await SupabaseConfig.client
                .rpc("list_my_reading_groups")
                .execute()
                .value
            return groups
        } catch {
            return []
        }
    }

    private struct LeaveGroupResponse: Decodable {
        let success: Bool
        let error: String?
        let group_deleted: Bool?
    }

    private struct DeleteGroupResponse: Decodable {
        let success: Bool
        let error: String?
    }

    /// Removes the caller from a group. If they were the last member, the
    /// server deletes the group itself — `groupDeleted` in the result
    /// reflects that so the caller can decide how to update local state.
    func leaveGroup(id: UUID) async -> (success: Bool, groupDeleted: Bool, error: String?) {
        do {
            try await ensureSignedIn()
            let response: LeaveGroupResponse = try await SupabaseConfig.client
                .rpc("leave_reading_group", params: ["p_group_id": id.uuidString])
                .execute()
                .value
            if !response.success {
                print("⚠️ leaveGroup(\(id)) failed: \(response.error ?? "unknown_error")")
            }
            return (response.success, response.group_deleted ?? false, response.error)
        } catch {
            logSupabaseFailure("leaveGroup(\(id)) failed", error)
            return (false, false, "network_error")
        }
    }

    /// Creator-only. Force-deletes a group regardless of remaining members;
    /// the server rejects this with `not_authorized` for non-creators.
    func deleteGroup(id: UUID) async -> (success: Bool, error: String?) {
        do {
            try await ensureSignedIn()
            let response: DeleteGroupResponse = try await SupabaseConfig.client
                .rpc("delete_reading_group", params: ["p_group_id": id.uuidString])
                .execute()
                .value
            if !response.success {
                print("⚠️ deleteGroup(\(id)) failed: \(response.error ?? "unknown_error")")
            }
            return (response.success, response.error)
        } catch {
            logSupabaseFailure("deleteGroup(\(id)) failed", error)
            return (false, "network_error")
        }
    }

    // MARK: - Scroll Sharing

    private struct ShareScrollParams: Encodable {
        let p_scroll_number: Int
        let p_title: String
        let p_notes: String
        let p_to_trader_code: String?
        let p_to_group_id: String?
    }

    private struct ShareScrollResponse: Decodable {
        let success: Bool
        let error: String?
    }

    func shareScroll(scrollNumber: Int, title: String, notes: String, toTraderCode: String) async -> Bool {
        do {
            try await ensureSignedIn()
            let params = ShareScrollParams(
                p_scroll_number: scrollNumber,
                p_title: title,
                p_notes: notes,
                p_to_trader_code: toTraderCode,
                p_to_group_id: nil
            )
            let response: ShareScrollResponse = try await SupabaseConfig.client
                .rpc("share_scroll", params: params)
                .execute()
                .value
            if !response.success {
                print("⚠️ shareScroll(toTraderCode: \(toTraderCode)) failed: \(response.error ?? "unknown_error")")
            }
            return response.success
        } catch {
            logSupabaseFailure("shareScroll(toTraderCode: \(toTraderCode)) failed", error)
            return false
        }
    }

    func shareScroll(scrollNumber: Int, title: String, notes: String, toGroupId: UUID) async -> Bool {
        do {
            try await ensureSignedIn()
            let params = ShareScrollParams(
                p_scroll_number: scrollNumber,
                p_title: title,
                p_notes: notes,
                p_to_trader_code: nil,
                p_to_group_id: toGroupId.uuidString
            )
            let response: ShareScrollResponse = try await SupabaseConfig.client
                .rpc("share_scroll", params: params)
                .execute()
                .value
            if !response.success {
                print("⚠️ shareScroll(toGroupId: \(toGroupId)) failed: \(response.error ?? "unknown_error")")
            }
            return response.success
        } catch {
            logSupabaseFailure("shareScroll(toGroupId: \(toGroupId)) failed", error)
            return false
        }
    }

    func fetchPendingShares() async -> [PendingScrollShare] {
        do {
            try await ensureSignedIn()
            let shares: [PendingScrollShare] = try await SupabaseConfig.client
                .rpc("fetch_pending_shares")
                .execute()
                .value
            return shares
        } catch {
            return []
        }
    }

    func resolveShare(id: UUID, status: String) async {
        do {
            try await ensureSignedIn()
            try await SupabaseConfig.client
                .rpc("resolve_scroll_share", params: ["p_share_id": id.uuidString, "p_status": status])
                .execute()
        } catch {
            // Best-effort.
        }
    }
}
