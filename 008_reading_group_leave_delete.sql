-- ============================================================
-- 008_reading_group_leave_delete.sql
--
-- Adds RPCs: leave_reading_group / delete_reading_group
--
-- Confirmed live schema (reading_groups / reading_group_members were
-- created directly on the project, not via a tracked migration — see
-- CARAVAN_SOCIAL_SCOPE.md §5):
--   reading_groups(id uuid pk, name text, group_code text,
--                   created_by uuid, created_at timestamptz)
--   reading_group_members(group_id uuid, user_id uuid, trader_code text,
--                          trader_name text, joined_at timestamptz)
--     -> group_id references reading_groups(id) ON DELETE CASCADE
--   shared_scrolls(..., to_group_id uuid)
--     -> to_group_id references reading_groups(id) ON DELETE CASCADE
--
-- Both dependent tables already cascade on delete of reading_groups, so
-- deleting the group row is sufficient cleanup for both RPCs below.
--
-- WhatsApp-style semantics (product decision):
--   - Any member (including the creator) may leave a group at any time.
--     If the departing member was the last one remaining, the group
--     itself is deleted as a side effect.
--   - The creator may force-delete the group outright at any time,
--     regardless of how many members remain. This removes every member
--     immediately.
--
-- Both RPCs are SECURITY DEFINER. RLS on reading_groups /
-- reading_group_members has no permissive policies (same convention as
-- 007_direct_messages.sql) — all access goes through RPCs, never raw
-- PostgREST table access.
-- ============================================================

create or replace function public.leave_reading_group(p_group_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_remaining int;
  v_group_deleted boolean := false;
begin
  if v_uid is null then
    return json_build_object('success', false, 'error', 'not_authenticated');
  end if;

  if not exists (
    select 1 from public.reading_group_members
    where group_id = p_group_id and user_id = v_uid
  ) then
    return json_build_object('success', false, 'error', 'not_a_member');
  end if;

  delete from public.reading_group_members
  where group_id = p_group_id and user_id = v_uid;

  select count(*) into v_remaining
  from public.reading_group_members
  where group_id = p_group_id;

  if v_remaining = 0 then
    -- Cascades to any remaining reading_group_members rows (none expected)
    -- and shared_scrolls rows pointed at this group.
    delete from public.reading_groups where id = p_group_id;
    v_group_deleted := true;
  end if;

  return json_build_object('success', true, 'group_deleted', v_group_deleted);
end;
$$;

grant execute on function public.leave_reading_group(uuid) to authenticated;

create or replace function public.delete_reading_group(p_group_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_creator uuid;
begin
  if v_uid is null then
    return json_build_object('success', false, 'error', 'not_authenticated');
  end if;

  select created_by into v_creator
  from public.reading_groups
  where id = p_group_id;

  if v_creator is null then
    return json_build_object('success', false, 'error', 'group_not_found');
  end if;

  if v_creator <> v_uid then
    return json_build_object('success', false, 'error', 'not_authorized');
  end if;

  -- Cascades to reading_group_members and shared_scrolls.
  delete from public.reading_groups where id = p_group_id;

  return json_build_object('success', true);
end;
$$;

grant execute on function public.delete_reading_group(uuid) to authenticated;
