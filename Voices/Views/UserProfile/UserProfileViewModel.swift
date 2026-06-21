import Foundation

@MainActor
final class UserProfileViewModel: ObservableObject {
    let userId: UUID
    let username: String

    @Published var profile: UserProfile?
    @Published var clips: [Clip] = []
    @Published var isFollowing = false
    @Published var isLoading = false
    @Published var isFollowLoading = false

    init(userId: UUID, username: String) {
        self.userId = userId
        self.username = username
    }

    // MARK: - Load

    func load() async {
        isLoading = true
        defer { isLoading = false }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.fetchProfile() }
            group.addTask { await self.fetchClips() }
            group.addTask { await self.checkFollowStatus() }
        }
    }

    func fetchProfile() async {
        do {
            let rows: [UserProfile] = try await SupabaseService.shared.client
                .from("profiles")
                .select("id, username, bio, follower_count, following_count, clip_count")
                .eq("id", value: userId.uuidString)
                .limit(1)
                .execute()
                .value
            profile = rows.first
            if let p = rows.first {
                print("UserProfileViewModel: fetched profile → follower_count=\(p.follower_count) following_count=\(p.following_count)")
            }
        } catch {
            print("UserProfileViewModel.fetchProfile error: \(error)")
        }
    }

    private func fetchClips() async {
        do {
            clips = try await SupabaseService.shared.client
                .from("clips")
                .select("id, user_id, audio_url, lat, lng, created_at, play_count, reply_count, duration_seconds, title, like_count, location_display, profiles!clips_user_id_fkey(username, avatar_url, beep_tone)")
                .eq("user_id", value: userId.uuidString)
                .is("channel_id", value: nil)
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            print("UserProfileViewModel.fetchClips error: \(error)")
        }
    }

    private func checkFollowStatus() async {
        isFollowing = await FollowService.shared.isFollowing(targetUserId: userId)
    }

    // MARK: - Follow / Unfollow

    func toggleFollow() async {
        let wasFollowing = isFollowing
        print("toggleFollow: isFollowing before = \(wasFollowing)")

        // Optimistic toggle — button updates instantly before the network call
        isFollowing = !wasFollowing
        print("isFollowing toggled to: \(isFollowing)")
        updateFollowerCount(by: wasFollowing ? -1 : 1)
        print("toggleFollow: isFollowing after  = \(isFollowing)")

        isFollowLoading = true
        defer { isFollowLoading = false }
        do {
            if wasFollowing {
                try await FollowService.shared.unfollow(targetUserId: userId)
            } else {
                try await FollowService.shared.follow(targetUserId: userId)
            }
            print("toggleFollow: network call succeeded (isFollowing = \(isFollowing))")
            // Re-fetch target profile to get server-authoritative counts
            await fetchProfile()
        } catch {
            // Revert optimistic changes on failure
            isFollowing = wasFollowing
            updateFollowerCount(by: wasFollowing ? 1 : -1)
            print("toggleFollow failed: \(error)")
        }
    }

    private func updateFollowerCount(by delta: Int) {
        guard let p = profile else { return }
        profile = UserProfile(
            id: p.id,
            username: p.username,
            bio: p.bio,
            avatar_url: p.avatar_url,
            beep_tone: p.beep_tone,
            follower_count: max(0, p.follower_count + delta),
            following_count: p.following_count,
            clip_count: p.clip_count
        )
    }
}
