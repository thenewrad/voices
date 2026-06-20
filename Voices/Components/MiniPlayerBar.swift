import SwiftUI

struct MiniPlayerBar: View {
    @Binding var isExpanded: Bool
    @ObservedObject private var player = AudioPlayerService.shared

    var body: some View {
        VStack(spacing: 0) {
            // Thin progress line along the very top
            GeometryReader { geo in
                Rectangle()
                    .fill(.white.opacity(0.45))
                    .frame(width: geo.size.width * CGFloat(player.progress), height: 2)
            }
            .frame(height: 2)

            HStack(spacing: 14) {
                if let clip = player.currentClip {
                    AvatarView(initials: clip.initials, username: clip.username, size: 38, avatarURL: clip.profiles?.avatar_url)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(clip.username)
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        let summary = clip.transcript ?? clip.title
                        if let summary {
                            MarqueeText(
                                text: summary,
                                font: .caption,
                                color: .white.opacity(0.72)
                            )
                            .id(summary)
                        } else {
                            Text(clip.timeDisplay)
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
                colors: [AppTheme.purple, AppTheme.skyBlue],
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

// MARK: - MarqueeText

private struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color

    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var scrollTask: Task<Void, Never>?

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }

    var body: some View {
        // Hidden text establishes height and reports container width via its frame.
        // The overlay carries the actual scrolling text, clipped to those bounds.
        Text(text)
            .font(font)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear {
                        containerWidth = geo.size.width
                        maybeStart()
                    }
                }
            )
            .overlay(alignment: .leading) {
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: offset)
                    .background(
                        GeometryReader { geo in
                            Color.clear.onAppear {
                                textWidth = geo.size.width
                                maybeStart()
                            }
                        }
                    )
            }
            .clipped()
            .onDisappear {
                scrollTask?.cancel()
                scrollTask = nil
            }
    }

    private func maybeStart() {
        guard containerWidth > 0, textWidth > 0, overflow > 0, scrollTask == nil else { return }
        scrollTask = Task { await runLoop() }
    }

    @MainActor
    private func runLoop() async {
        try? await Task.sleep(nanoseconds: 1_000_000_000) // let user read start of text
        let speed: Double = 20.0 // pts/sec (50% of original 40)
        while !Task.isCancelled {
            guard textWidth > containerWidth else { break }

            // Phase 1: exit — slide left until text is completely off screen
            let exitDuration = textWidth / speed
            withAnimation(.linear(duration: exitDuration)) {
                offset = -textWidth
            }
            try? await Task.sleep(nanoseconds: UInt64(exitDuration * 1_000_000_000))
            guard !Task.isCancelled else { break }

            // Phase 2: reposition off the right edge (no animation)
            withTransaction(Transaction(animation: nil)) {
                offset = containerWidth
            }

            // Phase 3: enter — slide in from right until text reaches left margin
            let entryDuration = containerWidth / speed
            withAnimation(.linear(duration: entryDuration)) {
                offset = 0
            }
            try? await Task.sleep(nanoseconds: UInt64(entryDuration * 1_000_000_000))
            guard !Task.isCancelled else { break }

            // Phase 4: pause 5 seconds at left margin before next cycle
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }
}
