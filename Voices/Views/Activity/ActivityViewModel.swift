import Foundation

enum ActivityItemType {
    case like
    case reply
    case replyToReply
    case follow
    case directMessage
}

enum ActivityFilter: CaseIterable {
    case likes, replies, messages

    var label: String {
        switch self {
        case .likes:    return "Likes"
        case .replies:  return "Replies"
        case .messages: return "Messages"
        }
    }

    func matches(_ type: ActivityItemType) -> Bool {
        switch self {
        case .likes:    return type == .like
        case .replies:  return type == .reply || type == .replyToReply
        case .messages: return type == .directMessage
        }
    }
}

struct ActivityItem: Identifiable {
    let id: UUID
    let type: ActivityItemType
    let actorUsername: String
    let actorUserId: UUID?     // set for .follow items — used to navigate to profile
    let clipTitle: String?
    let clipTranscript: String?
    let createdAt: Date
    let clip: Clip?
    let replyAudioUrl: String?
    let replyLikeCount: Int?
    let replyClipId: UUID?
    let dmMessageId: UUID?

    var contentLabel: String? {
        if let t = clipTitle, !t.isEmpty { return t }
        if let tr = clipTranscript, !tr.isEmpty {
            return tr.count > 30 ? String(tr.prefix(30)) + "..." : tr
        }
        return nil
    }

    var timeDisplay: String {
        let elapsed = Date().timeIntervalSince(createdAt)
        switch elapsed {
        case ..<60:      return "just now"
        case ..<3_600:   return "\(Int(elapsed / 60))m ago"
        case ..<86_400:  return "\(Int(elapsed / 3_600))h ago"
        default:
            let f = DateFormatter()
            f.dateStyle = .medium; f.timeStyle = .none
            return f.string(from: createdAt)
        }
    }

    var isUnread: Bool {
        createdAt > ActivityViewModel.lastRead
    }
}

@MainActor
final class ActivityViewModel: ObservableObject {
    @Published var items: [ActivityItem] = []
    @Published var isLoading = false
    @Published var unreadCount = 0

    private static let playedReplyStore = PersistedUUIDSet(key: "activity_played_reply_ids")
    private static let playedDMStore = PersistedUUIDSet(key: "activity_played_dm_ids")

    // Tracks which reply/DM audio the user has already played, so unplayed
    // rows can stay highlighted until listened to.
    @Published private(set) var playedReplyIDs: Set<UUID> = ActivityViewModel.playedReplyStore.load()
    @Published private(set) var playedDMIDs: Set<UUID> = ActivityViewModel.playedDMStore.load()

    private nonisolated static let lastReadKey = "activity_last_read_at"

    nonisolated static var lastRead: Date {
        (UserDefaults.standard.object(forKey: lastReadKey) as? Date) ?? .distantPast
    }

    func markReplyPlayed(_ id: UUID) {
        guard !playedReplyIDs.contains(id) else { return }
        playedReplyIDs.insert(id)
        Self.playedReplyStore.insert(id)
    }

    func markDMPlayed(_ id: UUID) {
        guard !playedDMIDs.contains(id) else { return }
        playedDMIDs.insert(id)
        Self.playedDMStore.insert(id)
    }

    // MARK: - Fetch

