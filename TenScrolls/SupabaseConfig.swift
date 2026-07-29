import Foundation
import Supabase

/// Central Supabase client for the Caravan social layer (leaderboard, friends,
/// cheers). Anonymous-auth only — no email/password, matching the rest of the
/// app's zero-friction, no-login design.
///
/// Project: `tenscrolls` (Supabase org "Nokael", free tier). Schema + RPCs are
/// defined in DATABASE_SCHEMA.md and the `caravan_core_schema` /
/// `fix_function_search_path` migrations applied to that project.
enum SupabaseConfig {
    static let projectURL = URL(string: "https://shodbktjnfadxalegapd.supabase.co")!

    /// Publishable key — safe to ship in the client, same trust level as the
    /// old "anon key". All real access control happens via RLS + the
    /// SECURITY DEFINER RPCs on the Postgres side, not this key.
    static let publishableKey = "sb_publishable_GtijMsXiS-nXTMFaBAv6dw_g31V4A0W"

    static let client = SupabaseClient(supabaseURL: projectURL, supabaseKey: publishableKey)
}
