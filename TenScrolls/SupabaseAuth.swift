import Foundation
import Supabase

/// Shared anonymous-auth gate for the Caravan social layer. Both
/// `SupabaseLeaderboard` and `SupabaseSharing` call into this instead of each
/// managing their own sign-in, so two actors never race into minting two
/// separate anonymous sessions for the same device.
actor SupabaseAuth {
    static let shared = SupabaseAuth()

    private var signInTask: Task<Void, Error>?

    private init() {}

    /// Ensures we have an anonymous Supabase session. Safe to call repeatedly —
    /// concurrent callers await the same in-flight sign-in instead of racing.
    func ensureSignedIn() async throws {
        if let task = signInTask {
            do {
                return try await task.value
            } catch {
                // Don't let a stale failure block retries forever — clear it
                // so the next caller starts a fresh attempt.
                signInTask = nil
                throw error
            }
        }
        let task = Task {
            if SupabaseConfig.client.auth.currentSession == nil {
                _ = try await SupabaseConfig.client.auth.signInAnonymously()
            }
        }
        signInTask = task
        do {
            try await task.value
        } catch {
            signInTask = nil
            throw error
        }
    }
}
