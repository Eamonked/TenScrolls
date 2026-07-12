# TenScrolls Anti-Cheat Implementation Guide

## Problem Statement

Users could game the habit tracker by:
- Tapping all three sessions (Dawn, Midday, Dusk) in rapid succession
- Marking sessions complete without reading the scroll
- Manipulating device time to complete sessions outside their windows
- Submitting fake timestamps to bypass server validation

## Solution: Layered Defense System

No single check stops all gaming. The solution layers multiple validation points so no attack vector succeeds alone.

### 1. Time-Window Gating (Main Lever)

**What it does:**
- Each session has a designated time window based on local time
- Dawn: 5:00 AM - 11:00 AM
- Midday: 11:00 AM - 4:00 PM  
- Dusk: 4:00 PM - 11:00 PM

**How it works:**
- Buttons for unavailable sessions are disabled and visually dimmed
- Lock icon appears on upcoming sessions
- "Missed" indicator appears on closed windows
- Attempting to tap shows toast: "Dawn window has closed for today"

**Implementation:**
```swift
// In Models.swift
enum Session {
    var timeWindow: SessionTimeWindow { ... }
    func isEligible(at date: Date = Date()) -> Bool
    func windowStatus(at date: Date = Date()) -> SessionWindowStatus
}

// In AppStore.swift
func toggleSession(_ session: WritableKeyPath<DayEntry, Bool>) {
    // Validate time window eligibility
    if !sessionType.isEligible(at: currentTime) {
        showToast("Window closed for today")
        return
    }
    // ... complete session
}
```

**What it prevents:**
- Opening app at 9 PM and trying to complete all three sessions
- Only Dusk would be tappable; Dawn and Midday show "window closed"

### 2. Server-Side Validation (Truth Layer)

**What it does:**
- All completion timestamps generated server-side via `now()` in Postgres
- Client-supplied timestamps are advisory only, never trusted
- Database RPC function validates window eligibility against server time
- One completion per slot per day enforced by UNIQUE constraint

**How it works:**
```sql
-- In DATABASE_SCHEMA.md
CREATE OR REPLACE FUNCTION complete_session(
    p_user_id UUID,
    p_session_type TEXT,
    p_scroll_id INTEGER,
    p_scroll_validated BOOLEAN
)
-- Uses now() for timestamp, never client value
-- Validates time window against server clock
-- Rejects duplicates and out-of-window attempts
```

**What it prevents:**
- Users flipping device clock to complete sessions early
- Intercepting Supabase calls to post fake timestamps
- Multiple completions of the same session

**Why it matters:**
- Client-side checks can be bypassed (device time, modified apps)
- Server validates against its own clock, which users can't manipulate
- Database constraints are the final truth barrier

### 3. Scroll Reading Friction Gate (Engagement Layer)

**What it does:**
- Users must scroll through entire scroll text before completing session
- Minimum 30-second reading time enforced
- Visual progress indicators guide the user
- Close button disabled until requirements met

**How it works:**
```swift
// In ScrollEditorSheet (Sheets.swift)
@State private var hasScrolledToBottom = false
@State private var readingStartTime: Date?

private var canComplete: Bool {
    hasScrolledToBottom && hasMetTimeRequirement
}

// Scroll tracking with GeometryReader
.onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
    if value < -50 { // Detected bottom scroll
        hasScrolledToBottom = true
    }
}
```

**Visual feedback:**
- "Scroll to the end to complete" with down arrow
- "Take your time (15s)" with clock showing countdown
- Lock icon on close button when requirements not met
- Sheet can't be swiped down to dismiss

**What it prevents:**
- Users opening scroll and immediately marking it complete
- Drive-by taps without engaging with content
- Gaming the system without reading the actual material

**Why it matters:**
- Time windows stop rapid-fire across slots
- Friction gate stops rapid-fire within a slot
- Forces meaningful interaction with the practice

### 4. Soft-Flagging for Edge Cases (Forgiveness Layer)

**What it does:**
- Allows "late" completions within grace period (30 minutes after window)
- Tracks completion as "on_time", "grace", or "late" status
- Leaderboard weights on-time completions slightly higher
- Doesn't hard-block legitimate users with irregular schedules

**How it works:**
```sql
-- Check time window eligibility
IF v_in_window THEN
    v_window_status := 'on_time';
ELSIF check_grace_period(p_session_type, v_server_time) THEN
    v_window_status := 'grace';
ELSE
    v_window_status := 'late';
END IF;

-- Leaderboard query with weighted scoring
weighted_score = (current_streak * 100) + (on_time_rate * 10)
```

**What it allows:**
- Travel across time zones
- Emergency situations
- Irregular work schedules
- Real-life flexibility

**What it prevents:**
- Feels punitive or inflexible
- Loses engaged users due to edge cases
- All-or-nothing binary thinking

**Why it matters:**
- Gaming less rewarding without blocking flexibility
- Legitimate users aren't punished for life happening
- Leaderboard still incentivizes consistency

## Attack Vector Analysis

### Attack: Rapid Triple-Tap at 9 PM
❌ **Blocked by:** Time-window gating (Layer 1)
- Only Dusk button is enabled
- Dawn and Midday show "window closed"

### Attack: Device Clock Manipulation
❌ **Blocked by:** Server-side validation (Layer 2)
- Server generates timestamp with `now()`
- Client time is never trusted
- Window validation happens server-side

