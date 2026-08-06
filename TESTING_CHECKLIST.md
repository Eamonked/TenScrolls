# Monetization Testing Checklist

**Last updated**: 2026-08-05 — updated for the multi-plan pricing rollout
(pricing_config, monthly/annual/lifetime, per-plan activation tracking).
See `MONETIZATION_STATUS.md` for how the system works.

## Phase 1: Database

- [ ] Migrations `002`–`010` applied on Supabase, including
      `006_secure_subscription_activation.sql` (locks `activate_subscription`
      to `service_role`), `009_pricing_config.sql` (pricing control table +
      `get_pricing_config()`), and `010_track_purchased_product.sql`
      (per-plan activation tracking — changes `activate_subscription_verified`'s
      signature and `get_subscription_status()`'s return shape, so these
      must be applied together, not independently).
- [ ] `verify-purchase` Edge Function deployed
      (`supabase functions deploy verify-purchase`) — must be redeployed
      after the `ALLOWED_PRODUCT_IDS`/`p_product_id` changes, or annual and
      lifetime purchases will clear Apple's purchase sheet and then fail
      server-side with `product_mismatch`.
- [ ] `get_subscription_status()`, `start_trial()`, `check_trial_expiry()`,
      `deactivate_subscription()`, `get_leaderboard_tiered()`,
      `get_pricing_config()` all callable.

## Phase 2: Xcode Build

- [ ] Project builds clean (Cmd+B).
- [ ] All three product IDs in `Configuration.storekit` match
      `StoreKitManager.allProductIDs` exactly:
      `ekme.TenScrolls.plus.monthly` (RecurringSubscription),
      `ekme.TenScrolls.plus.annual` (RecurringSubscription, same
      subscription group as monthly), `ekme.TenScrolls.plus.lifetime`
      (NonConsumable).
- [ ] Same three IDs are configured in App Store Connect with the intended
      real prices before any TestFlight/production build ships —
      `Configuration.storekit` only governs local simulator/sandbox
      testing.

## Phase 3: Scroll I is free (no gate)

- [ ] Fresh install, no sign-in / no trial / no purchase → Scroll I opens
      directly via `attemptOpenScroll`.
- [ ] Scroll I opens even fully offline (airplane mode from first launch).
- [ ] Search results, sharing, and Commonplace Book export for Scroll I's
      notes — confirm current gating behavior matches intent (these still
      gate on the blanket `hasPlusAccess` check, not per-scroll, as of this
      writing; flag if that should change).

## Phase 4: Scroll II+ gate

- [ ] As a free, non-trialing, non-purchased user, attempting to open
      Scroll II routes to the Day 30 paywall sheet instead of opening the
      reader — regardless of `totalDaysCompleted` (the gate isn't day-based,
      only the *nudge* is).
- [ ] Trial or Plus user opens Scroll II directly, no paywall.

## Phase 5: Trial flow

- [ ] Complete 3 consecutive fully-completed days → trial offer appears
      once, showing `pricing_config.trial_days` (not a hardcoded number —
      edit the row and confirm the copy changes on next launch/foreground).
- [ ] Starting the trial requires network (server-only, no StoreKit) — test
      the failure toast with network off.
- [ ] Trial offer does not reappear after being shown once
      (`hasShownTrialOffer`).
- [ ] `check_trial_expiry` flips status to `lapsed` and shows the expiry
      toast when `trial_end_date` is in the past.
- [ ] Changing `trial_days` in the `pricing_config` dashboard row and
      starting a *new* trial reflects the new length in `trial_end_date`
      (confirms `start_trial()` reads the table, not the old hardcoded 10).

## Phase 6: Purchase — happy path (online)

- [ ] `Day30PaywallView` renders one row per
      `pricing_config.active_product_ids`, each with StoreKit's live price
      and, on the featured plan, its badge from `product_badges`.
- [ ] The row matching `pricing_config.featured_product_id` is
      pre-selected when the paywall opens.
