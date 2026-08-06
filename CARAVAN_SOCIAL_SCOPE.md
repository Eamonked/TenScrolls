# Caravan Social Layer — Build Scope

> **Status (corrected 2026-08-04): substantially stale.** Written when the
> backend was `CloudKitLeaderboard`, fully stubbed. It has since been
> replaced with a real Supabase backend (`SupabaseLeaderboard.swift`), and
> most of workstreams A–D below are now done: server-arbitrated trader
> codes with collision retry, server-enforced cheers, deep-link invites, and
> a shareable streak seal all exist. The "Current State" table immediately
> below is out of date — see the corrected table that replaces it. What's
> still genuinely open is workstream E (leaderboard stats are still
> client-reported, not derived from validated sessions) — that part of this
> doc is accurate and still the real next step.

**Purpose:** Close the gap between what the GTM strategy assumes (a working social
layer driving acquisition/retention) and what's actually implemented, so the
"Caravan" feature is real before marketing spend points at it.

**Correction to earlier review:** I initially said there was no trace of a social
feature in the codebase. That was wrong — I'd only searched filenames. The
Caravan concept is fully designed and the client is fully built
(`CaravanView.swift`, `FriendSnapshot`, `LeaderboardEntry`, `traderCode`/
`friendCodes` in `AppState`). What's missing is narrower and more specific than
"no social feature": **the backend is a stub, and a few specific mechanics the
GTM plan leans on were never built.**

---

## 1. Current State

### Current State (corrected 2026-08-04)

| Piece | Status |
|---|---|
| Trader identity (handle + 6-char `traderCode`) | ✅ Built, **server-arbitrated** — `claimIdentity` RPC with collision retry (`SupabaseLeaderboard.claimIdentity`), not client-generated-and-hoped |
| Add friend by code, remove friend | ✅ Built (`CaravanView.addFriendCard`), reads via `get_trader_by_code` RPC |
| Streak duel view (1v1 comparison) | ✅ Built (`DuelCard`) |
| Global leaderboard UI (rank, XP, streak) | ✅ Built (`leaderboardSection`), reads via `get_leaderboard` RPC (SECURITY DEFINER, no direct table SELECT — see `002_leaderboard_gating.sql`) |
| Cheer / encouragement button | ✅ Built and **server-enforced** — `send_cheer` RPC, one per sender/recipient/day (`004_cheer_gating.sql`), plus push delivery (`register_push_token`, `acknowledge_cheer`) and a "seen" ack status, not just UI |
| **Backend** | ✅ Real Supabase project, anonymous auth (`SupabaseAuth`), not the old stubbed `CloudKitLeaderboard` |
| Postgres schema / migrations | ✅ `002`–`007` applied: leaderboard gating, subscriptions, cheer gating, subscription reconciliation, secure activation, direct messages. `session_completions`/`day_summaries`/`complete_session` from `DATABASE_SCHEMA.md` are **still not deployed** — unchanged from original scope |
| Trader-code uniqueness | ✅ Done — see identity row above |
| Invite mechanism | ✅ Built — `ShareCard.swift` / `SharingViews.swift` exist; no longer copy-paste-only |
| Shareable streak/milestone image ("Streak Seal") | ✅ Built (`ShareCard.swift`) |
| Direct messages | ✅ Built (`SupabaseMessaging.swift`, `007_direct_messages.sql`) — not in original scope at all |
| Reading groups (create/join/list) | ✅ Built (`SupabaseSharing.swift`), backed by a `reading_groups` table and `create_reading_group`/`join_reading_group`/`list_my_reading_groups` RPCs — not in original scope at all, see §5 below |
| Scroll sharing (to a friend or group) | ✅ Built (`SupabaseSharing.shareScroll`/`fetchPendingShares`/`resolveShare`), backed by `share_scroll`/`fetch_pending_shares`/`resolve_scroll_share` RPCs — not in original scope at all, see §5 below |
| Leaderboard anti-cheat (workstream E) | 🔴 **Still open, as originally scoped.** `leaderboard_snapshots` rows (xp, streak, etc.) are still published straight from client `AppState` via `publish()` — nothing yet derives them from validated `session_completions`. This is the one accurate, still-relevant gap from the original doc. |

**Bottom line:** the backend build-out (workstreams A–D) is done. What
remains is workstream E — closing the gap between client-reported leaderboard
stats and server-validated session data — plus deciding whether
`session_completions`/`complete_session` from `DATABASE_SCHEMA.md` are worth
deploying to make that possible, or whether a lighter-weight derivation is
enough.

---

## 2. Workstreams

> Workstreams A–D below are **done** as of 2026-08-04 (see corrected table
> above); left in place for historical context. Only **E** is still live work.

