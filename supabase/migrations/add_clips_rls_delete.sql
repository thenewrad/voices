-- RLS: allow users to delete only their own clips.
-- Assumes RLS is already enabled on the clips table.

create policy "users can delete own clips"
    on clips
    for delete
    using (auth.uid() = user_id);