- [ ] Repeat the full purchase flow below for **each** offered plan, not
      just monthly — annual and lifetime exercise the
      `ALLOWED_PRODUCT_IDS` check in `verify-purchase` and the
      `p_product_id` write in `activate_subscription_verified` that
      monthly alone won't catch.
- [ ] `StoreKitManager.purchase(productId:)` completes for the selected
      plan, JWS is produced.
- [ ] `activateSubscription(signedTransaction:)` sets local access
      immediately, then server confirms → `cachedSubscriptionStatus =
      .active`, "Welcome to Plus!" toast, paywall dismisses.
- [ ] `get_subscription_status()`'s `apple_product_id` matches the plan
      actually purchased (check via `SubscriptionInfo.purchasedProductId`/
      `.purchasedPlanLabel`, or query `users.apple_product_id` directly).
- [ ] Force-quit and relaunch: Plus access persists (both
      `cachedSubscriptionStatus` and `localEntitlementActive` should reflect
      `active` after the next foreground sync) — for the **lifetime** plan
      specifically, confirm this holds with no active recurring
      subscription at all (`Transaction.currentEntitlements` still reports
      the non-consumable as owned indefinitely).

## Phase 7: Purchase — server unreachable (the actual point of this change)

- [ ] Turn off network *after* StoreKit's purchase sheet confirms but
      *before* `verify-purchase` can be reached (airplane mode immediately
      after tapping Subscribe, or block Supabase's domain specifically).
- [ ] Expect: local access grants immediately, paywall dismisses, toast
      says syncing will finish later — Scroll II+ opens right away.
- [ ] Force-quit while still offline, relaunch while still offline: Scroll
      II+ should still be accessible (`localEntitlementActive` persisted
      from the earlier grant).
- [ ] Restore network, foreground the app: `refreshSubscriptionStatus()`
      should now succeed and `cachedSubscriptionStatus` should catch up to
      `active`.

## Phase 8: Purchase — explicit server denial

- [ ] Simulate `verify-purchase` returning `success: false` (e.g. reuse a
      JWS already bound to a different test account). Expect: local grant
      is revoked, toast shows the denial message, paywall stays up.

## Phase 9: Revocation / refund

- [ ] Revoke the sandbox subscription (StoreKit Test settings, or via
      App Store Connect sandbox tools).
- [ ] With the app open: `observeTransactionUpdates` should fire for
      **any** of the three product IDs, not just monthly (confirms the
      `Self.allProductIDs.contains(...)` check, not the old
      monthly-only equality check) —
      `reconcileStoreKitEntitlement()` should clear `localEntitlementActive`
      immediately (no network needed) and best-effort call
      `deactivate_subscription`.
- [ ] With the app closed at time of revocation: next foreground should
      catch it via the `refreshSubscriptionStatus()` poll instead.
- [ ] Confirm Scroll II+ locks back down and the "subscription has ended"
      toast appears.
- [ ] Lifetime purchases have nothing to revoke in normal operation (no
      renewal to fail) — skip this phase for that plan except via an
      explicit sandbox refund, which should behave the same as any other
      revoked transaction.

## Phase 10: Tiered leaderboard

- [ ] Free/lapsed user sees `PartialRevealLeaderboardCard` (percentile +
      population + cheers, no exact rank).
- [ ] Plus/trialing user sees the full leaderboard.
- [ ] Free/lapsed caller of `get_leaderboard_tiered` does not receive
      `population_count` server-side (migration `008`, if applied) even if
      client-side display logic is bypassed.

## Phase 11: Edge cases

- [ ] Consecutive-day counter resets correctly on a missed day (shields
      don't count toward it).
- [ ] Reinstall on the same Apple ID with an existing entitlement:
      `StoreKitManager.currentEntitlementJWS()` should let the app recognize
      Plus without the system "already subscribed" alert blocking a fresh
      `purchase()` call.

---

## Known gaps not covered by this checklist yet

- No automated tests — everything above is manual.
- Caravan add-friend/cheer/group actions aren't gated by subscription at
  all (separate from scroll/search/share/export gating) — not this
  checklist's scope, but worth its own pass.
