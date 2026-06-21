import SwiftUI

struct ChannelFeedView: View {
    let channel: Channel

    @StateObject private var vm: ChannelFeedViewModel
    @EnvironmentObject private var authService: AuthService
    @State private var showSettings = false
    @State private var showInvite = false
    @State private var showRecord = false

    init(channel: Channel) {
        self.channel = channel
        _vm = StateObject(wrappedValue: ChannelFeedViewModel(channel: channel))
    }

    private var currentUserId: UUID? {
        if case .authenticated(let profile) = authService.appState { return profile.id }
        return nil
    }

    private func canRemove(_ channelClip: ChannelClip) -> Bool {
        vm.userRole?.canRemoveClips == true || channelClip.postedBy == currentUserId
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
                    let allClips = vm.clips.compactMap(\.clip)
                    ForEach(vm.clips) { channelClip in
                        if let clip = channelClip.clip {
                            ClipRow(clip: clip, allClips: allClips)
                                .background(AppTheme.canvasBlack)
                                .overlay(alignment: .topTrailing) {
                                    if canRemove(channelClip) {
                                        Menu {
                                            Button("Remove from channel", role: .destructive) {
                                                Task { await vm.removeClip(channelClip) }
                                            }
                                        } label: {
                                            Image(systemName: "ellipsis.circle.fill")
                                                .foregroundStyle(.secondary)
                                                .padding(10)
                                        }
                                    }
                                }
                            Divider().overlay(Color(hex: "3A2820"))
                        }
                    }
                }
            }
        }
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if vm.userRole != nil, #available(iOS 17.0, *) {
                    Button {
                        showRecord = true
                    } label: {
                        Image(systemName: "mic.circle.fill")
                            .foregroundStyle(.red)
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
        .fullScreenCover(isPresented: $showRecord, onDismiss: { Task { await vm.load() } }) {
            if #available(iOS 17.0, *) {
                RecordView(channelId: channel.id, channelName: channel.name)
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

    var canPost: Bool { userRole != nil }

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
