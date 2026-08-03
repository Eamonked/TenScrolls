# Monetization Quick Start Guide

## 🚀 Get Running in 5 Steps

### Step 1: Deploy Database (5 minutes)

1. Open Supabase SQL Editor for your project
2. Copy contents of `003_subscription_model.sql`
3. Paste and run
4. Verify: Run `SELECT * FROM users LIMIT 1;` - should see new subscription columns

### Step 2: Add Files to Xcode (2 minutes)

```bash
# All files are already created in correct locations
# Just add them to Xcode project:
```

1. Open `TenScrolls.xcodeproj`
2. Right-click `TenScrolls` folder → "Add Files to 'TenScrolls'..."
3. Select these files:
   - `SubscriptionModels.swift`
   - `SupabaseSubscription.swift`
   - `Views/TrialOfferView.swift`
   - `Views/Day30PaywallView.swift`
   - `Views/PartialRevealLeaderboardCard.swift`
4. Build (Cmd+B) to verify

### Step 3: Wire Up UI (10 minutes)

#### A. ContentView.swift
Add these sheets:

```swift
.sheet(isPresented: $store.shouldShowTrialOffer) {
    TrialOfferView()
}
.sheet(isPresented: $store.shouldShowDay30Paywall) {
    Day30PaywallView()
}
```

#### B. TenScrollsApp.swift
Add foreground handler:

```swift
.onChange(of: scenePhase) { oldPhase, newPhase in
    if newPhase == .active {
        Task { await store.onAppForeground() }
    }
}
```

#### C. ScrollsView.swift
Add before opening Scroll II:

```swift
// In your scroll tap handler for scroll.id == 2
let access = await store.canAccessScroll(2)
if !access.isAccessible {
    store.shouldShowDay30Paywall = true
    return
}
```

### Step 4: Test Locally (No IAP Needed)

```swift
// The trial offer works without IAP
// Test by:
// 1. Complete 3 consecutive days
// 2. Trial offer should appear
// 3. Tap "Start Free Trial" - works immediately

// For Day 30 paywall testing:
// 1. Temporarily change check to:
//    if state.totalDaysCompleted >= 1  // instead of 30
// 2. Complete 1 day
// 3. Try to access Scroll II
// 4. Paywall should appear
```

### Step 5: Add StoreKit (Later - Optional for Now)

You can deploy and test WITHOUT StoreKit first. When ready:

1. Create subscription in App Store Connect
2. Add `StoreKitManager.swift` (see implementation guide)
3. Update `Day30PaywallView.swift` purchase flow
4. Test with sandbox accounts

---

## ✅ Verification Checklist

**Database**:
- [ ] Migration ran successfully
- [ ] Can query `get_leaderboard_tiered()` function
- [ ] Can call `start_trial()` function

**Xcode**:
- [ ] All 5 new files added
- [ ] Project builds without errors
- [ ] No missing imports

**Runtime Testing**:
- [ ] Trial offer appears after Day 3
- [ ] Trial offer can be started
- [ ] Day 30 paywall blocks Scroll II
- [ ] Subscription status persists across app restarts

---

## 🐛 Common Issues

### "RPC function not found"
**Fix**: Re-run `003_subscription_model.sql` migration

### "Cannot find SubscriptionModels in scope"
**Fix**: Add files to Xcode project target

### Trial offer doesn't appear
**Fix**: 
- Check `store.state.consecutiveDaysCompleted >= 3`
- Verify `hasShownTrialOffer` is `false` in AppState
- Add debug print in `checkEngagementMilestones()`

### Day 30 paywall doesn't show
**Fix**:
- Lower threshold temporarily to `>= 1` day for testing
- Check `totalDaysCompleted` value
- Verify `hasShownDay30Paywall` is `false`

---

## 📊 What Gets Tracked

The implementation automatically tracks:

- **Consecutive days completed** - for trial trigger
- **Total days completed** - for Day 30 gate
- **Subscription status** - cached from server
- **Trial/paywall shown state** - prevents re-showing

No additional analytics setup needed for basic functionality.

---

## 💰 Pricing Setup (App Store Connect)

When ready to launch:

1. **Create In-App Purchase**:
   - Type: Auto-Renewable Subscription
   - Reference Name: "TenScrolls Plus"
   - Product ID: `ekme.TenScrolls.plus.monthly` (must match `StoreKitManager.subscriptionProductID` exactly)

2. **Configure Pricing**:
   - Base Price: $4.99/month
   - Introductory Offer: 10-day free trial

3. **Add to Subscription Group**:
   - Name: "TenScrolls Plus"
   - Rank: 1

4. **Configure Auto-Renewal**:
   - Duration: 1 month
   - Family Sharing: Optional

---

## 🎯 Business Logic Summary

| Event | Trigger | Action |
|-------|---------|--------|
| Day 3 Complete | 3 consecutive days | Show trial offer |
| Trial Started | User accepts | 10 days full access |
| Trial Expires | 10 days pass | Revert to free, show upgrade |
| Day 30 Hit | 30 total days | Gate Scroll II, show paywall |
| Plus Activated | IAP purchase | Full permanent access |

---

## 🔗 Full Documentation

See `MONETIZATION_IMPLEMENTATION_GUIDE.md` for:
- Complete implementation details
- StoreKit integration guide
- Analytics setup
- Production deployment checklist
- Troubleshooting guide

