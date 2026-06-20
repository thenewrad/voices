import SwiftUI

struct FollowsListView: View {
    @StateObject private var vm: FollowsViewModel
    let title: String
    @State private var currentUserId: UUID? = nil

    init(profileId: UUID, mode: FollowsMode, title: String) {
        _vm = StateObject(wrappedValue: FollowsViewModel(profileId: profileId, mode: mode))
        self.title = title
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.users.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.filtered.isEmpty {
                    emptyState
                } else {
                    userList
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $vm.searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search"
            )
            .task {
                await vm.load()
                currentUserId = try? await SupabaseService.shared.client.auth.session.user.id
            }
        }
    }

    // MARK: - List

    private var userList: some View {
        List(vm.filtered) { user in
            FollowUserRow(user: user, currentUserId: currentUserId) {
                Task { await vm.toggleFollow(userId: user.id) }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            .listRowSeparatorTint(Color.secondary.opacity(0.2))
        }
        .listStyle(.plain)
        .animation(.default, value: vm.filtered.map(\.id))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(vm.searchText.isEmpty ? "Nobody here yet" : "No results for \"\(vm.searchText)\"")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }
}

// MARK: - Row

struct FollowUserRow: View {
    let user: FollowUser
    let currentUserId: UUID?
    let onToggle: () -> Void

    private var isSelf: Bool { user.id == currentUserId }

    var body: some View {
        HStack(spacing: 10) {
            // ZStack with hidden NavigationLink + visible content
            // suppresses the List disclosure chevron that .buttonStyle(.plain)
            // alone cannot remove when a NavigationLink is inside a List row.
            ZStack(alignment: .leading) {
                NavigationLink(destination: UserProfileView(userId: user.id, username: user.username)) {
                    EmptyView()
                }
                .opacity(0)

                HStack(spacing: 10) {
                    AvatarView(initials: user.initials, username: user.username, size: 44, avatarURL: user.avatar_url)
                    Text("@\(user.username)")
                        .font(.subheadline.bold())
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isSelf {
                Text("You")
                    .font(.subheadline.bold())
                    .foregroundColor(AppTheme.gold)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(minWidth: 92)
            } else {
                followButton
            }
        }
    }

    private var followButton: some View {
        Button(action: onToggle) {
            Group {
                if user.isLoadingFollow {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(user.isFollowing ? Color.secondary : Color.white)
                } else {
                    Text(user.isFollowing ? "Following ✓" : "Follow")
                        .fontWeight(.semibold)
                        .font(.subheadline)
                        .foregroundColor(user.isFollowing ? Color.secondary : Color.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minWidth: 92)
            .background {
                RoundedRectangle(cornerRadius: 15)
                    .fill(user.isFollowing
                          ? AnyShapeStyle(Color(.systemBackground))
                          : AnyShapeStyle(AppTheme.gradient))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 15)
                    .stroke(user.isFollowing ? Color.secondary : Color.clear, lineWidth: 1.5)
            }
            .animation(.easeInOut(duration: 0.15), value: user.isFollowing)
        }
        .buttonStyle(.plain)
        .disabled(user.isLoadingFollow)
    }
}
