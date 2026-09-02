import SwiftUI

extension Notification.Name {
    static let feedScrollToTop = Notification.Name("feedScrollToTop")
    static let followingScrollToTop = Notification.Name("followingScrollToTop")
    static let profileScrollToTop = Notification.Name("profileScrollToTop")
    static let clipPosted = Notification.Name("clipPosted")
}

struct ContentView: View {
    @State private var selectedTab = 0
    @State private var hasDraft = false
    @State private var showDraftResume = false

    init() {
        let bg = UIColor(AppTheme.canvasBlack)
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = bg
        UITabBar.appearance().standardAppearance   = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance

        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = bg
        navAppearance.titleTextAttributes       = [.foregroundColor: UIColor.white]
        navAppearance.largeTitleTextAttributes  = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance   = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance    = navAppearance

        UITableView.appearance().separatorInset  = .zero
        UITableView.appearance().layoutMargins   = .zero
    }

    var body: some View {
        TabView(selection: Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == selectedTab {
                    if newValue == 0 {
                        NotificationCenter.default.post(name: .feedScrollToTop, object: nil)
                    } else if newValue == 1 {
                        NotificationCenter.default.post(name: .followingScrollToTop, object: nil)
                    } else if newValue == 4 {
                        NotificationCenter.default.post(name: .profileScrollToTop, object: nil)
                    }
                }
                selectedTab = newValue
            }
        )) {
            FeedView()
                .tabItem { Label("Feed", systemImage: "waveform") }
                .tag(0)

            FollowingFeedView()
                .tabItem { Label("Following", systemImage: "person.2.fill") }
                .tag(1)

            if #available(iOS 17.0, *) {
                LocalView()
                    .tabItem { Label("Map", systemImage: "location.fill") }
                    .tag(2)
            }

            ChannelsDiscoveryView()
                .tabItem { Label("Channels", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(3)

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(4)
        }
        .tint(AppTheme.gold)
        .preferredColorScheme(.dark)
        .overlay(alignment: .bottom) {
            if hasDraft {
                draftBanner
                    .padding(.bottom, 56) // sit just above the tab bar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasDraft)
        .onAppear {
            hasDraft = ClipDraftStore.shared.hasDraft
        }
        .sheet(isPresented: $showDraftResume, onDismiss: {
            hasDraft = ClipDraftStore.shared.hasDraft
        }) {
            if #available(iOS 17.0, *), let draft = ClipDraftStore.shared.load() {
                RecordView(draft: draft)
            }
        }
    }

    private var draftBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppTheme.gold)

            VStack(alignment: .leading, spacing: 2) {
                Text("Unsaved recording")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Text("Your last post didn't go through.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Resume") {
                showDraftResume = true
            }
            .font(.subheadline.bold())
            .foregroundStyle(AppTheme.gold)

            Button {
                ClipDraftStore.shared.clear()
                hasDraft = false
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppTheme.cardDark)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(AppTheme.gold.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }
}

#Preview {
    ContentView()
}
