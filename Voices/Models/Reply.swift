import Foundation

struct Reply: Identifiable, Decodable {
    let id: UUID
    let clip_id: UUID
    let user_id: UUID
    let audio_url: String
    let duration_seconds: Int
    let created_at: Date
    let play_count: Int
    let like_count: Int
    let location_display: String?
    let reply_to_user_id: UUID?
    let reply_to_username: String?
    let profiles: ReplyProfile?

    var username: String { profiles?.username ?? "anonymous" }

    var initials: String {
        username
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map { String($0).uppercased() } }
            .joined()
    }

    var timeDisplay: String {
        let elapsed = Date().timeIntervalSince(created_at)
        switch elapsed {
        case ..<60:      return "just now"
        case ..<3_600:   return "\(Int(elapsed / 60))m ago"
        case ..<86_400:  return "\(Int(elapsed / 3_600))h ago"
        default:         return Self.dateFormatter.string(from: created_at)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    enum CodingKeys: String, CodingKey {
        case id, clip_id, user_id, audio_url, duration_seconds
        case created_at, play_count, like_count, location_display
        case reply_to_user_id, reply_to_username
        case profiles
    }
}

struct ReplyProfile: Decodable {
    let username: String?
    let avatar_url: String?
}
