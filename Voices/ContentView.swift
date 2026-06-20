import SwiftUI

extension Notification.Name {
    static let feedScrollToTop = Notification.Name("feedScrollToTop")
    static let followingScrollToTop = Notification.Name("followingScrollToTop")
    static let profileScrollToTop = Notification.Name("profileScrollToTop")
    static let clipPosted = Notification.Name("clipPosted")
}

struct ContentView: View {
    @State private var selectedTab = 0

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
    }
}

#Preview {
    ContentView()
}
