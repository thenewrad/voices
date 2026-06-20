import SwiftUI

/// Channels the current user is a member of (any role).
struct MyChannelsView: View {
    @StateObject private var vm = MyChannelsViewModel()

    var body: some View {
        Group {
            if vm.isLoading {
                ProgressView()
            } else if vm.channels.isEmpty {
                ChannelEmptyState(
                    title: "No channels yet",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: "Channels you create or join will show up here."
                )
            } else {
                List(vm.channels) { channel in
                    NavigationLink(value: channel) {
                        ChannelRowView(channel: channel)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("My Channels")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
        .refreshable { await vm.load() }
        .alert("Error", isPresented: $vm.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorMessage)
        }
    }
}

@MainActor
class MyChannelsViewModel: ObservableObject {
    @Published var channels: [Channel] = []
    @Published var isLoading = false
    @Published var showError = false
    @Published var errorMessage = ""

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            channels = try await ChannelService.shared.fetchMyChannels()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
