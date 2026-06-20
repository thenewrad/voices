import SwiftUI

struct ProfileSetupView: View {
    @EnvironmentObject private var authService: AuthService

    @State private var username = ""
    @State private var bio = ""
    @State private var isLoading = false
    @State private var error: String?
    @State private var availability: SetupAvailStatus = .idle
    @State private var checkTask: Task<Void, Never>? = nil
    @State private var selectedImage: UIImage? = nil
    @State private var showImagePicker = false

    enum SetupAvailStatus { case idle, checking, available, taken }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    Button { showImagePicker = true } label: {
                        ZStack {
                            if let selectedImage {
                                Image(uiImage: selectedImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 84, height: 84)
                                    .clipShape(Circle())
                            } else {
                                AvatarView(
                                    initials: username.isEmpty ? "?" : String(username.prefix(1)).uppercased(),
                                    username: username.isEmpty ? "_" : username,
                                    size: 84
                                )
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "camera.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(AppTheme.gold)
                                .background(Circle().fill(AppTheme.canvasBlack).padding(2))
                        }
                    }
                    .buttonStyle(.plain)

                    VStack(spacing: 4) {
                        Text("Set Up Your Profile")
                            .font(.title2.bold())
                        Text("Choose a username to get started")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Tap the avatar to add a profile photo (optional)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 32)
                .sheet(isPresented: $showImagePicker) {
                    ImagePickerView { image in
                        selectedImage = image
                    }
                }

                // Fields
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Username")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                        HStack {
                            TextField("username", text: $username)
                                .textContentType(.username)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .onChange(of: username) { newValue in
                                    let filtered = newValue.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
                                    if filtered != newValue { username = filtered; return }
                                    scheduleAvailabilityCheck(filtered)
                                }
                            switch availability {
                            case .idle:      EmptyView()
                            case .checking:  ProgressView().scaleEffect(0.75)
                            case .available: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            case .taken:     Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            }
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                        .padding(.horizontal, 24)

                        if availability == .taken {
                            Text("That username is already taken.")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 24)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Bio")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                        TextField("Tell people about yourself…", text: $bio, axis: .vertical)
                            .lineLimit(3...5)
                            .padding()
                            .background(Color(.systemGray6))
                            .cornerRadius(12)
                            .padding(.horizontal, 24)
                    }
                }

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Spacer()

                Button {
                    Task { await submit() }
                } label: {
                    Group {
                        if isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Text("Get Started")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(canSubmit ? AnyShapeStyle(AppTheme.gradient) : AnyShapeStyle(Color.secondary.opacity(0.3)))
                    .foregroundStyle(.white)
                    .cornerRadius(14)
                }
                .disabled(!canSubmit)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var canSubmit: Bool {
        !isLoading &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        availability != .taken &&
        availability != .checking
    }

    private func scheduleAvailabilityCheck(_ username: String) {
        availability = .idle
        guard !username.isEmpty else { return }
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

    private func submit() async {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if bioContainsLink(bio) {
            error = "Bio cannot contain links."
            return
        }
        isLoading = true
        error = nil
        do {
            try await authService.createProfile(username: trimmed, bio: bio)
            if let selectedImage, let jpeg = selectedImage.jpegData(compressionQuality: 0.8) {
                try? await authService.uploadAvatar(jpeg)
            }
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }
}

private func bioContainsLink(_ text: String) -> Bool {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return false }
    return detector.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
}

#Preview {
    ProfileSetupView()
        .environmentObject(AuthService())
}
