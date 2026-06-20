import SwiftUI

struct SearchView: View {
    @StateObject private var vm = SearchViewModel()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @State private var currentUserId: UUID? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                Divider().overlay(Color(hex: "3A2820"))

                Group {
                    if vm.isLoading {
                        ProgressView()
                            .tint(AppTheme.gold)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if !vm.hasSearched {
                        emptyPrompt
                    } else if vm.results.isEmpty {
                        noResults
                    } else {
                        resultsList
                    }
                }
            }
            .background(AppTheme.canvasBlack.ignoresSafeArea())
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.canvasBlack, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(AppTheme.gold)
                }
            }
            .task {
                searchFocused = true
                currentUserId = try? await SupabaseService.shared.client.auth.session.user.id
            }
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 15))

            TextField("Search users…", text: $vm.searchText)
                .focused($searchFocused)
                .foregroundColor(.primary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)

            if !vm.searchText.isEmpty {
                Button {
                    vm.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 15))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(hex: "2A1E18"))
        .cornerRadius(12)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Results

    private var resultsList: some View {
        List(vm.results) { user in
            FollowUserRow(user: user, currentUserId: currentUserId) {
                Task { await vm.toggleFollow(userId: user.id) }
            }
            .listRowBackground(AppTheme.cardDark)
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            .listRowSeparatorTint(Color(hex: "3A2820"))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppTheme.canvasBlack)
    }

    // MARK: - Empty states

    private var emptyPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44))
                .foregroundColor(Color(UIColor.tertiaryLabel))
            Text("Search for users")
                .font(.title3.bold())
            Text("Find people on Voices by username.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResults: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.slash")
                .font(.system(size: 44))
                .foregroundColor(Color(UIColor.tertiaryLabel))
            Text("No results found")
                .font(.title3.bold())
            Text("No users match \"\(vm.searchText)\".")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
