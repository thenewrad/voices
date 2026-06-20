import Foundation

struct FollowUser: Identifiable {
    let id: UUID
    let username: String
    let avatar_url: String?
    var isFollowing: Bool
    var isLoadingFollow: Bool = false

    var initials: String { String(username.prefix(1)).uppercased() }
}
