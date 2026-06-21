-- Clips recorded from a channel page should only ever appear in that
-- channel's feed, never in the general Feed/Following/Local/Profile
-- listings. channel_id is set at insert time whenever a clip is posted
-- via the channel record flow; general feed queries filter it IS NULL.

alter table clips add column if not exists channel_id uuid references channels(id) on delete cascade;
create index if not exists clips_channel_id_idx on clips (channel_id);

-- Backfill: clips already posted to a channel before this column existed.
update clips set channel_id = cc.channel_id
from channel_clips cc
where cc.clip_id = clips.id and clips.channel_id is null;
