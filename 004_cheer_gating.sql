-- Migration 004: Gate send_cheer behind Plus access.
--
-- Problem: cheers were server-enforced only for the one-per-sender/recipient/
-- day rate limit — there was no subscription check at all, so a free or
-- lapsed user could send unlimited encouragement despite the monetization
-- plan listing "The Caravan (friends, cheers, groups)" as Full Access for
-- Plus only, View Only otherwise. The client now gates the button in
-- DuelCard on hasPlusAccess, but that's UX only; this closes the same gap
-- server-side so a modified client can't bypass it.
--
-- Uses the same predicate as get_leaderboard_tiered/can_access_scroll_two:
-- subscription_status IN ('active', 'trialing') = Plus access.
--
-- Everything else (identity resolution, recipient lookup, insert, and the
-- unique_violation -> already_sent handling) is unchanged from the current
-- live definition.

CREATE OR REPLACE FUNCTION public.send_cheer(p_to_code text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_from_code text;
  v_to_uid uuid;
  v_cheer_id uuid;
  v_status text;
begin
  if v_uid is null then
    return json_build_object('success', false, 'error', 'not_authenticated');
  end if;
  select trader_code into v_from_code from public.users where id = v_uid;
  if v_from_code is null then
    return json_build_object('success', false, 'error', 'no_identity');
  end if;

  -- Plus-only gate: free/lapsed callers are rejected here, before any
  -- recipient lookup or insert happens.
  select subscription_status into v_status from public.users where id = v_uid;
  if v_status is null or v_status not in ('active', 'trialing') then
    return json_build_object('success', false, 'error', 'plus_required');
  end if;

  select id into v_to_uid from public.users where trader_code = p_to_code;
  if v_to_uid is null then
    return json_build_object('success', false, 'error', 'recipient_not_found');
  end if;
  begin
    insert into public.cheers (from_trader_code, to_trader_code, to_user_id)
    values (v_from_code, p_to_code, v_to_uid)
    returning id into v_cheer_id;
  exception when unique_violation then
    return json_build_object('success', true, 'already_sent', true);
  end;
  return json_build_object('success', true, 'already_sent', false, 'cheer_id', v_cheer_id);
end;
$function$;

REVOKE ALL ON FUNCTION public.send_cheer(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_cheer(text) TO authenticated, anon;

COMMENT ON FUNCTION public.send_cheer IS
'Sends a cheer from the caller to p_to_code. Requires Plus access
(subscription_status IN (''active'',''trialing'')) — free/lapsed callers get
{"success": false, "error": "plus_required"}. Rate-limited to one per
sender/recipient/day via the unique constraint on public.cheers.';