    func fetch(userId: UUID) async {
        isLoading = true
        defer { isLoading = false }

        struct ActivityProfile: Decodable { let username: String? }
        var all: [ActivityItem] = []

        // ── Step 1: resolve clip IDs ──────────────────────────────────────
        struct ClipIDRow: Decodable { let id: UUID }
        let clipIDs: [String]
        do {
            let rows: [ClipIDRow] = try await SupabaseService.shared.client
                .from("clips")
                .select("id")
                .eq("user_id", value: userId.uuidString)
                .execute()
                .value
            clipIDs = rows.map { $0.id.uuidString }
            print("ActivityViewModel: clipIDs = \(clipIDs)")
        } catch {
            print("ActivityViewModel: clip IDs fetch error — \(error)")
            clipIDs = []
        }

        // ── Step 2: likes (skipped if user has no clips) ──────────────────
        if clipIDs.isEmpty {
            print("ActivityViewModel: no clips, skipping likes/replies fetch")
        } else {
            struct LikeRow: Decodable {
                let created_at: Date
                let profiles: ActivityProfile?
                struct ClipInfo: Decodable {
                    let title: String?
                    let user_id: UUID
                }
                let clips: ClipInfo?
            }

            do {
                let response = try await SupabaseService.shared.client
                    .from("likes")
                    .select("created_at, profiles!likes_user_id_fkey(username), clips!likes_clip_id_fkey(title, user_id)")
                    .in("clip_id", values: clipIDs)
                    .execute()
                let decoder = JSONDecoder()
                let formatter = DateFormatter()
                formatter.calendar = Calendar(identifier: .iso8601)
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
                decoder.dateDecodingStrategy = .formatted(formatter)
                let likeRows = try decoder.decode([LikeRow].self, from: response.data)
                print("ActivityViewModel: decoded \(likeRows.count) like(s)")
                for like in likeRows {
                    guard let username = like.profiles?.username else { continue }
                    all.append(ActivityItem(
                        id: UUID(),
                        type: .like,
                        actorUsername: username,
                        actorUserId: nil,
                        clipTitle: like.clips?.title,
                        clipTranscript: nil,
                        createdAt: like.created_at,
                        clip: nil,
                        replyAudioUrl: nil,
                        replyLikeCount: nil,
                        replyClipId: nil,
                        dmMessageId: nil
                    ))
                }
            } catch let e as DecodingError {
                print("ActivityViewModel: likes DECODE error — \(e)")
            } catch {
                print("ActivityViewModel: likes NETWORK error — \(error)")
            }

            // ── Step 3: replies ───────────────────────────────────────────
            struct ReplyRow: Decodable {
                let id: UUID
                let clip_id: UUID
                let user_id: UUID
                let audio_url: String
                let like_count: Int
                let created_at: Date
                let profiles: ActivityProfile?
                struct ClipInfo: Decodable {
                    let id: UUID
                    let title: String?
                    let transcript: String?
                }
                let clips: ClipInfo?
            }

            do {
                let response = try await SupabaseService.shared.client
                    .from("replies")
                    .select("id, clip_id, user_id, audio_url, like_count, created_at, profiles!replies_user_id_fkey(username), clips!replies_clip_id_fkey(id, title, transcript)")
                    .in("clip_id", values: clipIDs)
                    .execute()
                let decoder = JSONDecoder()
                let formatter = DateFormatter()
                formatter.calendar = Calendar(identifier: .iso8601)
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
                decoder.dateDecodingStrategy = .formatted(formatter)
                let replyRows = try decoder.decode([ReplyRow].self, from: response.data)
                print("ActivityViewModel: decoded \(replyRows.count) reply(ies)")
                for reply in replyRows {
                    guard let username = reply.profiles?.username else { continue }
                    all.append(ActivityItem(
                        id: reply.id,
                        type: .reply,
                        actorUsername: username,
                        actorUserId: reply.user_id,
                        clipTitle: reply.clips?.title,
                        clipTranscript: reply.clips?.transcript,
                        createdAt: reply.created_at,
                        clip: nil,
                        replyAudioUrl: reply.audio_url,
                        replyLikeCount: reply.like_count,
                        replyClipId: reply.clip_id,
                        dmMessageId: nil
                    ))
                }
            } catch let e as DecodingError {
                print("ActivityViewModel: replies DECODE error — \(e)")
            } catch {
                print("ActivityViewModel: replies NETWORK error — \(error)")
            }
        }

        // ── Step 4: follows (always fetched, independent of clips) ────────
        struct FollowRow: Decodable {
            let follower_id: UUID
            let created_at: Date
            let profiles: ActivityProfile?
        }

        do {
            let response = try await SupabaseService.shared.client
                .from("follows")
                .select("follower_id, created_at, profiles!follows_follower_id_fkey(username)")
                .eq("following_id", value: userId.uuidString)
                .execute()
            let decoder = JSONDecoder()
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .iso8601)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
            decoder.dateDecodingStrategy = .formatted(formatter)
            let followRows = try decoder.decode([FollowRow].self, from: response.data)
            print("ActivityViewModel: decoded \(followRows.count) follow(s)")
            for follow in followRows {
                guard let username = follow.profiles?.username else { continue }
                all.append(ActivityItem(
                    id: follow.follower_id,
                    type: .follow,
                    actorUsername: username,
                    actorUserId: follow.follower_id,
                    clipTitle: nil,
                    clipTranscript: nil,
                    createdAt: follow.created_at,
                    clip: nil,
                    replyAudioUrl: nil,
                    replyLikeCount: nil,
                    replyClipId: nil,
                    dmMessageId: nil
                ))
            }
        } catch let e as DecodingError {
            print("ActivityViewModel: follows DECODE error — \(e)")
        } catch {
            print("ActivityViewModel: follows NETWORK error — \(error)")
        }

