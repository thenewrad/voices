import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var authService: AuthService
    @StateObject private var vm = ProfileViewModel()
    @ObservedObject private var player = AudioPlayerService.shared
    @State private var showSettings = false
    @State private var showFollowers = false
    @State private var showFollowing = false
    @State private var isNowPlayingPresented = false

    var body: some View {
        NavigationStack {
            Group {
                if case .authenticated(let profile) = authService.appState {
                    profileContent(profile)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.canvasBlack, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(authService)
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Profile content

    @ViewBuilder
    private func profileContent(_ profile: UserProfile) -> some View {
        ScrollViewReader { proxy in
        ScrollView {
            Color.clear.frame(height: 0).id("profileTop")

            LazyVStack(spacing: 0) {
                // Header
                profileHeader(profile)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 16)

                Divider().overlay(Color(hex: "3A2820"))

                // Clips
                if vm.isLoading && vm.clips.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 56)
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
                    .padding(.top, 56)
                } else {
                    ForEach(vm.clips) { clip in
                        ClipRow(clip: clip, allClips: vm.clips, onDelete: {
                            Task { await vm.deleteClip(id: clip.id, audioUrl: clip.audio_url) }
                        })
                        .background(AppTheme.canvasBlack)
                        Divider()
                            .overlay(Color(hex: "3A2820"))
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .profileScrollToTop)) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo("profileTop", anchor: .top)
            }
        }
        .background(AppTheme.canvasBlack)
        .safeAreaInset(edge: .bottom) {
            if player.currentClip != nil {
                MiniPlayerBar(isExpanded: $isNowPlayingPresented)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $isNowPlayingPresented) {
            NowPlayingView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .task {
            vm.refreshProfile = { await authService.fetchProfile() }
            await vm.fetchClips(userId: profile.id)
            await vm.listenForUpdates(userId: profile.id)
        }
        .refreshable {
            vm.refreshProfile = { await authService.fetchProfile() }
            await vm.fetchClips(userId: profile.id)
        }
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

            // Stats row — Followers and Following are tappable
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
            .background(AppTheme.canvasBlack)
            .cornerRadius(14)
            .sheet(isPresented: $showFollowers) {
                FollowsListView(profileId: profile.id, mode: .followers, title: "Followers")
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showFollowing) {
                FollowsListView(profileId: profile.id, mode: .following, title: "Following")
                    .presentationDragIndicator(.visible)
            }
        }
    }

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

#Preview {
    ProfileView()
        .environmentObject(AuthService())
}