### Attack: Modified App Binary
❌ **Blocked by:** Server-side validation (Layer 2)
- RPC function enforces all rules
- UNIQUE constraint prevents duplicates
- Scroll validation still required

### Attack: Opening Scroll and Immediately Closing
❌ **Blocked by:** Friction gate (Layer 3)
- Must scroll to bottom
- Must wait 30 seconds minimum
- Close button disabled until both met

### Attack: Intercepting API Calls
❌ **Blocked by:** Server-side validation (Layer 2)
- `SECURITY DEFINER` RPC runs with elevated privileges
- Row Level Security (RLS) prevents writing others' data
- Database validates all parameters

### Attack: Gaming During Grace Period
⚠️ **Mitigated by:** Soft-flagging (Layer 4)
- Late completions allowed but marked
- Leaderboard weighs on-time higher
- Not worth gaming for lower score

## Data Flow

### Local-First (Current State)
```
User taps button
  → AppStore.toggleSession()
  → Validates time window (client-side)
  → Updates DayEntry with timestamp
  → Persists to UserDefaults
  → Updates widget
```

### Server-Synced (Future State)
```
User taps button (after reading scroll)
  → Validates time window (client-side UX)
  → AppStore.completeSessionServerSide()
  → Supabase RPC: complete_session()
  → Server validates window against now()
  → Server validates scroll_progress_validated
  → Server checks UNIQUE constraint
  → Server inserts with server timestamp
  → Returns result to client
  → Client updates local state optimistically
  → Syncs to UserDefaults and widget
```

## Testing Checklist

### Time Window Tests
- [ ] Dawn button disabled at 3 AM (upcoming)
- [ ] Dawn button enabled at 8 AM (open)
- [ ] Dawn button disabled at 2 PM (closed)
- [ ] Midday button enabled at 1 PM
- [ ] Dusk button enabled at 7 PM
- [ ] Toast shows correct message for closed windows
- [ ] Visual indicators (lock, "missed") display correctly

### Friction Gate Tests
- [ ] Scroll view starts timer on appear
- [ ] Close button disabled initially
- [ ] Scrolling to bottom marks as complete
- [ ] Timer must reach 30 seconds
- [ ] Progress indicators update correctly
- [ ] Sheet can't be swiped down when locked
- [ ] Edit mode bypasses friction
- [ ] Empty scrolls bypass friction

### Server Validation Tests (when implemented)
- [ ] Server rejects out-of-window completions
- [ ] Server generates its own timestamps
- [ ] Server prevents duplicate completions
- [ ] Server requires scroll_validated = true
- [ ] Grace period allows 30-minute window
- [ ] Late completions are flagged correctly
- [ ] Leaderboard scoring weights properly

### Integration Tests
- [ ] Complete full day: Dawn → Midday → Dusk
- [ ] Attempt Dawn at 9 PM (should fail)
- [ ] Try to complete same session twice (should fail)
- [ ] Complete session without reading scroll (should fail)
- [ ] Complete session in grace period (should work, flagged)
- [ ] Streak calculates correctly with time windows
- [ ] Widget updates reflect window status

## Migration Path

### Phase 1: Local-First (Current) ✅
- Time window validation client-side
- Friction gate implemented
- Timestamps tracked locally
- Works without internet

### Phase 2: Optional Sync
- Add Supabase integration
- Keep local validation working
- Server sync in background
- Graceful fallback to local

### Phase 3: Server-Required for Leaderboard
- Leaderboard requires server validation
- Local-only mode still works
- Users opt into competition tier
- Import local data to server

### Phase 4: Full Server-Side
- All completions validated server-side
- Local is optimistic UI only
- Offline queue syncs when online
- Conflicts resolved server-wins

## Configuration

### Adjustable Parameters

```swift
// In Models.swift
private var minimumReadingTimeSeconds: TimeInterval { 30 }  // Can adjust

// In session time windows
case dawn: return SessionTimeWindow(start: (5, 0), end: (11, 0))  // Configurable

// In DATABASE_SCHEMA.md
v_grace_minutes INTEGER := 30;  // Grace period duration
```

### Hardening Options
- Increase minimum reading time (30s → 60s)
- Tighten time windows (6 hours → 4 hours)
- Remove grace period entirely
- Require scroll velocity tracking
- Add random reading comprehension check

### Softening Options
- Reduce minimum reading time (30s → 15s)
- Extend time windows (6 hours → 8 hours)
- Lengthen grace period (30min → 1 hour)
- Allow manual override with explanation

## Key Principles

1. **Client enforces UX, server enforces truth**
   - Client makes experience smooth
   - Server makes experience honest

2. **Layer defenses, don't rely on one**
   - Time windows + friction + server validation
   - No single point of failure

3. **Be flexible without being exploitable**
   - Grace periods for edge cases
   - Soft-flagging over hard-blocking
   - Weighted scoring over binary pass/fail

4. **Optimize for legitimate users first**
   - Don't punish 99% to stop 1%
   - Make gaming less rewarding, not impossible
   - Friction should feel intentional, not punitive

## Summary

The complete system prevents gaming through:
- ✅ Time windows stop same-hour triple-taps
- ✅ Server validation stops clock manipulation
- ✅ Friction gate stops instant completions
- ✅ Soft-flagging balances strictness and flexibility
- ✅ Database constraints enforce one-per-slot
- ✅ RLS prevents spoofing others' data

The result: meaningful engagement with the practice, not just checkbox ticking.
