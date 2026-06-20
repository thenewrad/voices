import SwiftUI

struct ChannelFeedView: View {
    let channel: Channel

    @StateObject private var vm: ChannelFeedViewModel
    @State private var showSettings = false
    @State private var showInvite = false
    @State private var showPostClip = false

    init(channel: Channel) {
        self.channel = channel
        _vm = StateObject(wrappedValue: ChannelFeedViewModel(channel: channel))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Header
                channelHeader

                Divider()

                // Feed
                if vm.isLoading && vm.clips.isEmpty {
                    ProgressView()
                        .padding(.top, 40)
                } else if vm.clips.isEmpty {
                    ChannelEmptyState(
                        title: "No clips yet",
                        systemImage: "waveform",
                        description: vm.canPost ? "Post the first clip to this channel." : "Members haven't posted yet."
                    )
                    .padding(.top, 40)
                } else {
                    ForEach(vm.clips) { channelClip in
                        ChannelClipRow(channelClip: channelClip, userRole: vm.userRole) {
                            Task { await vm.removeClip(channelClip) }
                        }
                        Divider()
                    }
                }
            }
        }
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if vm.userRole?.canPost == true {
                    Button {
                        showPostClip = true
                    } label: {
                        Image(systemName: "waveform.badge.plus")
                    }
                }
                if vm.userRole?.canChangeSettings == true {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
        }
        .task { await vm.load() }
        .refreshable { await vm.load() }
        .sheet(isPresented: $showSettings) {
            ChannelSettingsView(channel: channel)
        }
        .sheet(isPresented: $showInvite) {
            ChannelInviteView(channelId: channel.id)
        }
        .sheet(isPresented: $showPostClip) {
            PostClipToChannelView(channelId: channel.id) {
                Task { await vm.load() }
            }
        }
        .alert("Error", isPresented: $vm.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorMessage)
        }
    }

    private var channelHeader: some View {
        VStack(spacing: 12) {
            // Avatar
            Group {
                if let url = channel.avatarURL, let parsed = URL(string: url) {
                    AsyncImage(url: parsed) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        placeholderAvatar
                    }
                } else {
                    placeholderAvatar
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Text(channel.name)
                .font(.title2)
                .fontWeight(.bold)

            if let desc = channel.description, !desc.isEmpty {
                Text(desc)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            HStack(spacing: 20) {
                statView(value: channel.followerCount.abbreviated, label: "followers")
                statView(value: channel.clipCount.abbreviated, label: "clips")
                if let cat = channel.category {
                    statView(value: cat, label: "category")
                }
            }

            // Follow / Leave
            followButton

            if vm.userRole?.canManageMembers == true {
                Button {
                    showInvite = true
                } label: {
                    Label("Invite Members", systemImage: "person.badge.plus")
                        .font(.subheadline)
                }
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var followButton: some View {
        if vm.userRole == nil {
            // Not a member
            Button {
                Task { await vm.follow() }
            } label: {
                Text("Follow")
                    .fontWeight(.semibold)
                    .frame(width: 120)
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.isActionLoading)
        } else if vm.userRole == .follower {
            Button(role: .destructive) {
                Task { await vm.unfollow() }
            } label: {
                Text("Unfollow")
                    .frame(width: 120)
            }
            .buttonStyle(.bordered)
            .disabled(vm.isActionLoading)
        }
        // admins/mods/creators don't see follow button
    }

    private var placeholderAvatar: some View {
        ZStack {
            Color(.systemGray4)
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title)
                .foregroundStyle(.secondary)
        }
    }

    private func statView(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - ChannelClipRow

struct ChannelClipRow: View {
    let channelClip: ChannelClip
    let userRole: ChannelRole?
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Poster avatar placeholder
            Circle()
                .fill(Color(.systemGray4))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(channelClip.poster?.username ?? "Unknown")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Text(channelClip.postedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if let clip = channelClip.clip {
                    // Title
                    if !clip.title.isEmpty {
                        Text(clip.title)
                            .font(.subheadline)
                    }

                    // Audio player stub — wire up to your existing AudioPlayerView
                    AudioPlayerStub(durationSeconds: clip.durationSeconds, audioURL: clip.audioURL)

                    HStack(spacing: 16) {
                        Label(clip.playCount.abbreviated, systemImage: "play.fill")
                        Label(clip.likeCount.abbreviated, systemImage: "heart")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            // Remove button for admin/mod
            if userRole?.canRemoveClips == true {
                Menu {
                    Button("Remove from channel", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Stub — replace with your real AudioPlayerView
struct AudioPlayerStub: View {
    let durationSeconds: Int
    let audioURL: String

    var body: some View {
        HStack(spacing: 8) {
            Button {
                // play action
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(AppTheme.gold)
            }
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(.systemGray4))
                .frame(height: 4)
            Text(durationSeconds.formattedDuration)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

extension Int {
    var formattedDuration: String {
        let m = self / 60
        let s = self % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - ViewModel

@MainActor
class ChannelFeedViewModel: ObservableObject {
    @Published var clips: [ChannelClip] = []
    @Published var userRole: ChannelRole?
    @Published var isLoading = false
    @Published var isActionLoading = false
    @Published var showError = false
    @Published var errorMessage = ""

    let channel: Channel

    var canPost: Bool { userRole?.canPost ?? false }

    init(channel: Channel) {
        self.channel = channel
        self.userRole = channel.currentUserRole
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let clipsTask = ChannelService.shared.fetchChannelFeed(channelId: channel.id)
            async let roleTask  = ChannelService.shared.currentUserRole(channelId: channel.id)
            let (fetched, role) = try await (clipsTask, roleTask)
            clips    = fetched
            userRole = role
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func follow() async {
        isActionLoading = true
        defer { isActionLoading = false }
        do {
            try await ChannelService.shared.joinChannel(id: channel.id)
            userRole = .follower
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func unfollow() async {
        isActionLoading = true
        defer { isActionLoading = false }
        do {
            try await ChannelService.shared.leaveChannel(id: channel.id)
            userRole = nil
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func removeClip(_ channelClip: ChannelClip) async {
        do {
            try await ChannelService.shared.removeClipFromChannel(channelClipId: channelClip.id)
            clips.removeAll { $0.id == channelClip.id }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
