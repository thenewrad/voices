import Foundation
import Supabase

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var isLoading = false

    var refreshProfile: (() async -> Void)?

    private var channel: RealtimeChannelV2?

    // MARK: - Fetch

    func fetchClips(userId: UUID) async {
        // Debug: verify follower/following counts in Supabase
        do {
            struct CountRow: Decodable { let follower_count: Int; let following_count: Int }
            let rows: [CountRow] = try await SupabaseService.shared.client
                .from("profiles")
                .select("follower_count, following_count")
                .eq("id", value: userId.uuidString)
                .limit(1)
                .execute()
                .value
            if let c = rows.first {
                print("ProfileViewModel: DB counts → follower_count=\(c.follower_count) following_count=\(c.following_count)")
            } else {
                print("ProfileViewModel: no profile row found for userId=\(userId.uuidString)")
            }
        } catch {
            print("ProfileViewModel: counts query error — \(error)")
        }

        isLoading = true
        defer { isLoading = false }
        do {
            clips = try await SupabaseService.shared.client
                .from("clips")
                .select("id, user_id, audio_url, lat, lng, created_at, play_count, reply_count, duration_seconds, title, like_count, location_display, profiles!clips_user_id_fkey(username, avatar_url, beep_tone)")
                .eq("user_id", value: userId.uuidString)
                .is("channel_id", value: nil)
                .order("created_at", ascending: false)
                .execute()
                .value
            await refreshProfile?()
        } catch {
            print("ProfileViewModel.fetchClips error [\(type(of: error))]: \(error)")
        }
    }

    // MARK: - Delete

    func deleteClip(id: UUID, audioUrl: String) async {
        print("[DeleteClip] ── begin ─────────────────────────────")
        print("[DeleteClip] clip_id  : \(id.uuidString)")
        print("[DeleteClip] audio_url: \(audioUrl)")
        print("[DeleteClip] clips.count before: \(clips.count)")

        clips.removeAll { $0.id == id }
        print("[DeleteClip] clips.count after local remove: \(clips.count)")

        do {
            let userId = try await SupabaseService.shared.client.auth.session.user.id
            print("[DeleteClip] auth user_id: \(userId.uuidString)")

            // DB delete — requires RLS: auth.uid() = user_id
            do {
                try await SupabaseService.shared.client
                    .from("clips")
                    .delete()
                    .eq("id", value: id.uuidString)
                    .eq("user_id", value: userId.uuidString)
                    .execute()
                print("[DeleteClip] ✅ Supabase DB delete succeeded")
            } catch {
                print("[DeleteClip] ❌ Supabase DB delete FAILED: [\(type(of: error))] \(error)")
                // Restore the clip locally since DB delete failed
                await fetchClips(userId: userId)
                return
            }

            // Storage delete
            do {
                let _ = try await SupabaseService.shared.client.storage
                    .from("audio")
                    .remove(paths: [audioUrl])
                print("[DeleteClip] ✅ Storage delete succeeded for \(audioUrl)")
            } catch {
                print("[DeleteClip] ⚠️ Storage delete FAILED (clip row already deleted): [\(type(of: error))] \(error)")
            }

            await refreshProfile?()
        } catch {
            print("[DeleteClip] ❌ Auth session error: \(error)")
        }
        print("[DeleteClip] ── end ───────────────────────────────")
    }

    // MARK: - Realtime

    func listenForUpdates(userId: UUID) async {
        let ch = SupabaseService.shared.client.channel("profile-clips-\(userId.uuidString)")
        channel = ch
        // Filter to only this user's clips so we don't process the entire clips table
        let updates = ch.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "clips",
            filter: "user_id=eq.\(userId.uuidString)"
        )
        await ch.subscribe()
        for await update in updates {
            applyUpdate(update)
        }
    }

    private func applyUpdate(_ action: UpdateAction) {
        guard case .string(let idStr) = action.record["id"],
              let clipId = UUID(uuidString: idStr),
              let idx = clips.firstIndex(where: { $0.id == clipId }) else { return }
        if case .integer(let count) = action.record["play_count"] {
            clips[idx] = clips[idx].withPlayCount(count)
        }
    }

    func stopListening() async {
        if let ch = channel {
            await SupabaseService.shared.client.removeChannel(ch)
            channel = nil
        }
    }
}
