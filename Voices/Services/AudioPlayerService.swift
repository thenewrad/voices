import AVFoundation
import Combine
import MediaPlayer

// Uses AVPlayer for proper HTTP streaming from signed Supabase storage URLs.
@MainActor
final class AudioPlayerService: ObservableObject {
    static let shared = AudioPlayerService()

    @Published var queue: [Clip] = []
    @Published var currentIndex: Int = -1
    @Published var isPlaying: Bool = false
    @Published var progress: Double = 0
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isLoading: Bool = false
    @Published var listenedClipIDs: Set<UUID> = AudioPlayerService.listenedStore.load()

    private static let listenedStore = PersistedUUIDSet(key: "listenedClipIDs")

    var currentClip: Clip? {
        guard currentIndex >= 0, currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }

    /// Set by Drive Mode. Called instead of stopping when the queue runs out,
    /// giving the caller a chance to fetch a fresh nearby list and keep playback going.
    var onQueueExhausted: (() async -> Void)?

    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var endObserver: AnyCancellable?
    private var itemStatusObserver: AnyCancellable?

    private init() {
        // Background audio + AirPlay + Bluetooth A2DP
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .default,
            options: [.allowAirPlay, .allowBluetoothA2DP]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
        setupRemoteCommands()
    }

    // MARK: - Queue

    func loadQueue(_ clips: [Clip], startAt index: Int = 0) {
        queue = clips
        currentIndex = max(0, min(index, clips.count - 1))
        Task { await playCurrentClip() }
    }

    func play(clip: Clip, in clips: [Clip]) {
        let idx = clips.firstIndex(where: { $0.id == clip.id }) ?? 0
        loadQueue(clips, startAt: idx)
    }

    /// Replaces everything after the currently-playing clip with a freshly fetched
    /// list, without interrupting playback of the current clip. Used by Drive Mode
    /// to refresh the upcoming queue from the user's new location each time a post
    /// starts, while leaving the in-progress clip untouched.
    func setUpcomingQueue(_ clips: [Clip]) {
        guard currentIndex >= 0, currentIndex < queue.count else {
            queue = clips
            currentIndex = clips.isEmpty ? -1 : 0
            return
        }
        let playedAndCurrent = Array(queue.prefix(currentIndex + 1))
        let currentClipID = playedAndCurrent.last?.id
        let upcoming = clips.filter { $0.id != currentClipID }
        queue = playedAndCurrent + upcoming
    }

    /// Advances to and plays the next queued clip, if one exists.
    /// Returns false (and does nothing) if the queue has no further items.
    @discardableResult
    func playNextIfAvailable() async -> Bool {
        guard currentIndex < queue.count - 1 else { return false }
        currentIndex += 1
        await playCurrentClip()
        return true
    }

