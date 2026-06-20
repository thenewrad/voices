import SwiftUI

struct ReplyRow: View {
    let reply: Reply
    let allReplies: [Reply]
    let isLiked: Bool
    let onLike: () -> Void
    var onReply: (() -> Void)? = nil

    @ObservedObject private var player = ReplyPlayerService.shared

    private var isCurrent: Bool { player.currentReplyID == reply.id }
    private var hasBeenPlayed: Bool { player.listenedReplyIDs.contains(reply.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(initials: reply.initials, username: reply.username, avatarURL: reply.profiles?.avatar_url)

            VStack(alignment: .leading, spacing: 4) {
                headerRow
                waveformBar
                controlsRow
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            if !hasBeenPlayed {
                Capsule()
                    .fill(AppTheme.gradient)
                    .frame(width: 3)
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.4), value: hasBeenPlayed)
            }
        }
        .onTapGesture {
            if isCurrent {
                player.togglePlayPause()
            } else {
                let idx = allReplies.firstIndex(where: { $0.id == reply.id }) ?? 0
                player.play(replies: allReplies, startAt: idx)
            }
        }
    }

    // MARK: - Sub-views

    private var headerRow: some View {
        HStack(spacing: 4) {
            Text(reply.username)
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            if let replyTo = reply.reply_to_username {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(AppTheme.gold.opacity(0.8))
                Text("@\(replyTo)")
                    .font(.caption.bold())
                    .foregroundStyle(AppTheme.gold.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if let loc = reply.location_display, !loc.isEmpty {
                Text("· \(loc)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            Text(reply.timeDisplay)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var waveformBar: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.12))
                .frame(height: 14)

            if isCurrent {
                RoundedRectangle(cornerRadius: 2)
                    .fill(AppTheme.gradient)
                    .mask(alignment: .leading) {
                        GeometryReader { geo in
                            Rectangle()
                                .frame(width: geo.size.width * CGFloat(player.progress))
                        }
                    }
                    .animation(.linear(duration: 0.25), value: player.progress)
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(AppTheme.gradient.opacity(0.25))
                    .frame(height: 14)
            }

            if isCurrent && player.isLoading {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(.leading, 8)
            }
        }
        .frame(height: 14)
        .frame(maxWidth: .infinity)
    }

    private var controlsRow: some View {
        HStack(spacing: 16) {
            // Play / Pause — first, matching feed layout
            Button {
                if isCurrent { player.togglePlayPause() }
                else {
                    let idx = allReplies.firstIndex(where: { $0.id == reply.id }) ?? 0
                    player.play(replies: allReplies, startAt: idx)
                }
            } label: {
                Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.red)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            // Play count
            HStack(spacing: 3) {
                Image(systemName: "ear.fill")
                    .font(.system(size: 13))
                Text("\(reply.play_count)")
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(.secondary)

            // Like button
            Button { onLike() } label: {
                HStack(spacing: 3) {
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isLiked ? Color.red : Color.secondary)
                        .animation(.spring(response: 0.25, dampingFraction: 0.5), value: isLiked)
                    if reply.like_count > 0 {
                        Text("\(reply.like_count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            // Reply button
            if let onReply {
                Button { onReply() } label: {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
