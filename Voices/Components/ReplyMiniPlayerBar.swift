import SwiftUI

struct ReplyMiniPlayerBar: View {
    @Binding var isExpanded: Bool
    @ObservedObject private var player = ReplyPlayerService.shared

    var body: some View {
        VStack(spacing: 0) {
            // Thin progress line
            GeometryReader { geo in
                Rectangle()
                    .fill(.white.opacity(0.45))
                    .frame(width: geo.size.width * CGFloat(player.progress), height: 2)
            }
            .frame(height: 2)

            HStack(spacing: 14) {
                if let reply = player.currentReply {
                    AvatarView(initials: reply.initials, username: reply.username, size: 38, avatarURL: reply.profiles?.avatar_url)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("@\(reply.username)")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let replyTo = reply.reply_to_username {
                            Text("replied @\(replyTo)")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.72))
                                .lineLimit(1)
                        } else {
                            Text("Reply")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.72))
                        }
                    }

                    Spacer()
                }

                HStack(spacing: 4) {
                    transportButton(systemImage: "backward.fill", size: 15) { player.skipBack() }
                    transportButton(
                        systemImage: player.isPlaying ? "pause.fill" : "play.fill",
                        size: 20
                    ) { player.togglePlayPause() }
                    transportButton(systemImage: "forward.fill", size: 15) { player.skipForward() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(
            LinearGradient(
                colors: [AppTheme.rust, AppTheme.gold],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .contentShape(Rectangle())
        .onTapGesture { isExpanded = true }
    }

    private func transportButton(
        systemImage: String,
        size: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Full reply player sheet

struct ReplyNowPlayingView: View {
    @ObservedObject private var player = ReplyPlayerService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showReplySheet = false
    @State private var wasPlayingBeforeReply = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()

                if let reply = player.currentReply {
                    AvatarView(initials: reply.initials, username: reply.username, size: 120, avatarURL: reply.profiles?.avatar_url)
                        .shadow(color: AppTheme.rust.opacity(0.35), radius: 24, x: 0, y: 8)

                    Text("@\(reply.username)")
                        .font(.title3.bold())
                        .padding(.top, 12)

                    if let replyTo = reply.reply_to_username {
                        Text("replied @\(replyTo)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let loc = reply.location_display, !loc.isEmpty {
                        Text("📍 \(loc)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }

                    Text(reply.timeDisplay)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }

                Spacer()

                // Scrubber
                ReplyProgressScrubber(progress: player.progress) { fraction in
                    player.seek(to: fraction)
                }
                .frame(height: 6)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)

                // Transport
                HStack(spacing: 36) {
                    transportButton("backward.fill", size: 22) { player.skipBack() }

                    Button { player.togglePlayPause() } label: {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [AppTheme.rust, AppTheme.gold],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
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

                // Reply button — same capsule layout as NowPlayingView
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
                .disabled(player.currentReply == nil)
                .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity)
            .background(AppTheme.canvasBlack.ignoresSafeArea())
            .navigationTitle("Reply")
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
        }
        .sheet(isPresented: $showReplySheet) {
            if let reply = player.currentReply {
                ReplyRecordingView(
                    clipId: reply.clip_id,
                    replyToUserId: reply.user_id,
                    replyToUsername: reply.username
                ) {
                    showReplySheet = false
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
        .onChange(of: showReplySheet) { isShowing in
            if isShowing {
                wasPlayingBeforeReply = player.isPlaying
                player.togglePlayPause()
            } else if wasPlayingBeforeReply {
                player.togglePlayPause()
            }
        }
    }

    private func transportButton(_ image: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Scrubber

private struct ReplyProgressScrubber: View {
    let progress: Double
    let onScrub: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [AppTheme.rust, AppTheme.gold],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * CGFloat(progress))
                    .animation(.linear(duration: 0.25), value: progress)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        onScrub(max(0, min(1, v.location.x / geo.size.width)))
                    }
            )
        }
    }
}
