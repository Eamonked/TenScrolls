# TenScrolls Monetization Implementation Guide

## ✅ What's Been Implemented

### Phase 1: Data Model & Backend Foundations

**Database Schema** (`003_subscription_model.sql`):
- ✅ Subscription fields added to `users` table:
  - `subscription_status` (free/trialing/active/lapsed)
  - `trial_start_date`, `trial_end_date`
  - `plus_since`, `caravan_joined_at`
- ✅ Server-side functions for subscription management:
  - `get_subscription_status()` - Fetch user's subscription info
  - `start_trial()` - Begin 10-day free trial
  - `activate_subscription()` - Activate Plus after IAP purchase
  - `check_trial_expiry()` - Check and update expired trials
  - `calculate_percentile()` - Calculate user's percentile bucket
  - `get_leaderboard_tiered()` - Tiered leaderboard (full vs partial reveal)
  - `can_access_scroll_two()` - Day 30 content gate
  - `mark_caravan_joined()` - Track Caravan opt-in

**Swift Models** (`SubscriptionModels.swift`):
- ✅ `SubscriptionStatus` enum
- ✅ `SubscriptionInfo` struct
- ✅ `TieredLeaderboardEntry` struct
- ✅ `EngagementMilestone` logic
- ✅ `ScrollAccess` struct for content gating

**Subscription Service** (`SupabaseSubscription.swift`):
- ✅ Full actor-based subscription service
- ✅ Trial management
- ✅ Subscription activation
- ✅ Tiered leaderboard fetching
- ✅ Content access gates

**App State Updates**:
- ✅ `AppState` now tracks:
  - Cached subscription status
  - Trial offer shown status
  - Day 30 paywall shown status
  - Consecutive days completed (for trial trigger)
- ✅ `AppStore` subscription methods:
  - `refreshSubscriptionStatus()`
  - `startTrial()`
  - `activateSubscription()`
  - `checkEngagementMilestones()`
  - `canAccessScroll()`
  - `onAppForeground()`

### Phase 2: Engagement Trigger Logic

✅ **Consecutive day tracking**: `AppState.consecutiveDaysCompleted`
✅ **Trial offer trigger**: Fires after 3 consecutive completed days
✅ **Milestone checking**: `checkEngagementMilestones()` called after session completion

### Phase 3: The One-Way Mirror

✅ **Partial reveal card** (`PartialRevealLeaderboardCard.swift`):
- Shows percentile bucket only
- Displays cheer count
- Shows population signal
- Upgrade prompt

✅ **Server-side leaderboard gating**: `get_leaderboard_tiered()` returns different payloads based on subscription status

### Phase 4: Paywalls UI

✅ **Trial offer view** (`TrialOfferView.swift`):
- Clean, dismissible card
- Framed as "joining the Caravan"
- Low-pressure design matching app tone
- Lists Plus benefits

✅ **Day 30 paywall** (`Day30PaywallView.swift`):
- Anchored to user's actual stats
- Shows percentile dynamically
- FOMO-driven but not aggressive

---

## 🚧 What Still Needs Implementation

### 1. Database Migration Deployment

**Action Required**: Run `003_subscription_model.sql` on your Supabase project

```bash
# Connect to your Supabase project SQL editor
# Paste and run the contents of 003_subscription_model.sql
```

This will:
- Add subscription columns to users table
- Create all RPC functions
- Set up proper permissions

### 2. UI Integration in Existing Views

You need to integrate the new views into the existing app flow:

#### A. ContentView Integration

Add these sheets to your `ContentView`:

```swift
.sheet(isPresented: $store.shouldShowTrialOffer) {
    TrialOfferView()
        .environmentObject(store)
}
.sheet(isPresented: $store.shouldShowDay30Paywall) {
    Day30PaywallView()
        .environmentObject(store)
}
```

#### B. CaravanView Integration

Update `CaravanView.swift` to show partial reveal for free users:

```swift
// In the leaderboard section
if store.state.hasPlusAccess {
    // Show full leaderboard (existing code)
} else {
    // Show partial reveal
    PartialRevealLeaderboardCard(
        percentile: fetchedPercentile,
        populationCount: fetchedPopulation,
        cheerCount: fetchedCheerCount,
        onUpgrade: { showUpgradeSheet() }
    )
}
```

#### C. ScrollsView Integration

Add content gate before opening Scroll II:

```swift
// Before navigating to scroll reading
if scroll.id == 2 {
    let access = await store.canAccessScroll(2)
    if !access.isAccessible {
        store.shouldShowDay30Paywall = true
        return
    }
}
```

#### D. App Foreground Hook

Add to `TenScrollsApp.swift`:

```swift
.onChange(of: scenePhase) { oldPhase, newPhase in
    if newPhase == .active {
        Task {
            await store.onAppForeground()
        }
    }
}
```

### 3. StoreKit Integration (CRITICAL)

The paywall views currently have placeholder IAP code. You must implement:

**Create `StoreKitManager.swift`**:

