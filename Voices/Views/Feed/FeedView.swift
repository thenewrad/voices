import SwiftUI

struct FeedView: View {
    @EnvironmentObject private var authService: AuthService
    @StateObject private var feedVM = FeedViewModel()
    @StateObject private var activityVM = ActivityViewModel()
    @ObservedObject private var player = AudioPlayerService.shared
    @ObservedObject private var pushService = PushNotificationService.shared
    @State private var isNowPlayingPresented = false
    @State private var showActivity = false
    @State private var activityInitialFilter: ActivityFilter = .likes
    @State private var showSearch = false
    @State private var showRecord = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                feedHeader

                ZStack {
                    AppTheme.canvasBlack.ignoresSafeArea()

                    clipList

                    if feedVM.isLoading && feedVM.clips.isEmpty {
                        ProgressView()
                    } else if !feedVM.isLoading && feedVM.clips.isEmpty {
                        emptyState
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(AppTheme.canvasBlack.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.canvasBlack, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showSearch = true }) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.15))
                                .frame(width: 36, height: 36)
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.white)
                                .font(.system(size: 15))
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .sheet(isPresented: $showSearch) { SearchView() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showActivity = true
                        activityVM.markRead()
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.15))
                                .frame(width: 36, height: 36)
                            Image(systemName: "bell")
                                .foregroundColor(.white)
                                .font(.system(size: 15))
                        }
                        .overlay(alignment: .topTrailing) {
                            if activityVM.unreadCount > 0 {
                                Text("\(min(activityVM.unreadCount, 99))")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(minWidth: 16, minHeight: 16)
                                    .padding(2)
                                    .background(Color.red)
                                    .clipShape(Circle())
                                    .offset(x: 6, y: -6)
                                    .padding(.top, 6)
                                    .padding(.trailing, 6)
                            }
                        }
                        .clipped(antialiased: false)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .sheet(isPresented: $showActivity) {
                        ActivityView(initialFilter: activityInitialFilter)
                            .environmentObject(authService)
                    }
                }
            }
            .task {
                await feedVM.fetchClips()
                await LikeService.shared.fetchLikedClipIDs()
                if case .authenticated(let profile) = authService.appState {
                    await activityVM.fetch(userId: profile.id)
                }
                await feedVM.listenForNewClips()
                if let filter = pushService.pendingActivityFilter {
                    pushService.pendingActivityFilter = nil
                    activityInitialFilter = filter
                    activityVM.markRead()
                    showActivity = true
                }
            }
            .onChange(of: pushService.pendingActivityFilter) { newValue in
                guard let filter = newValue else { return }
                pushService.pendingActivityFilter = nil
                activityInitialFilter = filter
                activityVM.markRead()
                showActivity = true
            }
            .refreshable { await feedVM.fetchClips() }
            .safeAreaInset(edge: .bottom) {
                if player.currentClip != nil {
                    MiniPlayerBar(isExpanded: $isNowPlayingPresented)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .fullScreenCover(isPresented: $showRecord) {
            if #available(iOS 17.0, *) {
                RecordView()
            }
        }
        .sheet(isPresented: $isNowPlayingPresented) {
            NowPlayingView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Header

    private var feedHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ZeitFeed")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                Text("Click record icon and share your thoughts")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.gold)
            }
            Spacer()
            Button(action: { showRecord = true }) {
                ZStack {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 44, height: 44)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .background(AppTheme.canvasBlack)
        .overlay(alignment: .bottom) {
            Divider().overlay(Color(hex: "3A2820"))
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No clips yet")
                .font(.title3.bold())
            Text("Be the first to post, or follow others to see their clips here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - Clip list

    private var clipList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear.frame(height: 0).id("feedTop")

                LazyVStack(spacing: 0) {
                    ForEach(feedVM.clips) { clip in
                        ClipRow(clip: clip, allClips: feedVM.clips)
                            .background(AppTheme.canvasBlack)
                            .transition(.asymmetric(
                                insertion: .push(from: .top).combined(with: .opacity),
                                removal: .identity
                            ))
                        Divider()
                            .overlay(Color(hex: "3A2820"))
                            .padding(.leading, 72)
                    }
                }
            }
            .background(AppTheme.canvasBlack)
            .animation(.spring(response: 0.45, dampingFraction: 0.8),
                       value: feedVM.clips.map(\.id))
            .onReceive(NotificationCenter.default.publisher(for: .feedScrollToTop)) { _ in
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo("feedTop", anchor: .top)
                }
                Task { await feedVM.fetchClips() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .clipPosted)) { _ in
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo("feedTop", anchor: .top)
                }
                Task { await feedVM.fetchClips() }
            }
        }
    }
}

#Preview {
    FeedView()
}
