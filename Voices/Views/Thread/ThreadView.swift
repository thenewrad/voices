import SwiftUI

struct ThreadView: View {
    let clip: Clip
    var autoPlayReplyId: UUID? = nil
    @StateObject private var vm = ThreadViewModel()
    @ObservedObject private var player = AudioPlayerService.shared
    @ObservedObject private var replyPlayer = ReplyPlayerService.shared
    @State private var showReplySheet = false
    @State private var isNowPlayingPresented = false
    @State private var isReplyPlayerExpanded = false
    @State private var hasLoaded = false
    @State private var clipWasPlayingOnEntry = false
    @State private var audioWasPlayingBeforeReply = false
    @State private var replyAudioWasPlayingBeforeReply = false
    @State private var replyTarget: Reply? = nil

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ClipRow(clip: clip, allClips: [clip])
                    .background(AppTheme.canvasBlack)

                Divider().overlay(Color(hex: "3A2820"))

                replyBar

                Divider().overlay(Color(hex: "3A2820"))

                repliesSection
            }
        }
        .refreshable {
            await vm.fetchReplies(clipId: clip.id)
            await vm.fetchLikedReplyIDs()
        }
        .background(AppTheme.canvasBlack)
        .navigationTitle("Thread")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.canvasBlack, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task {
                        await vm.fetchReplies(clipId: clip.id)
                        await vm.fetchLikedReplyIDs()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(AppTheme.gold)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if replyPlayer.currentReply != nil {
                ReplyMiniPlayerBar(isExpanded: $isReplyPlayerExpanded)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if player.currentClip != nil {
                MiniPlayerBar(isExpanded: $isNowPlayingPresented)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $isReplyPlayerExpanded) {
            ReplyNowPlayingView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isNowPlayingPresented) {
            NowPlayingView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showReplySheet) {
            ReplyRecordingView(clipId: clip.id) {
                showReplySheet = false
                Task {
                    await vm.fetchReplies(clipId: clip.id)
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $replyTarget) { target in
            ReplyRecordingView(
                clipId: clip.id,
                replyToUserId: target.user_id,
                replyToUsername: target.username
            ) {
                replyTarget = nil
                Task { await vm.fetchReplies(clipId: clip.id) }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: replyTarget?.id) { id in
            if id != nil {
                audioWasPlayingBeforeReply = player.isPlaying
                player.pause()
                replyAudioWasPlayingBeforeReply = ReplyPlayerService.shared.isPlaying
                if ReplyPlayerService.shared.isPlaying { ReplyPlayerService.shared.togglePlayPause() }
            } else {
                if audioWasPlayingBeforeReply { player.resume(); audioWasPlayingBeforeReply = false }
                if replyAudioWasPlayingBeforeReply { ReplyPlayerService.shared.togglePlayPause(); replyAudioWasPlayingBeforeReply = false }
            }
        }
        .onChange(of: showReplySheet) { isShowing in
            if !isShowing {
                if audioWasPlayingBeforeReply {
                    player.resume()
                    audioWasPlayingBeforeReply = false
                }
                if replyAudioWasPlayingBeforeReply {
                    ReplyPlayerService.shared.togglePlayPause()
                    replyAudioWasPlayingBeforeReply = false
                }
            }
        }
        .onAppear {
            clipWasPlayingOnEntry = AudioPlayerService.shared.isPlaying
            guard !hasLoaded else { return }
            hasLoaded = true
            Task {
                await vm.fetchReplies(clipId: clip.id)
                await vm.fetchLikedReplyIDs()
                if !vm.replies.isEmpty {
                    let startIdx: Int
                    if let rid = autoPlayReplyId,
                       let idx = vm.replies.firstIndex(where: { $0.id == rid }) {
                        startIdx = idx
                    } else {
                        startIdx = 0
                    }
                    ReplyPlayerService.shared.play(replies: vm.replies, startAt: startIdx)
                }
            }
        }
        .onDisappear {
            ReplyPlayerService.shared.stop()
            if clipWasPlayingOnEntry {
                AudioPlayerService.shared.resume()
            }
        }
    }

    // MARK: - Reply bar

    private var replyBar: some View {
        Button {
            audioWasPlayingBeforeReply = player.isPlaying
            player.pause()
            replyAudioWasPlayingBeforeReply = ReplyPlayerService.shared.isPlaying
            if ReplyPlayerService.shared.isPlaying { ReplyPlayerService.shared.togglePlayPause() }
            showReplySheet = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("Reply")
                    .font(.subheadline.bold())
            }
            .foregroundStyle(AppTheme.gold)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(AppTheme.gold.opacity(0.07))
            .overlay(
                Rectangle()
                    .fill(AppTheme.gold.opacity(0.2))
                    .frame(height: 1),
                alignment: .bottom
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Replies

    private var repliesSection: some View {
        Group {
            if vm.isLoading {
                ProgressView()
                    .tint(AppTheme.gold)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 56)
            } else if vm.replies.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 38))
                        .foregroundColor(Color(UIColor.tertiaryLabel))
                    Text("No replies yet")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Pull down to refresh")
                        .font(.caption)
                        .foregroundColor(Color(UIColor.tertiaryLabel))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 56)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("Replies")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                        Text("\(vm.replies.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(Color(UIColor.tertiaryLabel))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    ForEach(vm.replies) { reply in
                        ReplyRow(
                            reply: reply,
                            allReplies: vm.replies,
                            isLiked: vm.likedReplyIDs.contains(reply.id),
                            onLike: { Task { await vm.toggleLike(reply: reply) } },
                            onReply: { replyTarget = reply }
                        )
                        .background(AppTheme.canvasBlack)

                        Divider()
                            .overlay(Color(hex: "3A2820"))
                            .padding(.leading, 64)
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        ThreadView(clip: Clip(
            id: UUID(),
            user_id: UUID(),
            audio_url: "",
            lat: nil,
            lng: nil,
            created_at: Date(),
            play_count: 12,
            like_count: 0,
            reply_count: 3,
            duration_seconds: 42,
            title: "",
            transcript: "",
            location_display: nil,
            rawUsername: "preview_user",
            profiles: nil
        ))
    }
}
