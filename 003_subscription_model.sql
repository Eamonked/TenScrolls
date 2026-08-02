-- Migration 003: Add subscription model to support monetization
--
-- Adds subscription tracking fields to the users table and implements
-- tiered leaderboard access based on subscription status.
--
-- See TenScrolls_Monetization_Plan.docx Phase 1 for business logic.

-- 1. Add subscription fields to users table
ALTER TABLE users ADD COLUMN IF NOT EXISTS subscription_status TEXT DEFAULT 'free' CHECK (subscription_status IN ('free', 'trialing', 'active', 'lapsed'));
ALTER TABLE users ADD COLUMN IF NOT EXISTS trial_start_date TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN IF NOT EXISTS trial_end_date TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN IF NOT EXISTS plus_since TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN IF NOT EXISTS caravan_joined_at TIMESTAMPTZ;

-- Add index for subscription queries
CREATE INDEX IF NOT EXISTS idx_users_subscription ON users(subscription_status);

-- 2. Function to calculate user's percentile bucket (for free users)
-- Returns percentile as an integer (1-100) based on XP ranking
CREATE OR REPLACE FUNCTION calculate_percentile(p_user_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
DECLARE
    v_rank INTEGER;
    v_total INTEGER;
    v_percentile INTEGER;
BEGIN
    -- Get user's rank by XP
    SELECT COUNT(*) + 1 INTO v_rank
    FROM leaderboard_snapshots
    WHERE xp > (SELECT xp FROM leaderboard_snapshots WHERE user_id = p_user_id);
    
    -- Get total number of users
    SELECT COUNT(*) INTO v_total FROM leaderboard_snapshots;
    
    IF v_total = 0 OR v_rank IS NULL THEN
        RETURN 50; -- Default middle percentile if no data
    END IF;
    
    -- Calculate percentile (higher is better, so invert the rank)
    v_percentile := 100 - FLOOR((v_rank::DECIMAL / v_total::DECIMAL) * 100);
    
    RETURN GREATEST(1, LEAST(100, v_percentile));
END;
$$;

REVOKE ALL ON FUNCTION calculate_percentile(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION calculate_percentile(UUID) TO authenticated, anon;

-- 3. Tiered leaderboard function - returns full or partial data based on subscription
CREATE OR REPLACE FUNCTION get_leaderboard_tiered(p_limit INTEGER DEFAULT 50)
RETURNS TABLE (
    trader_code TEXT,
    trader_name TEXT,
    level INTEGER,
    xp INTEGER,
    current_streak INTEGER,
    best_streak INTEGER,
    total_days INTEGER,
    scrolls_mastered INTEGER,
    last_active TIMESTAMPTZ,
    rank INTEGER,
    -- Fields only for Plus subscribers:
    is_locked BOOLEAN,
    percentile INTEGER,
    population_count INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
DECLARE
    v_user_id UUID;
    v_subscription_status TEXT;
    v_total_count INTEGER;
BEGIN
    -- Get current user's ID and subscription status
    v_user_id := auth.uid();
    
    SELECT subscription_status INTO v_subscription_status
    FROM users
    WHERE id = v_user_id;
    
    -- Default to 'free' if not found
    v_subscription_status := COALESCE(v_subscription_status, 'free');
    
    -- Get total population for context
    SELECT COUNT(*) INTO v_total_count FROM leaderboard_snapshots;
    
    -- Plus subscribers get full leaderboard
    IF v_subscription_status IN ('active', 'trialing') THEN
        RETURN QUERY
        SELECT
            ls.trader_code,
            ls.trader_name,
            ls.level,
            ls.xp,
            ls.current_streak,
            ls.best_streak,
            ls.total_days,
            ls.scrolls_mastered,
            ls.last_active,
            RANK() OVER (ORDER BY ls.xp DESC)::INTEGER AS rank,
            FALSE AS is_locked,
            NULL::INTEGER AS percentile,
            v_total_count AS population_count
        FROM leaderboard_snapshots ls
        ORDER BY ls.xp DESC
        LIMIT p_limit;
    ELSE
        -- Free/lapsed users get only their own percentile bucket
        RETURN QUERY
        SELECT
            NULL::TEXT AS trader_code,
            NULL::TEXT AS trader_name,
            NULL::INTEGER AS level,
            NULL::INTEGER AS xp,
            NULL::INTEGER AS current_streak,
            NULL::INTEGER AS best_streak,
            NULL::INTEGER AS total_days,
            NULL::INTEGER AS scrolls_mastered,
            NULL::TIMESTAMPTZ AS last_active,
            NULL::INTEGER AS rank,
            TRUE AS is_locked,
            calculate_percentile(v_user_id) AS percentile,
            v_total_count AS population_count
        LIMIT 1;
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION get_leaderboard_tiered(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_leaderboard_tiered(INTEGER) TO authenticated, anon;

-- 4. Function to get user's own subscription status
CREATE OR REPLACE FUNCTION get_subscription_status()
RETURNS TABLE (
    subscription_status TEXT,
    trial_start_date TIMESTAMPTZ,
    trial_end_date TIMESTAMPTZ,
    plus_since TIMESTAMPTZ,
    days_until_trial_end INTEGER,
    is_trial_active BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := auth.uid();
    
    RETURN QUERY
    SELECT
        u.subscription_status,
        u.trial_start_date,
        u.trial_end_date,
        u.plus_since,
        CASE
            WHEN u.trial_end_date IS NOT NULL AND u.trial_end_date > now()
            THEN EXTRACT(DAY FROM (u.trial_end_date - now()))::INTEGER
            ELSE 0
        END AS days_until_trial_end,
        (u.subscription_status = 'trialing' AND u.trial_end_date > now()) AS is_trial_active
    FROM users u
    WHERE u.id = v_user_id;
END;
$$;

REVOKE ALL ON FUNCTION get_subscription_status() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_subscription_status() TO authenticated, anon;

-- 5. Function to start a trial
CREATE OR REPLACE FUNCTION start_trial()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user_id UUID;
    v_current_status TEXT;
    v_trial_days INTEGER := 10; -- 10-day trial per monetization plan
BEGIN
    v_user_id := auth.uid();
    
    -- Check current subscription status
    SELECT subscription_status INTO v_current_status
    FROM users
    WHERE id = v_user_id;
    
    -- Only allow trial if currently 'free'
    IF v_current_status != 'free' THEN
        RETURN json_build_object(
            'success', false,
            'error', 'trial_not_eligible',
            'message', 'Trial already used or subscription active'
        );
    END IF;
    
    -- Start the trial
    UPDATE users
    SET
        subscription_status = 'trialing',
        trial_start_date = now(),
        trial_end_date = now() + (v_trial_days || ' days')::INTERVAL,
        updated_at = now()
    WHERE id = v_user_id;
    
    RETURN json_build_object(
        'success', true,
        'trial_start_date', now(),
        'trial_end_date', now() + (v_trial_days || ' days')::INTERVAL,
        'trial_days', v_trial_days
    );
END;
$$;

REVOKE ALL ON FUNCTION start_trial() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION start_trial() TO authenticated, anon;

-- 6. Function to activate Plus subscription
CREATE OR REPLACE FUNCTION activate_subscription()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := auth.uid();
    
    UPDATE users
    SET
        subscription_status = 'active',
        plus_since = COALESCE(plus_since, now()),
        updated_at = now()
    WHERE id = v_user_id;
    
    RETURN json_build_object(
        'success', true,
        'plus_since', (SELECT plus_since FROM users WHERE id = v_user_id)
    );
END;
$$;

REVOKE ALL ON FUNCTION activate_subscription() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION activate_subscription() TO authenticated, anon;

-- 7. Function to handle trial expiry (call this periodically or on app open)
CREATE OR REPLACE FUNCTION check_trial_expiry()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user_id UUID;
    v_status TEXT;
    v_trial_end TIMESTAMPTZ;
BEGIN
    v_user_id := auth.uid();
    
    SELECT subscription_status, trial_end_date
    INTO v_status, v_trial_end
    FROM users
    WHERE id = v_user_id;
    
    -- If trialing and trial has expired, move to lapsed
    IF v_status = 'trialing' AND v_trial_end < now() THEN
        UPDATE users
        SET subscription_status = 'lapsed',
            updated_at = now()
        WHERE id = v_user_id;
        
        RETURN json_build_object(
            'success', true,
            'expired', true,
            'new_status', 'lapsed'
        );
    END IF;
    
    RETURN json_build_object(
        'success', true,
        'expired', false,
        'status', v_status
    );
END;
$$;

REVOKE ALL ON FUNCTION check_trial_expiry() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION check_trial_expiry() TO authenticated, anon;

-- 8. Track when user joins Caravan (opts into social features)
CREATE OR REPLACE FUNCTION mark_caravan_joined()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE users
    SET caravan_joined_at = COALESCE(caravan_joined_at, now()),
        updated_at = now()
    WHERE id = auth.uid()
    AND caravan_joined_at IS NULL;
END;
$$;

REVOKE ALL ON FUNCTION mark_caravan_joined() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION mark_caravan_joined() TO authenticated, anon;

-- 9. Helper function to check if user has access to Scroll II (Day 30 paywall)
CREATE OR REPLACE FUNCTION can_access_scroll_two()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
DECLARE
    v_user_id UUID;
    v_status TEXT;
    v_total_days INTEGER;
BEGIN
    v_user_id := auth.uid();
    
    -- Get subscription status
    SELECT subscription_status INTO v_status
    FROM users
    WHERE id = v_user_id;
    
    -- Plus subscribers always have access
    IF v_status IN ('active', 'trialing') THEN
        RETURN TRUE;
    END IF;
    
    -- Free users: check if they've completed fewer than 30 days
    SELECT total_days INTO v_total_days
    FROM leaderboard_snapshots
    WHERE user_id = v_user_id;
    
    RETURN COALESCE(v_total_days, 0) < 30;
END;
$$;

REVOKE ALL ON FUNCTION can_access_scroll_two() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION can_access_scroll_two() TO authenticated, anon;

-- 10. Add comment to document the tiering logic
COMMENT ON FUNCTION get_leaderboard_tiered IS 
'Returns full leaderboard for Plus subscribers (active/trialing), or percentile bucket only for free/lapsed users. This implements the one-way mirror mechanic from the monetization plan.';

