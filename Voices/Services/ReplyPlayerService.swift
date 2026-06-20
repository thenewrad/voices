import AVFoundation

@MainActor
final class ReplyPlayerService: NSObject, ObservableObject {
    static let shared = ReplyPlayerService()

    @Published var currentReplyID: UUID? = nil
    @Published var currentReply: Reply? = nil
    @Published var isPlaying: Bool = false
    @Published var progress: Double = 0
    @Published var isLoading: Bool = false
    @Published var listenedReplyIDs: Set<UUID> = []

    /// Called once playback has advanced past the last reply in the current thread.
    var onQueueExhausted: (() -> Void)?

    private var replies: [Reply] = []
    private var currentIndex: Int = -1
    private var avPlayer: AVAudioPlayer?
    private var progressTimer: Timer?

    private override init() { super.init() }

    func play(replies: [Reply], startAt index: Int = 0) {
        guard !replies.isEmpty else { return }
        stop()
        self.replies = replies
        currentIndex = max(0, min(index, replies.count - 1))
        AudioCoordinator.shared.replyPlayerWillStart()
        Task { await playCurrentReply() }
    }

    func togglePlayPause() {
        guard let player = avPlayer else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopProgressTimer()
        } else {
            player.play()
            isPlaying = true
            startProgressTimer()
        }
    }

    func stop() {
        avPlayer?.stop()
        avPlayer = nil
        stopProgressTimer()
        isPlaying = false
        progress = 0
        currentReplyID = nil
        currentReply = nil
        currentIndex = -1
        onQueueExhausted = nil
    }

    func skipForward() {
        guard currentIndex < replies.count - 1 else { return }
        currentIndex += 1
        Task { await playCurrentReply() }
    }

    func skipBack() {
        if progress > 0.05 {
            avPlayer?.currentTime = 0
            progress = 0
        } else {
            currentIndex = max(0, currentIndex - 1)
            Task { await playCurrentReply() }
        }
    }

    func seek(to fraction: Double) {
        guard let player = avPlayer else { return }
        player.currentTime = player.duration * max(0, min(1, fraction))
        progress = fraction
    }

    // MARK: - Internal playback

    private func playCurrentReply() async {
        guard currentIndex >= 0, currentIndex < replies.count else {
            isPlaying = false
            currentReplyID = nil
            currentReply = nil
            let callback = onQueueExhausted
            onQueueExhausted = nil
            callback?()
            return
        }

        let reply = replies[currentIndex]
        currentReplyID = reply.id
        currentReply = reply
        isLoading = true
        progress = 0

        do {
            let url = try await SupabaseService.shared.client.storage
                .from("audio")
                .createSignedURL(path: reply.audio_url, expiresIn: 3600)

            let (data, _) = try await URLSession.shared.data(from: url)

            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)

            stopProgressTimer()
            avPlayer = try AVAudioPlayer(data: data)
            avPlayer?.delegate = self
            avPlayer?.prepareToPlay()
            avPlayer?.play()

            isLoading = false
            isPlaying = true
            listenedReplyIDs.insert(reply.id)
            startProgressTimer()

            Task {
                _ = try? await SupabaseService.shared.client
                    .from("replies")
                    .update(["play_count": reply.play_count + 1])
                    .eq("id", value: reply.id.uuidString)
                    .execute()
            }
        } catch {
            isLoading = false
            // Skip broken replies rather than halting the queue
            currentIndex += 1
            await playCurrentReply()
        }
    }

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.avPlayer, player.duration > 0 else { return }
                self.progress = player.currentTime / player.duration
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}

extension ReplyPlayerService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.stopProgressTimer()
            self.progress = 0
            self.currentIndex += 1
            await self.playCurrentReply()
        }
    }
}
