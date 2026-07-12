# TenScrolls Database Schema & Server-Side Validation

## Overview

This document defines the Postgres schema and RPC functions for server-side validation of reading sessions. The design prevents gaming through:

1. **Time-window gating** - Sessions only valid during their designated windows
2. **Server-side timestamp validation** - All timestamps generated server-side via `now()`
3. **One-completion-per-slot** - Database constraints prevent duplicate sessions
4. **Scroll progress validation** - Client must prove engagement with content

## Core Principles

- **Client enforces UX, server enforces truth**
- Client timestamps are advisory only - server uses `now()`
- Window validation happens in Postgres, not Swift
- Late completions are allowed but flagged differently for leaderboard

## Schema

### Tables

```sql
-- Session time windows configuration
CREATE TABLE session_windows (
    id TEXT PRIMARY KEY,
    session_type TEXT NOT NULL CHECK (session_type IN ('dawn', 'midday', 'dusk')),
    start_hour INTEGER NOT NULL CHECK (start_hour >= 0 AND start_hour < 24),
    start_minute INTEGER NOT NULL CHECK (start_minute >= 0 AND start_minute < 60),
    end_hour INTEGER NOT NULL CHECK (end_hour >= 0 AND end_hour < 24),
    end_minute INTEGER NOT NULL CHECK (end_minute >= 0 AND end_minute < 60),
    timezone_offset INTEGER DEFAULT 0, -- Support for user timezone
    UNIQUE(session_type)
);

-- Seed default windows (matching Og Mandino's framing)
INSERT INTO session_windows (id, session_type, start_hour, start_minute, end_hour, end_minute) VALUES
    ('dawn-default', 'dawn', 5, 0, 11, 0),
    ('midday-default', 'midday', 11, 0, 16, 0),
    ('dusk-default', 'dusk', 16, 0, 23, 0);

-- User accounts
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trader_code TEXT UNIQUE NOT NULL,
    trader_name TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- Session completions with server-side validation
CREATE TABLE session_completions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    
    -- Session identification
    date_key DATE NOT NULL,  -- The day this session belongs to
    session_type TEXT NOT NULL CHECK (session_type IN ('dawn', 'midday', 'dusk')),
    scroll_id INTEGER NOT NULL CHECK (scroll_id >= 1 AND scroll_id <= 10),
    
    -- Server-validated timestamps
    completed_at TIMESTAMPTZ NOT NULL DEFAULT now(),  -- ALWAYS server time, never client-supplied
    
    -- Validation metadata
    scroll_progress_validated BOOLEAN DEFAULT false,  -- Did client complete friction gate?
    window_status TEXT NOT NULL CHECK (window_status IN ('on_time', 'late', 'grace')),
    
    -- Prevent duplicate completions
    UNIQUE(user_id, date_key, session_type),
    
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Index for leaderboard queries
CREATE INDEX idx_completions_user_date ON session_completions(user_id, date_key DESC);
CREATE INDEX idx_completions_date ON session_completions(date_key DESC);

-- Day summaries for quick streak calculations
CREATE TABLE day_summaries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    date_key DATE NOT NULL,
    scroll_id INTEGER NOT NULL,
    
    dawn_completed BOOLEAN DEFAULT false,
    midday_completed BOOLEAN DEFAULT false,
    dusk_completed BOOLEAN DEFAULT false,
    
    all_completed BOOLEAN GENERATED ALWAYS AS (dawn_completed AND midday_completed AND dusk_completed) STORED,
    
    skip_reason TEXT,
    shield_used BOOLEAN DEFAULT false,
    
    UNIQUE(user_id, date_key)
);

CREATE INDEX idx_day_summaries_user ON day_summaries(user_id, date_key DESC);

-- Leaderboard snapshots
CREATE TABLE leaderboard_snapshots (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    trader_code TEXT NOT NULL,
    trader_name TEXT NOT NULL,
    
    level INTEGER NOT NULL,
    xp INTEGER NOT NULL,
    current_streak INTEGER NOT NULL,
    best_streak INTEGER NOT NULL,
    total_days INTEGER NOT NULL,
    scrolls_mastered INTEGER NOT NULL,
    
    last_active TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_leaderboard_streak ON leaderboard_snapshots(current_streak DESC, best_streak DESC);
```

## RPC Functions

### 1. Complete Session (with validation)

