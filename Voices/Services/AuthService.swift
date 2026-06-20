import Foundation
import Supabase

enum AppState {
    case loading
    case unauthenticated
    case needsProfile
    case authenticated(UserProfile)
}

@MainActor
final class AuthService: ObservableObject {
    @Published var appState: AppState = .loading

    // MARK: - Launch

    func checkSession() async {
        do {
            _ = try await SupabaseService.shared.client.auth.session
            await fetchProfile()
        } catch {
            appState = .unauthenticated
        }
    }

    // MARK: - Sign in

    func signIn(email: String, password: String) async throws {
        try await SupabaseService.shared.client.auth.signIn(email: email, password: password)
        await fetchProfile()
    }

    func signUp(email: String, password: String) async throws {
        try await SupabaseService.shared.client.auth.signUp(email: email, password: password)
        await fetchProfile()
    }

    func signInWithApple(idToken: String, nonce: String) async throws {
        try await SupabaseService.shared.client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
        )
        await fetchProfile()
    }

    // MARK: - Deep link callback

    func handle(url: URL) {
        Task {
            do {
                try await SupabaseService.shared.client.auth.session(from: url)
                await fetchProfile()
            } catch {
                // URL may not be an auth callback (e.g. a different deep link)
                print("AuthService.handle(url:) error: \(error)")
            }
        }
    }

    // MARK: - Sign out

    func signOut() async {
        try? await SupabaseService.shared.client.auth.signOut()
        appState = .unauthenticated
    }

    // MARK: - Profile

    func fetchProfile() async {
        do {
            let uid = try await SupabaseService.shared.client.auth.session.user.id
            let rows: [UserProfile] = try await SupabaseService.shared.client
                .from("profiles")
                .select("id, username, bio, avatar_url, beep_tone, follower_count, following_count, clip_count")
                .eq("id", value: uid.uuidString)
                .limit(1)
                .execute()
                .value
            appState = rows.first.map { .authenticated($0) } ?? .needsProfile
            if let tone = rows.first?.beep_tone {
                UserDefaults.standard.set(tone, forKey: "beepTone")
            }
            if rows.first != nil {
                await UserRelationshipService.shared.fetchRelationships()
            }
            // Re-save push token now that we have a confirmed session.
            // The APNs token callback fires early on launch before auth is ready,
            // so we retry here to ensure the token is always stored.
            if let tokenData = AppDelegate.lastDeviceToken {
                await PushNotificationService.shared.storeToken(tokenData)
            }
        } catch {
            appState = .unauthenticated
        }
    }

    func checkUsernameAvailable(_ username: String) async throws -> Bool {
        struct Row: Decodable { let id: UUID }
        var rows: [Row]
        if case .authenticated(let profile) = appState {
            rows = try await SupabaseService.shared.client
                .from("profiles")
                .select("id")
                .eq("username", value: username)
                .neq("id", value: profile.id.uuidString)
                .limit(1)
                .execute()
                .value
        } else {
            rows = try await SupabaseService.shared.client
                .from("profiles")
                .select("id")
                .eq("username", value: username)
                .limit(1)
                .execute()
                .value
        }
        return rows.isEmpty
    }

    func updateUsername(to newUsername: String) async throws {
        guard case .authenticated(let profile) = appState else { return }

        // Enforce 30-day cooldown
        struct ChangedRow: Decodable { let username_changed_at: String? }
        let rows: [ChangedRow] = try await SupabaseService.shared.client
            .from("profiles")
            .select("username_changed_at")
            .eq("id", value: profile.id.uuidString)
            .limit(1)
            .execute()
            .value
        if let dateStr = rows.first?.username_changed_at {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let changedAt = fmt.date(from: dateStr) {
                let days = Calendar.current.dateComponents([.day], from: changedAt, to: Date()).day ?? 31
                if days < 30 { throw UsernameError.cooldown(daysRemaining: 30 - days) }
            }
        }

        guard try await checkUsernameAvailable(newUsername) else {
            throw UsernameError.taken
        }

        struct ProfileUpdate: Encodable { let username: String; let username_changed_at: String }
        try await SupabaseService.shared.client
            .from("profiles")
            .update(ProfileUpdate(username: newUsername, username_changed_at: ISO8601DateFormatter().string(from: Date())))
            .eq("id", value: profile.id.uuidString)
            .execute()
        await fetchProfile()
    }

    func uploadAvatar(_ jpeg: Data) async throws {
        let uid = try await SupabaseService.shared.client.auth.session.user.id
        // storage RLS policies compare auth.uid()::text (lowercase) against the
        // first path segment, so the folder name must be lowercase too.
        let path = "\(uid.uuidString.lowercased())/avatar.jpg"
        let timestamp = Int(Date().timeIntervalSince1970)

        _ = try await SupabaseService.shared.client.storage
            .from("avatars")
            .upload(path, data: jpeg, options: FileOptions(contentType: "image/jpeg", upsert: true))

        let publicURL = try SupabaseService.shared.client.storage
            .from("avatars")
            .getPublicURL(path: path)
        let versionedURL = "\(publicURL.absoluteString)?v=\(timestamp)"

        struct AvatarUpdate: Encodable { let avatar_url: String }
        try await SupabaseService.shared.client
            .from("profiles")
            .update(AvatarUpdate(avatar_url: versionedURL))
            .eq("id", value: uid.uuidString)
            .execute()
        await fetchProfile()
    }

    func updateBeepTone(_ tone: BeepTone) async throws {
        guard case .authenticated(let profile) = appState else { return }
        struct ToneUpdate: Encodable { let beep_tone: String }
        try await SupabaseService.shared.client
            .from("profiles")
            .update(ToneUpdate(beep_tone: tone.rawValue))
            .eq("id", value: profile.id.uuidString)
            .execute()
        UserDefaults.standard.set(tone.rawValue, forKey: "beepTone")
    }

    func updateProfile(bio: String) async throws {
        guard case .authenticated(let profile) = appState else { return }
        let trimmed = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        struct ProfileUpdate: Encodable { let bio: String? }
        try await SupabaseService.shared.client
            .from("profiles")
            .update(ProfileUpdate(bio: trimmed.isEmpty ? nil : trimmed))
            .eq("id", value: profile.id.uuidString)
            .execute()
        await fetchProfile()
    }

    func createProfile(username: String, bio: String) async throws {

        let uid = try await SupabaseService.shared.client.auth.session.user.id
        struct ProfileInsert: Encodable {
            let id: UUID
            let username: String
            let bio: String?
        }
        try await SupabaseService.shared.client
            .from("profiles")
            .insert(ProfileInsert(id: uid, username: username, bio: bio.isEmpty ? nil : bio))
            .execute()
        await fetchProfile()
    }
}

enum UsernameError: LocalizedError {
    case taken
    case cooldown(daysRemaining: Int)
    var errorDescription: String? {
        switch self {
        case .taken:
            return "That username is already taken."
        case .cooldown(let days):
            return "You can change your username again in \(days) day\(days == 1 ? "" : "s")."
        }
    }
}
