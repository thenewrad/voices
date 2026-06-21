-- Channel icons: square image uploaded by the channel admin, stored at
-- {channel_id}/icon.jpg. Channels without one fall back to a gradient +
-- initials in the app (ChannelAvatarView), same idea as user avatars
-- (add_avatar_url.sql) but admin-only instead of self-only.

insert into storage.buckets (id, name, public)
values ('channel-icons', 'channel-icons', true)
on conflict (id) do nothing;

create policy "Public channel icon read" on storage.objects
    for select using (bucket_id = 'channel-icons');

create policy "Admin channel icon insert" on storage.objects
    for insert with check (
        bucket_id = 'channel-icons'
        and channel_user_role(((storage.foldername(name))[1])::uuid, auth.uid()) = 'admin'
    );

create policy "Admin channel icon update" on storage.objects
    for update using (
        bucket_id = 'channel-icons'
        and channel_user_role(((storage.foldername(name))[1])::uuid, auth.uid()) = 'admin'
    );
