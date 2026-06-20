-- Notification triggers for likes, replies, and follows.
-- Calls the send-notification edge function via pg_net (HTTP).
-- pg_net is enabled by default on Supabase projects.

-- Helper: invoke the send-notification edge function
create or replace function notify_user(
    p_recipient_id  uuid,
    p_title         text,
    p_body          text,
    p_data          jsonb default '{}'::jsonb
) returns void
language plpgsql
security definer
as $$
begin
    perform net.http_post(
        url     := 'https://vqibjqieliplqeldchky.supabase.co/functions/v1/send-notification',
        headers := jsonb_build_object(
            'Content-Type',  'application/json',
            'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZxaWJqcWllbGlwbHFlbGRjaGt5Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3NjYyMTc1NywiZXhwIjoyMDkyMTk3NzU3fQ.KYEkV-7doP8L3DM0_et2PCWfwfg8JQPw8drrnAULGXM'
        ),
        body    := jsonb_build_object(
            'recipient_user_id', p_recipient_id,
            'title',             p_title,
            'body',              p_body,
            'data',              p_data
        )
    );
end;
$$;

-- ---------------------------------------------------------------------------
-- LIKES trigger
-- ---------------------------------------------------------------------------

create or replace function trigger_notify_like()
returns trigger
language plpgsql
security definer
as $$
declare
    v_clip_owner   uuid;
    v_clip_title   text;
    v_liker_name   text;
begin
    select user_id, coalesce(nullif(trim(title), ''), 'your post')
    into   v_clip_owner, v_clip_title
    from   clips
    where  id = NEW.clip_id;

    if v_clip_owner is null or v_clip_owner = NEW.user_id then
        return NEW;
    end if;

    select username into v_liker_name from profiles where id = NEW.user_id;

    perform notify_user(
        p_recipient_id := v_clip_owner,
        p_title        := 'New like',
        p_body         := '@' || coalesce(v_liker_name, 'Someone') || ' liked ' || v_clip_title,
        p_data         := jsonb_build_object('type', 'like', 'clip_id', NEW.clip_id::text)
    );

    return NEW;
end;
$$;

drop trigger if exists on_like_inserted on likes;
create trigger on_like_inserted
    after insert on likes
    for each row execute function trigger_notify_like();

-- ---------------------------------------------------------------------------
-- REPLIES trigger
-- ---------------------------------------------------------------------------

create or replace function trigger_notify_reply()
returns trigger
language plpgsql
security definer
as $$
declare
    v_clip_owner   uuid;
    v_clip_title   text;
    v_replier_name text;
begin
    select user_id, coalesce(nullif(trim(title), ''), 'your post')
    into   v_clip_owner, v_clip_title
    from   clips
    where  id = NEW.clip_id;

    if v_clip_owner is null or v_clip_owner = NEW.user_id then
        return NEW;
    end if;

    select username into v_replier_name from profiles where id = NEW.user_id;

    perform notify_user(
        p_recipient_id := v_clip_owner,
        p_title        := 'New reply',
        p_body         := '@' || coalesce(v_replier_name, 'Someone') || ' replied to ' || v_clip_title,
        p_data         := jsonb_build_object('type', 'reply', 'clip_id', NEW.clip_id::text, 'reply_id', NEW.id::text)
    );

    return NEW;
end;
$$;

drop trigger if exists on_reply_inserted on replies;
create trigger on_reply_inserted
    after insert on replies
    for each row execute function trigger_notify_reply();

-- ---------------------------------------------------------------------------
-- FOLLOWS trigger
-- ---------------------------------------------------------------------------

create or replace function trigger_notify_follow()
returns trigger
language plpgsql
security definer
as $$
declare
    v_follower_name text;
begin
    select username into v_follower_name from profiles where id = NEW.follower_id;

    perform notify_user(
        p_recipient_id := NEW.following_id,
        p_title        := 'New follower',
        p_body         := '@' || coalesce(v_follower_name, 'Someone') || ' followed you',
        p_data         := jsonb_build_object('type', 'follow', 'follower_id', NEW.follower_id::text)
    );

    return NEW;
end;
$$;

drop trigger if exists on_follow_inserted on follows;
create trigger on_follow_inserted
    after insert on follows
    for each row execute function trigger_notify_follow();
