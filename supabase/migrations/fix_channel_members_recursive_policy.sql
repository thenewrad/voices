-- "infinite recursion detected in policy for relation channel_members":
-- the "Creator inserts themselves as admin" policy's WITH CHECK contained
-- a raw subquery against channel_members itself. Since INSERT policies on
-- the same table are OR'd together, evaluating any one of them (even one
-- that ultimately doesn't apply, e.g. accepting an invite with role =
-- 'member') still requires evaluating every policy's WITH CHECK — and a
-- self-referential subquery inline in a policy (rather than behind a
-- SECURITY DEFINER function) re-triggers RLS on the same table mid-check.
-- All the other policies on this table already avoid this via a SECURITY
-- DEFINER helper (is_channel_member, channel_user_role); these two follow
-- the same pattern.

create or replace function channel_has_no_members(p_channel_id uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select not exists (select 1 from channel_members where channel_id = p_channel_id);
$$;

drop policy if exists "Creator inserts themselves as admin on new channel" on channel_members;
create policy "Creator inserts themselves as admin on new channel" on channel_members for insert
    with check (auth.uid() = user_id and role = 'admin' and channel_has_no_members(channel_id));

-- Same fix applied to the invite-accept policy's invite lookup (channel_invites,
-- not channel_members, but kept consistent with the SECURITY DEFINER pattern).
create or replace function has_pending_channel_invite(p_channel_id uuid, p_user_id uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (
    select 1 from channel_invites
    where channel_id = p_channel_id
      and invited_user_id = p_user_id
      and status = 'pending'
  );
$$;

drop policy if exists "Invited user can join as member" on channel_members;
create policy "Invited user can join as member" on channel_members for insert
    with check (auth.uid() = user_id and role = 'member' and has_pending_channel_invite(channel_id, auth.uid()));
