-- Channel posting is now record-only, from the channel page itself, and
-- open to any member (not just admin/moderator/creator). There is no more
-- "pick an existing clip" flow, so any member who can be in the channel
-- at all should be able to post into it, and remove their own posts.

drop policy if exists "Admin/mod/creator can post clips" on channel_clips;
create policy "Members can post clips" on channel_clips for insert
    with check (posted_by = auth.uid() and is_channel_member(channel_id, auth.uid()));

drop policy if exists "Creator can remove own clip" on channel_clips;
create policy "Member can remove own clip" on channel_clips for delete
    using (posted_by = auth.uid());
