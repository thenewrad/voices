import SwiftUI
import MapKit

struct NowPlayingView: View {
    @ObservedObject private var player = AudioPlayerService.shared
    @ObservedObject private var likeService = LikeService.shared
    @ObservedObject private var replyPlayer = ReplyPlayerService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var trackedClipID: UUID? = nil
    @State private var showReplySheet = false
    @State private var wasPlayingBeforeReply = false
    @State private var isReplyPlayerExpanded = false
    @State private var isLoadingThread = false
    @State private var showMapLocation = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()

                if let clip = player.currentClip {
                    clipInfo(clip)
                }

                Spacer()

                // Progress bar + times
                VStack(spacing: 8) {
                    ProgressScrubber(progress: $player.progress) { fraction in
                        player.seek(to: fraction)
                    }
                    .frame(height: 6)
                    .padding(.horizontal, 24)

                    HStack {
                        Text(formatTime(player.currentTime))
                        Spacer()
                        Text(formatTime(max(0, player.duration - player.currentTime)))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 28)
                }
                .padding(.bottom, 32)

                // Transport
                HStack(spacing: 36) {
                    transportButton("backward.fill", size: 22) { player.skipBack() }

                    Button { player.togglePlayPause() } label: {
                        ZStack {
                            Circle()
                                .fill(AppTheme.gradient)
                                .frame(width: 70, height: 70)
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)

                    transportButton("forward.fill", size: 22) { player.skipForward() }
                }
                .padding(.bottom, 32)

                // Reply / Replies-thread buttons
                HStack(spacing: 12) {
                    Button { showReplySheet = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 20))
                            Text("Reply")
                                .font(.subheadline.bold())
                        }
                        .foregroundStyle(AppTheme.gold)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 11)
                        .background(AppTheme.gold.opacity(0.1))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(AppTheme.gold.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(player.currentClip == nil)

                    Button { Task { await playThread() } } label: {
                        HStack(spacing: 8) {
                            if isLoadingThread {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "bubble.left")
                                    .font(.system(size: 20))
                            }
                            Text("\(player.currentClip?.reply_count ?? 0)")
                                .font(.subheadline.bold())
                        }
                        .foregroundStyle(AppTheme.gold)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 11)
                        .background(AppTheme.gold.opacity(0.1))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(AppTheme.gold.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoadingThread || (player.currentClip?.reply_count ?? 0) == 0)
                }
                .padding(.bottom, 40)
            }
            .background(AppTheme.canvasBlack.ignoresSafeArea())
            .task(id: player.currentClip?.id) {
                trackedClipID = player.currentClip?.id
                await likeService.fetchLikedClipIDs()
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.canvasBlack, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(AppTheme.gold)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if replyPlayer.currentReply != nil {
                    ReplyMiniPlayerBar(isExpanded: $isReplyPlayerExpanded)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .sheet(isPresented: $isReplyPlayerExpanded) {
                ReplyNowPlayingView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showMapLocation) {
            if #available(iOS 17.0, *),
               let clip = player.currentClip,
               let lat = clip.lat, let lng = clip.lng {
                PostLocationMapView(
                    lat: lat,
                    lng: lng,
                    username: clip.username,
                    locationDisplay: clip.locationDisplay
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showReplySheet) {
            if let clip = player.currentClip {
                ReplyRecordingView(clipId: clip.id) {
                    showReplySheet = false
                    // Give the sheet time to dismiss and audio to resume, then close the player
                    Task {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        dismiss()
                    }
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
        .onChange(of: showReplySheet) { isShowing in
            if isShowing {
                wasPlayingBeforeReply = player.isPlaying
                player.pause()
            } else if wasPlayingBeforeReply {
                player.resume()
            }
        }
    }

    // MARK: - Clip info block

    @ViewBuilder
    private func clipInfo(_ clip: Clip) -> some View {
        let isLiked = likeService.likedClipIDs.contains(clip.id)

        VStack(spacing: 10) {
            // Avatar
            AvatarView(initials: clip.initials, username: clip.username, size: 120, avatarURL: clip.profiles?.avatar_url)
                .shadow(color: AppTheme.rust.opacity(0.35), radius: 24, x: 0, y: 8)

            // Username
            Text("@\(clip.username)")
                .font(.title3.bold())
                .foregroundStyle(.primary)
                .padding(.top, 8)

            // Title
            if let title = clip.title, !title.isEmpty {
                Text(title)
                    .font(.headline.bold())
                    .foregroundStyle(AppTheme.gold)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            // City — tappable when post has coordinates
            if let city = clip.location_display, !city.isEmpty {
                if clip.lat != nil {
                    Button { showMapLocation = true } label: {
                        Text("📍 \(city)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .underline(true, color: .secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("📍 \(city)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // Date & time
            Text(formatPostedDate(clip.created_at))
                .font(.caption)
                .foregroundStyle(.tertiary)

            // Like button — always shows count, optimistic increment via shared LikeService offset
            Button {
                Task { await likeService.toggleLike(clip: clip) }
            } label: {
                let offset = likeService.pendingLikeOffsets[clip.id] ?? 0
                HStack(spacing: 8) {
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(isLiked ? Color.red : AppTheme.gold)
                        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isLiked)

                    Text("\(max(0, clip.like_count + offset))")
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(AppTheme.gold)
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: offset)
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Reply thread playback

    private func playThread() async {
        guard let clip = player.currentClip, clip.reply_count > 0 else { return }
        isLoadingThread = true
        let threadVM = ThreadViewModel()
        await threadVM.fetchReplies(clipId: clip.id)
        isLoadingThread = false
        guard !threadVM.replies.isEmpty else { return }
        // Play the replies thread instead of advancing to the next post; once the
        // thread finishes, resume the main queue at the next post.
        ReplyPlayerService.shared.onQueueExhausted = {
            AudioPlayerService.shared.skipForward()
        }
        ReplyPlayerService.shared.play(replies: threadVM.replies)
    }

    // MARK: - Helpers

    private func transportButton(_ image: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func formatPostedDate(_ date: Date) -> String {
        let cal = Calendar.current
        let now = Date()
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = cal.isDate(date, equalTo: now, toGranularity: .year) ? "MMM d" : "MMM d, yyyy"
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"
        return "\(dateFmt.string(from: date)) · \(timeFmt.string(from: date).lowercased())"
    }
}

// MARK: - Scrub bar

private struct ProgressScrubber: View {
    @Binding var progress: Double
    let onScrub: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))

                Capsule()
                    .fill(AppTheme.gradient)
                    .frame(width: geo.size.width * CGFloat(progress))
                    .animation(.linear(duration: 0.25), value: progress)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let f = max(0, min(1, v.location.x / geo.size.width))
                        onScrub(f)
                    }
            )
        }
    }
}

#Preview {
    NowPlayingView()
}