    // MARK: - Transport

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    func resume() {
        player?.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    func skipForward() {
        guard !queue.isEmpty else { return }
        currentIndex = min(currentIndex + 1, queue.count - 1)
        Task { await playCurrentClip() }
    }

    func skipBack() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
        } else {
            currentIndex = max(currentIndex - 1, 0)
            Task { await playCurrentClip() }
        }
    }

    func replay() {
        seek(to: 0)
        if !isPlaying { resume() }
    }

    func seek(to fraction: Double) {
        guard let item = player?.currentItem else { return }
        let dur = CMTimeGetSeconds(item.duration)
        guard dur.isFinite, dur > 0 else { return }
        let target = CMTime(seconds: dur * fraction, preferredTimescale: 600)
        player?.seek(to: target)
        progress = fraction
        currentTime = dur * fraction
        updateNowPlayingInfo()
    }

    /// Jumps forward (positive) or back (negative) by the given number of seconds.
    func skip(by seconds: TimeInterval) {
        guard let item = player?.currentItem else { return }
        let dur = CMTimeGetSeconds(item.duration)
        guard dur.isFinite, dur > 0 else { return }
        let target = max(0, min(dur, currentTime + seconds))
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        progress = target / dur
        currentTime = target
        updateNowPlayingInfo()
    }

    // MARK: - Playback

    private func playCurrentClip() async {
        guard let clip = currentClip else { return }
        AudioCoordinator.shared.clipPlayerWillStart()
        tearDownObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        isLoading = true
        progress = 0
        currentTime = 0
        duration = 0

        print("[AudioPlayer] ── playCurrentClip ─────────────────────")
        print("[AudioPlayer] clip id   : \(clip.id.uuidString)")
        print("[AudioPlayer] audio_url : \(clip.audio_url)")
        print("[AudioPlayer] is HTTPS  : \(clip.audio_url.hasPrefix("https://"))")
        let session = AVAudioSession.sharedInstance()
        print("[AudioPlayer] AVAudioSession category: \(session.category.rawValue), active: \(session.isOtherAudioPlaying ? "other audio playing" : "ok")")

        do {
            let url = try await SupabaseService.shared.client.storage
                .from("audio")
                .createSignedURL(path: clip.audio_url, expiresIn: 3600)
            print("[AudioPlayer] signed URL: \(url.absoluteString)")

            let item = AVPlayerItem(url: url)
            if player == nil {
                player = AVPlayer(playerItem: item)
            } else {
                player?.replaceCurrentItem(with: item)
            }

            installTimeObserver()
            observeItemEnd()
            observeItemStatus(item)

            isLoading = false
            await BeepToneService.shared.play(clip.authorBeepTone)
            player?.play()
            isPlaying = true
            incrementPlayCount(for: clip)
            markAsListened(clip)

            // Fetch duration then update lock screen info
            if let asset = player?.currentItem?.asset {
                let d = try await asset.load(.duration)
                duration = CMTimeGetSeconds(d)
            }
            updateNowPlayingInfo()
        } catch {
            print("[AudioPlayer] ❌ playCurrentClip error: \(error.localizedDescription)")
            if let nsErr = error as NSError? {
                print("[AudioPlayer] ❌ NSError domain=\(nsErr.domain) code=\(nsErr.code) userInfo=\(nsErr.userInfo)")
            }
            isLoading = false
            isPlaying = false
        }
    }

    private func observeItemStatus(_ item: AVPlayerItem) {
        itemStatusObserver = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                switch status {
                case .readyToPlay:
                    print("[AudioPlayer] AVPlayerItem status: .readyToPlay ✓")
                case .failed:
                    let err = item.error
                    print("[AudioPlayer] AVPlayerItem status: .failed ❌")
                    print("[AudioPlayer] item.error: \(err?.localizedDescription ?? "nil")")
                    if let nsErr = err as NSError? {
                        print("[AudioPlayer] NSError domain=\(nsErr.domain) code=\(nsErr.code)")
                        print("[AudioPlayer] userInfo=\(nsErr.userInfo)")
                    }
                    Task { @MainActor [weak self] in
                        self?.isPlaying = false
                        self?.isLoading = false
                    }
                case .unknown:
                    print("[AudioPlayer] AVPlayerItem status: .unknown (still loading…)")
                @unknown default:
                    break
                }
            }
    }

    // MARK: - Lock screen / remote controls

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.resume() }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.pause() }
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.skipForward() }
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.skipBack() }
            return .success
        }

        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.skip(by: 10) }
            return .success
        }

        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.skip(by: -10) }
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let self, self.duration > 0 else { return }
                self.seek(to: e.positionTime / self.duration)
            }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let clip = currentClip else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        let title  = clip.title?.isEmpty == false ? clip.title! : "Voice clip"
        let artist = "@\(clip.username)"

        var info: [String: Any] = [
            MPMediaItemPropertyTitle:                 title,
            MPMediaItemPropertyArtist:               artist,
            MPMediaItemPropertyPlaybackDuration:     duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate:    isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType:       MPNowPlayingInfoMediaType.audio.rawValue,
        ]

        if let loc = clip.location_display {
            info[MPMediaItemPropertyAlbumTitle] = loc
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Observers

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player?.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let cur = CMTimeGetSeconds(time)
            Task { await MainActor.run {
                guard let item = self.player?.currentItem else { return }
                let dur = CMTimeGetSeconds(item.duration)
                guard dur.isFinite, dur > 0 else { return }
                self.currentTime = cur
                self.progress = cur / dur
                // Keep lock screen elapsed time in sync
                if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = cur
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
            }}
        }
    }

    private func observeItemEnd() {
        endObserver = NotificationCenter.default
            .publisher(for: .AVPlayerItemDidPlayToEndTime, object: player?.currentItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    if self.currentIndex < self.queue.count - 1 {
                        self.currentIndex += 1
                        await self.playCurrentClip()
                    } else if let onQueueExhausted = self.onQueueExhausted {
                        // Drive mode: ask for a freshly-fetched queue instead of stopping.
                        self.isPlaying = false
                        await onQueueExhausted()
                    } else {
                        self.isPlaying = false
                        self.progress = 1
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                    }
                }
            }
    }

    // MARK: - Listen history

    private func markAsListened(_ clip: Clip) {
        guard !listenedClipIDs.contains(clip.id) else { return }
        listenedClipIDs.insert(clip.id)
        Self.listenedStore.insert(clip.id)

        Task {
            guard let uid = try? await SupabaseService.shared.client.auth.session.user.id else {
                print("[AudioPlayer] markAsListened: no auth session — skipping clip_plays upsert")
                return
            }
            struct PlayInsert: Encodable { let user_id: UUID; let clip_id: UUID }
            do {
                try await SupabaseService.shared.client
                    .from("clip_plays")
                    .upsert(PlayInsert(user_id: uid, clip_id: clip.id), onConflict: "user_id,clip_id")
                    .execute()
                print("[AudioPlayer] markAsListened: recorded play for clip \(clip.id)")
            } catch {
                print("[AudioPlayer] markAsListened: clip_plays upsert FAILED — \(error)")
            }
        }
    }

    // MARK: - Play count

    private func incrementPlayCount(for clip: Clip) {
        guard currentIndex >= 0, currentIndex < queue.count else { return }
        queue[currentIndex] = Clip(
            id: clip.id,
            user_id: clip.user_id,
            audio_url: clip.audio_url,
            lat: clip.lat,
            lng: clip.lng,
            created_at: clip.created_at,
            play_count: clip.play_count + 1,
            like_count: clip.like_count,
            reply_count: clip.reply_count,
            duration_seconds: clip.duration_seconds,
            title: clip.title,
            transcript: clip.transcript,
            location_display: clip.location_display,
            rawUsername: clip.rawUsername,
            profiles: clip.profiles
        )

        Task {
            _ = try? await SupabaseService.shared.client
                .from("clips")
                .update(["play_count": clip.play_count + 1])
                .eq("id", value: clip.id.uuidString)
                .execute()
        }
    }

    private func tearDownObservers() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        endObserver = nil
        itemStatusObserver = nil
    }
}
