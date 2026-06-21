import SwiftUI

struct ChannelSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    let channel: Channel

    @State private var name: String
    @State private var description: String
    @State private var isPublic: Bool
    @State private var requiresApproval: Bool
    @State private var isMonetized: Bool
    @State private var avatarURL: String?
    @State private var members: [ChannelMember] = []
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var isUploadingIcon = false
    @State private var showImagePicker = false
    @State private var showDeleteConfirm = false
    @State private var error: String?

    init(channel: Channel) {
        self.channel = channel
        _name             = State(initialValue: channel.name)
        _description      = State(initialValue: channel.description ?? "")
        _isPublic         = State(initialValue: channel.isPublic)
        _requiresApproval = State(initialValue: channel.requiresApproval)
        _isMonetized      = State(initialValue: channel.isMonetized)
        _avatarURL        = State(initialValue: channel.avatarURL)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 10) {
                            ChannelAvatarView(name: name, size: 88, avatarURL: avatarURL)
                                .overlay {
                                    if isUploadingIcon {
                                        RoundedRectangle(cornerRadius: 88 * 0.22)
                                            .fill(.black.opacity(0.4))
                                        ProgressView().tint(.white)
                                    }
                                }
                            Button(avatarURL == nil ? "Upload Icon" : "Change Icon") {
                                showImagePicker = true
                            }
                            .font(.subheadline)
                            .disabled(isUploadingIcon)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }

                Section("Info") {
                    TextField("Channel name", text: $name)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section {
                    Toggle(isOn: $isPublic) {
                        Label("Public", systemImage: isPublic ? "globe" : "lock.fill")
                    }
                    if isPublic {
                        Toggle("Require approval to join", isOn: $requiresApproval)
                        Toggle("Monetization enabled", isOn: $isMonetized)
                    }
                } header: {
                    Text("Visibility & Monetization")
                }

                // Members list
                Section("Members (\(members.count))") {
                    if isLoading {
                        ProgressView()
                    } else {
                        ForEach(members) { member in
                            MemberRow(member: member) { newRole in
                                Task { await updateRole(member: member, role: newRole) }
                            } onRemove: {
                                Task { await removeMember(member) }
                            }
                        }
                    }
                }

                // Danger zone
                Section {
                    Button("Archive Channel", role: .destructive) {
                        Task { await archiveChannel() }
                    }
                    Button("Delete Channel", role: .destructive) {
                        showDeleteConfirm = true
                    }
                } header: {
                    Text("Danger Zone")
                }

                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).font(.subheadline)
                    }
                }
            }
            .navigationTitle("Channel Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog(
                "Delete \"\(channel.name)\"?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { Task { await deleteChannel() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This is permanent and cannot be undone.")
            }
            .task { await loadMembers() }
            .sheet(isPresented: $showImagePicker) {
                ImagePickerView { image in
                    Task { await uploadIcon(image) }
                }
            }
        }
    }

    private func loadMembers() async {
        isLoading = true
        defer { isLoading = false }
        do {
            members = try await ChannelService.shared.fetchMembers(channelId: channel.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func uploadIcon(_ image: UIImage) async {
        isUploadingIcon = true
        defer { isUploadingIcon = false }
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else { return }
        do {
            avatarURL = try await ChannelService.shared.uploadChannelIcon(channelId: channel.id, jpeg: jpeg)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        var updated = channel
        updated.name             = name.trimmingCharacters(in: .whitespaces)
        updated.description      = description.isEmpty ? nil : description
        updated.isPublic         = isPublic
        updated.requiresApproval = requiresApproval
        updated.isMonetized      = isMonetized
        do {
            try await ChannelService.shared.updateChannel(updated)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func updateRole(member: ChannelMember, role: ChannelRole) async {
        do {
            try await ChannelService.shared.updateMemberRole(
                channelId: channel.id,
                userId: member.userId,
                role: role
            )
            if let idx = members.firstIndex(where: { $0.id == member.id }) {
                members[idx].role = role
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func removeMember(_ member: ChannelMember) async {
        do {
            try await ChannelService.shared.removeMember(channelId: channel.id, userId: member.userId)
            members.removeAll { $0.id == member.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func archiveChannel() async {
        do {
            try await ChannelService.shared.archiveChannel(id: channel.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteChannel() async {
        do {
            try await ChannelService.shared.deleteChannel(id: channel.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - MemberRow

struct MemberRow: View {
    let member: ChannelMember
    let onRoleChange: (ChannelRole) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Circle()
                .fill(Color(.systemGray4))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: "person.fill").foregroundStyle(.secondary)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(member.profile?.username ?? "Unknown")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(member.role.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Section("Change Role") {
                    ForEach(ChannelRole.allCases.filter { $0 != .admin }, id: \.self) { role in
                        Button(role.rawValue.capitalized) {
                            onRoleChange(role)
                        }
                    }
                }
                Divider()
                Button("Remove", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
