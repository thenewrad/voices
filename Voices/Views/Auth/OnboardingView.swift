import SwiftUI
import AuthenticationServices
import CryptoKit

struct OnboardingView: View {
    @EnvironmentObject private var authService: AuthService
    @State private var showEmailSignIn = false
    @State private var currentNonce = ""
    @State private var error: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.purple, AppTheme.skyBlue],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo
                VStack(spacing: 14) {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 8)

                    Text("ZeitVox")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("ZeitVox is audio social media so put your airpods in. Listen to voices from the world around you based on your location. Record and share. This is a place for organic humans to interact.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                // Auth actions
                VStack(spacing: 12) {
                    if let error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    SignInWithAppleButton(.signIn) { request in
                        let nonce = Self.makeNonce()
                        currentNonce = nonce
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = Self.sha256(nonce)
                    } onCompletion: { result in
                        handleAppleResult(result)
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 52)
                    .cornerRadius(14)
                    .padding(.horizontal, 24)

                    Button {
                        showEmailSignIn = true
                    } label: {
                        Text("Continue with Email")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(.white.opacity(0.18))
                            .cornerRadius(14)
                    }
                    .padding(.horizontal, 24)

                    Text("By continuing you agree to our Terms & Privacy Policy")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 4)
                }
                .padding(.bottom, 52)
            }
        }
        .sheet(isPresented: $showEmailSignIn) {
            EmailSignInView()
                .environmentObject(authService)
        }
    }

    // MARK: - Apple Sign In

    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8)
            else {
                error = "Apple Sign In failed — could not read credentials."
                return
            }
            let nonce = currentNonce
            Task { @MainActor in
                do {
                    try await authService.signInWithApple(idToken: idToken, nonce: nonce)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        case .failure(let err):
            if (err as? ASAuthorizationError)?.code != .canceled {
                error = err.localizedDescription
            }
        }
    }

    // MARK: - Nonce helpers

    private static func makeNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var buf = [UInt8](repeating: 0, count: 16)
            _ = SecRandomCopyBytes(kSecRandomDefault, buf.count, &buf)
            buf.forEach { byte in
                guard remaining > 0, byte < charset.count else { return }
                result.append(charset[Int(byte)])
                remaining -= 1
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - Email sign in / sign up

struct EmailSignInView: View {
    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)

                    SecureField("Password", text: $password)
                        .textContentType(isSignUp ? .newPassword : .password)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                }
                .padding(.horizontal, 24)

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Button {
                    Task { await submit() }
                } label: {
                    Group {
                        if isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Text(isSignUp ? "Create Account" : "Sign In")
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

                Button {
                    isSignUp.toggle()
                    error = nil
                } label: {
                    Text(isSignUp
                         ? "Already have an account? Sign In"
                         : "Don't have an account? Sign Up")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.purple)
                }

                Spacer()
            }
            .padding(.top, 32)
            .navigationTitle(isSignUp ? "Create Account" : "Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var canSubmit: Bool {
        !isLoading && !email.isEmpty && password.count >= 6
    }

    private func submit() async {
        isLoading = true
        error = nil
        do {
            if isSignUp {
                try await authService.signUp(email: email, password: password)
            } else {
                try await authService.signIn(email: email, password: password)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

#Preview {
    OnboardingView()
        .environmentObject(AuthService())
}
