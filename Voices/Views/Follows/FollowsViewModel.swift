import Foundation

enum FollowsMode {
    case followers   // who follows this profile  (follows.following_id = profileId)
    case following   // who this profile follows  (follows.follower_id  = profileId)
}

@MainActor
final class FollowsViewModel: ObservableObject {
    let profileId: UUID
    let mode: FollowsMode

    @Published var users: [FollowUser] = []
    @Published var isLoading = false
    @Published var searchText = ""

    var filtered: [FollowUser] {
        searchText.isEmpty
            ? users
            : users.filter { $0.username.localizedCaseInsensitiveContains(searchText) }
    }

    init(profileId: UUID, mode: FollowsMode) {
        self.profileId = profileId
        self.mode = mode
    }

    // MARK: - Load

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // 1. Fetch the relevant user IDs from the follows table
            let targetIds: [UUID]
            switch mode {
            case .followers:
                struct Row: Decodable { let follower_id: UUID }
                let rows: [Row] = try await SupabaseService.shared.client
                    .from("follows")
                    .select("follower_id")
                    .eq("following_id", value: profileId.uuidString)
                    .execute()
                    .value
                targetIds = rows.map(\.follower_id)
            case .following:
                struct Row: Decodable { let following_id: UUID }
                let rows: [Row] = try await SupabaseService.shared.client
                    .from("follows")
                    .select("following_id")
                    .eq("follower_id", value: profileId.uuidString)
                    .execute()
                    .value
                targetIds = rows.map(\.following_id)
            }

            guard !targetIds.isEmpty else { users = []; return }

            // 2. Fetch profiles for those IDs
            struct ProfileRow: Decodable { let id: UUID; let username: String; let avatar_url: String? }
            let profiles: [ProfileRow] = try await SupabaseService.shared.client
                .from("profiles")
                .select("id, username, avatar_url")
                .in("id", values: targetIds.map(\.uuidString))
                .execute()
                .value

            // 3. Current user's following list — one query sets all isFollowing states
            let myFollowing = Set((try? await FollowService.shared.followingIds()) ?? [])

            users = profiles.map { p in
                FollowUser(id: p.id, username: p.username, avatar_url: p.avatar_url, isFollowing: myFollowing.contains(p.id))
            }
        } catch {
            print("FollowsViewModel.load error: \(error)")
        }
    }

    // MARK: - Follow / Unfollow

    func toggleFollow(userId: UUID) async {
        guard let idx = users.firstIndex(where: { $0.id == userId }) else { return }
        let wasFollowing = users[idx].isFollowing

        // Optimistic update
        users[idx].isFollowing = !wasFollowing
        users[idx].isLoadingFollow = true

        do {
            if wasFollowing {
                try await FollowService.shared.unfollow(targetUserId: userId)
            } else {
                try await FollowService.shared.follow(targetUserId: userId)
            }
        } catch {
            users[idx].isFollowing = wasFollowing   // revert on failure
            print("FollowsViewModel.toggleFollow error: \(error)")
        }
        users[idx].isLoadingFollow = false
    }
}
