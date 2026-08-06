# Caravan — Cross-Platform Build Scope (iOS + Android)

> **Note (2026-08-04):** `CARAVAN_SOCIAL_SCOPE.md`'s "Current State" table
> has since been corrected — workstreams A–D there (backend, trader codes,
> invites, share seal) are now done; only workstream E (server-derived
> leaderboard stats) is still open. This doc's own content below is
> forward-looking Android/cross-platform planning and is unaffected by that
> — no Android code exists yet either way — but treat any references below
> to "the backend is a stub" as describing the pre-Supabase state, not today.

**Supersedes/extends:** `CARAVAN_SOCIAL_SCOPE.md`. That doc assumed a single
Swift client talking to a backend. This doc adds the constraint that changes
the shape of the work: **the backend must serve an iOS client and an Android
client from day one**, even though only the iOS client exists today.

**Why this matters architecturally:** with a single client, it's tempting to
let business logic live partly in the app. With two clients on different
languages/toolchains and no shared codebase, any rule duplicated in both
clients *will* drift. The fix is the same principle already used for
anti-cheat: **push truth into Postgres (RPCs + RLS), keep clients thin.** The
existing `DATABASE_SCHEMA.md` design already does this for session
completions — that's good news, not a redesign. This scope makes sure Caravan
follows the same pattern instead of quietly becoming iOS-only logic.

---

## 1. What "cross-platform" actually changes

| Concern | If iOS-only | With Android too |
|---|---|---|
| Session/streak validation | Could live client-side | **Must** live in Postgres RPC (already true per `DATABASE_SCHEMA.md` — no change needed) |
| Leaderboard/cheer rules | Could live in `CloudKitLeaderboard` (Swift) | Must live in RPC/RLS so a Kotlin client gets identical behavior without reimplementing rules |
| Auth | Sign in with Apple is natural default | Need a method that works identically on both — anonymous auth (Supabase) is the common denominator; Sign in with Apple/Google become *additive* link options, not the primary path |
| Trader code issuance | Client-generate + hope | Must be server-arbitrated (RPC with uniqueness check + retry), since two platforms generating concurrently makes collisions more likely, not less |
| Push notifications (cheers, duel nudges) | APNs only | Needs APNs **and** FCM, fanned out from one server-side event |
| Invite deep links | Universal Links only | Universal Links (iOS) **and** App Links (Android), same web fallback domain, platform-sniffing redirect |
| Client contract | Implicit (one codebase, one dev) | Needs to be **explicit and versioned** — a doc or OpenAPI/RPC spec both clients build against, since Swift and Kotlin can't share types |

**Net effect on already-written docs:** `DATABASE_SCHEMA.md`'s core design
(RPCs, RLS, server timestamps) needs zero changes for Android — it was never
iOS-specific. What needs to change is: (1) explicitly documenting it as a
contract rather than "the thing AppStore.swift calls," (2) extending it per
`CARAVAN_SOCIAL_SCOPE.md` §B for friends/cheers, and (3) the platform-specific
glue (auth, push, deep links) covered below.

---

## 2. Architecture decision: how Android talks to the backend

**Recommendation: direct Supabase client SDKs on both platforms**, both
hitting the same Postgres schema/RPCs — not a custom REST/GraphQL gateway in
front of Supabase.

Why:
- Supabase ships first-party SDKs for Swift and Kotlin; no client has to
  hand-roll HTTP + auth token refresh.
- Because validation truth already lives in RPC functions (`SECURITY
  DEFINER`) and RLS policies, there's very little "business logic" left for a
  gateway layer to centralize — the database *is* the shared backend logic.
- A gateway adds a service to build, deploy, and version for marginal benefit
  here. Worth revisiting only if/when there's logic too complex for
  Postgres/RPC (e.g. payment processing, heavy fan-out push logic) — the
  notification fan-out in §5 is the most likely future candidate, and
  Supabase Edge Functions can absorb that without a separate service.

**What this requires that doesn't exist yet:** a **written client contract**
— table shapes, RPC names/signatures/return shapes, and error codes — treated
as a versioned interface, not just "read the Swift code." Recommend a single
`CARAVAN_API_CONTRACT.md` (or OpenAPI-style doc for the RPCs) that both the
iOS and future Android implementation are built against, updated in the same
PR as any schema/RPC change. Small overhead now; the alternative is an
Android dev reverse-engineering behavior from `CloudKitLeaderboard.swift`.

---

## 3. Workstreams (cross-platform additions to `CARAVAN_SOCIAL_SCOPE.md`)

### A. Backend stand-up (unchanged from existing scope, confirmed platform-neutral)
- Deploy Supabase project, apply `DATABASE_SCHEMA.md` + friends/cheers
  extension from `CARAVAN_SOCIAL_SCOPE.md` §B.
- Nothing here is iOS-specific — proceed as already scoped.

### B. Server-arbitrated trader codes (tightened from existing scope)
- Move code generation into an RPC: `issue_trader_code()` — server picks the
  candidate, checks uniqueness inside the same transaction, retries on
  collision, returns the final code. Neither client generates codes locally
  anymore; both just call the RPC on first launch.
