-- Stores APNs device tokens for silent push notifications.
-- One token per device; upserted on conflict so reinstalls update cleanly.

create table if not exists device_tokens (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null references auth.users(id) on delete cascade,
    token       text not null unique,
    platform    text not null default 'apns',
    created_at  timestamptz not null default now()
);

alter table device_tokens enable row level security;

-- Users can only read/write their own tokens
create policy "own tokens" on device_tokens
    for all using (auth.uid() = user_id);
