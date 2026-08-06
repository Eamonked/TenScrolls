-- ============================================================
-- 010_track_purchased_product.sql
--
-- Records which of the three products (monthly/annual/lifetime — see
-- StoreKitManager.allProductIDs) a subscriber actually activated with.
-- activate_subscription_verified() (006) previously only recorded Apple's
-- transaction IDs, not which product they belonged to — fine for gating
-- (every plan grants the same `active` status), but it meant there was no
-- way to ever show a reader "you're on the Annual plan" or treat lifetime
-- differently (e.g. never prompting a renewal reminder) without decoding
-- an Apple transaction ID again.
-- ============================================================

alter table public.users add column if not exists apple_product_id text;

-- activate_subscription_verified() gains a 4th parameter. Signature is
-- changing (not just the body), so the old 3-arg version is dropped first —
-- CREATE OR REPLACE FUNCTION cannot change a function's parameter list.
drop function if exists public.activate_subscription_verified(uuid, text, text);

create or replace function public.activate_subscription_verified(
    p_user_id uuid,
    p_original_transaction_id text,
    p_latest_transaction_id text,
    p_product_id text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
    v_existing_owner uuid;
begin
    if p_user_id is null or p_original_transaction_id is null then
        return json_build_object('success', false, 'error', 'missing_params');
    end if;

    -- Anti-replay: if this Apple transaction is already bound to a
    -- *different* TenScrolls account, refuse — this is what the UNIQUE
    -- index on apple_original_transaction_id ultimately enforces, but
    -- checking explicitly here gives a clean JSON error instead of a raw
    -- constraint-violation exception.
    select id into v_existing_owner
    from public.users
    where apple_original_transaction_id = p_original_transaction_id;

    if v_existing_owner is not null and v_existing_owner != p_user_id then
        return json_build_object(
            'success', false,
            'error', 'transaction_already_claimed',
            'message', 'This purchase is already linked to a different account.'
        );
    end if;

    update public.users
    set
        subscription_status = 'active',
        plus_since = coalesce(plus_since, now()),
        apple_original_transaction_id = p_original_transaction_id,
        apple_latest_transaction_id = coalesce(p_latest_transaction_id, p_original_transaction_id),
        apple_product_id = coalesce(p_product_id, apple_product_id),
        updated_at = now()
    where id = p_user_id;

    return json_build_object(
        'success', true,
        'plus_since', (select plus_since from public.users where id = p_user_id)
    );
end;
$$;

revoke all on function public.activate_subscription_verified(uuid, text, text, text) from public;
revoke execute on function public.activate_subscription_verified(uuid, text, text, text) from authenticated, anon;
grant execute on function public.activate_subscription_verified(uuid, text, text, text) to service_role;

comment on function public.activate_subscription_verified is
'Server-only counterpart to the locked-down activate_subscription(). Only
callable as service_role — meant to be invoked exclusively by the
verify-purchase Edge Function, and only after it has independently verified
a StoreKit-signed transaction (JWS) against Apple''s own certificates.
Enforces one Apple subscription -> one TenScrolls account via a UNIQUE
constraint on apple_original_transaction_id. p_product_id (added in 010)
records which of monthly/annual/lifetime this activation was for.';

-- get_subscription_status() gains apple_product_id in its result so the
-- client can eventually show which plan a subscriber is on. Return shape
-- is changing, so this also needs a drop-then-create rather than a plain
-- CREATE OR REPLACE.
drop function if exists public.get_subscription_status();

create or replace function public.get_subscription_status()
returns table (
    subscription_status text,
    trial_start_date timestamptz,
    trial_end_date timestamptz,
    plus_since timestamptz,
    days_until_trial_end integer,
    is_trial_active boolean,
    apple_product_id text
)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
    v_user_id uuid;
begin
    v_user_id := auth.uid();

    return query
    select
        u.subscription_status,
        u.trial_start_date,
        u.trial_end_date,
        u.plus_since,
        case
            when u.trial_end_date is not null and u.trial_end_date > now()
            then extract(day from (u.trial_end_date - now()))::integer
            else 0
        end as days_until_trial_end,
        (u.subscription_status = 'trialing' and u.trial_end_date > now()) as is_trial_active,
        u.apple_product_id
    from public.users u
    where u.id = v_user_id;
end;
$$;

revoke all on function public.get_subscription_status() from public;
grant execute on function public.get_subscription_status() to authenticated, anon;
