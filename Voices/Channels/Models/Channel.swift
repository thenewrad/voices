import Foundation

// MARK: - Channel Role

enum ChannelRole: String, Codable, CaseIterable, Hashable {
    case admin
    case moderator
    case creator
    case member
    case follower

    var canRemoveClips: Bool { self == .admin || self == .moderator }
    var canManageMembers: Bool { self == .admin || self == .moderator }
    var canChangeSettings: Bool { self == .admin }
}

// MARK: - Channel

struct Channel: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var description: String?
    var avatarURL: String?
    var isPublic: Bool
    var category: String?
    let createdBy: UUID
    var followerCount: Int
    var clipCount: Int
    var requiresApproval: Bool
    var isMonetized: Bool
    var maxMembers: Int?
    var isArchived: Bool
    let createdAt: Date

    // Joined from channel_members for the current user (not from DB column)
    var currentUserRole: ChannelRole?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case avatarURL        = "avatar_url"
        case isPublic         = "is_public"
        case category
        case createdBy        = "created_by"
        case followerCount    = "follower_count"
        case clipCount        = "clip_count"
        case requiresApproval = "requires_approval"
        case isMonetized      = "is_monetized"
        case maxMembers       = "max_members"
        case isArchived       = "is_archived"
        case createdAt        = "created_at"
    }
}

// MARK: - ChannelMember

struct ChannelMember: Codable, Identifiable {
    let id: UUID
    let channelId: UUID
    let userId: UUID
    var role: ChannelRole
    let joinedAt: Date

    // Joined from profiles
    var profile: ChannelMemberProfile?

    enum CodingKeys: String, CodingKey {
        case id
        case channelId = "channel_id"
        case userId    = "user_id"
        case role
        case joinedAt  = "joined_at"
        case profile   = "profiles"
    }
}

struct ChannelMemberProfile: Codable {
    let username: String
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case username
        case avatarURL = "avatar_url"
    }
}

// MARK: - ChannelClip

struct ChannelClip: Decodable, Identifiable {
    let id: UUID
    let channelId: UUID
    let clipId: UUID
    let postedBy: UUID
    let postedAt: Date

    // Joined — the clip's own user_id always equals postedBy, since the
    // only way to post is recording directly from the channel page.
    var clip: Clip?

    enum CodingKeys: String, CodingKey {
        case id
        case channelId = "channel_id"
        case clipId    = "clip_id"
        case postedBy  = "posted_by"
        case postedAt  = "posted_at"
        case clip      = "clips"
    }
}

// MARK: - ChannelInvite

struct ChannelInvite: Codable, Identifiable {
    let id: UUID
    let channelId: UUID
    let invitedBy: UUID
    let invitedUserId: UUID?
    let inviteCode: String?
    var status: InviteStatus
    let createdAt: Date
    let expiresAt: Date?

    // Joined
    var channel: Channel?

    enum CodingKeys: String, CodingKey {
        case id
        case channelId      = "channel_id"
        case invitedBy      = "invited_by"
        case invitedUserId  = "invited_user_id"
        case inviteCode     = "invite_code"
        case status
        case createdAt      = "created_at"
        case expiresAt      = "expires_at"
        case channel        = "channels"
    }
}

enum InviteStatus: String, Codable {
    case pending
    case accepted
    case declined
}

// MARK: - Channel Categories

enum ChannelCategory: String, CaseIterable, Identifiable {
    case humor    = "Humor"
    case music    = "Music"
    case tech     = "Tech"
    case news     = "News"
    case sports   = "Sports"
    case food     = "Food"
    case faith    = "Faith"
    case travel   = "Travel"
    case lifestyle = "Lifestyle"
    case other    = "Other"

    var id: String { rawValue }
}
