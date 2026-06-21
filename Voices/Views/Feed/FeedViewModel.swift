import Foundation
import Supabase

@MainActor
final class FeedViewModel: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var freshClipIDs: Set<UUID> = []

    private var channel: RealtimeChannelV2?

    // MARK: - Fetch

    func fetchClips() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched: [Clip] = try await SupabaseService.shared.client
                .from("clips")
                .select("id, user_id, audio_url, lat, lng, created_at, play_count, reply_count, duration_seconds, title, like_count, location_display, profiles!clips_user_id_fkey(username, avatar_url, beep_tone)")
                .is("channel_id", value: nil)
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
                .value

            let hidden = UserRelationshipService.shared.hiddenUserIDs
            let filtered = fetched.filter { clip in
                guard let uid = clip.user_id else { return true }
                return !hidden.contains(uid)
            }
            let existingIDs = Set(clips.map(\.id))
            let newIDs = Set(filtered.map(\.id)).subtracting(existingIDs)
            clips = filtered

            if !newIDs.isEmpty && !existingIDs.isEmpty {
                freshClipIDs = newIDs
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    freshClipIDs = []
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Realtime

    func listenForNewClips() async {
        let ch = SupabaseService.shared.client.channel("feed-clips-changes")
        channel = ch
        let insertions = ch.postgresChange(InsertAction.self, schema: "public", table: "clips")
        let updates    = ch.postgresChange(UpdateAction.self, schema: "public", table: "clips")
        await ch.subscribe()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in insertions { await self.fetchClips() }
            }
            group.addTask {
                for await update in updates { await self.applyUpdate(update) }
            }
        }
    }

    private func applyUpdate(_ action: UpdateAction) {
        guard case .string(let idStr) = action.record["id"],
              let clipId = UUID(uuidString: idStr),
              let idx = clips.firstIndex(where: { $0.id == clipId }) else { return }
        if case .integer(let count) = action.record["play_count"] {
            clips[idx] = clips[idx].withPlayCount(count)
        }
        if case .integer(let count) = action.record["reply_count"] {
            clips[idx] = clips[idx].withReplyCount(count)
        }
        if case .integer(let count) = action.record["like_count"] {
            clips[idx] = clips[idx].withLikeCount(count)
            LikeService.shared.clearLikeOffset(for: clipId)
        }
    }

    func stopListening() async {
        if let ch = channel {
            await SupabaseService.shared.client.removeChannel(ch)
            channel = nil
        }
    }
}
