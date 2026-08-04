-- Migration 007: 1:1 direct messages, restricted to mutual friends.
--
-- Problem: "Add friend by code" (CaravanView.addFriendCard / AppStore.addFriend)
-- has only ever been a local, client-side action — state.friendCodes never
-- reaches the server (AppStore.addFriend/removeFriend just mutate local
-- state and schedulePersist()). There's no way for the backend to know two
-- traders have actually added each other, so there's no way to gate
-- anything — like DMs — on "are these two mutual friends" rather than
-- "does trader X know trader Y's code" (share_scroll's p_to_trader_code
-- already shows that's a weak bar: any valid code works, added or not).
--
-- This migration:
--   1. Adds friend_links — one directional edge per "add friend" action.
--      Two rows in opposite directions (A->B and B->A) = mutual friendship.
--   2. Adds direct_messages for 1:1 DMs.
--   3. Adds RPCs: add_friend_link / remove_friend_link (sync the existing
--      local add/remove action server-side) and send_direct_message /
--      fetch_direct_messages / fetch_dm_threads / mark_dm_read.
--
-- RLS is enabled on both new tables with NO permissive policies — same
-- access pattern as the rest of Caravan (reading_groups, shared_scrolls,
-- cheers): all reads/writes go through SECURITY DEFINER RPCs below, never
-- raw PostgREST table access, so there is nothing for a policy to grant.
--
-- Every RETURNS TABLE below uses output column names distinct from the
-- underlying table columns (dm_id vs id, sent_at vs created_at, etc.) and
-- every reference inside the function body is table-qualified — the
-- unqualified `WHERE id = v_uid` bug that broke fetch_pending_shares
-- (id colliding with a RETURNS TABLE column of the same name) doesn't get
-- a chance to recur here.

-- ============================================================
-- 1. Schema
-- ============================================================

create table if not exists public.friend_links (
    truster_id uuid not null references public.users(id) on delete cascade,
    friend_id  uuid not null references public.users(id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (truster_id, friend_id),
    constraint friend_links_no_self check (truster_id <> friend_id)
);

create index if not exists idx_friend_links_friend on public.friend_links(friend_id);

alter table public.friend_links enable row level security;

create table if not exists public.direct_messages (
    id uuid primary key default gen_random_uuid(),
    from_user_id uuid not null references public.users(id) on delete cascade,
    to_user_id   uuid not null references public.users(id) on delete cascade,
    body text not null check (char_length(btrim(body)) between 1 and 1000),
    created_at timestamptz not null default now(),
    read_at timestamptz,
    constraint direct_messages_no_self check (from_user_id <> to_user_id)
);

-- One index for "conversation between A and B, in order" regardless of who
-- sent which message — least/greatest normalizes the pair so both
-- directions hit the same index range.
create index if not exists idx_dm_pair_time
    on public.direct_messages (least(from_user_id, to_user_id), greatest(from_user_id, to_user_id), created_at);

create index if not exists idx_dm_unread
    on public.direct_messages (to_user_id, from_user_id)
    where read_at is null;

alter table public.direct_messages enable row level security;

-- ============================================================
-- 2. Friend sync RPCs
-- ============================================================

create or replace function public.add_friend_link(p_friend_code text)
 returns json
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_friend_id uuid;
  v_mutual boolean;
begin
  if v_uid is null then
    return json_build_object('success', false, 'error', 'not_authenticated');
  end if;
  if p_friend_code is null or btrim(p_friend_code) = '' then
    return json_build_object('success', false, 'error', 'code_required');
  end if;

  select id into v_friend_id from public.users where trader_code = upper(btrim(p_friend_code));
  if v_friend_id is null then
    return json_build_object('success', false, 'error', 'recipient_not_found');
  end if;
  if v_friend_id = v_uid then
    return json_build_object('success', false, 'error', 'cannot_add_self');
  end if;

  insert into public.friend_links (truster_id, friend_id)
  values (v_uid, v_friend_id)
  on conflict (truster_id, friend_id) do nothing;

  select exists(
    select 1 from public.friend_links where truster_id = v_friend_id and friend_id = v_uid
  ) into v_mutual;

  return json_build_object('success', true, 'mutual', v_mutual);
end;
$function$;

REVOKE ALL ON FUNCTION public.add_friend_link(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.add_friend_link(text) TO authenticated, anon;

comment on function public.add_friend_link is
'Records that the caller added p_friend_code as a friend (one directional
edge). Returns {"success":true,"mutual":bool} — mutual is true only once the
other trader has added the caller back too. Call alongside the existing
local state.friendCodes append in AppStore.addFriend; send_direct_message
below only allows messages once mutual is true.';

create or replace function public.remove_friend_link(p_friend_code text)
 returns json
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_friend_id uuid;
begin
  if v_uid is null then
    return json_build_object('success', false, 'error', 'not_authenticated');
  end if;

  select id into v_friend_id from public.users where trader_code = upper(btrim(p_friend_code));
  if v_friend_id is null then
    return json_build_object('success', true);
  end if;

  delete from public.friend_links where truster_id = v_uid and friend_id = v_friend_id;

  return json_build_object('success', true);
end;
$function$;

REVOKE ALL ON FUNCTION public.remove_friend_link(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.remove_friend_link(text) TO authenticated, anon;

comment on function public.remove_friend_link is
'Removes the caller''s one-directional edge to p_friend_code (mirrors
AppStore.removeFriend). Does not touch the other trader''s edge back — if
they had also added the caller, that edge stays until they remove it too,
same as the local friendCodes lists already work independently per device.
Once either edge is gone the pair is no longer mutual, so
send_direct_message/fetch_direct_messages stop working between them.';

-- ============================================================
-- 3. Direct messages
-- ============================================================

create or replace function public.send_direct_message(p_to_code text, p_body text)
 returns json
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_to_id uuid;
  v_mutual boolean;
  v_body text := btrim(coalesce(p_body, ''));
  v_msg_id uuid;
  v_created_at timestamptz;
begin
  if v_uid is null then
    return json_build_object('success', false, 'error', 'not_authenticated');
  end if;
  if v_body = '' then
    return json_build_object('success', false, 'error', 'empty_message');
  end if;
  if char_length(v_body) > 1000 then
    return json_build_object('success', false, 'error', 'message_too_long');
  end if;

  select id into v_to_id from public.users where trader_code = upper(btrim(p_to_code));
  if v_to_id is null then
    return json_build_object('success', false, 'error', 'recipient_not_found');
  end if;
  if v_to_id = v_uid then
    return json_build_object('success', false, 'error', 'cannot_message_self');
  end if;

  select exists(select 1 from public.friend_links where truster_id = v_uid   and friend_id = v_to_id)
     and exists(select 1 from public.friend_links where truster_id = v_to_id and friend_id = v_uid)
    into v_mutual;

  if not v_mutual then
    return json_build_object('success', false, 'error', 'not_mutual_friends');
  end if;

  insert into public.direct_messages (from_user_id, to_user_id, body)
  values (v_uid, v_to_id, v_body)
  returning id, created_at into v_msg_id, v_created_at;

  return json_build_object('success', true, 'message_id', v_msg_id, 'created_at', v_created_at);
end;
$function$;

REVOKE ALL ON FUNCTION public.send_direct_message(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_direct_message(text, text) TO authenticated, anon;

comment on function public.send_direct_message is
'Sends a 1:1 DM from the caller to p_to_code. Requires mutual friendship —
both friend_links edges (caller->recipient and recipient->caller) must
exist, or this returns {"success":false,"error":"not_mutual_friends"}
without inserting anything. Body capped at 1000 chars.';

create or replace function public.fetch_direct_messages(p_with_code text, p_limit integer default 50, p_before timestamptz default null)
 returns table (
   dm_id uuid,
   from_trader_code text,
   to_trader_code text,
   body text,
   sent_at timestamptz,
   read_at timestamptz,
   is_mine boolean
 )
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_with_id uuid;
  v_mutual boolean;
begin
  if v_uid is null then
    return;
  end if;

  select u.id into v_with_id from public.users u where u.trader_code = upper(btrim(p_with_code));
  if v_with_id is null then
    return;
  end if;

  select exists(select 1 from public.friend_links fl where fl.truster_id = v_uid     and fl.friend_id = v_with_id)
     and exists(select 1 from public.friend_links fl where fl.truster_id = v_with_id and fl.friend_id = v_uid)
    into v_mutual;
  if not v_mutual then
    return;
  end if;

  return query
  select
    dm.id,
    sender.trader_code,
    recipient.trader_code,
    dm.body,
    dm.created_at,
    dm.read_at,
    dm.from_user_id = v_uid
  from public.direct_messages dm
  join public.users sender    on sender.id = dm.from_user_id
  join public.users recipient on recipient.id = dm.to_user_id
  where
    ((dm.from_user_id = v_uid and dm.to_user_id = v_with_id)
     or (dm.from_user_id = v_with_id and dm.to_user_id = v_uid))
    and (p_before is null or dm.created_at < p_before)
  order by dm.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 200));
end;
$function$;

REVOKE ALL ON FUNCTION public.fetch_direct_messages(text, integer, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fetch_direct_messages(text, integer, timestamptz) TO authenticated, anon;

comment on function public.fetch_direct_messages is
'Returns up to p_limit messages (newest first) between the caller and
p_with_code. Returns an empty set — not an error — if the pair is not
currently mutual friends, so a lapsed friendship just makes the thread
disappear rather than erroring the client. p_before pages further back in
history by passing the oldest sent_at already fetched.';

create or replace function public.fetch_dm_threads()
 returns table (
   thread_trader_code text,
   thread_trader_name text,
   last_message text,
   last_message_at timestamptz,
   last_message_is_mine boolean,
   unread_count integer
 )
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return;
  end if;

  return query
  with mutual_friends as (
    select fl1.friend_id as peer_id
    from public.friend_links fl1
    join public.friend_links fl2
      on fl2.truster_id = fl1.friend_id and fl2.friend_id = fl1.truster_id
    where fl1.truster_id = v_uid
  ),
  last_msgs as (
    select
      mf.peer_id,
      dm.body,
      dm.created_at,
      (dm.from_user_id = v_uid) as is_mine,
      row_number() over (partition by mf.peer_id order by dm.created_at desc) as rn
    from mutual_friends mf
    left join public.direct_messages dm
      on (dm.from_user_id = v_uid and dm.to_user_id = mf.peer_id)
      or (dm.from_user_id = mf.peer_id and dm.to_user_id = v_uid)
  ),
  unread as (
    select dm.from_user_id as peer_id, count(*) as cnt
    from public.direct_messages dm
    where dm.to_user_id = v_uid and dm.read_at is null
    group by dm.from_user_id
  )
  select
    peer.trader_code,
    peer.trader_name,
    lm.body,
    lm.created_at,
    lm.is_mine,
    coalesce(unread.cnt, 0)::integer
  from mutual_friends mf
  join public.users peer on peer.id = mf.peer_id
  left join last_msgs lm on lm.peer_id = mf.peer_id and lm.rn = 1
  left join unread on unread.peer_id = mf.peer_id
  order by coalesce(lm.created_at, to_timestamp(0)) desc;
end;
$function$;

REVOKE ALL ON FUNCTION public.fetch_dm_threads() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fetch_dm_threads() TO authenticated, anon;

comment on function public.fetch_dm_threads is
'One row per mutual friend (not per message with history — threads with no
messages yet still appear, last_message/last_message_at null), ordered by
most recent activity, with an unread_count for the Caravan tab badge. Only
mutual friends appear here at all, same restriction as
fetch_direct_messages/send_direct_message.';

create or replace function public.mark_dm_read(p_with_code text)
 returns json
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_with_id uuid;
  v_count integer;
begin
  if v_uid is null then
    return json_build_object('success', false, 'error', 'not_authenticated');
  end if;

  select id into v_with_id from public.users where trader_code = upper(btrim(p_with_code));
  if v_with_id is null then
    return json_build_object('success', true, 'updated', 0);
  end if;

  update public.direct_messages
  set read_at = now()
  where to_user_id = v_uid and from_user_id = v_with_id and read_at is null;

  get diagnostics v_count = row_count;

  return json_build_object('success', true, 'updated', v_count);
end;
$function$;

REVOKE ALL ON FUNCTION public.mark_dm_read(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_dm_read(text) TO authenticated, anon;

comment on function public.mark_dm_read is
'Marks every unread message from p_with_code to the caller as read. Call
when a DM thread is opened, mirroring how resolve_scroll_share clears a
pending share.';