### A. Stand up the backend (blocking everything else) — ✅ DONE
- Deploy a Supabase project; apply the schema in `DATABASE_SCHEMA.md` as a first migration.
- Decide identity model: the schema assumes `auth.uid() = user_id` via RLS, but this app has no login. Use **Supabase anonymous auth**, mint a `users` row on first launch, and store the resulting `user_id` locally alongside `traderCode`.
- Server-side trader-code issuance: move `generateTraderCode()` server-side (or keep client generation but have first-sync `INSERT ... ON CONFLICT DO NOTHING` + retry on collision) so two devices can't collide.
- Replace `CloudKitLeaderboard`'s stubbed body with real Supabase calls. **No UI changes needed** — `CaravanView` already only talks to the actor's public interface (`fetchLeaderboard`, `fetchFriend`, `sendCheer`, `fetchCheerCount`, `publish`), so this is a swap behind an existing seam, not a rewrite.

### B. Extend the schema for friends/cheers — ✅ DONE (cheers; see `004_cheer_gating.sql`)
`DATABASE_SCHEMA.md` covers sessions, streaks, and a global leaderboard, but not:
- **Cheers table**: `cheers(id, from_trader_code, to_trader_code, created_at)` + a unique/rate-limit constraint (e.g., one cheer per sender/recipient/day) so `sendCheer` isn't spammable.
- **Friend snapshot fetch**: `fetchFriend(code:)` can just be a public, rate-limited read against `leaderboard_snapshots` keyed by `trader_code` — no separate friendship table needed since this is unidirectional "add by code," not mutual-follow.
- Decide whether `leaderboard_snapshots` is trusted client-reported data (matches current design) or recomputed server-side from `session_completions`/`day_summaries`. As designed, a modified client could publish a fake `xp`/`streak` straight to the leaderboard — worth closing before this is a public/competitive surface, even if session completion itself stays anti-cheated.

### C. Invite flow (this is what the GTM's "frictionless invites" actually requires) — ✅ DONE
Built via `ShareCard.swift` / `SharingViews.swift`. Original requirements list kept below for reference:
- Associated domain / Universal Link (or at minimum a custom URL scheme) so a shared link opens the app directly to "add friend" pre-filled with the sender's code.
- `onOpenURL` handler in `TenScrollsApp.swift` routing into `CaravanView` with `friendInput` pre-populated.
- A proper share sheet action from the identity card (currently only copies the code to clipboard) — "Share invite link" alongside "Copy code."
- Fallback web landing page for non-users who tap the link (App Store redirect + code passthrough via Universal Link params, since a fresh install can't handle a custom scheme before the app exists on-device).

### D. Shareable Streak Seal (the GTM's Instagram/X asset) — ✅ DONE (`ShareCard.swift`)
Original requirements list kept below for reference:
- A `ShareCard` SwiftUI view (streak count, level, rank, trader handle) styled to match the app's brass/ink theme.
- Render to `UIImage` via `ImageRenderer` (iOS 16+, fine given the iOS 18 widget target already in use) and hand off to `UIActivityViewController`.
- Trigger points: weekly recap, milestone unlocks (7/14/30/60/100-day, per `Constants.milestones`), and on-demand from the identity card.

### E. Anti-cheat parity for the social surface — 🔴 STILL OPEN (the real remaining work)
Session-level anti-cheat (server time, window gating, grace periods) is already well designed. Before leaderboard/duels go live publicly, decide: does XP/streak shown to friends and on the global board get **derived from validated `session_completions`** (safer, more work) or synced from local state (faster, gameable)? Given the GTM plan explicitly markets "leaderboards" as a differentiator, gameability undermines the pitch — I'd lean toward deriving it server-side, at least for `current_streak`/`best_streak`/`total_days` (the existing `calculate_current_streak()` RPC already does this — it's just not yet what feeds `leaderboard_snapshots`).

---

## 3. Suggested Sequencing

1. **A (backend stand-up)** — unblocks everything; can reuse existing UI as-is once done.
2. **B (schema extensions)** in the same migration pass as A.
3. **E (server-derived stats)** before any public leaderboard exposure — cheap to do now, expensive to retrofit after people notice gamed rankings.
4. **C (invites)** and **D (share seal)** in parallel — these are the two pieces the GTM plan's acquisition loop actually depends on, and neither touches the backend work above.
5. Only once C + D exist does the GTM's TestFlight beta ("20–50 users in 3–4 Caravans, test invite friction") test something real. Right now that beta would just be testing manual code copy-paste, which isn't the mechanic the GTM plan is banking on.

## 5. Reading Groups & Scroll Sharing (undocumented until now)

This feature exists entirely outside the original GTM-driven scope above —
it isn't mentioned anywhere in this doc's earlier workstreams, but it's real
and working. Documented here so it has coverage at all.

**What it is:** a way for traders to form a named group (beyond 1:1 friend
duels) and to share a specific scroll/passage — with notes — to either a
single friend by trader code or to a whole group.

