import SwiftUI

@main
struct VoicesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var authService = AuthService()
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some Scene {
        WindowGroup {
            rootView
                .environmentObject(authService)
                .task {
                    Self.purgeOrphanedAudioFiles()
                    await pingSupabase()
                    await authService.checkSession()
                }
                .onOpenURL { url in authService.handle(url: url) }
        }
    }

    // Remove any .m4a temp files left behind by crashes or failed uploads
    private static func purgeOrphanedAudioFiles() {
        let tmp = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "m4a" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // Keeps Supabase free tier from pausing due to inactivity
    private func pingSupabase() async {
        guard let url = URL(string: "https://vqibjqieliplqeldchky.supabase.co/auth/v1/health") else { return }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        try? await URLSession.shared.data(for: request)
    }

    @ViewBuilder
    private var rootView: some View {
        if case .loading = authService.appState {
            splashView
        } else if case .unauthenticated = authService.appState {
            if !hasSeenOnboarding {
                OnboardingSplashView(onDone: { hasSeenOnboarding = true })
            } else {
                OnboardingView()
            }
        } else if case .needsProfile = authService.appState {
            ProfileSetupView()
        } else {
            ContentView()
        }
    }

    private var splashView: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.purple, AppTheme.skyBlue],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white)
                ProgressView()
                    .tint(.white)
            }
        }
    }
}
