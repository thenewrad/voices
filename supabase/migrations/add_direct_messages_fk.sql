-- Add foreign key so PostgREST can resolve the profiles join in ActivityViewModel.
ALTER TABLE direct_messages
  ADD CONSTRAINT direct_messages_sender_id_fkey
  FOREIGN KEY (sender_id) REFERENCES profiles(id) ON DELETE CASCADE;