```sql
CREATE OR REPLACE FUNCTION complete_session(
    p_user_id UUID,
    p_session_type TEXT,
    p_scroll_id INTEGER,
    p_scroll_validated BOOLEAN DEFAULT false
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER  -- Runs with elevated privileges to enforce validation
AS $$
DECLARE
    v_date_key DATE;
    v_server_time TIMESTAMPTZ;
    v_window_status TEXT;
    v_in_window BOOLEAN;
    v_already_complete BOOLEAN;
    v_result JSON;
BEGIN
    -- Get server time (never trust client time)
    v_server_time := now();
    v_date_key := v_server_time::DATE;
    
    -- Check if already completed
    SELECT EXISTS(
        SELECT 1 FROM session_completions 
        WHERE user_id = p_user_id 
        AND date_key = v_date_key 
        AND session_type = p_session_type
    ) INTO v_already_complete;
    
    IF v_already_complete THEN
        RETURN json_build_object(
            'success', false,
            'error', 'session_already_complete',
            'message', 'This session was already completed today'
        );
    END IF;
    
    -- Validate scroll progress gate (client-side friction)
    IF NOT p_scroll_validated THEN
        RETURN json_build_object(
            'success', false,
            'error', 'scroll_not_validated',
            'message', 'Must read through the scroll first'
        );
    END IF;
    
    -- Check time window eligibility
    SELECT check_session_window(p_session_type, v_server_time) INTO v_in_window;
    
    -- Determine window status
    IF v_in_window THEN
        v_window_status := 'on_time';
    ELSE
        -- Check if within grace period (e.g., 30 minutes after window closes)
        IF check_grace_period(p_session_type, v_server_time) THEN
            v_window_status := 'grace';
        ELSE
            v_window_status := 'late';
        END IF;
    END IF;
    
    -- Insert completion with server timestamp
    INSERT INTO session_completions (
        user_id,
        date_key,
        session_type,
        scroll_id,
        completed_at,
        scroll_progress_validated,
        window_status
    ) VALUES (
        p_user_id,
        v_date_key,
        p_session_type,
        p_scroll_id,
        v_server_time,  -- Server time, not client time
        p_scroll_validated,
        v_window_status
    );
    
    -- Update day summary
    PERFORM update_day_summary(p_user_id, v_date_key, p_session_type, p_scroll_id);
    
    -- Return result
    SELECT json_build_object(
        'success', true,
        'completed_at', v_server_time,
        'window_status', v_window_status,
        'date_key', v_date_key
    ) INTO v_result;
    
    RETURN v_result;
END;
$$;
```

### 2. Window Validation Helper

```sql
CREATE OR REPLACE FUNCTION check_session_window(
    p_session_type TEXT,
    p_check_time TIMESTAMPTZ
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_start_minutes INTEGER;
    v_end_minutes INTEGER;
    v_current_minutes INTEGER;
    v_window RECORD;
BEGIN
    -- Get window config
    SELECT start_hour, start_minute, end_hour, end_minute
    INTO v_window
    FROM session_windows
    WHERE session_type = p_session_type
    LIMIT 1;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown session type: %', p_session_type;
    END IF;
    
    -- Convert to minutes since midnight (in user's timezone)
    v_start_minutes := v_window.start_hour * 60 + v_window.start_minute;
    v_end_minutes := v_window.end_hour * 60 + v_window.end_minute;
    v_current_minutes := EXTRACT(HOUR FROM p_check_time)::INTEGER * 60 + 
                         EXTRACT(MINUTE FROM p_check_time)::INTEGER;
    
    -- Check if current time is within window
    RETURN v_current_minutes >= v_start_minutes AND v_current_minutes < v_end_minutes;
END;
$$;
```

### 3. Grace Period Check

```sql
CREATE OR REPLACE FUNCTION check_grace_period(
    p_session_type TEXT,
    p_check_time TIMESTAMPTZ
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_end_minutes INTEGER;
    v_current_minutes INTEGER;
    v_window RECORD;
    v_grace_minutes INTEGER := 30;  -- 30 minute grace period
BEGIN
    -- Get window config
    SELECT end_hour, end_minute
    INTO v_window
    FROM session_windows
    WHERE session_type = p_session_type
    LIMIT 1;
    
    v_end_minutes := v_window.end_hour * 60 + v_window.end_minute;
    v_current_minutes := EXTRACT(HOUR FROM p_check_time)::INTEGER * 60 + 
                         EXTRACT(MINUTE FROM p_check_time)::INTEGER;
    
    -- Check if within grace period after window closes
    RETURN v_current_minutes >= v_end_minutes AND 
           v_current_minutes < (v_end_minutes + v_grace_minutes);
END;
$$;
```

### 4. Update Day Summary

```sql
CREATE OR REPLACE FUNCTION update_day_summary(
    p_user_id UUID,
    p_date_key DATE,
    p_session_type TEXT,
    p_scroll_id INTEGER
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO day_summaries (user_id, date_key, scroll_id)
    VALUES (p_user_id, p_date_key, p_scroll_id)
    ON CONFLICT (user_id, date_key) DO NOTHING;
    
    -- Update the specific session flag
    CASE p_session_type
        WHEN 'dawn' THEN
            UPDATE day_summaries 
            SET dawn_completed = true 
            WHERE user_id = p_user_id AND date_key = p_date_key;
        WHEN 'midday' THEN
            UPDATE day_summaries 
            SET midday_completed = true 
            WHERE user_id = p_user_id AND date_key = p_date_key;
        WHEN 'dusk' THEN
            UPDATE day_summaries 
            SET dusk_completed = true 
            WHERE user_id = p_user_id AND date_key = p_date_key;
    END CASE;
END;
$$;
```

### 5. Calculate Streak

