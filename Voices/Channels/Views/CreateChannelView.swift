import SwiftUI
import PhotosUI

struct CreateChannelView: View {
    @Environment(\.dismiss) private var dismiss
    let onCreated: (Channel) -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var isPublic = true
    @State private var category: ChannelCategory = .other
    @State private var requiresApproval = false
    @State private var maxMembersEnabled = false
    @State private var maxMembers = 50
    @State private var isLoading = false
    @State private var error: String?

    private var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                // Channel identity
                Section("Channel Info") {
                    TextField("Channel name", text: $name)
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }

                // Category
                Section("Category") {
                    Picker("Category", selection: $category) {
                        ForEach(ChannelCategory.allCases) { cat in
                            Text("\(cat.emoji) \(cat.rawValue)").tag(cat)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                // Visibility
                Section {
                    Toggle(isOn: $isPublic) {
                        Label("Public channel", systemImage: isPublic ? "globe" : "lock.fill")
                    }
                    if isPublic {
                        Toggle("Require approval to join", isOn: $requiresApproval)
                    }
                } header: {
                    Text("Visibility")
                } footer: {
                    Text(isPublic
                        ? "Anyone can discover and follow this channel."
                        : "Only invited members can see and join this channel.")
                }

                // Membership cap
                Section {
                    Toggle("Limit members", isOn: $maxMembersEnabled)
                    if maxMembersEnabled {
                        Stepper("Max members: \(maxMembers)", value: $maxMembers, in: 2...10_000, step: 10)
                    }
                } header: {
                    Text("Members")
                }

                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("New Channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await create() }
                    }
                    .disabled(!isValid || isLoading)
                    .overlay {
                        if isLoading { ProgressView().scaleEffect(0.7) }
                    }
                }
            }
        }
    }

    private func create() async {
        isLoading = true
        error = nil
        do {
            let channel = try await ChannelService.shared.createChannel(
                name: name.trimmingCharacters(in: .whitespaces),
                description: description.isEmpty ? nil : description,
                isPublic: isPublic,
                category: category.rawValue,
                requiresApproval: requiresApproval,
                maxMembers: maxMembersEnabled ? maxMembers : nil
            )
            onCreated(channel)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
