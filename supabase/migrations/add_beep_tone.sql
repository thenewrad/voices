-- Each user's chosen intro tone, played for listeners before their clips.
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS beep_tone TEXT NOT NULL DEFAULT 'standard';
