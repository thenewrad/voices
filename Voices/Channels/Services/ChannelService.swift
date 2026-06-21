import Foundation
import Supabase

@MainActor
class ChannelService: ObservableObject {

    static let shared = ChannelService()
    private let client = SupabaseService.shared.client

    // MARK: - Channel CRUD

    /// Create a channel. The DB trigger auto-adds the creator as admin.
    func createChannel(
        name: String,
        description: String? = nil,
        avatarURL: String? = nil,
        isPublic: Bool = true,
        category: String? = nil,
        requiresApproval: Bool = false,
        isMonetized: Bool = false,
        maxMembers: Int? = nil
    ) async throws -> Channel {
        guard let userId = client.auth.currentUser?.id else { throw ChannelError.notAuthenticated }

        struct Insert: Encodable {
            let name: String
            let description: String?
            let avatar_url: String?
            let is_public: Bool
            let category: String?
            let created_by: UUID
            let requires_approval: Bool
            let is_monetized: Bool
            let max_members: Int?
        }

        let row = Insert(
            name: name,
            description: description,
            avatar_url: avatarURL,
            is_public: isPublic,
            category: category,
            created_by: userId,
            requires_approval: requiresApproval,
            is_monetized: isMonetized,
            max_members: maxMembers
        )

        return try await client
            .from("channels")
            .insert(row)
            .select()
            .single()
            .execute()
            .value
    }

    func updateChannel(_ channel: Channel) async throws {
        struct Update: Encodable {
            let name: String
            let description: String?
            let avatar_url: String?
            let is_public: Bool
            let category: String?
            let requires_approval: Bool
            let is_monetized: Bool
            let max_members: Int?
        }

        let update = Update(
            name: channel.name,
            description: channel.description,
            avatar_url: channel.avatarURL,
            is_public: channel.isPublic,
            category: channel.category,
            requires_approval: channel.requiresApproval,
            is_monetized: channel.isMonetized,
            max_members: channel.maxMembers
        )

        try await client
            .from("channels")
            .update(update)
            .eq("id", value: channel.id)
            .execute()
    }

    func archiveChannel(id: UUID) async throws {
        try await client
            .from("channels")
            .update(["is_archived": true])
            .eq("id", value: id)
            .execute()
    }

    func deleteChannel(id: UUID) async throws {
        try await client
            .from("channels")
            .delete()
            .eq("id", value: id)
            .execute()
    }

    // MARK: - Discovery

    /// Fetch all public channels, optionally filtered by category
    func fetchPublicChannels(category: String? = nil, search: String? = nil) async throws -> [Channel] {
        var query = client
            .from("channels")
            .select()
            .eq("is_public", value: true)
            .eq("is_archived", value: false)

        if let category {
            query = query.eq("category", value: category)
        }
        if let search, !search.isEmpty {
            query = query.ilike("name", value: "%\(search)%")
        }

        return try await query
            .order("follower_count", ascending: false)
            .execute()
            .value
    }

    /// Channels the current user is a member of (any role)
    func fetchMyChannels() async throws -> [Channel] {
        guard let userId = client.auth.currentUser?.id else { throw ChannelError.notAuthenticated }

        // Fetch member rows, join channels
        struct MemberWithChannel: Decodable {
            let role: ChannelRole
            let channels: Channel
        }

        let rows: [MemberWithChannel] = try await client
            .from("channel_members")
            .select("role, channels(*)")
            .eq("user_id", value: userId)
            .eq("channels.is_archived", value: false)
            .execute()
            .value

        return rows.map { row in
            var ch = row.channels
            ch.currentUserRole = row.role
            return ch
        }
    }

    // MARK: - Membership

    func joinChannel(id: UUID) async throws {
        guard let userId = client.auth.currentUser?.id else { throw ChannelError.notAuthenticated }

        struct Insert: Encodable {
            let channel_id: UUID
            let user_id: UUID
            let role: String
        }

        try await client
            .from("channel_members")
            .insert(Insert(channel_id: id, user_id: userId, role: "follower"))
            .execute()
    }

    func leaveChannel(id: UUID) async throws {
        guard let userId = client.auth.currentUser?.id else { throw ChannelError.notAuthenticated }

        try await client
            .from("channel_members")
            .delete()
            .eq("channel_id", value: id)
            .eq("user_id", value: userId)
            .execute()
    }

    func fetchMembers(channelId: UUID) async throws -> [ChannelMember] {
        return try await client
            .from("channel_members")
            .select("*, profiles(username, avatar_url)")
            .eq("channel_id", value: channelId)
            .order("joined_at", ascending: true)
            .execute()
            .value
    }

