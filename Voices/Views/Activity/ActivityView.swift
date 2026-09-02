import SwiftUI
import AVFoundation
import UIKit

// MARK: - Helpers

private struct FollowProfileTarget: Identifiable {
    let id: UUID
    let username: String
}

// MARK: - Single-reply audio player

@MainActor
private final class SingleReplyPlayer: NSObject, ObservableObject {
    @Published var isLoading = true
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var error: String?

    var onFinished: (() -> Void)?
    private var player: AVAudioPlayer?
    private var timeTask: Task<Void, Never>?

    func load(audioUrl: String) async {
        isLoading = true
        isPlaying = false
        error = nil
        do {
            let signedURL = try await SupabaseService.shared.client.storage
                .from("audio")
                .createSignedURL(path: audioUrl, expiresIn: 3600)
            let (data, _) = try await URLSession.shared.data(from: signedURL)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.play()
            player = p
            duration = p.duration
            isLoading = false
            isPlaying = true
            startTimeTask()
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    func togglePlayPause() {
        guard let p = player else { return }
        if p.isPlaying { p.pause(); isPlaying = false }
        else { p.play(); isPlaying = true }
    }

    func restart() {
        guard let p = player else { return }
        p.currentTime = 0
        p.play()
        isPlaying = true
    }

    // Stops audio only — does NOT resume the main player.
    // Use this when navigating within the queue or on sheet dismiss.
    func stopAudio() {
        timeTask?.cancel()
        timeTask = nil
        player?.stop()
        player = nil
        isPlaying = false
        isLoading = true
        currentTime = 0
        duration = 0
        error = nil
    }

    private func startTimeTask() {
        timeTask?.cancel()
        timeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self, self.player != nil {
                self.currentTime = self.player?.currentTime ?? 0
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.timeTask?.cancel()
            self.isPlaying = false
            self.currentTime = self.duration
            self.onFinished?()
        }
    }
}

extension SingleReplyPlayer: AVAudioPlayerDelegate {}

// MARK: - ActivityView

struct ActivityView: View {
    @EnvironmentObject private var authService: AuthService
    @StateObject private var vm = ActivityViewModel()
    @ObservedObject private var relationships = UserRelationshipService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showNowPlaying = false
    @State private var playerQueue: [ActivityItem] = []
    @State private var playerStartIndex: Int = 0
    @State private var showQueuePlayer = false
    @State private var followTarget: FollowProfileTarget?
    @State private var selectedFilter: ActivityFilter

    // Row-level options menu
    @State private var optionsItem: ActivityItem?
    @State private var showOptions = false
    @State private var threadClip: Clip?
    @State private var showThreadSheet = false

    init(initialFilter: ActivityFilter = .likes) {
        _selectedFilter = State(initialValue: initialFilter)
    }

    private var filteredItems: [ActivityItem] {
        vm.items.filter { selectedFilter.matches($0.type) }
    }

    private var audioItems: [ActivityItem] {
        filteredItems.filter { $0.replyAudioUrl != nil && $0.sharedClipId == nil }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                Group {
                    if vm.isLoading && vm.items.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if filteredItems.isEmpty {
                        emptyState
                    } else {
                        activityList
                    }
                }
            }
            .background(AppTheme.canvasBlack.ignoresSafeArea())
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.canvasBlack, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(AppTheme.gold)
                }
            }
            .onAppear { UIApplication.shared.applicationIconBadgeNumber = 0 }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                UIApplication.shared.applicationIconBadgeNumber = 0
            }
            .task {
                if case .authenticated(let profile) = authService.appState {
                    await vm.fetch(userId: profile.id)
                    vm.markRead()
                }
            }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showQueuePlayer) {
            ActivityQueuePlayerView(items: playerQueue, startIndex: playerStartIndex, vm: vm)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $followTarget) { target in
            NavigationStack { UserProfileView(userId: target.id, username: target.username) }
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showThreadSheet) {
            if let clip = threadClip {
                NavigationStack {
                    ThreadView(clip: clip, autoPlayReplyId: optionsItem?.id)
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .confirmationDialog("", isPresented: $showOptions, presenting: optionsItem) { item in
            if item.type == .reply || item.type == .replyToReply {
                Button("Open Thread") { Task { await openThread(for: item) } }
            }
            if item.type == .directMessage {
                Button("Delete Message", role: .destructive) {
                    Task { await deleteMessage(item) }
                }
            }
            if let userId = item.actorUserId {
                Button("Hide @\(item.actorUsername)") {
                    Task { try? await relationships.hideUser(userId: userId, username: item.actorUsername) }
                }
                Button("Block @\(item.actorUsername)", role: .destructive) {
                    Task { try? await relationships.blockUser(userId: userId, username: item.actorUsername) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Tap handling

    private func handleTap(_ item: ActivityItem) {
        switch item.type {
        case .like:
            guard let clipId = item.replyClipId else { return }
            Task { await playLikedClip(clipId: clipId) }
        case .reply, .replyToReply:
            guard item.replyAudioUrl != nil else { return }
            vm.markReplyPlayed(item.id)
            playerQueue = audioItems
            playerStartIndex = audioItems.firstIndex(where: { $0.id == item.id }) ?? 0
            showQueuePlayer = true
        case .directMessage:
            if let sharedClipId = item.sharedClipId {
                vm.markDMPlayed(item.id)
                Task { await playLikedClip(clipId: sharedClipId) }
            } else {
                guard item.replyAudioUrl != nil else { return }
                vm.markDMPlayed(item.id)
                playerQueue = audioItems
                playerStartIndex = audioItems.firstIndex(where: { $0.id == item.id }) ?? 0
                showQueuePlayer = true
            }
        case .follow:
            guard let uid = item.actorUserId else { return }
            followTarget = FollowProfileTarget(id: uid, username: item.actorUsername)
        }
    }

    private func playLikedClip(clipId: UUID) async {
        let clips: [Clip] = (try? await SupabaseService.shared.client
            .from("clips")
            .select("id, user_id, audio_url, lat, lng, created_at, play_count, reply_count, duration_seconds, title, like_count, location_display, transcript, profiles!clips_user_id_fkey(username, avatar_url, beep_tone)")
            .eq("id", value: clipId.uuidString)
            .limit(1)
            .execute()
            .value) ?? []
        guard let clip = clips.first else { return }
        AudioPlayerService.shared.play(clip: clip, in: [clip])
        showNowPlaying = true
    }

    private func openThread(for item: ActivityItem) async {
        guard let clipId = item.replyClipId else { return }
        let clips: [Clip] = (try? await SupabaseService.shared.client
            .from("clips")
            .select("id, user_id, audio_url, lat, lng, created_at, play_count, reply_count, duration_seconds, title, like_count, location_display, transcript, profiles!clips_user_id_fkey(username, avatar_url, beep_tone)")
            .eq("id", value: clipId.uuidString)
            .limit(1)
            .execute()
            .value) ?? []
        guard let clip = clips.first else { return }
        threadClip = clip
        showThreadSheet = true
    }

    private func deleteMessage(_ item: ActivityItem) async {
        guard let msgId = item.dmMessageId else { return }
        _ = try? await SupabaseService.shared.client
            .from("direct_messages")
            .delete()
            .eq("id", value: msgId.uuidString)
            .execute()
        if case .authenticated(let profile) = authService.appState {
            await vm.fetch(userId: profile.id)
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 0) {
            ForEach(ActivityFilter.allCases, id: \.self) { tab in
                Button { selectedFilter = tab } label: {
                    Text(tab.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selectedFilter == tab ? AppTheme.gold : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(selectedFilter == tab ? AppTheme.gold : Color.clear)
                                .frame(height: 2)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .background(AppTheme.canvasBlack)
        .overlay(alignment: .bottom) {
            Divider().overlay(Color(hex: "3A2820"))
        }
    }

    // MARK: - List

    private var activityList: some View {
        List(filteredItems) { item in
            HStack(spacing: 0) {
                Button { handleTap(item) } label: {
                    ActivityRow(item: item)
                }
                .buttonStyle(.plain)

                if item.type == .reply || item.type == .replyToReply || item.type == .directMessage {
                    Button {
                        optionsItem = item
                        showOptions = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowBackground(rowBackground(for: item))
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 8))
            .listRowSeparatorTint(Color(hex: "3A2820"))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppTheme.canvasBlack)
    }

    private func rowBackground(for item: ActivityItem) -> Color {
        switch item.type {
        case .like:   return AppTheme.canvasBlack
        case .follow: return AppTheme.cardDark
        case .reply, .replyToReply:
            return vm.playedReplyIDs.contains(item.id) ? AppTheme.canvasBlack : AppTheme.cardDark
        case .directMessage:
            return vm.playedDMIDs.contains(item.id) ? AppTheme.canvasBlack : AppTheme.cardDark
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bell.slash")
                .font(.system(size: 44))
                .foregroundColor(Color(UIColor.tertiaryLabel))
            Text("No activity yet")
                .font(.title3.bold())
            Text("Likes, replies, and new followers will appear here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Activity row

struct ActivityRow: View {
    let item: ActivityItem

    private var typeIcon: String {
        switch item.type {
        case .like:           return "heart.fill"
        case .reply:          return "bubble.left.fill"
        case .replyToReply:   return "arrowshape.turn.up.left.fill"
        case .follow:         return "person.fill"
        case .directMessage:  return item.sharedClipId != nil ? "arrowshape.turn.up.forward.fill" : "waveform.badge.mic"
        }
    }

    private var typeColor: Color {
        switch item.type {
        case .like:           return .red
        case .reply:          return AppTheme.gold
        case .replyToReply:   return AppTheme.rust
        case .follow:         return AppTheme.gold
        case .directMessage:  return AppTheme.slate
        }
    }

    private var actionLine: Text {
        switch item.type {
        case .like:
            let base = Text("@\(item.actorUsername)").bold() + Text(" liked ")
            if let label = item.contentLabel { return base + Text("\"\(label)\"").foregroundColor(AppTheme.gold) }
            return base
        case .reply:
            let base = Text("@\(item.actorUsername)").bold() + Text(" replied to ")
            if let label = item.contentLabel { return base + Text("\"\(label)\"").foregroundColor(AppTheme.gold) }
            return base
        case .replyToReply:
            return Text("@\(item.actorUsername)").bold() + Text(" replied to your reply.")
        case .follow:
            return Text("@\(item.actorUsername)").bold() + Text(" followed you.")
        case .directMessage:
            if item.sharedClipId != nil {
                return Text("@\(item.actorUsername)").bold() + Text(" shared a post with you.")
            }
            return Text("@\(item.actorUsername)").bold() + Text(" sent you a voice message.")
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(
                    initials: String(item.actorUsername.prefix(1)).uppercased(),
                    username: item.actorUsername,
                    size: 40
                )
                Image(systemName: typeIcon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(3)
                    .background(typeColor)
                    .clipShape(Circle())
                    .offset(x: 4, y: 4)
            }

            actionLine
                .font(.subheadline)
                .foregroundColor(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                Text(item.timeDisplay)
                    .font(.caption2)
                    .foregroundColor(Color(UIColor.tertiaryLabel))
                if item.isUnread {
                    Circle().fill(AppTheme.rust).frame(width: 7, height: 7)
                }
            }
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Queue player sheet

private struct ActivityQueuePlayerView: View {
    let items: [ActivityItem]
    let startIndex: Int
    @ObservedObject var vm: ActivityViewModel

    @StateObject private var replyPlayer = SingleReplyPlayer()
    @State private var currentIndex: Int
    @State private var wasMainPlayerPlaying = false

    // Like state for the current reply item
    @State private var isLiked = false
    @State private var likeCount = 0
    @State private var isLiking = false

    @Environment(\.dismiss) private var dismiss

    init(items: [ActivityItem], startIndex: Int, vm: ActivityViewModel) {
        self.items = items
        self.startIndex = startIndex
        self.vm = vm
        _currentIndex = State(initialValue: startIndex)
    }

    private var currentItem: ActivityItem? {
        guard currentIndex >= 0, currentIndex < items.count else { return nil }
        return items[currentIndex]
    }

    private var canSkipForward: Bool {
        var next = currentIndex + 1
        while next < items.count { if !isPlayed(items[next]) { return true }; next += 1 }
        return false
    }

    private var canSkipBack: Bool { currentIndex > 0 || replyPlayer.currentTime > 3 }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 16)

            if let item = currentItem {
                // Identity
                HStack(spacing: 12) {
                    AvatarView(
                        initials: String(item.actorUsername.prefix(1)).uppercased(),
                        username: item.actorUsername,
                        size: 44
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.type == .directMessage ? "Voice message from" : "Reply from")
                            .font(.caption).foregroundColor(.secondary)
                        Text("@\(item.actorUsername)")
                            .font(.subheadline.bold()).foregroundColor(.primary)
                    }
                    Spacer()
                    // Queue position
                    Text("\(currentIndex + 1) / \(items.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 4)
                }
                .padding(.horizontal, 24)
            }

            Spacer(minLength: 0)

            // Playback state
            if replyPlayer.isLoading {
                ProgressView().scaleEffect(1.4).tint(AppTheme.gold)
            } else if let err = replyPlayer.error {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 40)).foregroundColor(.red)
                    Text(err).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
                }
            } else {
                Image(systemName: replyPlayer.isPlaying ? "waveform" : "checkmark.circle")
                    .font(.system(size: 48))
                    .foregroundColor(replyPlayer.isPlaying ? AppTheme.gold : .secondary)
                    .animation(.easeInOut(duration: 0.3), value: replyPlayer.isPlaying)
            }

            Spacer(minLength: 0)

            // Transport
            HStack(spacing: 40) {
                Button { skipBack() } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(canSkipBack ? .primary : .tertiary)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .disabled(!canSkipBack)

                Button { replyPlayer.togglePlayPause() } label: {
                    ZStack {
                        Circle().fill(AppTheme.gradient).frame(width: 64, height: 64)
                        Image(systemName: replyPlayer.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .disabled(replyPlayer.isLoading)

                Button { skipForward() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(canSkipForward ? .primary : .tertiary)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .disabled(!canSkipForward)
            }
            .padding(.bottom, 16)

            // Like button — replies only
            if let item = currentItem, item.type == .reply || item.type == .replyToReply {
                Button {
                    guard !isLiking else { return }
                    Task { await toggleLike(item: item) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isLiked ? "heart.fill" : "heart")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(isLiked ? .red : .secondary)
                            .animation(.spring(response: 0.25, dampingFraction: 0.5), value: isLiked)
                        if likeCount > 0 {
                            Text("\(likeCount)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 28).padding(.vertical, 12)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            }

            Button("Close") { dismiss() }
                .font(.subheadline.weight(.medium)).foregroundColor(.secondary)
                .padding(.top, 4).padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity)
        .background(AppTheme.canvasBlack.ignoresSafeArea())
        .onAppear {
            wasMainPlayerPlaying = AudioPlayerService.shared.isPlaying
            AudioCoordinator.shared.replyPlayerWillStart()
            replyPlayer.onFinished = handleAutoAdvance
        }
        .task(id: currentIndex) {
            await loadCurrentItem()
            await loadLikeState()
        }
        .onDisappear {
            replyPlayer.stopAudio()
            if wasMainPlayerPlaying { AudioPlayerService.shared.resume() }
        }
    }

    // MARK: - Queue navigation

    private func skipForward() {
        var next = currentIndex + 1
        while next < items.count && isPlayed(items[next]) { next += 1 }
        guard next < items.count else { return }
        currentIndex = next
    }

    private func skipBack() {
        if replyPlayer.currentTime > 3 {
            replyPlayer.restart()
        } else if currentIndex > 0 {
            currentIndex -= 1
        } else {
            replyPlayer.restart()
        }
    }

    private func handleAutoAdvance() {
        var next = currentIndex + 1
        while next < items.count && isPlayed(items[next]) { next += 1 }
        if next < items.count {
            currentIndex = next
        } else {
            dismiss()
        }
    }

    private func isPlayed(_ item: ActivityItem) -> Bool {
        if item.type == .directMessage { return vm.playedDMIDs.contains(item.id) }
        return vm.playedReplyIDs.contains(item.id)
    }

    private func loadCurrentItem() async {
        guard let item = currentItem, let audioUrl = item.replyAudioUrl else {
            dismiss(); return
        }
        // Mark played before loading so auto-advance skips it
        if item.type == .directMessage { vm.markDMPlayed(item.id) }
        else { vm.markReplyPlayed(item.id) }
        await replyPlayer.load(audioUrl: audioUrl)
    }

    // MARK: - Like

    private func loadLikeState() async {
        guard let item = currentItem,
              item.type == .reply || item.type == .replyToReply else {
            isLiked = false; likeCount = 0; return
        }
        likeCount = item.replyLikeCount ?? 0
        guard let uid = try? await SupabaseService.shared.client.auth.session.user.id else { return }
        struct LikeRow: Decodable { let reply_id: UUID }
        let rows: [LikeRow]? = try? await SupabaseService.shared.client
            .from("reply_likes")
            .select("reply_id")
            .eq("user_id", value: uid.uuidString)
            .eq("reply_id", value: item.id.uuidString)
            .execute()
            .value
        isLiked = !(rows?.isEmpty ?? true)
    }

    private func toggleLike(item: ActivityItem) async {
        isLiking = true
        defer { isLiking = false }
        let wasLiked = isLiked
        isLiked = !wasLiked
        likeCount = max(0, likeCount + (wasLiked ? -1 : 1))
        do {
            let uid = try await SupabaseService.shared.client.auth.session.user.id
            if wasLiked {
                try await SupabaseService.shared.client
                    .from("reply_likes").delete()
                    .eq("user_id", value: uid.uuidString)
                    .eq("reply_id", value: item.id.uuidString)
                    .execute()
                struct P: Encodable { let p_reply_id: UUID }
                _ = try? await SupabaseService.shared.client
                    .rpc("decrement_reply_like_count", params: P(p_reply_id: item.id)).execute()
            } else {
                struct Insert: Encodable { let user_id: UUID; let reply_id: UUID }
                try await SupabaseService.shared.client
                    .from("reply_likes").insert(Insert(user_id: uid, reply_id: item.id)).execute()
                struct P: Encodable { let p_reply_id: UUID }
                _ = try? await SupabaseService.shared.client
                    .rpc("increment_reply_like_count", params: P(p_reply_id: item.id)).execute()
            }
        } catch {
            isLiked = wasLiked
            likeCount = max(0, likeCount + (wasLiked ? 1 : -1))
        }
    }
}
