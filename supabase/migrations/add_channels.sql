-- Channels: named groups users can create, follow, and post clips into.
-- Mirrors the schema already applied directly against the live project
-- (see supabase/functions and Voices/Channels for the client-side usage).

create table if not exists channels (
    id                uuid primary key default gen_random_uuid(),
    name              text not null,
    description       text,
    avatar_url        text,
    is_public         boolean not null default true,
    category          text,
    created_by        uuid not null references profiles(id) on delete cascade,
    follower_count    int not null default 0,
    clip_count        int not null default 0,
    requires_approval boolean not null default false,
    is_monetized      boolean not null default false,
    max_members       int,
    is_archived       boolean not null default false,
    created_at        timestamptz not null default now()
);

create table if not exists channel_members (
    id         uuid primary key default gen_random_uuid(),
    channel_id uuid not null references channels(id) on delete cascade,
    user_id    uuid not null references profiles(id) on delete cascade,
    role       text not null default 'follower' check (role in ('admin', 'moderator', 'creator', 'follower')),
    joined_at  timestamptz not null default now(),
    unique(channel_id, user_id)
);

create table if not exists channel_clips (
    id         uuid primary key default gen_random_uuid(),
    channel_id uuid not null references channels(id) on delete cascade,
    clip_id    uuid not null references clips(id) on delete cascade,
    posted_by  uuid not null references profiles(id) on delete cascade,
    posted_at  timestamptz not null default now(),
    unique(channel_id, clip_id)
);

create table if not exists channel_invites (
    id              uuid primary key default gen_random_uuid(),
    channel_id      uuid not null references channels(id) on delete cascade,
    invited_by      uuid not null references profiles(id) on delete cascade,
    invited_user_id uuid references profiles(id) on delete cascade,
    invite_code     text unique default encode(gen_random_bytes(8), 'hex'),
    status          text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
    created_at      timestamptz not null default now(),
    expires_at      timestamptz
);

create index if not exists channels_public_idx        on channels (is_public) where is_public = true;
create index if not exists channels_category_idx      on channels (category);
create index if not exists channel_members_channel_id_idx on channel_members (channel_id);
create index if not exists channel_members_user_id_idx    on channel_members (user_id);
create index if not exists channel_clips_channel_id_idx   on channel_clips (channel_id);
create index if not exists channel_clips_posted_at_idx    on channel_clips (channel_id, posted_at desc);

alter table channels        enable row level security;
alter table channel_members enable row level security;
alter table channel_clips   enable row level security;
alter table channel_invites enable row level security;

-- MARK: - Helper functions (SECURITY DEFINER to read channel_members without recursive RLS)

create or replace function channel_user_role(p_channel_id uuid, p_user_id uuid)
returns text language sql stable security definer as $$
  select role from channel_members
  where channel_id = p_channel_id and user_id = p_user_id
  limit 1;
$$;

create or replace function is_channel_member(p_channel_id uuid, p_user_id uuid)
returns boolean language sql stable security definer as $$
  select exists (
    select 1 from channel_members
    where channel_id = p_channel_id and user_id = p_user_id
  );
$$;

-- MARK: - channels policies

create policy "Public channels visible to all" on channels for select
    using (is_public = true and is_archived = false);

create policy "Private channels visible to members" on channels for select
    using (is_public = false and is_archived = false and is_channel_member(id, auth.uid()));

create policy "Archived channels visible to admin" on channels for select
    using (is_archived = true and channel_user_role(id, auth.uid()) = 'admin');

create policy "Authenticated users can create channels" on channels for insert
    with check (auth.uid() is not null and created_by = auth.uid());

create policy "Admin can update channel" on channels for update
    using (channel_user_role(id, auth.uid()) = 'admin');

create policy "Admin can delete channel" on channels for delete
    using (channel_user_role(id, auth.uid()) = 'admin');

-- MARK: - channel_members policies

create policy "Members visible for public channels or to members" on channel_members for select
    using (
        exists (select 1 from channels where channels.id = channel_members.channel_id and channels.is_public = true)
        or is_channel_member(channel_id, auth.uid())
    );

