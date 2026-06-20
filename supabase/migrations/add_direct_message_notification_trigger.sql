-- Notification trigger for direct messages.
-- Fires when a new DM is inserted and notifies the recipient via the
-- send-notification edge function (same pattern as likes/replies/follows).

create or replace function trigger_notify_direct_message()
returns trigger
language plpgsql
security definer
as $$
declare
    v_sender_name text;
begin
    -- Skip self-messages (shouldn't happen but be safe)
    if NEW.sender_id = NEW.recipient_id then
        return NEW;
    end if;

    select username into v_sender_name from profiles where id = NEW.sender_id;

    perform notify_user(
        p_recipient_id := NEW.recipient_id,
        p_title        := 'New voice message',
        p_body         := '@' || coalesce(v_sender_name, 'Someone') || ' sent you a voice message',
        p_data         := jsonb_build_object('type', 'direct_message', 'message_id', NEW.id::text)
    );

    return NEW;
end;
$$;

drop trigger if exists on_direct_message_inserted on direct_messages;
create trigger on_direct_message_inserted
    after insert on direct_messages
    for each row execute function trigger_notify_direct_message();
