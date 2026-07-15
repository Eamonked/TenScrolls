# Widget Extension Setup Instructions

## Problem
The widget files exist but the widget extension target is not configured in the Xcode project. This is why widgets don't appear in the widget gallery.

## Solution: Add Widget Extension Target

### Step 1: Open Xcode Project
1. Open `TenScrolls.xcodeproj` in Xcode
2. Wait for the project to fully load

### Step 2: Add Widget Extension Target
1. Click on the **TenScrolls** project in the navigator (top item)
2. At the bottom of the targets list, click the **"+"** button
3. Search for **"Widget Extension"**
4. Select **Widget Extension** and click **Next**

### Step 3: Configure Widget Extension
1. **Product Name**: `TenScrollsWidget` (must match the folder name exactly)
2. **Team**: Select your development team
3. **Organization Identifier**: Should auto-fill to match your app
4. **Bundle Identifier**: Should be `ekme.TenScrolls.TenScrollsWidget`
5. **Include Configuration Intent**: ❌ Uncheck this (we don't need it)
6. Click **Finish**

### Step 4: Handle the Dialog
Xcode will ask: **"Activate 'TenScrollsWidget' scheme?"**
- Click **Activate**

### Step 5: Delete Xcode's Template Files
Xcode creates template files we don't need. Delete these:
1. In the Project Navigator, find the `TenScrollsWidget` group
2. Select and delete (Move to Trash):
   - `TenScrollsWidget.swift` (if Xcode created a new one)
   - `TenScrollsWidget.intentdefinition` (if present)
   - Any other template files Xcode created

### Step 6: Add Existing Widget Files to Target
1. In Project Navigator, find the **existing** `TenScrollsWidget` folder
2. Select all widget files:
   - `JournalWidget.swift`
   - `TenScrollsWidget.swift`
   - `TenScrollsWidgetBundle.swift`
   - `WidgetViews.swift`
3. In the **File Inspector** (right sidebar), under **Target Membership**:
   - ✅ Check `TenScrollsWidget` target
   - ❌ Uncheck `TenScrolls` target (widgets shouldn't be in main app)

### Step 7: Add WidgetData.swift to Both Targets
The `WidgetData.swift` file needs to be shared between app and widget:
1. Find `WidgetData.swift` in Project Navigator
2. In **File Inspector** → **Target Membership**:
   - ✅ Check `TenScrolls` target
   - ✅ Check `TenScrollsWidget` target

### Step 8: Configure App Groups
Both the app and widget need to share data via App Groups.

#### For Main App (TenScrolls):
1. Select **TenScrolls** target
2. Go to **Signing & Capabilities** tab
3. If "App Groups" isn't there, click **+ Capability** → **App Groups**
4. Click **"+"** under App Groups
5. Add: `group.ekme.TenScrolls`
6. Make sure it's ✅ checked

#### For Widget Extension (TenScrollsWidget):
1. Select **TenScrollsWidget** target
2. Go to **Signing & Capabilities** tab
3. If "App Groups" isn't there, click **+ Capability** → **App Groups**
4. Click **"+"** under App Groups
5. Add: `group.ekme.TenScrolls` (same as main app!)
6. Make sure it's ✅ checked

### Step 9: Configure Widget Info.plist
1. Select **TenScrollsWidget** target
2. Go to **Build Settings** tab
3. Search for **"Info.plist File"**
4. Make sure it points to the correct path (Xcode usually handles this)

If there's an Info.plist in TenScrollsWidget folder:
1. Open it
2. Add these keys if not present:
```xml
<key>NSExtension</key>
<dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.widgetkit-extension</string>
</dict>
```

### Step 10: Build and Run
1. Select **TenScrolls** scheme (not TenScrollsWidget)
2. Choose your device or simulator
3. Click **Build** (⌘B)
4. If it builds successfully, click **Run** (⌘R)

### Step 11: Test Widgets
1. On your device/simulator, go to home screen
2. Long press empty space
3. Tap **"+"** button
4. Search for **"Ten Scrolls"**
5. You should now see **two widgets**:
   - Daily Practice
   - Journal Reflection

## If Widgets Still Don't Appear

### Check Bundle Identifiers
1. **Main App** target → **General** tab
   - Bundle Identifier should be: `ekme.TenScrolls`
2. **Widget** target → **General** tab
   - Bundle Identifier should be: `ekme.TenScrolls.TenScrollsWidget`

### Check App Groups Match
Both targets must use **exactly** the same App Group name:
- `group.ekme.TenScrolls`

### Check Deployment Target
1. **TenScrollsWidget** target → **General** tab → **Deployment Info**
2. iOS version should match or be lower than main app
3. Recommended: iOS 16.0 or later (for best widget support)

### Clean Build
Sometimes Xcode needs a fresh start:
1. **Product** → **Clean Build Folder** (⇧⌘K)
2. Quit Xcode completely
3. Delete `~/Library/Developer/Xcode/DerivedData/TenScrolls-*` folder
4. Reopen project and build again

## Alternative: Quick Fix (If Above Doesn't Work)

If you're having trouble with the Xcode setup, here's a simpler approach:

### Option A: Create Widget Extension from Scratch
1. **File** → **New** → **Target**
2. Choose **Widget Extension**
3. Name it `TenScrollsWidget`
4. After creation, replace Xcode's template files with our widget files
5. Follow steps 6-11 above

### Option B: Check Existing Target
If there's already a TenScrollsWidget target but it's not working:
1. Select **TenScrollsWidget** target
2. **Build Phases** → **Compile Sources**
3. Make sure all 4 widget .swift files are listed
4. If not, click **"+"** and add them

## Verification Checklist

After setup, verify:
- [ ] TenScrollsWidget target exists in project
- [ ] All 4 widget files are in TenScrollsWidget target membership
- [ ] WidgetData.swift is in BOTH target memberships
- [ ] App Groups capability added to BOTH targets
- [ ] Both use same App Group: `group.ekme.TenScrolls`
- [ ] Project builds without errors
- [ ] App runs on device/simulator
- [ ] Widgets appear in widget gallery

## Common Errors

### "No such module 'WidgetKit'"
- **Fix**: Make sure TenScrollsWidget target has iOS 14.0+ deployment target

### "Cannot find 'WidgetData' in scope"
- **Fix**: Add WidgetData.swift to TenScrollsWidget target membership

### "App Groups entitlement not found"
- **Fix**: Add App Groups capability to both targets with same identifier

### Widgets build but don't appear
- **Fix**: Make sure TenScrollsWidgetBundle has `@main` attribute
- **Fix**: Check that widget bundle identifier starts with app identifier

## Need Help?

If widgets still don't work after following these steps:
1. Check Xcode console for error messages when running
2. Make sure you're testing on iOS 16.0 or later
3. Try removing and re-adding the widget extension target
4. Ensure code signing is configured for both targets

## Success!

Once configured correctly:
- Build and run the app
- Go to home screen → long press → tap "+"
- Search "Ten Scrolls"
- You'll see both widgets available! 🎉
