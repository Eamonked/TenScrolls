-- ============================================================
-- 009_pricing_config.sql
--
-- Single source of truth for everything about Plus pricing *except* the
-- actual charged amounts, which only Apple controls (App Store Connect) —
-- see StoreKitManager.displayPrice(for:). This table controls:
--   - trial_days:            length of the free trial (start_trial() below
--                             now reads this instead of a hardcoded 10)
--   - featured_product_id:   which of the three products
--                             (monthly/annual/lifetime — see
--                             StoreKitManager.allProductIDs) is
--                             pre-selected/highlighted on the paywall
--   - active_product_ids:    which products are actually offered to new
--                             signups right now (a product can exist in
--                             App Store Connect and still be excluded here,
--                             e.g. lifetime not launched yet)
--   - product_badges:        marketing label per product id, e.g.
--                             {"ekme.TenScrolls.plus.annual": "BEST VALUE"}
--                             — empty/missing key means no badge
--
-- Singleton row (id = 1), edited directly via the Supabase dashboard
-- (Table Editor or SQL), same operating model as feature_gates_registry —
-- Eamon edits the row, every client picks it up on its next
-- get_pricing_config() call (PricingConfigStore.refresh(), called at
-- launch and on every foreground).
-- ============================================================

create table if not exists public.pricing_config (
    id integer primary key default 1,
    trial_days integer not null default 10,
    featured_product_id text not null default 'ekme.TenScrolls.plus.annual',
    active_product_ids text[] not null default array[
        'ekme.TenScrolls.plus.monthly',
        'ekme.TenScrolls.plus.annual',
        'ekme.TenScrolls.plus.lifetime'
    ],
    product_badges jsonb not null default '{"ekme.TenScrolls.plus.annual": "BEST VALUE"}'::jsonb,
    updated_at timestamptz not null default now(),
    constraint pricing_config_singleton check (id = 1)
);

insert into public.pricing_config (id)
values (1)
on conflict (id) do nothing;

-- No permissive RLS policies — same convention as feature_gates_registry
-- and reading_groups (007/008): all read access goes through the
-- SECURITY DEFINER RPC below, never raw PostgREST table access. Writes are
-- dashboard-only.
alter table public.pricing_config enable row level security;

-- Dropped first rather than CREATE OR REPLACE: Postgres refuses to change
-- a function's return type/columns in place (42P13), and this run may be
-- replacing an earlier version of this function with a different column
-- set than what's below.
drop function if exists public.get_pricing_config();

create or replace function public.get_pricing_config()
returns table (
    trial_days integer,
    featured_product_id text,
    active_product_ids text[],
    product_badges jsonb
)
language sql
security definer
set search_path = public
stable
as $$
    select trial_days, featured_product_id, active_product_ids, product_badges
    from public.pricing_config
    where id = 1;
$$;

revoke all on function public.get_pricing_config() from public;
grant execute on function public.get_pricing_config() to authenticated, anon;

-- start_trial() now reads trial length from pricing_config instead of the
-- hardcoded "v_trial_days INTEGER := 10" it shipped with in
-- 003_subscription_model.sql. Falls back to 10 if the singleton row is
-- somehow missing, matching the client's own compiled-in default
-- (PricingConfig.compiledDefault) so the two can never disagree on the
-- fallback value.
create or replace function public.start_trial()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
    v_user_id uuid;
    v_current_status text;
    v_trial_days integer;
begin
    v_user_id := auth.uid();

    select coalesce((select trial_days from public.pricing_config where id = 1), 10)
    into v_trial_days;

    select subscription_status into v_current_status
    from public.users
    where id = v_user_id;

    if v_current_status != 'free' then
        return json_build_object(
            'success', false,
            'error', 'trial_not_eligible',
            'message', 'Trial already used or subscription active'
        );
    end if;

    update public.users
    set
        subscription_status = 'trialing',
        trial_start_date = now(),
        trial_end_date = now() + (v_trial_days || ' days')::interval,
        updated_at = now()
    where id = v_user_id;

    return json_build_object(
        'success', true,
        'trial_start_date', now(),
        'trial_end_date', now() + (v_trial_days || ' days')::interval,
        'trial_days', v_trial_days
    );
end;
$$;

revoke all on function public.start_trial() from public;
grant execute on function public.start_trial() to authenticated, anon;
