# TenScrolls — Push Notification Setup for Cheers

Backend and Swift code are already built and deployed. What's left are four
manual steps that require your Apple Developer account and Xcode project
access. Do these in order.

---

## 1. Add the Push Notifications capability in Xcode

1. Open `TenScrolls.xcodeproj`.
2. Select the **TenScrolls** target → **Signing & Capabilities** tab.
3. Click **+ Capability** → add **Push Notifications**.
4. This adds the `aps-environment` entitlement automatically — no manual
   plist editing needed.

---

## 2. Create an APNs Auth Key in the Apple Developer Portal

1. Go to [developer.apple.com/account](https://developer.apple.com/account)
   → **Certificates, Identifiers & Profiles** → **Keys**.
2. Click **+** to create a new key.
3. Name it something like `TenScrolls APNs Key`.
4. Check **Apple Push Notifications service (APNs)**.
5. Click **Continue** → **Register**, then **Download** the `.p8` file
   immediately — Apple only lets you download it once.
6. Note down, from this same page:
   - **Key ID** (shown next to the key)
   - **Team ID** (top-right of the developer portal, under your name/org)

Keep the `.p8` file somewhere safe — you'll need its contents in step 3.

---

## 3. Set Supabase Edge Function secrets

Go to the `tenscrolls` project in the Supabase dashboard → **Edge Functions**
→ **Secrets** (or use the CLI: `supabase secrets set`). Add:

| Secret name | Value |
|---|---|
| `APNS_TEAM_ID` | Your Team ID from step 2 |
| `APNS_KEY_ID` | Your Key ID from step 2 |
| `APNS_AUTH_KEY` | Full contents of the `.p8` file, including the `-----BEGIN PRIVATE KEY-----` / `-----END PRIVATE KEY-----` lines |
| `APNS_BUNDLE_ID` | Your app's bundle identifier — confirm the exact value in Xcode (General tab), expected to be `ekme.TenScrolls` |

---

## 4. Rebuild, reinstall, and grant permission

1. Build and install the updated app on both real devices (yours and
   Sheila's) — this is the build that already includes the
   `AppDelegate`/push registration code.
2. Open the app and make sure notification permission is granted when
   prompted (Settings → TenScrolls → Notifications, if you need to check
   or re-enable it).
3. Granting permission is what triggers `registerForRemoteNotifications()`,
   which gets you a device token and uploads it to Supabase automatically.

---

## Verifying it worked

Once all four steps are done, ask Claude to:
- Query the `push_tokens` table to confirm a row exists for each device.
- Send a test cheer between the two devices and confirm:
  - The recipient gets a push notification with a **"Got it"** action.
  - Tapping "Got it" (or the notification itself) marks it acknowledged.
  - The sender's duel card flips from "Send encouragement" → **"Seen"**.

---

## Known limitation (worth revisiting later)

The `send-cheer-push` Edge Function was deployed with `verify_jwt: false`,
so its URL is technically callable without authentication. Today the
function only *reads* data (device token lookup) and can't write or leak
anything sensitive if misused — worst case is a wasted APNs call. If this
ever needs hardening, add a shared-secret header check between the
database trigger and the function.
