import Foundation

/// Single source of truth for "what requires Plus" across the entire app.
///
/// This is the Swift half of the `feature_gates` table (see the
/// `feature_gates_registry` migration) — every case here must have a
/// matching row keyed by `rawValue` in that table. The table is the real
/// control surface: Eamon edits `requires_plus` there directly (Supabase
/// dashboard, Table Editor or SQL) and every client picks it up on its next
/// foreground refresh, no build/release needed. `defaultRequiresPlus` below
/// only exists as the offline/first-launch fallback for `FeatureGateStore`,
/// and should be kept in sync with whatever's actually seeded in the table
/// (see the migration's INSERT) rather than treated as its own source of
/// truth — if the two drift, the table always wins once it's reachable.
///
/// Adding a new gateable feature: add a case here (with a default), add a
/// matching row to `feature_gates` in Supabase, and call
/// `store.isAccessible(.yourCase)` at the point that needs to check it.
enum AppFeature: String, CaseIterable, Codable {
    // MARK: Scrolls
    /// The core paywall — Scroll II through X. Scroll I is hardcoded free
    /// in `AppStore.canAccessScroll` and has no gate at all, by design; it
    /// can never be controlled by this table even if someone adds a row
    /// for it.
    case scrollContent = "scroll_content"
    /// Send-to-friend / destination-sheet share actions in `ScrollsView`.
    case scrollSharing = "scroll_sharing"
    /// Reading a shared scroll's notes and importing it into a slot
    /// (`SharingViews`).
    case scrollImport = "scroll_import"
    /// Search result content preview for gated scrolls (`SearchView`).
    case scrollSearchPreview = "scroll_search_preview"
    /// Commonplace Book export (`SettingsView.exportCommonplace`).
    case commonplaceExport = "commonplace_export"

    // MARK: Library
    /// "Save this excerpt as a Scroll" from a Library book's highlight menu
    /// (`PDFReaderView`, `LibraryReaderView`).
    case saveAsScroll = "save_as_scroll"

    // MARK: Caravan
    /// Full leaderboard (rank + names) vs the partial-reveal percentile
    /// card. Client-side mirror only — the actual enforcement is
    /// server-side in `get_leaderboard_tiered()` and can't be changed by
    /// flipping this table, since a client can't be trusted to self-report
    /// its own gating. Kept here so the map is complete and the client UI
    /// doesn't show a mismatched state.
    case leaderboardFullView = "leaderboard_full_view"
    /// The blurred invite card / trader code reveal in `CaravanView`.
    case caravanInvite = "caravan_invite"
    /// Sending a cheer to a friend.
    case caravanCheer = "caravan_cheer"
    /// Adding a friend by code. Free today — see `MONETIZATION_STATUS.md`'s
    /// "known gaps" note.
    case caravanAddFriend = "caravan_add_friend"
    /// Creating or joining a reading group. Free today, same known gap.
    case caravanJoinGroup = "caravan_join_group"
    /// Sending a direct message. Free today, same known gap.
    case caravanDirectMessage = "caravan_direct_message"

    // MARK: Always-free sections (listed for a complete map, not because
    // anything here is expected to become gated)
    case journal = "journal"
    case habits = "habits"
    case todaySessions = "today_sessions"
    /// Unlocked by the in-app "seals" currency, not by Plus — not actually
    /// wired to `subscription_status` anywhere. Listed for completeness.
    case themes = "themes"

    /// Compiled-in fallback used only when `feature_gates` hasn't been
    /// fetched yet (first launch, offline) — see `FeatureGateStore`. Must
    /// match the `requires_plus` seeded for this key in the migration;
    /// the live table is what actually governs behavior once reachable.
    var defaultRequiresPlus: Bool {
        switch self {
        case .scrollContent, .scrollSharing, .scrollImport, .scrollSearchPreview,
             .commonplaceExport, .saveAsScroll, .leaderboardFullView,
             .caravanInvite, .caravanCheer:
            return true
        case .caravanAddFriend, .caravanJoinGroup, .caravanDirectMessage,
             .journal, .habits, .todaySessions, .themes:
            return false
        }
    }

    var section: String {
        switch self {
        case .scrollContent, .scrollSharing, .scrollImport, .scrollSearchPreview, .commonplaceExport:
            return "Scrolls"
        case .saveAsScroll:
            return "Library"
        case .leaderboardFullView, .caravanInvite, .caravanCheer, .caravanAddFriend, .caravanJoinGroup, .caravanDirectMessage:
            return "Caravan"
        case .journal: return "Journal"
        case .habits: return "Habits"
        case .todaySessions: return "Today"
        case .themes: return "Settings"
        }
    }

    var label: String {
        switch self {
        case .scrollContent: return "Reading Scroll II–X"
        case .scrollSharing: return "Sharing a scroll (send/export)"
        case .scrollImport: return "Viewing/importing a shared scroll"
        case .scrollSearchPreview: return "Search result content preview"
        case .commonplaceExport: return "Commonplace Book export"
        case .saveAsScroll: return "Save Library excerpt as a Scroll"
        case .leaderboardFullView: return "Full leaderboard (rank + names)"
        case .caravanInvite: return "Invite section / trader code reveal"
        case .caravanCheer: return "Sending a cheer to a friend"
        case .caravanAddFriend: return "Adding a friend by code"
        case .caravanJoinGroup: return "Creating/joining a reading group"
        case .caravanDirectMessage: return "Sending a direct message"
        case .journal: return "Journal (all entries + widget)"
        case .habits: return "Custom habit tracking"
        case .todaySessions: return "Daily dawn/midday/dusk stamps"
        case .themes: return "Theme unlocks (seals currency)"
        }
    }
}
