# TenScrolls Monetization — Current Status

**Last updated**: 2026-08-05

This replaces `MONETIZATION_IMPLEMENTATION_GUIDE.md`, `MONETIZATION_QUICK_START.md`,
`IMPLEMENTATION_STATUS.md`, and `IMPLEMENTATION_SUMMARY.md`, which described an
earlier, partially-built state (placeholder IAP, `com.tenscrolls.plus.monthly`
product ID, Scroll I gated behind Plus, no offline fallback) that no longer
matches the code. This is the one doc to keep current going forward.

---

## What Plus gates

- **Scroll I is permanently free.** `AppStore.canAccessScroll(1)` always
  returns accessible — no subscription, trial, or day count required. This
  is the hook; there's no going back to gating it without a deliberate
  product decision.
- **Scroll II onward requires Plus** (`hasPlusAccess`): an active
  subscription, an active trial, or a locally-confirmed StoreKit
  entitlement (see below). Enforced at a single choke point,
  `ContentView.attemptOpenScroll`, which every path into a scroll's reader
  goes through.
- Day-progress (`scroll.status`) still governs which scroll is *next in
  sequence* — the subscription gate above is layered on top of that, not a
  replacement for it.
- The **Day 30 paywall** (`shouldShowDay30Paywall`) is a one-time proactive
  nudge shown once `totalDaysCompleted >= 30` for a non-Plus user — not the
  enforcement mechanism itself. It exists because 30 days is roughly what it
  takes to master Scroll I and reach Scroll II naturally. The actual block
  happens at `attemptOpenScroll` regardless of day count.
