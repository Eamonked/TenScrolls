#!/usr/bin/env swift

import Foundation

let projectURL = "https://shodbktjnfadxalegapd.supabase.co"
let publishableKey = "sb_publishable_GtijMsXiS-nXTMFaBAv6dw_g31V4A0W"

print("🔍 Checking Existing RPC Functions...")
print("")

let rpcsUsedInCode = [
    "claim_identity",
    "get_leaderboard",
    "get_trader_by_code",
    "send_cheer",
    "fetch_cheer_count",
    "register_push_token",
    "acknowledge_cheer",
    "fetch_unacknowledged_cheers",
    "fetch_cheer_ack_status",
    "create_reading_group",
    "join_reading_group",
    "fetch_my_reading_groups",
    "share_scroll",
    "fetch_pending_shares",
    "resolve_scroll_share"
]

func checkRPC(_ funcName: String) async -> String {
    let url = URL(string: "\(projectURL)/rest/v1/rpc/\(funcName)")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.addValue(publishableKey, forHTTPHeaderField: "apikey")
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = "{}".data(using: .utf8)
    
    do {
        let (_, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 200, 400:
                return "✅"
            case 404:
                return "❌"
            default:
                return "⚠️ "
            }
        }
    } catch {
        return "❌"
    }
    return "❌"
}

Task {
    print("📋 RPC Functions Used in Code:\n")
    
    for rpc in rpcsUsedInCode {
        let status = await checkRPC(rpc)
        print("   \(status) \(rpc)")
    }
    
    print("\n" + String(repeating: "=", count: 50))
    print("✅ Check complete!")
    print(String(repeating: "=", count: 50))
    
    exit(0)
}

RunLoop.main.run()
