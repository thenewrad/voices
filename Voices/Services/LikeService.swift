import Foundation

@MainActor
final class LikeService: ObservableObject {
    static let shared = LikeService()
    private init() {}

    @Published var likedClipIDs: Set<UUID> = []
    @Published var pendingLikeOffsets: [UUID: Int] = [:]

    // MARK: - Load

    func fetchLikedClipIDs() async {
        do {
            let uid = try await SupabaseService.shared.client.auth.session.user.id
            struct Row: Decodable { let clip_id: UUID }
            let rows: [Row] = try await SupabaseService.shared.client
                .from("likes")
                .select("clip_id")
                .eq("user_id", value: uid.uuidString)
                .execute()
                .value
            likedClipIDs = Set(rows.map(\.clip_id))
        } catch {
            print("LikeService.fetchLikedClipIDs error: \(error)")
        }
    }

    // MARK: - Toggle (optimistic)

    func toggleLike(clip: Clip) async {
        let wasLiked = likedClipIDs.contains(clip.id)
        let delta = wasLiked ? -1 : 1

        if wasLiked { likedClipIDs.remove(clip.id) }
        else         { likedClipIDs.insert(clip.id) }
        pendingLikeOffsets[clip.id] = (pendingLikeOffsets[clip.id] ?? 0) + delta

        do {
            if wasLiked {
                try await unlike(clipId: clip.id)
            } else {
                try await like(clipId: clip.id)
            }
        } catch {
            // Revert on failure
            if wasLiked { likedClipIDs.insert(clip.id) }
            else         { likedClipIDs.remove(clip.id) }
            pendingLikeOffsets[clip.id] = (pendingLikeOffsets[clip.id] ?? 0) - delta
            print("LikeService.toggleLike error: \(error)")
        }
    }

    func clearLikeOffset(for clipId: UUID) {
        pendingLikeOffsets.removeValue(forKey: clipId)
    }

    // MARK: - Network

    private func like(clipId: UUID) async throws {
        let uid = try await SupabaseService.shared.client.auth.session.user.id
        print("LikeService.like: INSERT likes user_id=\(uid.uuidString) clip_id=\(clipId.uuidString)")
        struct LikeInsert: Encodable { let user_id: UUID; let clip_id: UUID }
        do {
            try await SupabaseService.shared.client
                .from("likes")
                .insert(LikeInsert(user_id: uid, clip_id: clipId))
                .execute()
            print("LikeService.like: INSERT succeeded")
        } catch {
            print("LikeService.like: INSERT failed [\(type(of: error))]: \(error)")
            throw error
        }
        struct P: Encodable { let clip_id: UUID }
        do {
            _ = try await SupabaseService.shared.client
                .rpc("increment_like_count", params: P(clip_id: clipId)).execute()
            print("LikeService.like: increment_like_count succeeded")
        } catch {
            print("LikeService.like: increment_like_count failed [\(type(of: error))]: \(error)")
        }
    }

    private func unlike(clipId: UUID) async throws {
        let uid = try await SupabaseService.shared.client.auth.session.user.id
        print("LikeService.unlike: DELETE likes user_id=\(uid.uuidString) clip_id=\(clipId.uuidString)")
        do {
            try await SupabaseService.shared.client
                .from("likes")
                .delete()
                .eq("user_id", value: uid.uuidString)
                .eq("clip_id", value: clipId.uuidString)
                .execute()
            print("LikeService.unlike: DELETE succeeded")
        } catch {
            print("LikeService.unlike: DELETE failed [\(type(of: error))]: \(error)")
            throw error
        }
        struct P: Encodable { let clip_id: UUID }
        do {
            _ = try await SupabaseService.shared.client
                .rpc("decrement_like_count", params: P(clip_id: clipId)).execute()
            print("LikeService.unlike: decrement_like_count succeeded")
        } catch {
            print("LikeService.unlike: decrement_like_count failed [\(type(of: error))]: \(error)")
        }
    }
}
