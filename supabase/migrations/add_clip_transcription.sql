-- Add AI-generated title and raw transcript to clips.
-- The transcribe-clip edge function populates these after each upload.
-- Both default to empty string so clips appear immediately while processing.

alter table clips
  add column if not exists title      text not null default '',
  add column if not exists transcript text not null default '';
