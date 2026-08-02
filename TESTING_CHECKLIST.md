# Monetization Testing Checklist

## 🧪 Pre-Deployment Testing

### Phase 1: Database Migration

- [ ] **Run migration successfully**
  ```sql
  -- In Supabase SQL Editor:
  -- Paste 003_subscription_model.sql
  -- Execute
  -- Verify no errors
  ```

- [ ] **Verify columns exist**
  ```sql
  SELECT column_name, data_type 
  FROM information_schema.columns 
  WHERE table_name = 'users' 
  AND column_name LIKE '%subscription%';
  -- Should see: subscription_status, trial_start_date, trial_end_date, plus_since
  ```

- [ ] **Test RPC functions**
  ```sql
  -- Test get_subscription_status
  SELECT * FROM get_subscription_status();
  
  -- Test start_trial
  SELECT * FROM start_trial();
  
  -- Test get_leaderboard_tiered
  SELECT * FROM get_leaderboard_tiered(10);
  ```

### Phase 2: Xcode Build

- [ ] **Add all new files to project**
  - SubscriptionModels.swift
  - SupabaseSubscription.swift
  - TrialOfferView.swift
  - Day30PaywallView.swift
  - PartialRevealLeaderboardCard.swift

- [ ] **Build succeeds** (Cmd+B)
- [ ] **No missing imports**
- [ ] **No compiler warnings** (optional, but clean)

### Phase 3: Trial Offer Flow

- [ ] **Trigger Day 3 offer**
  1. Launch app fresh
  2. Complete all 3 sessions on Day 1
  3. Complete all 3 sessions on Day 2
  4. Complete all 3 sessions on Day 3
  5. After final session → Trial offer should appear

- [ ] **Trial offer UI displays correctly**
  - "Join the Caravan" heading
  - Shows 3 benefits
  - "Start Free Trial" button
  - "Maybe later" button
  - Clean design matching app theme

- [ ] **Start trial succeeds**
  1. Tap "Start Free Trial"
  2. Button shows loading state
  3. Toast appears: "Trial started!"
  4. Sheet dismisses automatically

- [ ] **Trial offer doesn't repeat**
  1. Force close app
  2. Reopen
  3. Trial offer should NOT appear again
  4. Even if manually triggering `checkEngagementMilestones()`

- [ ] **Dismiss trial offer works**
  1. Reset app state (delete and reinstall)
  2. Trigger Day 3 offer again
  3. Tap "Maybe later"
  4. Sheet dismisses
  5. Offer doesn't appear again

### Phase 4: Subscription State

- [ ] **Subscription status persists**
  1. Start trial
  2. Force close app
  3. Reopen
  4. Subscription status should be "trialing"
  5. Check: `print(store.state.subscriptionStatus)`

- [ ] **Subscription syncs from server**
  1. Launch app
  2. Wait for `onAppForeground()` to complete
  3. Status should match server state
  4. Check Supabase users table: `subscription_status` column

- [ ] **Trial expiry works**
  1. In Supabase: Set `trial_end_date` to past date
  2. Launch app (or bring to foreground)
  3. Should show toast: "Your trial has ended"
  4. Status should change to "lapsed"

### Phase 5: Day 30 Paywall

- [ ] **Trigger paywall (temporary hack for testing)**
  ```swift
  // In AppState.swift, temporarily change:
  var shouldShowDay30Paywall: Bool {
      totalDaysCompleted >= 1 &&  // Changed from 30 to 1
      !(hasShownDay30Paywall ?? false) &&
      !hasPlusAccess
  }
  ```

- [ ] **Paywall blocks Scroll II**
  1. Complete 1 day (or 30 for real test)
  2. Try to tap/open Scroll II
  3. Paywall should appear instead
  4. Scroll II should NOT open

- [ ] **Paywall UI displays correctly**
  - "You've reached Day 30" heading
  - Lock icon
  - Shows user stats (streak, XP, level)
  - Shows percentile if available
  - "Upgrade to Plus" button
  - Pricing shown: "$4.99/month"

- [ ] **Paywall dismisses correctly**
  1. Tap "Not now"
  2. Sheet dismisses
  3. Paywall doesn't reappear on next scroll tap
  4. Check: `hasShownDay30Paywall` is true

- [ ] **Plus bypasses paywall**
  1. Activate subscription (see next section)
  2. Try to access Scroll II
  3. Should open directly, no paywall
  4. Even at 30+ days

### Phase 6: Subscription Activation

- [ ] **Manual activation works** (for testing without IAP)
  ```swift
  // In console or button:
  Task {
      await store.activateSubscription()
  }
  ```
  1. Call activateSubscription()
  2. Toast appears: "Welcome to Plus!"
  3. Status changes to "active"
  4. Full access granted

- [ ] **Activated state persists**
  1. Activate subscription
  2. Force close app
  3. Reopen
  4. Should still have Plus access
  5. Check: `store.state.subscriptionStatus == .active`

### Phase 7: Tiered Leaderboard

- [ ] **Free user sees partial reveal**
  1. Ensure subscription is "free" or "lapsed"
  2. Navigate to Caravan/Leaderboard tab
  3. Should see PartialRevealLeaderboardCard
  4. Shows percentile ("Top X%")
  5. Shows population count
  6. Shows "Unlock Plus to see your exact rank"

- [ ] **Plus user sees full leaderboard**
  1. Activate subscription
  2. Navigate to Caravan/Leaderboard tab
  3. Should see full list of traders
  4. Shows exact ranks
  5. Shows all trader names and stats