-- NOTE: live policy compares cm.channel_id to itself (always true), so the
-- "first member" guard is a no-op once channel_members has any row at all.
-- Replicated as deployed; not fixed here.
create policy "Creator inserts themselves as admin on new channel" on channel_members for insert
    with check (
        auth.uid() = user_id and role = 'admin'
        and not exists (select 1 from channel_members cm where cm.channel_id = cm.channel_id)
    );

create policy "Users can follow public open channels" on channel_members for insert
    with check (
        auth.uid() = user_id and role = 'follower'
        and exists (
            select 1 from channels
            where channels.id = channel_members.channel_id
              and channels.is_public = true
              and channels.requires_approval = false
        )
    );

create policy "Admin or mod can add members" on channel_members for insert
    with check (channel_user_role(channel_id, auth.uid()) in ('admin', 'moderator'));

create policy "Admin or mod can update member roles" on channel_members for update
    using (channel_user_role(channel_id, auth.uid()) in ('admin', 'moderator'));

create policy "Members can leave" on channel_members for delete
    using (user_id = auth.uid());

create policy "Admin or mod can remove members" on channel_members for delete
    using (channel_user_role(channel_id, auth.uid()) in ('admin', 'moderator'));

-- MARK: - channel_clips policies

create policy "Clips visible to members or public channel viewers" on channel_clips for select
    using (
        exists (select 1 from channels where channels.id = channel_clips.channel_id and channels.is_public = true)
        or is_channel_member(channel_id, auth.uid())
    );

create policy "Admin/mod/creator can post clips" on channel_clips for insert
    with check (posted_by = auth.uid() and channel_user_role(channel_id, auth.uid()) in ('admin', 'moderator', 'creator'));

create policy "Creator can remove own clip" on channel_clips for delete
    using (posted_by = auth.uid() and channel_user_role(channel_id, auth.uid()) = 'creator');

create policy "Admin or mod can remove any clip" on channel_clips for delete
    using (channel_user_role(channel_id, auth.uid()) in ('admin', 'moderator'));

-- MARK: - channel_invites policies

create policy "Invitee can view their invites" on channel_invites for select
    using (invited_user_id = auth.uid());

create policy "Admin or mod can view channel invites" on channel_invites for select
    using (channel_user_role(channel_id, auth.uid()) in ('admin', 'moderator'));

create policy "Admin or mod can create invites" on channel_invites for insert
    with check (invited_by = auth.uid() and channel_user_role(channel_id, auth.uid()) in ('admin', 'moderator'));

create policy "Invitee can accept or decline" on channel_invites for update
    using (invited_user_id = auth.uid());

-- MARK: - Triggers

create or replace function add_channel_admin_on_create()
returns trigger language plpgsql security definer as $$
begin
  insert into channel_members (channel_id, user_id, role)
  values (new.id, new.created_by, 'admin');
  return new;
end;
$$;

create trigger on_channel_created
    after insert on channels
    for each row execute function add_channel_admin_on_create();

create or replace function sync_channel_follower_count()
returns trigger language plpgsql security definer as $$
begin
  if TG_OP = 'INSERT' then
    update channels set follower_count = follower_count + 1 where id = new.channel_id;
  elsif TG_OP = 'DELETE' then
    update channels set follower_count = greatest(0, follower_count - 1) where id = old.channel_id;
  end if;
  return null;
end;
$$;

create trigger on_channel_member_change
    after insert or delete on channel_members
    for each row execute function sync_channel_follower_count();

create or replace function sync_channel_clip_count()
returns trigger language plpgsql security definer as $$
begin
  if TG_OP = 'INSERT' then
    update channels set clip_count = clip_count + 1 where id = new.channel_id;
  elsif TG_OP = 'DELETE' then
    update channels set clip_count = greatest(0, clip_count - 1) where id = old.channel_id;
  end if;
  return null;
end;
$$;

create trigger on_channel_clip_change
    after insert or delete on channel_clips
    for each row execute function sync_channel_clip_count();
