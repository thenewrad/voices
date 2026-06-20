import Foundation

struct UserProfile: Decodable, Equatable {
    let id: UUID
    let username: String
    let bio: String?
    let avatar_url: String?
    let beep_tone: String?
    let follower_count: Int
    let following_count: Int
    let clip_count: Int
}
