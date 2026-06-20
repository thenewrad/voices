-- Profile avatar stored as a public URL (includes ?v=timestamp for cache-busting on update).
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS avatar_url TEXT;

-- Public avatars bucket
INSERT INTO storage.buckets (id, name, public)
VALUES ('avatars', 'avatars', true)
ON CONFLICT (id) DO NOTHING;

-- Anyone can view avatars
CREATE POLICY "Public avatar read" ON storage.objects
  FOR SELECT USING (bucket_id = 'avatars');

-- Authenticated users can upload to their own folder ({user_id}/avatar.jpg)
CREATE POLICY "Owner avatar insert" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'avatars' AND
    auth.uid()::text = (storage.foldername(name))[1]
  );

-- Authenticated users can update their own avatar
CREATE POLICY "Owner avatar update" ON storage.objects
  FOR UPDATE USING (
    bucket_id = 'avatars' AND
    auth.uid()::text = (storage.foldername(name))[1]
  );
