-- Lets an invited user insert themselves into channel_members once they
-- accept, without needing an admin/mod-only insert policy. Checks the
-- invite's status = 'pending', so the app must insert the membership row
-- before flipping the invite to 'accepted' — not after.
create policy "Invited user can join as member" on channel_members for insert
    with check (
        auth.uid() = user_id and role = 'member'
        and exists (
            select 1 from channel_invites
            where channel_invites.channel_id = channel_members.channel_id
              and channel_invites.invited_user_id = auth.uid()
              and channel_invites.status = 'pending'
        )
    );

-- "member" is the role granted to accepted invitees (previously, and
-- incorrectly, "creator").
alter table channel_members drop constraint channel_members_role_check;
alter table channel_members add constraint channel_members_role_check
    check (role = any (array['admin', 'moderator', 'creator', 'member', 'follower']));
