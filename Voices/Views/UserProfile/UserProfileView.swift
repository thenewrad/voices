import SwiftUI

struct UserProfileView: View {
    @StateObject private var vm: UserProfileViewModel
    @EnvironmentObject private var authService: AuthService
    @ObservedObject private var player = AudioPlayerService.shared
    @ObservedObject private var relationships = UserRelationshipService.shared
    @State private var isNowPlayingPresented = false
    @State private var showFollowers = false
    @State private var showFollowing = false
    @State private var showProfileActions = false
    @State private var showDMSheet = false

    init(userId: UUID, username: String) {
        _vm = StateObject(wrappedValue: UserProfileViewModel(userId: userId, username: username))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let profile = vm.profile {
                    profileHeader(profile)
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                        .padding(.bottom, 24)

                    Divider()

                    if vm.isLoading && vm.clips.isEmpty {
                        ProgressView().padding(.top, 60)
                    } else if vm.clips.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "waveform")
                                .font(.system(size: 38))
                                .foregroundStyle(.tertiary)
                            Text("No clips yet")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 64)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(vm.clips) { clip in
                                ClipRow(clip: clip, allClips: vm.clips)
                                Divider().padding(.leading, 72)
                            }
                        }
                    }
                } else if vm.isLoading {
                    ProgressView().padding(.top, 60)
                }
            }
        }
        .navigationTitle("@\(vm.username)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showProfileActions = true } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog("", isPresented: $showProfileActions) {
            Button("Send Message") { showDMSheet = true }
            Button("Hide @\(vm.username)") {
                Task { try? await relationships.hideUser(userId: vm.userId, username: vm.username) }
            }
            Button("Block @\(vm.username)", role: .destructive) {
                Task { try? await relationships.blockUser(userId: vm.userId, username: vm.username) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showDMSheet) {
            DirectMessageRecordingView(
                recipientId: vm.userId,
                recipientUsername: vm.username
            ) { showDMSheet = false }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .task { await vm.load() }
        .refreshable { await vm.load() }
        .safeAreaInset(edge: .bottom) {
            if player.currentClip != nil {
                MiniPlayerBar(isExpanded: $isNowPlayingPresented)
            }
        }
        .sheet(isPresented: $isNowPlayingPresented) {
            NowPlayingView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func profileHeader(_ profile: UserProfile) -> some View {
        VStack(spacing: 16) {
            AvatarView(
                initials: String(profile.username.prefix(1)).uppercased(),
                username: profile.username,
                size: 84,
                avatarURL: profile.avatar_url
            )

            VStack(spacing: 6) {
                Text("@\(profile.username)")
                    .font(.title3.bold())

                if let bio = profile.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .environment(\.openURL, OpenURLAction { _ in .discarded })
                }
            }

            // Stats — Followers and Following are tappable
            HStack(spacing: 0) {
                statCell(value: profile.clip_count, label: "Clips")
                Divider().frame(height: 32)
                Button { showFollowers = true } label: {
                    statCell(value: profile.follower_count, label: "Followers")
                }
                .buttonStyle(.plain)
                Divider().frame(height: 32)
                Button { showFollowing = true } label: {
                    statCell(value: profile.following_count, label: "Following")
                }
                .buttonStyle(.plain)
            }
            .background(Color(.systemGray6))
            .cornerRadius(14)
            .sheet(isPresented: $showFollowers) {
                FollowsListView(profileId: profile.id, mode: .followers, title: "Followers")
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showFollowing) {
                FollowsListView(profileId: profile.id, mode: .following, title: "Following")
                    .presentationDragIndicator(.visible)
            }

            followButton
        }
    }

    // MARK: - Follow button

    private var followButton: some View {
        Button {
            Task {
                await vm.toggleFollow()
                await authService.fetchProfile()
            }
        } label: {
            Text(vm.isFollowing ? "Following ✓" : "Follow")
                .fontWeight(.semibold)
                .foregroundStyle(vm.isFollowing ? Color.secondary : Color.white)
                .frame(width: 140, height: 38)
                .background {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(vm.isFollowing
                              ? AnyShapeStyle(Color(.systemBackground))
                              : AnyShapeStyle(AppTheme.gradient))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(vm.isFollowing ? Color.secondary : Color.clear, lineWidth: 1.5)
                }
                .animation(.easeInOut(duration: 0.15), value: vm.isFollowing)
        }
        .buttonStyle(.plain)
        .disabled(vm.isFollowLoading)
    }

    // MARK: - Stat cell

    private func statCell(value: Int, label: String) -> some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(.title3.bold())
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}