- The **Day 3 trial offer** (`shouldOfferTrial`) fires after 3 *consecutive*
  fully-completed days (shields don't count) for a still-`free` user, shown
  once (`hasShownTrialOffer`).

## How subscription state is determined

`AppState.hasPlusAccess` is an OR of two independent signals:

```swift
subscriptionStatus.hasAccess || (localEntitlementActive ?? false)
```

1. **`subscriptionStatus`** (`cachedSubscriptionStatus`) — set from the
   Supabase-verified server record (`get_subscription_status` RPC). This is
   the system of record: cross-device state, trial start/end dates,
   `plus_since`, and what the leaderboard's tiered RPCs key off of.
2. **`localEntitlementActive`** — set from
   `StoreKitManager.hasActiveEntitlement()`, checked directly against
   Apple's on-device receipt cache. No network call, no Supabase sign-in.
   This is the fallback that keeps Plus content unlocked when Supabase is
   unreachable but Apple has already verified a real purchase.

Both are refreshed independently on every foreground
(`AppStore.onAppForeground()` calls `refreshLocalEntitlement()` first, then
the network-dependent `refreshSubscriptionStatus()`), and both are also
event-driven via `StoreKitManager.observeTransactionUpdates` for the app's
lifetime.

### Purchase flow

1. `StoreKitManager.purchase()` runs the real App Store sheet; StoreKit
   verifies the result on-device and hands back a signed JWS
   (`Transaction.jwsRepresentation`).
2. `AppStore.activateSubscription(signedTransaction:)` grants
   `localEntitlementActive = true` **immediately** — Apple already verified
   it, so the reader isn't blocked on a server round trip.
3. It then sends the JWS to Supabase's `verify-purchase` Edge Function
   (`supabase/functions/verify-purchase`), which independently re-verifies
   it against Apple's own certificates, confirms the product id is one of
   `ALLOWED_PRODUCT_IDS` (monthly/annual/lifetime — a hardcoded
   monthly-only check here previously rejected annual/lifetime purchases
   with `product_mismatch` even though the client fully supported them;
   fixed alongside the multi-plan paywall work) and, only if valid, calls
   `activate_subscription_verified()` (a `service_role`-only RPC — see
   `006_secure_subscription_activation.sql`, extended in
   `010_track_purchased_product.sql` to also record which product id was
   purchased) to flip `subscription_status` server-side.
4. Outcome handling:
   - **Server confirms** → `cachedSubscriptionStatus = .active`, toast,
     done.
   - **Server explicitly denies** (e.g. transaction already bound to a
     different account) → local grant is revoked. This is a real denial,
     not a connectivity problem, so it should block.
   - **Server unreachable** (thrown error — network, timeout, etc.) → local
     grant stays. Toast tells the reader it'll finish syncing later; the
     next foreground poll or transaction-update event retries.

### Revocation / downgrade flow

`AppStore.reconcileStoreKitEntitlement()` is the single place a subscriber
gets downgraded. It's called both from the poll in
`refreshSubscriptionStatus()` (when the server still says `active`) and from
the event-driven `observeStoreKitEntitlementChanges()` listener. It checks
Apple's entitlement directly; if it's gone, it clears
`localEntitlementActive` immediately (on-device, no network needed) and then
best-effort calls Supabase's `deactivate_subscription` RPC to flip the
server record to `lapsed`. The event-driven half
(`StoreKitManager.observeTransactionUpdates`) matches against *any* id in
`allProductIDs`, not just monthly — a prior version only matched
`subscriptionProductID` (monthly), so a renewal/refund/revocation on
annual or lifetime would never have fired `onEntitlementChange` at all;
fixed alongside the multi-plan work.

### Which plan a subscriber is on

`users.apple_product_id` (added in `010_track_purchased_product.sql`)
records which of the three products the most recent successful activation
was for, and `get_subscription_status()` returns it as
`SubscriptionInfo.purchasedProductId` /
`.purchasedPlanLabel` ("Monthly"/"Annual"/"Lifetime"). Not surfaced in any
view yet — there's no "you're on the Annual plan" UI in Settings today —
but the data is there for whenever that's wanted. Every plan grants
identical `active` access regardless; this is purely informational.

### Trial

The trial is entirely server-side (`start_trial` / `check_trial_expiry`
RPCs) and never touches StoreKit — there's no product to purchase for a
trial. `startTrial()` requires a live Supabase call; there's currently no
offline fallback for *starting* a trial (only for an already-purchased
subscription). Its length is no longer hardcoded: `start_trial()` reads
`trial_days` from the `pricing_config` table (see below), falling back to
10 only if that singleton row is somehow missing.

## Pricing config (single source of truth)

`pricing_config` (migration `009_pricing_config.sql`, singleton row `id =
1`, edited directly via the Supabase dashboard) controls everything about
how Plus is presented **except actual charged amounts**, which only Apple
controls via App Store Connect:

- `trial_days` — length of the free trial (see above).
- `featured_product_id` — which plan is pre-selected/highlighted on the
  paywall. Currently the annual plan, per the product decision to
  prioritize annual over monthly.
- `active_product_ids` — which of the three products (see below) are
  actually offered to new signups right now; a product can exist in App
  Store Connect and still be excluded here.
- `product_badges` — marketing label per product id (e.g. `"BEST VALUE"`
  on annual); missing key means no badge.

`PricingConfigStore.swift` loads and caches this table (same three-layer
fallback pattern as `FeatureGateStore`: in-memory → `UserDefaults` cache →
`PricingConfig.compiledDefault`), and `AppStore.pricingConfigSnapshot`
mirrors it for synchronous reads from views. Refreshed at launch and on
every `onAppForeground()`, same cadence as feature gates.
`Day30PaywallView`, `TrialOfferView`, and the Caravan's locked-ledger CTA
all read from this instead of a hardcoded trial length or price string.

## Product / StoreKit config

- Three product IDs, all live in App Store Connect and mirrored in
  `Configuration.storekit` for local simulator/sandbox testing:
  **`ekme.TenScrolls.plus.monthly`**, **`ekme.TenScrolls.plus.annual`**,
  **`ekme.TenScrolls.plus.lifetime`** (see
  `StoreKitManager.allProductIDs`). Earlier docs referenced
  `com.tenscrolls.plus.monthly` — that was a placeholder and is wrong; if
  you find it anywhere else, fix it. `Configuration.storekit` previously
  only had monthly plus a mis-cased, wrongly-typed yearly product
  (`ekme.Tenscrolls.plus.yearly` under `subscriptionSuiteGroups`, which
  doesn't resolve via `Product.products(for:)`) — fixed to a proper
  `RecurringSubscription` annual entry in the same subscription group,
  plus a `NonConsumable` lifetime entry.
- `StoreKitManager.loadProducts()` fetches all three (needed for
  entitlement checks regardless of what's currently offered);
  `loadProducts(ids:)` fetches just an offered subset (what the paywall
  actually renders, per `pricing_config.active_product_ids`) without
  forcing the full fetch first. Both share one cache, so whichever runs
  first doesn't block the other's correctness.
- There's also a `storeKit.storekit` file in the repo root — confirmed
  empty and not referenced by the `TenScrolls` scheme's
  `StoreKitConfigurationFileReference` (which points at
  `Configuration.storekit`). No longer present as of this writing.
- Edge Function secrets: `ALLOW_XCODE_STOREKIT_TESTING=true` lets local
  Xcode-signed (unsigned-by-Apple) transactions verify during development —
  see the comment block at the top of
  `supabase/functions/verify-purchase/index.ts`. `APPLE_APP_ID` still needs
  to be set once there's a real App Store Connect listing; safe to leave
  unset until then.

## Known gaps / not yet done

- **No end-to-end device testing recorded** for the local-entitlement
  fallback path specifically (kill network mid-purchase, kill network with
  a previously-active local grant, etc.) — see the refreshed
  `TESTING_CHECKLIST.md`.
- **Caravan isn't fully view-only for free/lapsed users** — add-friend,
  cheer, and group actions still have no subscription check (only the
  leaderboard reveal and sharing/export paths are gated).
- **No funnel analytics** (trial shown → started → converted, paywall shown
  → upgraded). Nothing tracks this yet.
- **No introductory-offer/free-trial-via-StoreKit path** — the trial is
  entirely the server-side `pricing_config`/`start_trial` mechanism above;
  none of the three App Store Connect products have a StoreKit-native
  intro offer configured. Fine as-is (avoids Apple's own trial-abuse and
  cross-plan eligibility rules entirely), but worth knowing if anyone goes
  looking for one on the product pages.
- **Migrations `009` and `010` haven't been applied to the live Supabase
  project yet**, and `verify-purchase` hasn't been redeployed with the
  `ALLOWED_PRODUCT_IDS`/`p_product_id` changes — see "Deploying this
  work" below.
- **App Store Connect product IDs need a manual double-check** against
  `StoreKitManager.allProductIDs` before shipping — the
  `Configuration.storekit` mismatch found during this work (wrong casing,
  wrong id, wrong container type on the yearly product) suggests IDs have
  drifted between places before.

## Deploying this work

None of this repo's tools have network access to `supabase.co` or App
Store Connect, so the following need to be run manually:

1. Apply `009_pricing_config.sql` and `010_track_purchased_product.sql` to
   the `tenscrolls` Supabase project, in order, after everything through
   `008` (via the SQL Editor in the dashboard, or `supabase db push` with
   the Supabase CLI pointed at this project).
2. Redeploy the Edge Function: `supabase functions deploy verify-purchase`.
   Required — `activate_subscription_verified` now takes a 4th parameter
   (`p_product_id`) and the old 3-arg signature was dropped by migration
   `010`, so the *previously deployed* function would start failing every
   activation (not just annual/lifetime) until this is redeployed.
3. Confirm `ekme.TenScrolls.plus.monthly` / `.annual` / `.lifetime` exist
   in App Store Connect with exactly those IDs and the real prices, and
   that annual sits in the same subscription group as monthly (Apple
   requires same-group for it to appear as an upgrade/downgrade path
   rather than a separate, non-comparable subscription).
4. Once (1) is live, edit the `pricing_config` row in the dashboard to the
   real trial length, featured plan, and badge copy — the seeded defaults
   (10-day trial, annual featured, "BEST VALUE" badge) are placeholders.
