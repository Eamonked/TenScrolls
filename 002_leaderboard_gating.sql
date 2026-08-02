-- Migration: close direct public read access to leaderboard_snapshots.
--
-- Problem: the existing RLS policy `"Leaderboard is public" ON
-- leaderboard_snapshots FOR SELECT USING (true)` lets ANY authenticated
-- (including anonymous) client query the raw table directly — any columns,
-- any filter, any order — independent of whatever the app's own
-- `.order("xp", ascending: false)` call asks for. The app's client-side
-- sort was never the actual exposure; the open table policy was.
--
-- Fix: replace direct table reads with two SECURITY DEFINER RPCs that
-- compute order (and, later, entitlement-based tiering) server-side, then
-- drop the public SELECT policy so the table itself is no longer reachable
-- except through these functions. This mirrors the pattern already used for
-- `complete_session` etc. in DATABASE_SCHEMA.md: client enforces UX, server
-- enforces truth.
--
-- This intentionally keeps today's behavior (every caller still receives
-- the full leaderboard) unchanged — it only centralizes the read path so
-- that free/Plus tiering (see TenScrolls_Monetization_Plan.docx, Technical
-- Build Scope B/C) is a change to these two functions later, not a new
-- table-security problem to solve from scratch.

-- 1. Full leaderboard read, ranked server-side.
CREATE OR REPLACE FUNCTION get_leaderboard(p_limit INTEGER DEFAULT 50)
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
    rank INTEGER
)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
    SELECT
        trader_code,
        trader_name,
        level,
        xp,
        current_streak,
        best_streak,
        total_days,
        scrolls_mastered,
        last_active,
        RANK() OVER (ORDER BY xp DESC)::INTEGER AS rank
    FROM leaderboard_snapshots
    ORDER BY xp DESC
    LIMIT p_limit;
$$;

REVOKE ALL ON FUNCTION get_leaderboard(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_leaderboard(INTEGER) TO authenticated, anon;

-- 2. Single-trader lookup by code, for the "add friend" flow — previously
--    also served by the same open table policy.
CREATE OR REPLACE FUNCTION get_trader_by_code(p_code TEXT)
RETURNS TABLE (
    trader_code TEXT,
    trader_name TEXT,
    level INTEGER,
    xp INTEGER,
    current_streak INTEGER,
    best_streak INTEGER,
    total_days INTEGER,
    scrolls_mastered INTEGER,
    last_active TIMESTAMPTZ
)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
    SELECT
        trader_code, trader_name, level, xp, current_streak,
        best_streak, total_days, scrolls_mastered, last_active
    FROM leaderboard_snapshots
    WHERE trader_code = p_code
    LIMIT 1;
$$;

REVOKE ALL ON FUNCTION get_trader_by_code(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_trader_by_code(TEXT) TO authenticated, anon;

-- 3. Close the open door. Writes (upsert of one's own row) still work via
--    the existing "Users can update own snapshot" policy — only the public
--    SELECT is removed.
DROP POLICY IF EXISTS "Leaderboard is public" ON leaderboard_snapshots;