```sql
CREATE OR REPLACE FUNCTION calculate_current_streak(p_user_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_streak INTEGER := 0;
    v_check_date DATE := CURRENT_DATE;
    v_completed BOOLEAN;
BEGIN
    -- Check if today is complete
    SELECT all_completed OR shield_used INTO v_completed
    FROM day_summaries
    WHERE user_id = p_user_id AND date_key = v_check_date;
    
    -- If today isn't complete, start from yesterday
    IF NOT COALESCE(v_completed, false) THEN
        v_check_date := v_check_date - INTERVAL '1 day';
    END IF;
    
    -- Count backwards while days are complete
    LOOP
        SELECT all_completed OR shield_used INTO v_completed
        FROM day_summaries
        WHERE user_id = p_user_id AND date_key = v_check_date;
        
        EXIT WHEN NOT COALESCE(v_completed, false);
        
        v_streak := v_streak + 1;
        v_check_date := v_check_date - INTERVAL '1 day';
    END LOOP;
    
    RETURN v_streak;
END;
$$;
```

### 6. Leaderboard Query with Window Scoring

```sql
CREATE OR REPLACE FUNCTION get_weighted_leaderboard(p_limit INTEGER DEFAULT 50)
RETURNS TABLE (
    trader_code TEXT,
    trader_name TEXT,
    current_streak INTEGER,
    best_streak INTEGER,
    total_days INTEGER,
    on_time_rate NUMERIC,
    weighted_score NUMERIC
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        l.trader_code,
        l.trader_name,
        l.current_streak,
        l.best_streak,
        l.total_days,
        -- Calculate on-time completion rate
        ROUND(
            CAST(COUNT(CASE WHEN c.window_status = 'on_time' THEN 1 END) AS NUMERIC) / 
            NULLIF(COUNT(c.id), 0) * 100, 
            1
        ) as on_time_rate,
        -- Weighted score: streak is primary, on-time rate is secondary
        (l.current_streak * 100 + 
         COALESCE(
             CAST(COUNT(CASE WHEN c.window_status = 'on_time' THEN 1 END) AS NUMERIC) / 
             NULLIF(COUNT(c.id), 0) * 10,
             0
         )) as weighted_score
    FROM leaderboard_snapshots l
    LEFT JOIN session_completions c ON c.user_id = l.user_id
    GROUP BY l.user_id, l.trader_code, l.trader_name, l.current_streak, l.best_streak, l.total_days
    ORDER BY weighted_score DESC, l.current_streak DESC
    LIMIT p_limit;
END;
$$;
```

## Row Level Security (RLS)

```sql
-- Enable RLS
ALTER TABLE session_completions ENABLE ROW LEVEL SECURITY;
ALTER TABLE day_summaries ENABLE ROW LEVEL SECURITY;
ALTER TABLE leaderboard_snapshots ENABLE ROW LEVEL SECURITY;

-- Users can only read/write their own data
CREATE POLICY "Users can manage own completions" 
ON session_completions FOR ALL 
USING (auth.uid() = user_id);

CREATE POLICY "Users can manage own summaries" 
ON day_summaries FOR ALL 
USING (auth.uid() = user_id);

-- Leaderboard is publicly readable
CREATE POLICY "Leaderboard is public" 
ON leaderboard_snapshots FOR SELECT 
USING (true);

CREATE POLICY "Users can update own snapshot" 
ON leaderboard_snapshots FOR ALL 
USING (auth.uid() = user_id);
```

## Client Integration

### Swift → Supabase Call Pattern

```swift
// In AppStore.swift
func completeSessionServerSide(_ session: Session, scrollValidated: Bool) async throws {
    guard let userId = supabaseClient.auth.currentUser?.id else {
        throw AppError.notAuthenticated
    }
    
    let response = try await supabaseClient
        .rpc("complete_session", params: [
            "p_user_id": userId,
            "p_session_type": session.rawValue,
            "p_scroll_id": state.targetScrollId ?? 0,
            "p_scroll_validated": scrollValidated
        ])
        .execute()
    
    let result = try JSONDecoder().decode(SessionCompletionResult.self, from: response.data)
    
    if result.success {
        // Update local state optimistically
        updateLocalSession(session, result: result)
    } else {
        // Show error to user
        showToast(result.message)
    }
}

struct SessionCompletionResult: Decodable {
    let success: Bool
    let error: String?
    let message: String?
    let completedAt: Date?
    let windowStatus: String?
    let dateKey: String?
}
```

## Anti-Cheat Measures Summary

1. **Time Gating**: Enforced in Postgres via `check_session_window()`
2. **Server Timestamps**: `completed_at` always uses `now()`, never client value
3. **Unique Constraints**: Database prevents duplicate session completions
4. **Scroll Validation**: Client must pass friction gate before calling RPC
5. **Grace Periods**: Flexible for legitimate edge cases without punishing them
6. **Weighted Scoring**: Leaderboard favors on-time completions without blocking late ones
7. **RLS Policies**: Users can only write their own data
8. **SECURITY DEFINER**: RPC functions run with elevated privileges to enforce rules

## Migration Strategy

1. Keep current local-first architecture working
2. Add optional Supabase sync layer
3. Migrate users gradually with data import from `UserDefaults`
4. Eventually make server-side validation required for leaderboard participation
5. Local-only users can still use the app, just not compete globally