- [ ] **Percentile calculates correctly**
  1. Query `get_leaderboard_tiered()` as free user
  2. Note percentile value
  3. Calculate manually: If you're #3 out of 10, percentile should be ~70
  4. Should match or be close

### Phase 8: Edge Cases

- [ ] **Offline behavior**
  1. Turn off WiFi/cellular
  2. Complete sessions
  3. Try to start trial (should fail gracefully)
  4. Try to access Scroll II (should use cached status)
  5. Turn connection back on
  6. Should sync properly

- [ ] **Fresh install after trial**
  1. Start trial on one device
  2. Delete app
  3. Reinstall (same Apple ID/device)
  4. With anonymous auth, starts fresh
  5. Can start trial again (expected behavior)

- [ ] **Consecutive days reset**
  1. Complete 2 consecutive days
  2. Miss day 3
  3. Complete day 4
  4. `consecutiveDaysCompleted` should be 1, not 3
  5. Trial offer should NOT appear

- [ ] **Shield doesn't count as consecutive day**
  1. Complete day 1
  2. Use shield on day 2 (don't complete sessions)
  3. Complete day 3
  4. `consecutiveDaysCompleted` should be 2, not 3
  5. Shield counts for streak, not consecutive completion

---

## 🎯 Success Criteria

All checks above should pass before considering the implementation complete.

### Critical Path (Must Work)
- ✅ Trial offer appears at Day 3
- ✅ Trial can be started
- ✅ Day 30 paywall blocks Scroll II
- ✅ Subscription status persists
- ✅ Plus access bypasses all gates

### Important (Should Work)
- ✅ Partial reveal shows for free users
- ✅ Full leaderboard shows for Plus users
- ✅ Trial expires correctly
- ✅ Status syncs from server

### Nice to Have (Can Fix Later)
- ✅ Offline graceful degradation
- ✅ Consecutive days accuracy
- ✅ Shield exclusion from consecutive count

---

## 🐛 Known Issues to Watch For

### "Cannot find type 'SubscriptionStatus'"
**Cause**: Files not added to Xcode project
**Fix**: Add SubscriptionModels.swift to target

### Trial offer never appears
**Cause**: `consecutiveDaysCompleted` not incrementing
**Fix**: 
- Check log has entries with `allComplete == true`
- Verify shields aren't being counted
- Add debug print in `consecutiveDaysCompleted` getter

### Paywall doesn't block Scroll II
**Cause**: UI integration missing
**Fix**: Add access check before opening scroll reader

### "RPC function not found"
**Cause**: Migration not run or failed
**Fix**: Re-run 003_subscription_model.sql in Supabase

### Subscription status always shows "free"
**Cause**: Server sync not happening
**Fix**: 
- Check `onAppForeground()` is called
- Verify Supabase auth is working
- Check network connectivity

---

## 📊 Manual Test Scenarios

### Scenario 1: Happy Path - Trial to Paid

1. User completes Days 1-3 consecutively
2. Trial offer appears
3. User starts trial
4. User explores for 10 days (all features unlocked)
5. Day 11: Trial expires, features revert
6. Day 30: Hits paywall on Scroll II
7. User upgrades to Plus
8. Full access forever

**Expected**: Smooth flow, no errors, all gates work

### Scenario 2: Free User Path

1. User completes Days 1-3 consecutively
2. Trial offer appears
3. User dismisses ("Maybe later")
4. Continues using app as free user
5. Day 30: Hits paywall on Scroll II
6. Views leaderboard: sees percentile only
7. Stays free

**Expected**: Limited experience, upgrade prompts work

### Scenario 3: Immediate Subscriber

1. User starts app
2. Explores for 5 minutes
3. Sees paywall accidentally or via settings
4. Subscribes immediately
5. Never sees trial offer (already has access)
6. Full experience from Day 1

**Expected**: No trial offer, immediate full access

---

## ✅ Final Verification

Before considering implementation complete:

- [ ] All "Critical Path" items pass
- [ ] All "Important" items pass
- [ ] At least 2 full scenarios tested end-to-end
- [ ] No crashes or hangs
- [ ] UI looks polished (no placeholder text visible)
- [ ] Performance is smooth (no lag opening sheets)

---

## 📝 Test Results Log

Use this template to track your testing:

```
Date: ___________
Tester: ___________
Device: ___________
iOS Version: ___________

Phase 1: Database
- Migration: [ ] Pass [ ] Fail
- RPC functions: [ ] Pass [ ] Fail

Phase 2: Build
- Files added: [ ] Pass [ ] Fail
- Compiles: [ ] Pass [ ] Fail

Phase 3: Trial Offer
- Appears Day 3: [ ] Pass [ ] Fail
- Activates trial: [ ] Pass [ ] Fail
- Doesn't repeat: [ ] Pass [ ] Fail

Phase 4: Subscription State
- Persists: [ ] Pass [ ] Fail
- Syncs: [ ] Pass [ ] Fail
- Expires: [ ] Pass [ ] Fail

Phase 5: Day 30 Paywall
- Blocks Scroll II: [ ] Pass [ ] Fail
- UI correct: [ ] Pass [ ] Fail
- Plus bypasses: [ ] Pass [ ] Fail

Phase 6: Activation
- Manual works: [ ] Pass [ ] Fail
- State persists: [ ] Pass [ ] Fail

Phase 7: Leaderboard
- Partial reveal: [ ] Pass [ ] Fail
- Full access Plus: [ ] Pass [ ] Fail

Phase 8: Edge Cases
- Offline: [ ] Pass [ ] Fail
- Consecutive reset: [ ] Pass [ ] Fail
- Shield exclusion: [ ] Pass [ ] Fail

Notes:
_______________________________
_______________________________
_______________________________
```

