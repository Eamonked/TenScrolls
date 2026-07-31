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
            let groups: [ReadingGroupSummary] = try await SupabaseConfig.client
                .rpc("fetch_my_reading_groups")
                .execute()
                .value
            return groups
        } catch {
            return []
        }
    }

    // MARK: - Scroll Sharing

    func shareScroll(scrollNumber: Int, title: String, notes: String, toTraderCode: String) async -> Bool {
        do {
            try await ensureSignedIn()
            let ok: Bool = try await SupabaseConfig.client
                .rpc("share_scroll_to_trader", params: [
                    "p_scroll_number": String(scrollNumber),
                    "p_title": title,
                    "p_notes": notes,
                    "p_to_trader_code": toTraderCode
                ])
                .execute()
                .value
            return ok
        } catch {
            return false
        }
    }

    func shareScroll(scrollNumber: Int, title: String, notes: String, toGroupId: UUID) async -> Bool {
        do {
            try await ensureSignedIn()
            let ok: Bool = try await SupabaseConfig.client
                .rpc("share_scroll_to_group", params: [
                    "p_scroll_number": String(scrollNumber),
                    "p_title": title,
                    "p_notes": notes,
                    "p_to_group_id": toGroupId.uuidString
                ])
                .execute()
                .value
            return ok
        } catch {
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
