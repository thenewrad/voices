-- Likes system: one row per user/clip pair.
-- like_count is a denormalised column on clips, updated via RPC.

create table if not exists likes (
    id         uuid primary key default gen_random_uuid(),
    user_id    uuid not null references auth.users(id) on delete cascade,
    clip_id    uuid not null references clips(id)      on delete cascade,
    created_at timestamptz not null default now(),
    unique(user_id, clip_id)
);

alter table likes enable row level security;

create policy "likes visible to all"   on likes for select using (true);
create policy "users can like"         on likes for insert with check (auth.uid() = user_id);
create policy "users can unlike"       on likes for delete  using  (auth.uid() = user_id);

-- Denormalised count column on clips
alter table clips add column if not exists like_count int not null default 0;

create or replace function increment_like_count(clip_id uuid)
returns void language sql security definer as $$
    update clips set like_count = like_count + 1 where id = clip_id;
$$;

create or replace function decrement_like_count(clip_id uuid)
returns void language sql security definer as $$
    update clips set like_count = greatest(0, like_count - 1) where id = clip_id;
$$;
