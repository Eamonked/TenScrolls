#!/usr/bin/env swift

import Foundation

// Simple test script to verify Supabase database connectivity
// This tests if we can query the leaderboard_snapshots table

let projectURL = "https://shodbktjnfadxalegapd.supabase.co"
let publishableKey = "sb_publishable_GtijMsXiS-nXTMFaBAv6dw_g31V4A0W"

// Test 1: Check if we can reach the API endpoint
print("🔍 Testing Supabase Database Connection...")
print("📍 Project URL: \(projectURL)")
print("")

func testAPIEndpoint() async throws {
    let url = URL(string: "\(projectURL)/rest/v1/")!
    var request = URLRequest(url: url)
    request.addValue(publishableKey, forHTTPHeaderField: "apikey")
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let (data, response) = try await URLSession.shared.data(for: request)
    
    if let httpResponse = response as? HTTPURLResponse {
        print("✅ API Endpoint Status: \(httpResponse.statusCode)")
        if httpResponse.statusCode == 200 {
            print("✅ Database is reachable")
        }
    }
}

// Test 2: Query leaderboard_snapshots table
func testLeaderboardQuery() async throws {
    let url = URL(string: "\(projectURL)/rest/v1/leaderboard_snapshots?select=*&limit=5")!
    var request = URLRequest(url: url)
    request.addValue(publishableKey, forHTTPHeaderField: "apikey")
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let (data, response) = try await URLSession.shared.data(for: request)
    
    if let httpResponse = response as? HTTPURLResponse {
        print("\n📊 Leaderboard Query Status: \(httpResponse.statusCode)")
        
        if httpResponse.statusCode == 200 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                print("✅ Successfully queried leaderboard_snapshots table")
                print("📝 Found \(json.count) entries")
                
                if json.isEmpty {
                    print("ℹ️  Table is empty (no leaderboard data yet)")
                } else {
                    print("\n🏆 Sample entries:")
                    for (index, entry) in json.prefix(3).enumerated() {
                        let traderCode = entry["trader_code"] as? String ?? "unknown"
                        let traderName = entry["trader_name"] as? String ?? "unknown"
                        let streak = entry["current_streak"] as? Int ?? 0
                        let xp = entry["xp"] as? Int ?? 0
                        print("  \(index + 1). \(traderName) (\(traderCode)) - Streak: \(streak), XP: \(xp)")
                    }
                }
            }
        } else {
            let errorText = String(data: data, encoding: .utf8) ?? "unknown error"
            print("❌ Query failed: \(errorText)")
        }
    }
}

// Test 3: Check auth endpoint
func testAuthEndpoint() async throws {
    let url = URL(string: "\(projectURL)/auth/v1/health")!
    var request = URLRequest(url: url)
    request.addValue(publishableKey, forHTTPHeaderField: "apikey")
    
    let (_, response) = try await URLSession.shared.data(for: request)
    
    if let httpResponse = response as? HTTPURLResponse {
        print("\n🔐 Auth Service Status: \(httpResponse.statusCode)")
        if httpResponse.statusCode == 200 {
            print("✅ Authentication service is available")
        }
    }
}

// Test 4: Test RPC function
func testRPCFunction() async throws {
    let url = URL(string: "\(projectURL)/rest/v1/rpc/fetch_cheer_count")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.addValue(publishableKey, forHTTPHeaderField: "apikey")
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    
    // Test with a sample trader code
    let body = ["p_code": "SAMPLE"]
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    
    let (data, response) = try await URLSession.shared.data(for: request)
    
    if let httpResponse = response as? HTTPURLResponse {
        print("\n⚡ RPC Function Test Status: \(httpResponse.statusCode)")
        if httpResponse.statusCode == 200 {
            print("✅ RPC functions are working")
            if let result = String(data: data, encoding: .utf8) {
                print("   Response: \(result)")
            }
        } else {
            let errorText = String(data: data, encoding: .utf8) ?? "unknown error"
            print("⚠️  RPC response: \(errorText)")
        }
    }
}

// Run all tests
Task {
    do {
        try await testAPIEndpoint()
        try await testLeaderboardQuery()
        try await testAuthEndpoint()
        try await testRPCFunction()
        
        print("\n" + String(repeating: "=", count: 50))
        print("✅ Database connectivity test complete!")
        print(String(repeating: "=", count: 50))
    } catch {
        print("\n❌ Error during testing: \(error)")
    }
    
    exit(0)
}

RunLoop.main.run()
