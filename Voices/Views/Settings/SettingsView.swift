import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var authService: AuthService
    @ObservedObject private var relationships = UserRelationshipService.shared
    @AppStorage("includeLocationByDefault") private var includeLocationByDefault = true
    @Environment(\.dismiss) private var dismiss
    @State private var showSignOutConfirm = false
    @State private var showImagePicker = false
    @State private var isUploadingAvatar = false
    @State private var avatarUploadError: String? = nil

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if case .authenticated(let profile) = authService.appState {
                        // Photo row
                        HStack {
                            Text("Profile Photo")
                            Spacer()
                            Button {
                                showImagePicker = true
                            } label: {
                                AvatarView(
                                    initials: String(profile.username.prefix(1)).uppercased(),
                                    username: profile.username,
                                    size: 44,
                                    avatarURL: profile.avatar_url
                                )
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "pencil.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(AppTheme.gold)
                                        .background(Circle().fill(AppTheme.canvasBlack).padding(1))
                                }
                            }
                            .buttonStyle(.plain)
                            if isUploadingAvatar {
                                ProgressView().padding(.leading, 6)
                            }
                        }

                        if let err = avatarUploadError {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        NavigationLink {
                            EditUsernameView()
                                .environmentObject(authService)
                        } label: {
                            HStack {
                                Text("Username")
                                Spacer()
                                Text("@\(profile.username)")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        NavigationLink {
                            EditProfileView()
                                .environmentObject(authService)
                        } label: {
                            HStack {
                                Text("Bio")
                                Spacer()
                                Text(profile.bio.flatMap { $0.isEmpty ? nil : $0 } ?? "Add a bio")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                    }
                } header: {
                    Text("Profile")
                }

                Section {
                    Toggle(isOn: $includeLocationByDefault) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Include location on posts")
                            Text("Adds your post to the discovery map by default")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(AppTheme.gold)
                } header: {
                    Text("Privacy")
                }

                Section {
                    NavigationLink {
                        BeepTonePickerView()
                            .environmentObject(authService)
                    } label: {
                        HStack {
                            Text("Beep Tone")
                            Spacer()
                            Text(BeepTone.stored.displayName)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Personalization")
                }

                Section {
                    NavigationLink {
                        BlockedUsersView()
                    } label: {
                        HStack {
                            Text("Blocked Users")
                            Spacer()
                            Text("\(relationships.blockedUsers.count)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    NavigationLink {
                        HiddenUsersView()
                    } label: {
                        HStack {
                            Text("Hidden Users")
                            Spacer()
                            Text("\(relationships.hiddenUsers.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Blocked & Hidden")
                }

                Section {
                    Button("Sign Out", role: .destructive) {
                        showSignOutConfirm = true
                    }
                } header: {
                    Text("Account")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.canvasBlack.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.canvasBlack, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(AppTheme.gold)
                }
            }
            .confirmationDialog("Sign out of Voices?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    Task { await authService.signOut() }
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showImagePicker) {
                ImagePickerView { image in
                    Task { await uploadAvatar(image) }
                }
            }
        }
    }

    private func uploadAvatar(_ image: UIImage) async {
        isUploadingAvatar = true
        avatarUploadError = nil
        defer { isUploadingAvatar = false }
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else { return }
        do {
            try await authService.uploadAvatar(jpeg)
        } catch {
            print("SettingsView: avatar upload error — \(error)")
            avatarUploadError = "Upload failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Edit Username

private struct EditUsernameView: View {
    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var newUsername = ""
    @State private var isSaving = false
    @State private var saveError: String? = nil
    @State private var availability: AvailStatus = .idle
    @State private var checkTask: Task<Void, Never>? = nil
    @State private var daysRemaining: Int? = nil

    enum AvailStatus { case idle, checking, available, taken }

    private var currentUsername: String {
        guard case .authenticated(let p) = authService.appState else { return "" }
        return p.username
    }

    private var canSave: Bool {
        !isSaving &&
        !newUsername.isEmpty &&
        newUsername != currentUsername &&
        availability == .available &&
        daysRemaining == nil
    }

    var body: some View {
        List {
            if let days = daysRemaining {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "clock")
                            .foregroundStyle(AppTheme.gold)
                        Text("You can change your username again in \(days) day\(days == 1 ? "" : "s").")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                HStack {
                    TextField("new username", text: $newUsername)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: newUsername) { newValue in
                            let filtered = newValue.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
                            if filtered != newValue { newUsername = filtered; return }
                            scheduleCheck(filtered)
                        }
                    availabilityIcon
                }
            } header: {
                Text("New Username")
            } footer: {
                Text("Can only be changed once every 30 days.")
            }

            if let error = saveError {
                Section {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.canvasBlack.ignoresSafeArea())
        .navigationTitle("Change Username")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.canvasBlack, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView().tint(AppTheme.gold) }
                    else { Text("Save").fontWeight(.semibold) }
                }
                .foregroundStyle(AppTheme.gold)
                .disabled(!canSave)
            }
        }
        .task { await loadCooldown() }
    }

    @ViewBuilder
    private var availabilityIcon: some View {
        switch availability {
        case .idle:      EmptyView()
        case .checking:  ProgressView().scaleEffect(0.75)
        case .available: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .taken:     Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func scheduleCheck(_ username: String) {
        availability = .idle
        guard !username.isEmpty, username != currentUsername else { return }
        checkTask?.cancel()
        availability = .checking
        checkTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            do {
                availability = try await authService.checkUsernameAvailable(username) ? .available : .taken
            } catch {
                availability = .idle
            }
        }
    }

    private func loadCooldown() async {
        guard let uid = try? await SupabaseService.shared.client.auth.session.user.id else { return }
        struct Row: Decodable { let username_changed_at: String? }
        guard let rows: [Row] = try? await SupabaseService.shared.client
            .from("profiles")
            .select("username_changed_at")
            .eq("id", value: uid.uuidString)
            .limit(1)
            .execute()
            .value,
              let dateStr = rows.first?.username_changed_at else { return }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let changedAt = fmt.date(from: dateStr) else { return }
        let days = Calendar.current.dateComponents([.day], from: changedAt, to: Date()).day ?? 31
        if days < 30 { daysRemaining = 30 - days }
    }

    private func save() async {
        isSaving = true
        saveError = nil
        do {
            try await authService.updateUsername(to: newUsername)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
        isSaving = false
    }
}

// MARK: - Edit Profile

private struct EditProfileView: View {
    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var bio = ""
    @State private var isSaving = false
    @State private var saveError: String? = nil

    private let limit = 150

    private var currentBio: String {
        guard case .authenticated(let profile) = authService.appState else { return "" }
        return profile.bio ?? ""
    }

    private var hasChanges: Bool { bio != currentBio }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $bio)
                        .frame(minHeight: 88)
                        .onChange(of: bio) { newValue in
                            if newValue.count > limit {
                                bio = String(newValue.prefix(limit))
                            }
                        }
                    HStack {
                        Spacer()
                        Text("\(bio.count) / \(limit)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(bio.count >= limit ? AppTheme.rust : .secondary)
                    }
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            } header: {
                Text("Bio")
            } footer: {
                Text("150 characters max. Shown on your profile.")
            }

            if let error = saveError {
                Section {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.canvasBlack.ignoresSafeArea())
        .navigationTitle("Edit Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.canvasBlack, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView().tint(AppTheme.gold)
                    } else {
                        Text("Save").fontWeight(.semibold)
                    }
                }
                .foregroundStyle(AppTheme.gold)
                .disabled(!hasChanges || isSaving)
            }
        }
        .onAppear { bio = currentBio }
    }

    private func save() async {
        guard !bioContainsLink(bio) else {
            saveError = "Bio cannot contain links."
            return
        }
        isSaving = true
        saveError = nil
        do {
            try await authService.updateProfile(bio: bio)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
        isSaving = false
    }
}

// MARK: - Blocked Users

private struct BlockedUsersView: View {
    @ObservedObject private var relationships = UserRelationshipService.shared

    var body: some View {
        List {
            if relationships.blockedUsers.isEmpty {
                Section {
                    Text("No blocked users.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            } else {
                Section {
                    ForEach(relationships.blockedUsers) { user in
                        HStack(spacing: 12) {
                            AvatarView(
                                initials: String(user.username.prefix(1)).uppercased(),
                                username: user.username,
                                size: 36
                            )
                            Text("@\(user.username)")
                                .font(.subheadline)
                            Spacer()
                            Button("Unblock") {
                                Task { try? await relationships.unblockUser(userId: user.id) }
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AppTheme.gold)
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(AppTheme.cardDark)
                    }
                } footer: {
                    Text("Blocked users cannot like or reply to your posts.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.canvasBlack.ignoresSafeArea())
        .navigationTitle("Blocked Users")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.canvasBlack, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

// MARK: - Hidden Users

private struct HiddenUsersView: View {
    @ObservedObject private var relationships = UserRelationshipService.shared

    var body: some View {
        List {
            if relationships.hiddenUsers.isEmpty {
                Section {
                    Text("No hidden users.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            } else {
                Section {
                    ForEach(relationships.hiddenUsers) { user in
                        HStack(spacing: 12) {
                            AvatarView(
                                initials: String(user.username.prefix(1)).uppercased(),
                                username: user.username,
                                size: 36
                            )
                            Text("@\(user.username)")
                                .font(.subheadline)
                            Spacer()
                            Button("Unhide") {
                                Task { try? await relationships.unhideUser(userId: user.id) }
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AppTheme.gold)
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(AppTheme.cardDark)
                    }
                } footer: {
                    Text("Hidden users will not appear in your feed.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.canvasBlack.ignoresSafeArea())
        .navigationTitle("Hidden Users")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.canvasBlack, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

// MARK: - Beep Tone Picker

private struct BeepTonePickerView: View {
    @EnvironmentObject private var authService: AuthService
    @AppStorage("beepTone") private var selectedRaw: String = BeepTone.standard.rawValue
    @State private var previewingTone: BeepTone? = nil

    private var selected: BeepTone { BeepTone(rawValue: selectedRaw) ?? .standard }

    var body: some View {
        List {
            Section {
                ForEach(BeepTone.allCases) { tone in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(tone.displayName)
                                    .font(.subheadline)
                                if tone.isDefault {
                                    Text("Default")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(AppTheme.gold)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(AppTheme.gold.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                            }
                        }

                        Spacer()

                        Button {
                            Task { await BeepToneService.shared.play(tone) }
                        } label: {
                            Image(systemName: previewingTone == tone ? "speaker.wave.2.fill" : "speaker.wave.2")
                                .font(.system(size: 15))
                                .foregroundStyle(AppTheme.gold)
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain)

                        if selected == tone {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(AppTheme.gold)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedRaw = tone.rawValue
                        Task { try? await authService.updateBeepTone(tone) }
                    }
                    .listRowBackground(AppTheme.cardDark)
                }
            } footer: {
                Text("Other users will hear this tone when they play your posts.")
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.canvasBlack.ignoresSafeArea())
        .navigationTitle("Beep Tone")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.canvasBlack, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

// MARK: - Image Picker

struct ImagePickerView: UIViewControllerRepresentable {
    var onImagePicked: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.allowsEditing = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePickerView
        init(_ parent: ImagePickerView) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = info[.editedImage] as? UIImage ?? info[.originalImage] as? UIImage
            parent.dismiss()
            if let image { parent.onImagePicked(image) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Shared helpers

private func bioContainsLink(_ text: String) -> Bool {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return false }
    return detector.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
}
