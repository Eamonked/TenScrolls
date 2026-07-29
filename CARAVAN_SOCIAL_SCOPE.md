# Caravan Social Layer — Build Scope

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

| Piece | Status |
|---|---|
| Trader identity (handle + 6-char `traderCode`) | ✅ Built, client-only |
| Add friend by code, remove friend | ✅ Built (`CaravanView.addFriendCard`) |
| Streak duel view (1v1 comparison) | ✅ Built (`DuelCard`) |
| Global leaderboard UI (rank, XP, streak) | ✅ Built (`leaderboardSection`) |
| Cheer / encouragement button | ✅ Built (UI only) |
| **Backend for all of the above** (`CloudKitLeaderboard`) | 🔴 Fully stubbed — every method is a no-op or returns empty, explicitly "for next phase migration (Supabase)" |
| Postgres schema for reading sessions/streaks/leaderboard | ✅ Designed (`DATABASE_SCHEMA.md`) but **not deployed anywhere**, and doesn't cover friends or cheers |
| Trader-code uniqueness | 🔴 Generated client-side (`AppState.generateTraderCode()`), no server-side collision check or reservation |
| Invite mechanism | 🔴 Copy-paste the code only — no deep link, no `onOpenURL`, no Universal Links / URL scheme anywhere in `TenScrollsApp.swift` or `Info.plist` |
| Shareable streak/milestone image ("Streak Seal") | 🔴 Does not exist — no share-card view, no `ImageRenderer` usage, no share sheet integration found |
| Leaderboard anti-cheat | ⚠️ Session-level anti-cheat is solid (server time, window gating, unique constraints) but `leaderboard_snapshots` as designed looks like a client-published snapshot — nothing yet ties XP/streak on the leaderboard back to validated `session_completions` |

**Bottom line:** this isn't a "build social from scratch" project — it's "wire up
a backend to an already-built UI, plus build the two acquisition mechanics
(invite, shareable seal) the GTM plan actually depends on."

---

## 2. Workstreams

### A. Stand up the backend (blocking everything else)
- Deploy a Supabase project; apply the schema in `DATABASE_SCHEMA.md` as a first migration.
- Decide identity model: the schema assumes `auth.uid() = user_id` via RLS, but this app has no login. Use **Supabase anonymous auth**, mint a `users` row on first launch, and store the resulting `user_id` locally alongside `traderCode`.
- Server-side trader-code issuance: move `generateTraderCode()` server-side (or keep client generation but have first-sync `INSERT ... ON CONFLICT DO NOTHING` + retry on collision) so two devices can't collide.
- Replace `CloudKitLeaderboard`'s stubbed body with real Supabase calls. **No UI changes needed** — `CaravanView` already only talks to the actor's public interface (`fetchLeaderboard`, `fetchFriend`, `sendCheer`, `fetchCheerCount`, `publish`), so this is a swap behind an existing seam, not a rewrite.

### B. Extend the schema for friends/cheers
`DATABASE_SCHEMA.md` covers sessions, streaks, and a global leaderboard, but not:
- **Cheers table**: `cheers(id, from_trader_code, to_trader_code, created_at)` + a unique/rate-limit constraint (e.g., one cheer per sender/recipient/day) so `sendCheer` isn't spammable.
- **Friend snapshot fetch**: `fetchFriend(code:)` can just be a public, rate-limited read against `leaderboard_snapshots` keyed by `trader_code` — no separate friendship table needed since this is unidirectional "add by code," not mutual-follow.
- Decide whether `leaderboard_snapshots` is trusted client-reported data (matches current design) or recomputed server-side from `session_completions`/`day_summaries`. As designed, a modified client could publish a fake `xp`/`streak` straight to the leaderboard — worth closing before this is a public/competitive surface, even if session completion itself stays anti-cheated.

### C. Invite flow (this is what the GTM's "frictionless invites" actually requires)
Nothing here exists yet. Needed:
- Associated domain / Universal Link (or at minimum a custom URL scheme) so a shared link opens the app directly to "add friend" pre-filled with the sender's code.
- `onOpenURL` handler in `TenScrollsApp.swift` routing into `CaravanView` with `friendInput` pre-populated.
- A proper share sheet action from the identity card (currently only copies the code to clipboard) — "Share invite link" alongside "Copy code."
- Fallback web landing page for non-users who tap the link (App Store redirect + code passthrough via Universal Link params, since a fresh install can't handle a custom scheme before the app exists on-device).

### D. Shareable Streak Seal (the GTM's Instagram/X asset)
Also doesn't exist. Needed:
- A `ShareCard` SwiftUI view (streak count, level, rank, trader handle) styled to match the app's brass/ink theme.
- Render to `UIImage` via `ImageRenderer` (iOS 16+, fine given the iOS 18 widget target already in use) and hand off to `UIActivityViewController`.
- Trigger points: weekly recap, milestone unlocks (7/14/30/60/100-day, per `Constants.milestones`), and on-demand from the identity card.

### E. Anti-cheat parity for the social surface
Session-level anti-cheat (server time, window gating, grace periods) is already well designed. Before leaderboard/duels go live publicly, decide: does XP/streak shown to friends and on the global board get **derived from validated `session_completions`** (safer, more work) or synced from local state (faster, gameable)? Given the GTM plan explicitly markets "leaderboards" as a differentiator, gameability undermines the pitch — I'd lean toward deriving it server-side, at least for `current_streak`/`best_streak`/`total_days` (the existing `calculate_current_streak()` RPC already does this — it's just not yet what feeds `leaderboard_snapshots`).

---

## 3. Suggested Sequencing

1. **A (backend stand-up)** — unblocks everything; can reuse existing UI as-is once done.
2. **B (schema extensions)** in the same migration pass as A.
3. **E (server-derived stats)** before any public leaderboard exposure — cheap to do now, expensive to retrofit after people notice gamed rankings.
4. **C (invites)** and **D (share seal)** in parallel — these are the two pieces the GTM plan's acquisition loop actually depends on, and neither touches the backend work above.
5. Only once C + D exist does the GTM's TestFlight beta ("20–50 users in 3–4 Caravans, test invite friction") test something real. Right now that beta would just be testing manual code copy-paste, which isn't the mechanic the GTM plan is banking on.

## 4. Open Questions
- Anonymous-auth device loss: if a user reinstalls or switches devices, do they lose their `traderCode`/friends? Worth a lightweight recovery path (e.g., "restore by code" using the existing `traderCode` as a portable identifier) before this becomes a support issue.
- Rate limits / abuse: cheer spam, leaderboard scraping, and code enumeration (6 chars from a 32-symbol alphabet is ~1 billion combinations, but a public leaderboard makes valid codes discoverable — worth confirming that's an acceptable trust model for a habit app, not, say, a payments app).
