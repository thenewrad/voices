import SwiftUI

/// Admin/Mod: invite a user by username
struct ChannelInviteView: View {
    @Environment(\.dismiss) private var dismiss

    let channelId: UUID

    /// Same live-lookup-as-you-type mechanism as the main Search tab.
    @StateObject private var search = SearchViewModel()
    @State private var isSending = false
    @State private var successMessage: String?
    @State private var error: String?

    private var trimmedUsername: String {
        search.searchText.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $search.searchText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    if search.isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else {
                        ForEach(search.results) { user in
                            Button {
                                search.searchText = user.username
                                search.results = []
                            } label: {
                                HStack(spacing: 10) {
                                    AvatarView(initials: user.initials, username: user.username, size: 32, avatarURL: user.avatar_url)
                                    Text(user.username)
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Invite by username")
                } footer: {
                    Text("They'll receive a notification to accept or decline.")
                }

                if let success = successMessage {
                    Section {
                        Label(success, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).font(.subheadline)
                    }
                }
            }
            .navigationTitle("Invite Member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { Task { await send() } }
                        .disabled(trimmedUsername.isEmpty || isSending)
                }
            }
        }
    }

    private func send() async {
        isSending = true
        error = nil
        successMessage = nil
        let trimmed = trimmedUsername
        do {
            try await ChannelService.shared.inviteMember(channelId: channelId, username: trimmed)
            successMessage = "Invite sent to @\(trimmed)"
            search.searchText = ""
            search.results = []
        } catch {
            self.error = error.localizedDescription
        }
        isSending = false
    }
}

// MARK: - Pending Invites (shown on the user's own profile/inbox)

struct ChannelInvitesInboxView: View {
    @State private var invites: [ChannelInvite] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var acceptedChannel: Channel?

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if invites.isEmpty {
                ChannelEmptyState(title: "No pending invites", systemImage: "envelope")
            } else {
                List(invites) { invite in
                    InviteRow(invite: invite) { accepted in
                        Task { await respond(invite: invite, accept: accepted) }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Channel Invites")
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $acceptedChannel) { channel in
            NavigationStack {
                ChannelFeedView(channel: channel)
            }
        }
        .alert("Error", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            invites = try await ChannelService.shared.fetchMyInvites()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func respond(invite: ChannelInvite, accept: Bool) async {
        do {
            try await ChannelService.shared.respondToInvite(id: invite.id, accept: accept)
            invites.removeAll { $0.id == invite.id }
            if accept {
                acceptedChannel = invite.channel
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct InviteRow: View {
    let invite: ChannelInvite
    let onRespond: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(AppTheme.gold)
                .frame(width: 44, height: 44)
                .background(AppTheme.gold.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(invite.channel?.name ?? "Unknown Channel")
                    .font(.headline)
                Text("You've been invited to join")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    onRespond(false)
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.red)
                        .frame(width: 36, height: 36)
                        .background(Color.red.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)

                Button {
                    onRespond(true)
                } label: {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                        .frame(width: 36, height: 36)
                        .background(Color.green.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}
