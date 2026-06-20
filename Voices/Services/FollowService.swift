import Foundation

@MainActor
final class FollowService {
    static let shared = FollowService()
    private init() {}

    // MARK: - Check

    func isFollowing(targetUserId: UUID) async -> Bool {
        do {
            let currentId = try await SupabaseService.shared.client.auth.session.user.id
            struct Row: Decodable { let follower_id: UUID }
            let rows: [Row] = try await SupabaseService.shared.client
                .from("follows")
                .select("follower_id")
                .eq("follower_id", value: currentId.uuidString)
                .eq("following_id", value: targetUserId.uuidString)
                .execute()
                .value
            return !rows.isEmpty
        } catch {
            return false
        }
    }

    // MARK: - Follow

    func follow(targetUserId: UUID) async throws {
        let currentId = try await SupabaseService.shared.client.auth.session.user.id
        print("follow: INSERT follows follower_id=\(currentId) following_id=\(targetUserId)")
        struct FollowInsert: Encodable {
            let follower_id: UUID
            let following_id: UUID
        }
        do {
            try await SupabaseService.shared.client
                .from("follows")
                .insert(FollowInsert(follower_id: currentId, following_id: targetUserId))
                .execute()
            print("follow: INSERT follows succeeded")
        } catch {
            let msg = error.localizedDescription
            if msg.contains("23505") || msg.contains("duplicate key") {
                print("follow: already following — treating as success")
            } else {
                print("follow: INSERT follows failed — \(error)")
                throw error
            }
        }

        struct TargetParam: Encodable { let target_id: UUID }
        _ = try? await SupabaseService.shared.client
            .rpc("increment_follower_count", params: TargetParam(target_id: targetUserId))
            .execute()
        _ = try? await SupabaseService.shared.client
            .rpc("increment_following_count", params: TargetParam(target_id: currentId))
            .execute()
    }

    // MARK: - Unfollow

    func unfollow(targetUserId: UUID) async throws {
        let currentId = try await SupabaseService.shared.client.auth.session.user.id
        print("unfollow: DELETE follows follower_id=\(currentId) following_id=\(targetUserId)")
        struct TargetParam: Encodable { let target_id: UUID }
        try await SupabaseService.shared.client
            .from("follows")
            .delete()
            .eq("follower_id", value: currentId.uuidString)
            .eq("following_id", value: targetUserId.uuidString)
            .execute()
        print("unfollow: DELETE follows succeeded")
        _ = try? await SupabaseService.shared.client
            .rpc("decrement_follower_count", params: TargetParam(target_id: targetUserId))
            .execute()
        _ = try? await SupabaseService.shared.client
            .rpc("decrement_following_count", params: TargetParam(target_id: currentId))
            .execute()
    }

    // MARK: - Following IDs (for Following feed)

    func followingIds() async throws -> [UUID] {
        let currentId = try await SupabaseService.shared.client.auth.session.user.id
        struct Row: Decodable { let following_id: UUID }
        let rows: [Row] = try await SupabaseService.shared.client
            .from("follows")
            .select("following_id")
            .eq("follower_id", value: currentId.uuidString)
            .execute()
            .value
        return rows.map(\.following_id)
    }
}