        // ── Step 5: replies directed at the current user's replies ────────
        struct ReplyToReplyRow: Decodable {
            let id: UUID
            let clip_id: UUID
            let audio_url: String
            let like_count: Int
            let created_at: Date
            let profiles: ActivityProfile?
            struct ClipInfo: Decodable { let title: String?; let transcript: String? }
            let clips: ClipInfo?
        }

        do {
            let response = try await SupabaseService.shared.client
                .from("replies")
                .select("id, clip_id, audio_url, like_count, created_at, profiles!replies_user_id_fkey(username), clips!replies_clip_id_fkey(title, transcript)")
                .eq("reply_to_user_id", value: userId.uuidString)
                .execute()
            let decoder = JSONDecoder()
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .iso8601)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
            decoder.dateDecodingStrategy = .formatted(formatter)
            let rows = try decoder.decode([ReplyToReplyRow].self, from: response.data)
            for row in rows {
                guard let username = row.profiles?.username else { continue }
                // Skip if this item is already in all (replied to own clip)
                guard !all.contains(where: { $0.id == row.id }) else { continue }
                all.append(ActivityItem(
                    id: row.id,
                    type: .replyToReply,
                    actorUsername: username,
                    actorUserId: nil,
                    clipTitle: row.clips?.title,
                    clipTranscript: row.clips?.transcript,
                    createdAt: row.created_at,
                    clip: nil,
                    replyAudioUrl: row.audio_url,
                    replyLikeCount: row.like_count,
                    replyClipId: row.clip_id,
                    dmMessageId: nil
                ))
            }
        } catch let e as DecodingError {
            print("ActivityViewModel: replyToReply DECODE error — \(e)")
        } catch {
            print("ActivityViewModel: replyToReply NETWORK error — \(error)")
        }

        // ── Step 6: direct messages received ─────────────────────────────
        struct DMRow: Decodable {
            let id: UUID
            let audio_url: String
            let created_at: Date
            let sender_id: UUID
        }
        do {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .iso8601)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .formatted(formatter)

            let response = try await SupabaseService.shared.client
                .from("direct_messages")
                .select("id, audio_url, created_at, sender_id")
                .eq("recipient_id", value: userId.uuidString)
                .order("created_at", ascending: false)
                .execute()
            let dmRows = try decoder.decode([DMRow].self, from: response.data)

            if !dmRows.isEmpty {
            // Look up sender usernames from profiles separately (avoids broken FK join)
            struct ProfileRow: Decodable { let id: UUID; let username: String }
            let senderIds = Array(Set(dmRows.map { $0.sender_id.uuidString }))
            let profileRows: [ProfileRow] = try await SupabaseService.shared.client
                .from("profiles")
                .select("id, username")
                .in("id", values: senderIds)
                .execute()
                .value
            let usernameByID = Dictionary(uniqueKeysWithValues: profileRows.map { ($0.id, $0.username) })

            for dm in dmRows {
                let username = usernameByID[dm.sender_id] ?? "unknown"
                all.append(ActivityItem(
                    id: dm.id,
                    type: .directMessage,
                    actorUsername: username,
                    actorUserId: dm.sender_id,
                    clipTitle: nil,
                    clipTranscript: nil,
                    createdAt: dm.created_at,
                    clip: nil,
                    replyAudioUrl: dm.audio_url,
                    replyLikeCount: nil,
                    replyClipId: nil,
                    dmMessageId: dm.id
                ))
            }
            } // end if !dmRows.isEmpty
        } catch {
            print("ActivityViewModel: DM fetch error — \(error)")
        }

        // ── Merge and publish ─────────────────────────────────────────────
        items = all.sorted { $0.createdAt > $1.createdAt }.prefix(100).map { $0 }
        unreadCount = items.filter(\.isUnread).count
        print("ActivityViewModel: \(items.count) total item(s), \(unreadCount) unread")
    }

    // MARK: - Mark read

    func markRead() {
        UserDefaults.standard.set(Date(), forKey: Self.lastReadKey)
        unreadCount = 0
    }
}
