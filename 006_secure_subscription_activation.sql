-- Migration 006: Close the spoofable-activation hole in activate_subscription().
--
-- Problem: activate_subscription() (migration 003) does zero verification —
-- it just flips subscription_status to 'active' for whoever calls it, and
-- is GRANT EXECUTE'd to `authenticated, anon`. Since this app uses anonymous
-- auth only (see SupabaseConfig.swift), that means any device with the
-- publishable key — i.e. anyone who's ever installed the app — can call
-- this RPC directly via PostgREST and grant themselves permanent Plus
-- access with no purchase, no App Store involvement at all. Nothing in
-- StoreKitManager.purchase() succeeding is currently verified server-side;
-- the client is simply trusted.
--
-- Fix: activation now requires a StoreKit-signed transaction (the JWS
-- `jwsRepresentation` string StoreKit hands back after a real purchase),
-- verified against Apple's own signing certificates by the `verify-purchase`
-- Edge Function (Deno, using Apple's official app-store-server-library) —
-- Postgres has no JWS/X.509 verification of its own, so that step has to
-- happen there, not in a plpgsql function. Only once Apple's signature
-- checks out does the Edge Function call activate_subscription_verified()
-- below, authenticated as service_role, which this migration keeps locked
-- away from `authenticated`/`anon` entirely.
--
-- Also closes a related receipt-replay gap: a captured JWS is a static
-- signed blob, not session-bound, so without a uniqueness check the same
-- purchase could be replayed to activate Plus on multiple anonymous
-- TenScrolls accounts. apple_original_transaction_id is UNIQUE per user
-- for exactly this reason.

-- 1. Track the Apple transaction behind an activation, for idempotency and
--    anti-replay. UNIQUE (not just indexed) so a second account can never
--    successfully claim a transaction ID already bound to a first account —
--    activate_subscription_verified() below relies on this constraint to
--    reject that case with a clear error rather than silently allowing it.
ALTER TABLE users ADD COLUMN IF NOT EXISTS apple_original_transaction_id TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS apple_latest_transaction_id TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_apple_original_transaction_id
    ON users(apple_original_transaction_id)
    WHERE apple_original_transaction_id IS NOT NULL;

-- 2. Lock the old client-callable activate_subscription() down completely.
--    Kept (not dropped) only because deactivate_subscription() and other
--    code may reference it conceptually in docs — it's now unreachable by
--    any client role, so it can't be exploited even if left in place.
REVOKE EXECUTE ON FUNCTION activate_subscription() FROM authenticated, anon;

-- 3. The real activation path. Takes an explicit p_user_id rather than
--    reading auth.uid(), because the caller is the Edge Function acting as
--    service_role on the authenticated user's behalf — auth.uid() would be
--    NULL in that context. GRANT is service_role only: no authenticated or
--    anon client can ever call this directly, verified or not.
CREATE OR REPLACE FUNCTION activate_subscription_verified(
    p_user_id UUID,
    p_original_transaction_id TEXT,
    p_latest_transaction_id TEXT
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_existing_owner UUID;
BEGIN
    IF p_user_id IS NULL OR p_original_transaction_id IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'missing_params');
    END IF;

    -- Anti-replay: if this Apple transaction is already bound to a
    -- *different* TenScrolls account, refuse — this is what the UNIQUE
    -- index above ultimately enforces, but checking explicitly here gives
    -- a clean JSON error instead of a raw constraint-violation exception.
    SELECT id INTO v_existing_owner
    FROM users
    WHERE apple_original_transaction_id = p_original_transaction_id;

    IF v_existing_owner IS NOT NULL AND v_existing_owner != p_user_id THEN
        RETURN json_build_object(
            'success', false,
            'error', 'transaction_already_claimed',
            'message', 'This purchase is already linked to a different account.'
        );
    END IF;

    UPDATE users
    SET
        subscription_status = 'active',
        plus_since = COALESCE(plus_since, now()),
        apple_original_transaction_id = p_original_transaction_id,
        apple_latest_transaction_id = COALESCE(p_latest_transaction_id, p_original_transaction_id),
        updated_at = now()
    WHERE id = p_user_id;

    RETURN json_build_object(
        'success', true,
        'plus_since', (SELECT plus_since FROM users WHERE id = p_user_id)
    );
END;
$$;

REVOKE ALL ON FUNCTION activate_subscription_verified(UUID, TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION activate_subscription_verified(UUID, TEXT, TEXT) FROM authenticated, anon;
GRANT EXECUTE ON FUNCTION activate_subscription_verified(UUID, TEXT, TEXT) TO service_role;

COMMENT ON FUNCTION activate_subscription_verified IS
'Server-only counterpart to the now-locked-down activate_subscription().
Only callable as service_role — meant to be invoked exclusively by the
verify-purchase Edge Function, and only after it has independently verified
a StoreKit-signed transaction (JWS) against Apple''s own certificates.
Enforces one Apple subscription -> one TenScrolls account via a UNIQUE
constraint on apple_original_transaction_id, preventing a captured/shared
JWS from activating Plus on more than one anonymous account.';
