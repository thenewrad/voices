import SwiftUI

struct SharePostSheet: View {
    let clip: Clip
    @Environment(\.dismiss) private var dismiss

    @State private var following: [FollowUser] = []
    @State private var selected: Set<UUID> = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var isSending = false
    @State private var error: String?

    private struct FollowUser: Identifiable {
        let id: UUID
        let username: String
        let avatarURL: String?
    }

    private var filtered: [FollowUser] {
        guard !searchText.isEmpty else { return following }
        return following.filter { $0.username.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if following.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "person.2")
                            .font(.system(size: 44))
                            .foregroundStyle(.tertiary)
                        Text("Follow people to share posts with them.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered) { user in
                        let isSelected = selected.contains(user.id)
                        Button {
                            if isSelected { selected.remove(user.id) }
                            else { selected.insert(user.id) }
                        } label: {
                            userRow(user: user, isSelected: isSelected)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(isSelected ? AppTheme.cardDark : AppTheme.canvasBlack)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .searchable(text: $searchText, prompt: "Search people")
                }
            }
            .background(AppTheme.canvasBlack.ignoresSafeArea())
            .navigationTitle("Share Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.canvasBlack, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button(selected.count > 1 ? "Send (\(selected.count))" : "Send") {
                            Task { await send() }
                        }
                        .fontWeight(.semibold)
                        .foregroundStyle(selected.isEmpty ? Color.secondary : AppTheme.gold)
                        .disabled(selected.isEmpty)
                    }
                }
            }
            .alert("Couldn't send", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .task { await loadFollowing() }
        }
    }

    // MARK: - Row

    private func userRow(user: FollowUser, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            AvatarView(
                initials: String(user.username.prefix(1)).uppercased(),
                username: user.username,
                size: 40,
                avatarURL: user.avatarURL
            )
            Text("@\(user.username)")
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.gold)
                    .font(.system(size: 22))
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Data

    private func loadFollowing() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let currentId = try await SupabaseService.shared.client.auth.session.user.id

            struct FollowRow: Decodable { let following_id: UUID }
            let followRows: [FollowRow] = try await SupabaseService.shared.client
                .from("follows")
                .select("following_id")
                .eq("follower_id", value: currentId.uuidString)
                .execute()
                .value

            guard !followRows.isEmpty else { return }

            struct ProfileRow: Decodable { let id: UUID; let username: String?; let avatar_url: String? }
            let profileRows: [ProfileRow] = try await SupabaseService.shared.client
                .from("profiles")
                .select("id, username, avatar_url")
                .in("id", values: followRows.map { $0.following_id.uuidString })
                .execute()
                .value

            following = profileRows
                .compactMap { row in
                    guard let username = row.username else { return nil }
                    return FollowUser(id: row.id, username: username, avatarURL: row.avatar_url)
                }
                .sorted { $0.username.lowercased() < $1.username.lowercased() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func send() async {
        guard !selected.isEmpty else { return }
        isSending = true
        do {
            let senderId = try await SupabaseService.shared.client.auth.session.user.id

            struct ShareInsert: Encodable {
                let sender_id: UUID
                let recipient_id: UUID
                let audio_url: String
                let duration_seconds: Int
                let clip_id: UUID
            }

            let rows = selected.map { recipientId in
                ShareInsert(
                    sender_id: senderId,
                    recipient_id: recipientId,
                    audio_url: clip.audio_url,
                    duration_seconds: clip.duration_seconds,
                    clip_id: clip.id
                )
            }

            try await SupabaseService.shared.client
                .from("direct_messages")
                .insert(rows)
                .execute()

            dismiss()
        } catch {
            isSending = false
            self.error = error.localizedDescription
        }
    }
}
