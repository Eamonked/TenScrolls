#!/usr/bin/env swift

import Foundation

let projectURL = "https://shodbktjnfadxalegapd.supabase.co"
let publishableKey = "sb_publishable_GtijMsXiS-nXTMFaBAv6dw_g31V4A0W"

print("🔍 Checking Database Schema...")
print("")

// Check users table structure
func checkUsersTable() async throws {
    let url = URL(string: "\(projectURL)/rest/v1/users?select=*&limit=1")!
    var request = URLRequest(url: url)
    request.addValue(publishableKey, forHTTPHeaderField: "apikey")
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let (data, response) = try await URLSession.shared.data(for: request)
    
    if let httpResponse = response as? HTTPURLResponse {
        print("📋 Users Table Query Status: \(httpResponse.statusCode)")
        
        if httpResponse.statusCode == 200 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                print("✅ Users table exists")
                if let first = json.first {
                    print("📝 Fields found:")
                    for (key, value) in first.sorted(by: { $0.key < $1.key }) {
                        let typeInfo = type(of: value)
                        print("   - \(key): \(typeInfo)")
                    }
                } else {
                    print("ℹ️  Table is empty")
                }
            }
        } else {
            let errorText = String(data: data, encoding: .utf8) ?? "unknown"
            print("❌ Error: \(errorText)")
        }
    }
}

// Check leaderboard_snapshots table structure
func checkLeaderboardTable() async throws {
    let url = URL(string: "\(projectURL)/rest/v1/leaderboard_snapshots?select=*&limit=1")!
    var request = URLRequest(url: url)
    request.addValue(publishableKey, forHTTPHeaderField: "apikey")
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let (data, response) = try await URLSession.shared.data(for: request)
    
    if let httpResponse = response as? HTTPURLResponse {
        print("\n📊 Leaderboard_Snapshots Table Query Status: \(httpResponse.statusCode)")
        
        if httpResponse.statusCode == 200 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                print("✅ Leaderboard_snapshots table exists")
                if let first = json.first {
                    print("📝 Fields found:")
                    for (key, value) in first.sorted(by: { $0.key < $1.key }) {
                        let typeInfo = type(of: value)
                        print("   - \(key): \(typeInfo)")
                    }
                } else {
                    print("ℹ️  Table is empty")
                }
            }
        }
    }
}

// Check for subscription-related RPC functions
func checkRPCFunctions() async throws {
    print("\n🔧 Testing RPC Functions:")
    
    let functions = [
        "claim_identity",
        "fetch_leaderboard_tiered",
        "calculate_percentile",
        "get_subscription_status"
    ]
    
    for funcName in functions {
        let url = URL(string: "\(projectURL)/rest/v1/rpc/\(funcName)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(publishableKey, forHTTPHeaderField: "apikey")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{}".data(using: .utf8)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 200 || httpResponse.statusCode == 400 {
                print("   ✅ \(funcName) exists (status: \(httpResponse.statusCode))")
            } else if httpResponse.statusCode == 404 {
                print("   ❌ \(funcName) not found")
            } else {
                print("   ⚠️  \(funcName) - status: \(httpResponse.statusCode)")
            }
        }
    }
}

// Check all tables
func checkAllTables() async throws {
    print("\n📑 Checking All Tables:")
    
    let tables = [
        "users",
        "leaderboard_snapshots",
        "session_completions",
        "day_summaries",
        "session_windows",
        "reading_groups",
        "cheers"
    ]
    
    for tableName in tables {
        let url = URL(string: "\(projectURL)/rest/v1/\(tableName)?select=*&limit=0")!
        var request = URLRequest(url: url)
        request.addValue(publishableKey, forHTTPHeaderField: "apikey")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 200 {
                print("   ✅ \(tableName)")
            } else if httpResponse.statusCode == 404 {
                print("   ❌ \(tableName) - NOT FOUND")
            } else {
                print("   ⚠️  \(tableName) - status: \(httpResponse.statusCode)")
            }
        }
    }
}

Task {
    do {
        try await checkUsersTable()
        try await checkLeaderboardTable()
        try await checkRPCFunctions()
        try await checkAllTables()
        
        print("\n" + String(repeating: "=", count: 50))
        print("✅ Schema check complete!")
        print(String(repeating: "=", count: 50))
    } catch {
        print("\n❌ Error: \(error)")
    }
    
    exit(0)
}

RunLoop.main.run()