```swift
import StoreKit

actor StoreKitManager {
    static let shared = StoreKitManager()
    
    // Product ID from App Store Connect
    private let subscriptionProductID = "com.tenscrolls.plus.monthly"
    
    private var products: [Product] = []
    
    func loadProducts() async throws {
        products = try await Product.products(for: [subscriptionProductID])
    }
    
    func purchase() async throws -> Bool {
        guard let product = products.first else {
            throw StoreError.productNotFound
        }
        
        let result = try await product.purchase()
        
        switch result {
        case .success(let verification):
            // Verify transaction
            let transaction = try checkVerified(verification)
            await transaction.finish()
            return true
        case .userCancelled:
            return false
        case .pending:
            return false
        @unknown default:
            return false
        }
    }
    
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }
    
    enum StoreError: Error {
        case productNotFound
        case failedVerification
    }
}
```

**Update Day30PaywallView.swift**:

```swift
private func upgradeToPlus() {
    isActivating = true
    Task {
        do {
            let purchased = try await StoreKitManager.shared.purchase()
            if purchased {
                let success = await store.activateSubscription()
                if success {
                    dismiss()
                }
            }
        } catch {
            store.showToast("Purchase failed. Please try again.")
        }
        isActivating = false
    }
}
```

### 4. App Store Connect Configuration

1. **Create subscription** in App Store Connect:
   - Product ID: `com.tenscrolls.plus.monthly`
   - Duration: 1 month
   - Price: $4.99/month
   - Free trial: 10 days

2. **Add subscription group**: "TenScrolls Plus"

3. **Configure trial**: First-time subscribers only, 10 days

### 5. Testing Workflow

#### Local Testing (without IAP):

The implementation includes simulation paths for testing:

```swift
// In TrialOfferView, startTrial() works without IAP
// In Day30PaywallView, you can temporarily bypass IAP by calling:
await store.activateSubscription()
```

#### StoreKit Testing:

1. Create `Configuration.storekit` file in Xcode
2. Add your subscription product
3. Test purchase flows in simulator
4. Test with sandbox accounts

### 6. Analytics Events (Phase 6)

Add analytics tracking:

```swift
// When trial offer is shown
Analytics.track("trial_offer_shown", properties: [
    "consecutive_days": store.state.consecutiveDaysCompleted
])

// When trial is started
Analytics.track("trial_started")

// When Day 30 paywall is shown
Analytics.track("day_30_paywall_shown", properties: [
    "percentile": percentile,
    "total_days": store.state.totalDaysCompleted
])

// When Plus is activated
Analytics.track("subscription_activated", properties: [
    "source": "trial" or "day_30_paywall"
])
```

---

## 📋 Deployment Checklist

### Backend

- [ ] Run `003_subscription_model.sql` migration on Supabase
- [ ] Verify all RPC functions are created (test in SQL editor)
- [ ] Test `get_leaderboard_tiered()` returns correct payloads
- [ ] Test `start_trial()` and `activate_subscription()` work

### iOS

- [ ] Add new Swift files to Xcode project
- [ ] Integrate views into ContentView/CaravanView/ScrollsView
- [ ] Add foreground observer to TenScrollsApp
- [ ] Implement StoreKit manager
- [ ] Configure App Store Connect subscription
- [ ] Test trial flow end-to-end
- [ ] Test Day 30 paywall trigger
- [ ] Test partial reveal leaderboard for free users

### Testing

- [ ] Verify Day 3 trial offer appears correctly
- [ ] Verify Day 30 paywall blocks Scroll II access
- [ ] Test trial expiry (adjust trial_days in SQL to 0 for testing)
- [ ] Test subscription activation unlocks features
- [ ] Test partial reveal shows percentile correctly
- [ ] Test full leaderboard shows for Plus users

### Production

- [ ] Set up App Store Connect subscription
- [ ] Configure pricing and trial period
- [ ] Add subscription copy to App Store listing
- [ ] Test with TestFlight beta users
- [ ] Monitor conversion funnel analytics

---

## 🎯 Key Business Logic

### Trial Eligibility
- Triggers after **3 consecutive days** completed (all three sessions)
- Only shown once (tracked in `hasShownTrialOffer`)
- Only for `free` subscription status

### Day 30 Paywall
- Triggers when `totalDaysCompleted >= 30`
- Blocks access to Scroll II and beyond
- Shows user's percentile to create FOMO
- Only shown once per session (tracked in `hasShownDay30Paywall`)

### Subscription States
- **free**: Default, limited features
- **trialing**: 10-day trial, full access
- **active**: Paid subscription, full access
- **lapsed**: Trial expired without conversion, reverts to free features

### The One-Way Mirror
- Free users see their percentile bucket (not exact rank)
- Free users see population count and cheer count
- Free users see "locked" indicator
- Plus users see full leaderboard with exact ranks

---

## 📞 Support

If you encounter issues:

1. Check Supabase logs for RPC errors
2. Verify migration ran successfully
3. Test subscription flows in isolation
4. Check StoreKit configuration in App Store Connect

