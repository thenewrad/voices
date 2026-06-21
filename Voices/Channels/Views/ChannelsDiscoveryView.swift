import SwiftUI

struct ChannelsDiscoveryView: View {
    @StateObject private var vm = ChannelsDiscoveryViewModel()
    @State private var showCreate = false

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

                // Category pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        CategoryPill(label: "All", isSelected: vm.selectedCategory == nil) {
                            vm.selectedCategory = nil
                            Task { await vm.load() }
                        }
                        ForEach(ChannelCategory.allCases) { cat in
                            CategoryPill(
                                label: cat.rawValue,
                                isSelected: vm.selectedCategory == cat.rawValue
                            ) {
                                vm.selectedCategory = cat.rawValue
                                Task { await vm.load() }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollBounceBehavior(.basedOnSize)
                .padding(.bottom, 8)

                Divider()

                if vm.isLoading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if vm.channels.isEmpty {
                    Spacer()
                    ChannelEmptyState(title: "No channels yet", systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                } else {
                    List(vm.channels) { channel in
                        NavigationLink(value: channel) {
                            ChannelRowView(channel: channel)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                    .listStyle(.plain)
                    .refreshable { await vm.load() }
                }
            }
            .navigationTitle("Channels")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(destination: MyChannelsView()) {
                        Image(systemName: "person.2")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(destination: ChannelInvitesInboxView()) {
                        Image(systemName: "envelope")
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
                    vm.channels.insert(newChannel, at: 0)
                }
            }
            .task { await vm.load() }
            .alert("Error", isPresented: $vm.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(vm.errorMessage)
            }
        }
    }
}

// MARK: - View Model

@MainActor
class ChannelsDiscoveryViewModel: ObservableObject {
    @Published var channels: [Channel] = []
    @Published var searchText = ""
    @Published var selectedCategory: String?
    @Published var isLoading = false
    @Published var showError = false
    @Published var errorMessage = ""

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            channels = try await ChannelService.shared.fetchPublicChannels(
                category: selectedCategory,
                search: searchText.isEmpty ? nil : searchText
            )
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Supporting Views

struct CategoryPill: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? AppTheme.gold : Color(.systemGray5),
                            in: Capsule())
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

struct ChannelRowView: View {
    let channel: Channel

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            Group {
                if let url = channel.avatarURL, let parsed = URL(string: url) {
                    AsyncImage(url: parsed) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        channelPlaceholder
                    }
                } else {
                    channelPlaceholder
                }
            }
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(channel.name)
                        .font(.headline)
                    if !channel.isPublic {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let desc = channel.description, !desc.isEmpty {
                    Text(desc)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    Label("\(channel.followerCount.abbreviated)", systemImage: "person.2")
                    Label("\(channel.clipCount.abbreviated)", systemImage: "waveform")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            if let role = channel.currentUserRole {
                Text(role.rawValue.capitalized)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppTheme.gold.opacity(0.15), in: Capsule())
                    .foregroundStyle(AppTheme.gold)
            }
        }
    }

    private var channelPlaceholder: some View {
        ZStack {
            Color(.systemGray4)
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
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

extension Int {
    var abbreviated: String {
        switch self {
        case 1_000_000...: return String(format: "%.1fM", Double(self) / 1_000_000)
        case 1_000...:     return String(format: "%.1fK", Double(self) / 1_000)
        default:           return "\(self)"
        }
    }
}
