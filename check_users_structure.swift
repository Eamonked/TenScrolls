#!/usr/bin/env swift

import Foundation

let projectURL = "https://shodbktjnfadxalegapd.supabase.co"
let publishableKey = "sb_publishable_GtijMsXiS-nXTMFaBAv6dw_g31V4A0W"

print("🔍 Checking Users Table Structure...")
print("")

// First, let's create a test user via anonymous auth
func testAnonymousAuth() async throws -> String? {
    let url = URL(string: "\(projectURL)/auth/v1/signup")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.addValue(publishableKey, forHTTPHeaderField: "apikey")
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let body = ["options": ["data": [:]]] as [String: Any]
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    
    let (data, response) = try await URLSession.shared.data(for: request)
    
    if let httpResponse = response as? HTTPURLResponse {
        print("📝 Anonymous Auth Status: \(httpResponse.statusCode)")
        
        if httpResponse.statusCode == 200 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let accessToken = json["access_token"] as? String {
                print("✅ Got auth token")
                return accessToken
            }
        } else {
            let errorText = String(data: data, encoding: .utf8) ?? "unknown"
            print("Response: \(errorText)")
        }
    }
    return nil
}

// Check the users table with auth
func checkUsersTableWithAuth(token: String) async throws {
    let url = URL(string: "\(projectURL)/rest/v1/users?select=*")!
    var request = URLRequest(url: url)
    request.addValue(publishableKey, forHTTPHeaderField: "apikey")
    request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let (data, response) = try await URLSession.shared.data(for: request)
    
    if let httpResponse = response as? HTTPURLResponse {
        print("\n📋 Users Table (Authenticated) Status: \(httpResponse.statusCode)")
        
        if httpResponse.statusCode == 200 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                print("✅ Can query users table")
                print("📝 Found \(json.count) users")
                
                if let first = json.first {
                    print("\n🔍 User record fields:")
                    for (key, value) in first.sorted(by: { $0.key < $1.key }) {
                        print("   - \(key): \(value)")
                    }
                }
            }
        } else {
            let errorText = String(data: data, encoding: .utf8) ?? "unknown"
            print("❌ Error: \(errorText)")
        }
    }
}

// Check what get_leaderboard returns
func checkLeaderboardRPC(token: String) async throws {
    let url = URL(string: "\(projectURL)/rest/v1/rpc/get_leaderboard")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.addValue(publishableKey, forHTTPHeaderField: "apikey")
    request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let body = ["p_limit": 5] as [String: Any]
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    
    let (data, response) = try await URLSession.shared.data(for: request)
    
    if let httpResponse = response as? HTTPURLResponse {
        print("\n📊 get_leaderboard RPC Status: \(httpResponse.statusCode)")
        
        if httpResponse.statusCode == 200 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                print("✅ get_leaderboard works")
                print("📝 Returns \(json.count) entries")
                
                if let first = json.first {
                    print("\n🔍 Leaderboard entry fields:")
                    for (key, value) in first.sorted(by: { $0.key < $1.key }) {
                        print("   - \(key): \(value)")
                    }
                }
            }
        } else {
            let errorText = String(data: data, encoding: .utf8) ?? "unknown"
            print("Response: \(errorText)")
        }
    }
}

Task {
    do {
        if let token = try await testAnonymousAuth() {
            try await checkUsersTableWithAuth(token: token)
            try await checkLeaderboardRPC(token: token)
        }
        
        print("\n" + String(repeating: "=", count: 50))
        print("✅ Check complete!")
        print(String(repeating: "=", count: 50))
    } catch {
        print("\n❌ Error: \(error)")
    }
    
    exit(0)
}

RunLoop.main.run()
