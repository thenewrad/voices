import Foundation

@MainActor
final class ThreadViewModel: ObservableObject {
    @Published var replies: [Reply] = []
    @Published var isLoading = false
    @Published var likedReplyIDs: Set<UUID> = []
    @Published var lastError: String? = nil

    // MARK: - Fetch

    func fetchReplies(clipId: UUID) async {
        let selectString = "id, clip_id, user_id, audio_url, duration_seconds, play_count, like_count, created_at, reply_to_user_id, reply_to_username, profiles!replies_user_id_fkey(username, avatar_url)"
        let clipIdStr = clipId.uuidString.lowercased()
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await SupabaseService.shared.client
                .from("replies")
                .select(selectString)
                .eq("clip_id", value: clipIdStr)
                .order("created_at", ascending: true)
                .execute()
            let decoder = JSONDecoder()
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .iso8601)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
            decoder.dateDecodingStrategy = .formatted(formatter)
            let fetched = try decoder.decode([Reply].self, from: response.data)
            replies = fetched
        } catch {
            if let decodingError = error as? DecodingError {
                switch decodingError {
                case .keyNotFound(let key, _):
                    lastError = "Missing key: \(key)"
                case .typeMismatch(let type, let context):
                    lastError = "Type mismatch: \(type) at \(context.codingPath)"
                case .valueNotFound(let type, let context):
                    lastError = "Value not found: \(type) at \(context.codingPath)"
                default:
                    lastError = "Decode error: \(decodingError)"
                }
            } else {
                lastError = error.localizedDescription
            }
        }
    }

    func fetchLikedReplyIDs() async {
        guard let uid = try? await SupabaseService.shared.client.auth.session.user.id else { return }
        struct LikeRow: Decodable { let reply_id: UUID }
        guard let rows: [LikeRow] = try? await SupabaseService.shared.client
            .from("reply_likes")
            .select("reply_id")
            .eq("user_id", value: uid.uuidString)
            .execute()
            .value
        else { return }
        likedReplyIDs = Set(rows.map { $0.reply_id })
    }

    // MARK: - Like

    func toggleLike(reply: Reply) async {
        let wasLiked = likedReplyIDs.contains(reply.id)

        // Optimistic update
        if wasLiked { likedReplyIDs.remove(reply.id) }
        else         { likedReplyIDs.insert(reply.id) }
        updateLocalLikeCount(reply: reply, delta: wasLiked ? -1 : 1)

        do {
            let uid = try await SupabaseService.shared.client.auth.session.user.id
            if wasLiked {
                try await SupabaseService.shared.client
                    .from("reply_likes")
                    .delete()
                    .eq("user_id", value: uid.uuidString)
                    .eq("reply_id", value: reply.id.uuidString)
                    .execute()
                struct P: Encodable { let p_reply_id: UUID }
                _ = try? await SupabaseService.shared.client
                    .rpc("decrement_reply_like_count", params: P(p_reply_id: reply.id))
                    .execute()
            } else {
                struct Insert: Encodable { let user_id: UUID; let reply_id: UUID }
                try await SupabaseService.shared.client
                    .from("reply_likes")
                    .insert(Insert(user_id: uid, reply_id: reply.id))
                    .execute()
                struct P: Encodable { let p_reply_id: UUID }
                _ = try? await SupabaseService.shared.client
                    .rpc("increment_reply_like_count", params: P(p_reply_id: reply.id))
                    .execute()
            }
        } catch {
            print("[ThreadVM] ❌ toggleLike ERROR: \(error)")
            // Revert on failure
            if wasLiked { likedReplyIDs.insert(reply.id) }
            else         { likedReplyIDs.remove(reply.id) }
            updateLocalLikeCount(reply: reply, delta: wasLiked ? 1 : -1)
        }
    }

    private func updateLocalLikeCount(reply: Reply, delta: Int) {
        guard let idx = replies.firstIndex(where: { $0.id == reply.id }) else { return }
        let r = replies[idx]
        replies[idx] = Reply(
            id: r.id, clip_id: r.clip_id, user_id: r.user_id,
            audio_url: r.audio_url, duration_seconds: r.duration_seconds,
            created_at: r.created_at, play_count: r.play_count,
            like_count: max(0, r.like_count + delta),
            location_display: r.location_display,
            reply_to_user_id: r.reply_to_user_id,
            reply_to_username: r.reply_to_username,
            profiles: r.profiles
        )
    }
}
