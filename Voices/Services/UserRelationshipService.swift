import Foundation

@MainActor
final class UserRelationshipService: ObservableObject {
    static let shared = UserRelationshipService()
    private init() {}

    struct RelationshipUser: Identifiable, Equatable {
        let id: UUID
        let username: String
    }

    @Published var hiddenUserIDs: Set<UUID> = []
    @Published var blockedUserIDs: Set<UUID> = []
    @Published var hiddenUsers: [RelationshipUser] = []
    @Published var blockedUsers: [RelationshipUser] = []

    func fetchRelationships() async {
        guard let uid = try? await SupabaseService.shared.client.auth.session.user.id else { return }

        // Two-step fetch avoids FK join ambiguity through auth.users
        struct HiddenRow: Decodable { let hidden_user_id: UUID }
        if let rows: [HiddenRow] = try? await SupabaseService.shared.client
            .from("hidden_users")
            .select("hidden_user_id")
            .eq("user_id", value: uid.uuidString)
            .execute()
            .value {
            hiddenUserIDs = Set(rows.map { $0.hidden_user_id })
            hiddenUsers = await resolveUsernames(for: rows.map { $0.hidden_user_id })
        }

        struct BlockedRow: Decodable { let blocked_user_id: UUID }
        if let rows: [BlockedRow] = try? await SupabaseService.shared.client
            .from("blocked_users")
            .select("blocked_user_id")
            .eq("user_id", value: uid.uuidString)
            .execute()
            .value {
            blockedUserIDs = Set(rows.map { $0.blocked_user_id })
            blockedUsers = await resolveUsernames(for: rows.map { $0.blocked_user_id })
        }
    }

    private func resolveUsernames(for ids: [UUID]) async -> [RelationshipUser] {
        guard !ids.isEmpty else { return [] }
        struct ProfileRow: Decodable { let id: UUID; let username: String? }
        guard let profiles: [ProfileRow] = try? await SupabaseService.shared.client
            .from("profiles")
            .select("id, username")
            .in("id", values: ids.map { $0.uuidString })
            .execute()
            .value else { return [] }
        let map = Dictionary(uniqueKeysWithValues: profiles.compactMap { row -> (UUID, String)? in
            guard let name = row.username else { return nil }
            return (row.id, name)
        })
        return ids.compactMap { id in
            guard let name = map[id] else { return nil }
            return RelationshipUser(id: id, username: name)
        }
    }

    func blockUser(userId: UUID, username: String) async throws {
        guard let uid = try? await SupabaseService.shared.client.auth.session.user.id else { return }
        struct Insert: Encodable { let user_id: UUID; let blocked_user_id: UUID }
        try await SupabaseService.shared.client
            .from("blocked_users")
            .upsert(Insert(user_id: uid, blocked_user_id: userId), onConflict: "user_id,blocked_user_id")
            .execute()
        blockedUserIDs.insert(userId)
        if !blockedUsers.contains(where: { $0.id == userId }) {
            blockedUsers.append(RelationshipUser(id: userId, username: username))
        }
        try await hideUser(userId: userId, username: username)
    }

    func hideUser(userId: UUID, username: String) async throws {
        guard let uid = try? await SupabaseService.shared.client.auth.session.user.id else { return }
        struct Insert: Encodable { let user_id: UUID; let hidden_user_id: UUID }
        try await SupabaseService.shared.client
            .from("hidden_users")
            .upsert(Insert(user_id: uid, hidden_user_id: userId), onConflict: "user_id,hidden_user_id")
            .execute()
        hiddenUserIDs.insert(userId)
        if !hiddenUsers.contains(where: { $0.id == userId }) {
            hiddenUsers.append(RelationshipUser(id: userId, username: username))
        }
    }

    func unblockUser(userId: UUID) async throws {
        guard let uid = try? await SupabaseService.shared.client.auth.session.user.id else { return }
        try await SupabaseService.shared.client
            .from("blocked_users")
            .delete()
            .eq("user_id", value: uid.uuidString)
            .eq("blocked_user_id", value: userId.uuidString)
            .execute()
        blockedUserIDs.remove(userId)
        blockedUsers.removeAll { $0.id == userId }
    }

    func unhideUser(userId: UUID) async throws {
        guard let uid = try? await SupabaseService.shared.client.auth.session.user.id else { return }
        try await SupabaseService.shared.client
            .from("hidden_users")
            .delete()
            .eq("user_id", value: uid.uuidString)
            .eq("hidden_user_id", value: userId.uuidString)
            .execute()
        hiddenUserIDs.remove(userId)
        hiddenUsers.removeAll { $0.id == userId }
    }
}