**Backend:**
- `reading_groups` table (confirmed live via `check_db_schema.swift` against
  the deployed project)
- `create_reading_group(p_name)` — creates a group, returns `group_id` +
  `group_code`
- `join_reading_group(p_code)` — joins by code, returns `group_id` + `name`
- `list_my_reading_groups()` — lists the caller's groups (`ReadingGroupSummary`)
- `share_scroll(p_scroll_number, p_title, p_notes, p_to_trader_code, p_to_group_id)` — shares to one or the other (mutually exclusive params)
- `fetch_pending_shares()` — shares awaiting the caller's response
- `resolve_scroll_share(p_share_id, p_status)` — accept/dismiss a pending share

**Client:** all of the above wired up in `SupabaseSharing.swift`
(`createGroup`, `joinGroup`, `fetchMyGroups`, `shareScroll` (two overloads,
by trader code or by group id), `fetchPendingShares`, `resolveShare`).

**Note on a historical bug, now fixed:** `fetchMyGroups()` carries an inline
comment noting that an earlier version called the RPC by the wrong name
(`fetch_my_reading_groups` instead of the actual `list_my_reading_groups`),
which silently 404'd and always returned an empty list (swallowed by the
function's `catch`). The current code already calls the correct
`list_my_reading_groups` — this is fixed, not an open issue. Flagging only
because `check_existing_rpcs.swift` (one of the diagnostic scripts in this
repo) still lists the old wrong name and will show a false ❌ for it; that's
a stale diagnostic script, not a live bug. Worth updating that script's RPC
name list while touching this area, but not urgent.

**Resolved — leave/delete built (`008_reading_group_leave_delete.sql`).**
WhatsApp-style semantics: any member (including the creator) can leave a
group anytime via `leave_reading_group`; if they were the last member, the
group is auto-deleted as a side effect (cascades to `reading_group_members`
and `shared_scrolls`, both already `ON DELETE CASCADE`). The creator can
also force-delete the group outright at any time via `delete_reading_group`,
regardless of remaining members — enforced server-side (`not_authorized`
for non-creators), not gated client-side. Client: `readingGroupRow` now has
a swipe-to-leave action (mirroring `DuelRow`) plus a long-press "Delete
Group" context menu — shown only when `member_count == 1` (i.e. the
viewer is the last remaining member), since the client has no `is_creator`
signal to gate on otherwise and delete/leave are equivalent at that point.
A creator force-deleting a group that still has other members isn't
reachable from the UI yet — the RPC supports it, but exposing it needs
`is_creator` added to `list_my_reading_groups`'s response first. Both
actions include a confirmation alert and are wired through
`SupabaseSharing.leaveGroup`/`deleteGroup` and
`AppStore.leaveReadingGroup`/`deleteReadingGroup`. Not yet run: the
migration needs to be applied to the live project, and the app needs a
build/run pass to confirm it compiles.

**Original gap notes, kept for history:** verified in both directions
before the fix:
- **Backend:** no `leave_reading_group` or `delete_reading_group` RPC exists
  anywhere in the migrations (`002`–`007`) or the deployed project. Once a
  trader creates or joins a group via `create_reading_group`/
  `join_reading_group`, there is no corresponding way to undo it server-side.
- **Client:** `CaravanView.readingGroupRow` renders only a share button.
  Compare to the friends list one section up (`DuelRow`), which has
  `.swipeActions(edge: .trailing) { Button(role: .destructive, action:
  onRemove) }` for removing a friend — reading groups have no equivalent
  swipe action, context menu, or button of any kind.
- Net effect: joining or creating a group is currently permanent. This also
  raises an undecided product question the backend doesn't yet answer:
  should a group's creator be able to delete it outright (affecting all
  members), versus an ordinary member only being able to leave it? Those are
  two different RPCs with different authorization checks (creator-only vs.
  self), not one.

**Open question:** this whole feature is unmentioned in the GTM plan and in
workstreams A–E above. Worth deciding whether it's a supported, marketed
feature or an internal/experimental one — that affects whether it needs its
own anti-cheat/abuse consideration (e.g. group size limits, share spam) the
way workstream E covers the leaderboard, and now also whether leave/delete
is worth building before this ships more broadly.

## 6. Open Questions
- Anonymous-auth device loss: if a user reinstalls or switches devices, do they lose their `traderCode`/friends? Worth a lightweight recovery path (e.g., "restore by code" using the existing `traderCode` as a portable identifier) before this becomes a support issue.
- Rate limits / abuse: cheer spam, leaderboard scraping, and code enumeration (6 chars from a 32-symbol alphabet is ~1 billion combinations, but a public leaderboard makes valid codes discoverable — worth confirming that's an acceptable trust model for a habit app, not, say, a payments app).
