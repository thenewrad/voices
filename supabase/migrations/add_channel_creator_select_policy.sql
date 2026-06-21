-- createChannel does .insert(row).select() — for INSERT with RETURNING,
-- Postgres re-checks SELECT policies against the new row. Public channels
-- were always visible via "Public channels visible to all" (no membership
-- dependency), but private channels only had "Private channels visible to
-- members", which depends on is_channel_member() — itself dependent on the
-- add_channel_admin_on_create AFTER trigger having already run. That race
-- made "new row violates row-level security policy" appear only when
-- creating a private channel. This policy removes the dependency entirely:
-- a creator can always see their own channel, trigger timing aside.
create policy "Creator can view own channel" on channels for select
    using (created_by = auth.uid());