    func updateMemberRole(channelId: UUID, userId: UUID, role: ChannelRole) async throws {
        try await client
            .from("channel_members")
            .update(["role": role.rawValue])
            .eq("channel_id", value: channelId)
            .eq("user_id", value: userId)
            .execute()
    }

    func removeMember(channelId: UUID, userId: UUID) async throws {
        try await client
            .from("channel_members")
            .delete()
            .eq("channel_id", value: channelId)
            .eq("user_id", value: userId)
            .execute()
    }

    // MARK: - Invites

    func inviteMember(channelId: UUID, username: String) async throws {
        guard let inviterId = client.auth.currentUser?.id else { throw ChannelError.notAuthenticated }

        // Resolve username → user id
        struct Profile: Decodable { let id: UUID }
        let profiles: [Profile] = try await client
            .from("profiles")
            .select("id")
            .eq("username", value: username)
            .limit(1)
            .execute()
            .value
        guard let profile = profiles.first else { throw ChannelError.userNotFound }

        struct Insert: Encodable {
            let channel_id: UUID
            let invited_by: UUID
            let invited_user_id: UUID
        }

        try await client
            .from("channel_invites")
            .insert(Insert(channel_id: channelId, invited_by: inviterId, invited_user_id: profile.id))
            .execute()
    }

    func fetchMyInvites() async throws -> [ChannelInvite] {
        guard let userId = client.auth.currentUser?.id else { throw ChannelError.notAuthenticated }

        return try await client
            .from("channel_invites")
            .select("*, channels(id, name, description, avatar_url, is_public, category, created_by, follower_count, clip_count, requires_approval, is_monetized, max_members, is_archived, created_at)")
            .eq("invited_user_id", value: userId)
            .eq("status", value: "pending")
            .execute()
            .value
    }

    func respondToInvite(id: UUID, accept: Bool) async throws {
        guard let userId = client.auth.currentUser?.id else { throw ChannelError.notAuthenticated }

        let newStatus = accept ? "accepted" : "declined"

        // Fetch invite to get channel id
        let invite: ChannelInvite = try await client
            .from("channel_invites")
            .select()
            .eq("id", value: id)
            .single()
            .execute()
            .value

        // Join while the invite is still "pending" — the RLS policy that lets
        // an invited user insert themselves checks for that exact status, so
        // this must happen before the invite's status is updated below.
        if accept {
            struct Insert: Encodable {
                let channel_id: UUID
                let user_id: UUID
                let role: String
            }
            try await client
                .from("channel_members")
                .insert(Insert(channel_id: invite.channelId, user_id: userId, role: "member"))
                .execute()
        }

        try await client
            .from("channel_invites")
            .update(["status": newStatus])
            .eq("id", value: id)
            .execute()
    }

    // MARK: - Channel Clips

    func fetchChannelFeed(channelId: UUID, limit: Int = 30, offset: Int = 0) async throws -> [ChannelClip] {
        return try await client
            .from("channel_clips")
            .select("""
                *,
                clips(id, user_id, audio_url, lat, lng, created_at, play_count, reply_count, duration_seconds, title, like_count, location_display, profiles!clips_user_id_fkey(username, avatar_url, beep_tone))
            """)
            .eq("channel_id", value: channelId)
            .order("posted_at", ascending: false)
            .range(from: offset, to: offset + limit - 1)
            .execute()
            .value
    }

    func postClipToChannel(channelId: UUID, clipId: UUID) async throws {
        guard let userId = client.auth.currentUser?.id else { throw ChannelError.notAuthenticated }

        struct Insert: Encodable {
            let channel_id: UUID
            let clip_id: UUID
            let posted_by: UUID
        }

        try await client
            .from("channel_clips")
            .insert(Insert(channel_id: channelId, clip_id: clipId, posted_by: userId))
            .execute()
    }

    func removeClipFromChannel(channelClipId: UUID) async throws {
        try await client
            .from("channel_clips")
            .delete()
            .eq("id", value: channelClipId)
            .execute()
    }

    // MARK: - Current User Role

    func currentUserRole(channelId: UUID) async throws -> ChannelRole? {
        guard let userId = client.auth.currentUser?.id else { return nil }

        struct Row: Decodable { let role: ChannelRole }
        let rows: [Row] = try await client
            .from("channel_members")
            .select("role")
            .eq("channel_id", value: channelId)
            .eq("user_id", value: userId)
            .limit(1)
            .execute()
            .value

        return rows.first?.role
    }
}

// MARK: - Errors

enum ChannelError: LocalizedError {
    case notAuthenticated
    case userNotFound

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "You must be signed in."
        case .userNotFound:     return "User not found."
        }
    }
}
