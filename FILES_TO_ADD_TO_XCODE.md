# Files to Add to Xcode Project

## New Files Created for Monetization

Add these files to your Xcode project:

### Database Migration (Documentation Only)
- `003_subscription_model.sql` - Run this on Supabase, don't add to Xcode

### Swift Source Files (Add to TenScrolls target)

1. **Models**:
   - `TenScrolls/SubscriptionModels.swift` - Subscription data models
   
2. **Services**:
   - `TenScrolls/SupabaseSubscription.swift` - Subscription service actor

3. **Views** (add to TenScrolls/Views folder):
   - `TenScrolls/Views/TrialOfferView.swift` - Day 3 trial offer card
   - `TenScrolls/Views/Day30PaywallView.swift` - Day 30 paywall
   - `TenScrolls/Views/PartialRevealLeaderboardCard.swift` - Freemium leaderboard view

### Modified Files

These files were updated with subscription functionality:
- `TenScrolls/AppState.swift` - Added subscription tracking fields
- `TenScrolls/AppStore.swift` - Added subscription methods
- `TenScrolls/Models.swift` - Already up to date

### Documentation
- `MONETIZATION_IMPLEMENTATION_GUIDE.md` - Complete implementation guide
- `FILES_TO_ADD_TO_XCODE.md` - This file

---

## How to Add Files to Xcode

1. **Open Xcode project**: `TenScrolls.xcodeproj`

2. **Add Swift files**:
   - Right-click on `TenScrolls` folder in Navigator
   - Choose "Add Files to 'TenScrolls'..."
   - Select all new .swift files listed above
   - Make sure "Copy items if needed" is **unchecked** (files are already in place)
   - Make sure target "TenScrolls" is **checked**

3. **Verify Views folder**:
   - Drag the new View files into the `Views` group in Xcode for organization
   - Or let Xcode keep them at the root level (both work)

4. **Build project**:
   - Press Cmd+B to build
   - Fix any import issues if they arise

---

## Expected Result

After adding files, your project structure should look like:

```
TenScrolls/
├── Models.swift (modified)
├── AppState.swift (modified)
├── AppStore.swift (modified)
├── SubscriptionModels.swift (new)
├── SupabaseSubscription.swift (new)
├── SupabaseConfig.swift (existing)
├── SupabaseAuth.swift (existing)
├── SupabaseLeaderboard.swift (existing)
├── SupabaseSharing.swift (existing)
└── Views/
    ├── TrialOfferView.swift (new)
    ├── Day30PaywallView.swift (new)
    ├── PartialRevealLeaderboardCard.swift (new)
    ├── CaravanView.swift (existing - needs updates)
    ├── ContentView.swift (existing - needs updates)
    └── ... (other existing views)
```

---

## Next Steps After Adding to Xcode

1. Build project to verify no compilation errors
2. Run database migration on Supabase
3. Integrate views into existing UI (see MONETIZATION_IMPLEMENTATION_GUIDE.md)
4. Implement StoreKit IAP flow
5. Test trial and paywall flows

