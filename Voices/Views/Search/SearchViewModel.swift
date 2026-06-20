import Foundation
import Combine

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var results: [FollowUser] = []
    @Published var isLoading = false
    @Published var hasSearched = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        $searchText
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] text in
                Task { @MainActor [weak self] in
                    await self?.search(text: text)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Search

    private func search(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            hasSearched = false
            isLoading = false
            return
        }

        isLoading = true
        hasSearched = true

        do {
            struct ProfileRow: Decodable { let id: UUID; let username: String; let avatar_url: String? }
            let rows: [ProfileRow] = try await SupabaseService.shared.client
                .from("profiles")
                .select("id, username, avatar_url")
                .ilike("username", pattern: "%\(trimmed)%")
                .limit(30)
                .execute()
                .value

            let myFollowing = Set((try? await FollowService.shared.followingIds()) ?? [])
            results = rows.map { p in
                FollowUser(id: p.id, username: p.username, avatar_url: p.avatar_url, isFollowing: myFollowing.contains(p.id))
            }
            print("SearchViewModel: \(results.count) result(s) for \"\(trimmed)\"")
        } catch {
            print("SearchViewModel.search error: \(error)")
            results = []
        }

        isLoading = false
    }

    // MARK: - Follow / Unfollow

    func toggleFollow(userId: UUID) async {
        guard let idx = results.firstIndex(where: { $0.id == userId }) else { return }
        let wasFollowing = results[idx].isFollowing

        results[idx].isFollowing = !wasFollowing
        results[idx].isLoadingFollow = true

        do {
            if wasFollowing {
                try await FollowService.shared.unfollow(targetUserId: userId)
            } else {
                try await FollowService.shared.follow(targetUserId: userId)
            }
        } catch {
            results[idx].isFollowing = wasFollowing
            print("SearchViewModel.toggleFollow error: \(error)")
        }
        results[idx].isLoadingFollow = false
    }
}
