-- Migration 005: Reconciliation counterpart to activate_subscription.
--
-- Problem: activate_subscription() flips subscription_status to 'active' at
-- the moment of purchase, but nothing ever flips it back. If a user cancels,
-- a renewal payment fails, or Apple issues a refund, subscription_status
-- stays 'active' in Postgres indefinitely — there's no App Store Server
-- Notifications webhook and, until now, no client-driven reconciliation
-- path either. Every Plus gate in the app (leaderboard tiering, add-friend,
-- send-cheer, Scroll II) reads subscription_status, so this one gap silently
-- undermines all of them for anyone whose paid subscription actually lapsed.
--
-- Fix: a narrow RPC the client calls after cross-checking StoreKit's
-- Transaction.currentEntitlements (see StoreKitManager.hasActiveEntitlement())
-- against the cached server status. Only touches the active -> lapsed
-- transition — 'trialing' is governed separately by check_trial_expiry
-- (time-based, no StoreKit involved), and 'free'/'lapsed' are no-ops here.

CREATE OR REPLACE FUNCTION deactivate_subscription()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user_id UUID;
    v_status TEXT;
BEGIN
    v_user_id := auth.uid();

    SELECT subscription_status INTO v_status FROM users WHERE id = v_user_id;

    IF v_status = 'active' THEN
        UPDATE users
        SET subscription_status = 'lapsed',
            updated_at = now()
        WHERE id = v_user_id;

        RETURN json_build_object('success', true, 'changed', true, 'new_status', 'lapsed');
    END IF;

    -- Already free/trialing/lapsed — nothing to do, not an error.
    RETURN json_build_object('success', true, 'changed', false, 'status', v_status);
END;
$$;

REVOKE ALL ON FUNCTION deactivate_subscription() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION deactivate_subscription() TO authenticated, anon;

COMMENT ON FUNCTION deactivate_subscription IS
'Reconciliation counterpart to activate_subscription: flips an active paid
subscriber to lapsed when the client confirms via StoreKit
(Transaction.currentEntitlements) that the App Store no longer reports an
active entitlement for this product — covers cancellation, refund, and
failed-renewal cases that would otherwise leave subscription_status stuck
at active indefinitely. Only touches the active -> lapsed transition;
trialing is governed separately by check_trial_expiry.';
