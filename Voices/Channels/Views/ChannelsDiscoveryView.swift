import SwiftUI

// MARK: - Filter Mode

enum ChannelFilter: Hashable {
    case myChannels
    case all
    case category(String)

    var label: String {
        switch self {
        case .myChannels:       return "My Channels"
        case .all:              return "All"
        case .category(let c):  return c
        }
    }
}

// MARK: - Main View

struct ChannelsDiscoveryView: View {
    @StateObject private var vm = ChannelsDiscoveryViewModel()
    @ObservedObject private var player = AudioPlayerService.shared
    @State private var showCreate = false
    @State private var isNowPlayingPresented = false

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // Search bar
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search channels", text: $vm.searchText)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await vm.load() } }
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
                .padding(.vertical, 8)

                // Filter pills — My Channels first, then All, then categories
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterPill(label: "My Channels",
                                   isSelected: vm.activeFilter == .myChannels) {
                            vm.activeFilter = .myChannels
                            Task { await vm.load() }
                        }

                        FilterPill(label: "All",
                                   isSelected: vm.activeFilter == .all) {
                            vm.activeFilter = .all
                            Task { await vm.load() }
                        }

                        ForEach(ChannelCategory.allCases) { cat in
                            FilterPill(
                                label: cat.rawValue,
                                isSelected: vm.activeFilter == .category(cat.rawValue)
                            ) {
                                vm.activeFilter = .category(cat.rawValue)
                                Task { await vm.load() }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollBounceBehavior(.basedOnSize)
                .padding(.bottom, 8)

                Divider()

                // Grid content
                if vm.isLoading && vm.channels.isEmpty {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if vm.channels.isEmpty {
                    Spacer()
                    ChannelEmptyState(
                        title: vm.activeFilter == .myChannels ? "No channels yet" : "No channels found",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: vm.activeFilter == .myChannels
                            ? "Create a channel or follow one to see it here."
                            : "Try a different search or category."
                    )
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(vm.channels) { channel in
                                NavigationLink(value: channel) {
                                    ChannelTileView(channel: channel)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                    }
                    .refreshable { await vm.load() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if player.currentClip != nil {
                    MiniPlayerBar(isExpanded: $isNowPlayingPresented)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle("Channels")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(destination: ChannelInvitesInboxView()) {
                        Image(systemName: "envelope")
                            .overlay(alignment: .topTrailing) {
                                if vm.hasPendingInvites {
                                    Circle()
                                        .fill(.red)
                                        .frame(width: 8, height: 8)
                                        .offset(x: 4, y: -4)
                                }
                            }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationDestination(for: Channel.self) { channel in
                ChannelFeedView(channel: channel)
            }
            .sheet(isPresented: $showCreate) {
                CreateChannelView { newChannel in
                    // New channel — user is admin, insert at top
                    var ch = newChannel
                    ch.currentUserRole = .admin
                    vm.channels.insert(ch, at: 0)
                    vm.activeFilter = .myChannels
                }
            }
            .task { await vm.load() }
            .onAppear { Task { await vm.checkPendingInvites() } }
            .alert("Error", isPresented: $vm.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(vm.errorMessage)
            }
            .sheet(isPresented: $isNowPlayingPresented) {
                NowPlayingView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

// MARK: - Channel Tile (square grid card)

struct ChannelTileView: View {
    let channel: Channel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                // Avatar image or gradient + initials placeholder
                Group {
                    if let url = channel.avatarURL, let parsed = URL(string: url) {
                        AsyncImage(url: parsed) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().scaledToFill()
                            default:
                                gradientPlaceholder
                            }
                        }
                    } else {
                        gradientPlaceholder
                    }
                }
                .frame(width: geo.size.width, height: geo.size.width)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .aspectRatio(1, contentMode: .fit)  // force square

            // Name + metadata, below the tile
            Text(channel.name)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(2)

            HStack(spacing: 6) {
                Label(channel.followerCount.abbreviated, systemImage: "person.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let role = channel.currentUserRole, role != .follower {
                    Text(role.rawValue.capitalized)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(AppTheme.gold.opacity(0.15), in: Capsule())
                        .foregroundStyle(AppTheme.gold)
                }

                if !channel.isPublic {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var gradientPlaceholder: some View {
        ZStack {
            ChannelAvatarView.gradient(for: channel.name)
            let initials = ChannelAvatarView.initials(for: channel.name)
            Text(initials.isEmpty ? "?" : initials)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

// MARK: - View Model

@MainActor
class ChannelsDiscoveryViewModel: ObservableObject {
    @Published var channels: [Channel] = []
    @Published var searchText = ""
    @Published var activeFilter: ChannelFilter = .myChannels
    @Published var isLoading = false
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var hasPendingInvites = false

    /// Silent — a failed badge check shouldn't surface an error alert.
    func checkPendingInvites() async {
        hasPendingInvites = !((try? await ChannelService.shared.fetchMyInvites())?.isEmpty ?? true)
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            switch activeFilter {
            case .myChannels:
                let all = try await ChannelService.shared.fetchMyChannels()
                channels = all.sorted { lhs, rhs in
                    roleOrder(lhs.currentUserRole) < roleOrder(rhs.currentUserRole)
                }
            case .all:
                channels = try await ChannelService.shared.fetchPublicChannels(
                    search: searchText.isEmpty ? nil : searchText
                )
            case .category(let cat):
                channels = try await ChannelService.shared.fetchPublicChannels(
                    category: cat,
                    search: searchText.isEmpty ? nil : searchText
                )
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// Lower number = shown first
    private func roleOrder(_ role: ChannelRole?) -> Int {
        switch role {
        case .admin:      return 0
        case .moderator:  return 1
        case .creator:    return 2
        case .member:     return 3
        case .follower:   return 4
        case nil:         return 5
        }
    }
}

// MARK: - Filter Pill

struct FilterPill: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? AppTheme.gold : Color(.systemGray5),
                            in: Capsule())
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ChannelRowView (kept for any list reuse elsewhere)

struct ChannelRowView: View {
    let channel: Channel

    var body: some View {
        HStack(spacing: 12) {
            ChannelAvatarView(name: channel.name, size: 50, avatarURL: channel.avatarURL)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(channel.name).font(.headline)
                    if !channel.isPublic {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let desc = channel.description, !desc.isEmpty {
                    Text(desc).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 10) {
                    Label(channel.followerCount.abbreviated, systemImage: "person.2")
                    Label(channel.clipCount.abbreviated, systemImage: "waveform")
                }
                .font(.caption).foregroundStyle(.tertiary)
            }

            Spacer()

            if let role = channel.currentUserRole {
                Text(role.rawValue.capitalized)
                    .font(.caption2).fontWeight(.semibold)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(AppTheme.gold.opacity(0.15), in: Capsule())
                    .foregroundStyle(AppTheme.gold)
            }
        }
    }
}

extension Int {
    var abbreviated: String {
        switch self {
        case 1_000_000...: return String(format: "%.1fM", Double(self) / 1_000_000)
        case 1_000...:     return String(format: "%.1fK", Double(self) / 1_000)
        default:           return "\(self)"
        }
    }
}

// MARK: - Empty State

/// iOS 16-compatible stand-in for ContentUnavailableView (deployment target is 16.6).
struct ChannelEmptyState: View {
    let title: String
    let systemImage: String
    var description: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3.bold())
            if let description {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
    }
}
