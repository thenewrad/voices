-- Reply-to-reply notifications: when a reply targets another reply
-- (reply_to_user_id set), only the targeted user is notified — not the
-- thread/post creator. trigger_notify_reply (add_notification_triggers.sql)
-- is updated here to skip nested replies, since this trigger now owns that case.

create or replace function trigger_notify_reply_to_reply()
returns trigger
language plpgsql
security definer
as $$
declare
    v_replier_name text;
begin
    if NEW.reply_to_user_id is null then return NEW; end if;
    if NEW.reply_to_user_id = NEW.user_id then return NEW; end if;

    select username into v_replier_name from profiles where id = NEW.user_id;

    perform notify_user(
        p_recipient_id := NEW.reply_to_user_id,
        p_title        := 'New reply',
        p_body         := '@' || coalesce(v_replier_name, 'Someone') || ' replied to your reply',
        p_data         := jsonb_build_object('type', 'reply_to_reply', 'reply_id', NEW.id::text, 'clip_id', NEW.clip_id::text)
    );

    return NEW;
end;
$$;

drop trigger if exists on_reply_to_reply_inserted on replies;
create trigger on_reply_to_reply_inserted
    after insert on replies
    for each row execute function trigger_notify_reply_to_reply();

-- Thread creator is notified only for top-level replies (reply_to_user_id is
-- null); nested replies are handled entirely by trigger_notify_reply_to_reply.
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
    if NEW.reply_to_user_id is not null then return NEW; end if;

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