- This matters more with two platforms: client-side generation "with retry on
  conflict" (as originally scoped) is fine for one client, but reasoning about
  two independent clients racing to claim codes is simpler if the server owns
  it outright.

### C. Auth contract (new — not in original scope)
- **Primary path (both platforms):** Supabase anonymous auth on first launch,
  mint a `users` row, store `user_id` + `traderCode` locally.
- **Recovery path (both platforms):** "Restore by trader code" — already an
  open question in the original scope, now a hard requirement rather than a
  nice-to-have, since Android users switching devices/reinstalling need the
  same recovery UX iOS users do.
- **Do not** make Sign in with Apple the primary identity mechanism — it's
  iOS/macOS-only. If added later, it's an optional *link* on top of the
  anonymous identity (mirrored by Google Sign-In as the Android equivalent),
  not a replacement for it.

### D. Push notification fan-out (new — not in original scope)
Cheers and duel nudges need to reach whichever device the recipient is on.
- Add a `device_tokens` table: `(user_id, platform ['ios'|'android'], token,
  updated_at)`. Each client registers/refreshes its token on launch.
- `sendCheer` RPC (per `CARAVAN_SOCIAL_SCOPE.md` §B) triggers a Supabase Edge
  Function (or a lightweight queue consumer) that looks up the recipient's
  token(s) and dispatches to APNs or FCM depending on `platform`. Keep this
  fan-out server-side — neither client should need platform-conditional logic
  for "how do I notify a friend."
- Out of scope for v1 if timeline is tight: cheers can work as "shows up next
  time the recipient opens Caravan" without push, and push added in a fast-
  follow. Flagging so it's a conscious cut, not an oversight.

### E. Invite deep links, cross-platform (extends original scope §C)
- **iOS:** Universal Links (as already scoped).
- **Android:** App Links, same domain, `assetlinks.json` served alongside
  iOS's `apple-app-site-association` at the same web root.
- **Shared web fallback:** one landing page, platform-sniffed — routes to the
  App Store or Play Store as appropriate, passes the inviter's trader code
  through as a query param either way so post-install attribution works on
  both stores (App Store: needs a deferred deep-linking approach, e.g.
  clipboard-passthrough or a service like Branch/AppsFlyer if native deferred
  linking isn't acceptable; Play Store: Play Install Referrer API handles this
  natively, no third party needed).
- This is the one place where "iOS-only" original scope silently underscoped
  the work — deferred deep linking on iOS after a fresh install is
  meaningfully harder than on Android, worth budgeting for explicitly rather
  than discovering it mid-build.

### F. Android client (new — does not exist yet)
Not covered by the original scope at all, since it predates this
requirement. Two honest options:
1. **Build Android now, in parallel with backend work** — needs its own
   scope (Compose UI mirroring `CaravanView`, Kotlin data layer, etc.), not
   detailed here.
2. **Design backend now, build Android later** — this doc's approach:
   everything above (RPC-first logic, explicit contract, dual push/deep-link
   plumbing) is written so that whenever Android work starts, it's additive
   against a stable contract instead of requiring backend rework.

**Recommend confirming which of these two this scope is actually funding** —
it changes near-term sequencing a lot (see §4).

---

## 4. Suggested Sequencing

1. **A + B** (backend stand-up, server-arbitrated codes) — unblocks
   everything, platform-neutral, do first regardless of Android timeline.
2. **`CARAVAN_API_CONTRACT.md`** written alongside A — cheap now, expensive
   to retrofit once an Android dev is building against assumptions.
3. **C (auth contract)** — needed before any client (existing iOS or future
   Android) can call authenticated RPCs for real.
4. **Server-derived stats** (per original scope §E) before any public
   leaderboard exposure — same reasoning as before, unaffected by platform.
5. **E (deep links)** — do the iOS half first (unblocks the existing app),
   but stand up the shared web landing page and `assetlinks.json` alongside
   `apple-app-site-association` even if Android isn't live yet, so the domain
   contract doesn't need revisiting later.
6. **D (push fan-out)** — can genuinely wait; ship cheers without push first,
   add push once there's a second platform actually consuming it (no point
   building FCM fan-out with zero Android installs to receive it).
7. **F (Android client)** — sequence depends on the answer to the open
   question below.

---

## 5. Open Questions

- **Is Android being built now, or is this scope purely "don't paint the
  backend into an iOS-only corner"?** Determines whether F is an active
  workstream or a future one. Worth pinning down before sequencing gets
  finalized, since it changes whether §D (push) and the Play Store half of
  §E (deep links) are near-term or deferred.
- **Deferred deep linking on iOS**: accept the UX gap (link opens App Store,
  user copies code manually after install) for v1, or bring in a third-party
  attribution SDK (Branch, AppsFlyer, adjust) to close it? Affects both
  platforms' invite-flow polish, but iOS is the harder case.
- **Anonymous-auth device loss** (carried over from original scope, now
  applies identically to both platforms): confirm "restore by trader code" is
  sufficient, or whether a lightweight optional email link is needed for
  peace of mind.
- **Notification provider**: raw APNs/FCM calls from an Edge Function, or a
  unified push provider (OneSignal, etc.) to avoid maintaining two
  integrations by hand? Worth a quick cost/complexity comparison before §D.
