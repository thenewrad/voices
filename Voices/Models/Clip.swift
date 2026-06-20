import Foundation

struct Clip: Identifiable, Decodable, Equatable {
    let id: UUID
    let user_id: UUID?
    let audio_url: String
    let lat: Double?
    let lng: Double?
    let created_at: Date
    let play_count: Int
    let like_count: Int
    let reply_count: Int
    let duration_seconds: Int
    let title: String?
    let transcript: String?
    let location_display: String?   // city name — never raw coords in UI
    let rawUsername: String?
    let profiles: ClipProfile?

    var username: String { rawUsername ?? profiles?.username ?? "anonymous" }

    var authorBeepTone: BeepTone {
        BeepTone(rawValue: profiles?.beep_tone ?? "") ?? .standard
    }

    var initials: String {
        username
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map { String($0).uppercased() } }
            .joined()
    }

    // Returns city name from DB; nil when location was not captured or is hidden.
    // Raw lat/lng are never surfaced to the UI.
    var locationDisplay: String? { location_display }

    var timeDisplay: String {
        let elapsed = Date().timeIntervalSince(created_at)
        switch elapsed {
        case ..<60:      return "just now"
        case ..<3_600:   return "\(Int(elapsed / 60))m ago"
        case ..<86_400:  return "\(Int(elapsed / 3_600))h ago"
        default:
            return Self.dateFormatter.string(from: created_at)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    enum CodingKeys: String, CodingKey {
        case id, user_id, audio_url, lat, lng
        case created_at, play_count, like_count, reply_count, duration_seconds
        case title, transcript, location_display
        case rawUsername = "username"
        case profiles
    }
}

struct ClipProfile: Decodable, Equatable {
    let username: String?
    let avatar_url: String?
    let beep_tone: String?
}

extension Clip {
    func withPlayCount(_ count: Int) -> Clip {
        Clip(id: id, user_id: user_id, audio_url: audio_url,
             lat: lat, lng: lng, created_at: created_at,
             play_count: count, like_count: like_count, reply_count: reply_count,
             duration_seconds: duration_seconds, title: title,
             transcript: transcript, location_display: location_display,
             rawUsername: rawUsername, profiles: profiles)
    }

    func withReplyCount(_ count: Int) -> Clip {
        Clip(id: id, user_id: user_id, audio_url: audio_url,
             lat: lat, lng: lng, created_at: created_at,
             play_count: play_count, like_count: like_count, reply_count: count,
             duration_seconds: duration_seconds, title: title,
             transcript: transcript, location_display: location_display,
             rawUsername: rawUsername, profiles: profiles)
    }

    func withLikeCount(_ count: Int) -> Clip {
        Clip(id: id, user_id: user_id, audio_url: audio_url,
             lat: lat, lng: lng, created_at: created_at,
             play_count: play_count, like_count: count, reply_count: reply_count,
             duration_seconds: duration_seconds, title: title,
             transcript: transcript, location_display: location_display,
             rawUsername: rawUsername, profiles: profiles)
    }
}
