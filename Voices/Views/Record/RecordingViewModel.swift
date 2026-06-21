import AVFoundation
import CoreLocation
import Combine
import Supabase
import SwiftUI

@available(iOS 17.0, *)
@MainActor
final class RecordingViewModel: NSObject, ObservableObject {

    // MARK: - Published state

    @Published var isRecording = false
    @Published var isPaused = false
    @Published var isUploading = false
    @Published var isPreviewingRecording = false
    @Published var isPlayingPreview = false
    @Published var previewProgress: Double = 0
    @Published var waveformSamples: [Float] = Array(repeating: 0.05, count: 60)
    @Published var progress: Double = 1.0
    @Published var statusMessage: String? = nil
    @Published var uploadFailed = false
    @Published var showPermissionAlert = false
    @Published var includeLocation = UserDefaults.standard.object(forKey: "includeLocationByDefault") as? Bool ?? true

    var timeRemainingString: String {
        let secs = Int(timeRemaining)
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    // MARK: - Private

    private static let maxDuration: TimeInterval = 120
    private var timeRemaining: TimeInterval = 120

    private var audioRecorder: AVAudioRecorder?
    private let audioEngine = AVAudioEngine()
    private var recordingURL: URL?

    private var countdownTimer: AnyCancellable?
    private var previewPlayer: AVAudioPlayer?
    private var previewTimer: AnyCancellable?

    // Tracks player state so we can restore it after recording
    private var playerWasPlaying = false
    private var playbackRestored = false

    private let locationManager = CLLocationManager()
    private var lastLocation: CLLocation?

    /// When set, the posted clip is also attached to this channel.
    private let channelId: UUID?

    // MARK: - Init

    init(channelId: UUID? = nil) {
        self.channelId = channelId
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.requestWhenInUseAuthorization()
    }

    // MARK: - Public

    func toggleRecording() {
        if isRecording || isPaused { stopRecording() } else { startRecording() }
    }

    func pauseRecording() {
        guard isRecording, !isPaused else { return }
        audioRecorder?.pause()
        countdownTimer?.cancel()
        countdownTimer = nil
        stopEngine()
        isPaused = true
    }

    func resumeRecording() {
        guard isPaused else { return }
        audioRecorder?.record()
        startEngineForWaveform()
        resumeCountdown()
        isPaused = false
    }

    func postNow() {
        guard isRecording || isPaused else { return }
        stopRecording()
    }

    func togglePreviewPlayback() {
        guard let player = previewPlayer else { return }
        if player.isPlaying {
            player.pause()
            previewTimer?.cancel()
            isPlayingPreview = false
        } else {
            if previewProgress >= 1.0 { player.currentTime = 0; previewProgress = 0 }
            player.play()
            isPlayingPreview = true
            startPreviewTimer()
        }
    }

    func discardAndReRecord() {
        stopPreviewPlayer()
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        resetToIdle()
    }

    func confirmPost() {
        stopPreviewPlayer()
        guard let url = recordingURL else { return }
        uploadClip(url: url)
    }

    func cancelRecording() {
        countdownTimer?.cancel()
        countdownTimer = nil
        audioRecorder?.stop()
        stopEngine()
        locationManager.stopUpdatingLocation()
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        restorePlaybackSession()
        resetToIdle()
    }

    // MARK: - Start

    private func startRecording() {
        Task {
            guard await requestMicPermission() else {
                showPermissionAlert = true
                return
            }

            // Pause any active playback before taking over the audio session
            playerWasPlaying = AudioPlayerService.shared.isPlaying
            playbackRestored = false
            AudioPlayerService.shared.pause()

            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: [.defaultToSpeaker, .allowBluetoothHFP])
                try session.setActive(true)
            } catch {
                statusMessage = "Audio session error: \(error.localizedDescription)"
                restorePlaybackSession()
                return
            }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4a")
            recordingURL = url

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 22_050,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]

            do {
                audioRecorder = try AVAudioRecorder(url: url, settings: settings)
                audioRecorder?.isMeteringEnabled = true
                audioRecorder?.record(forDuration: Self.maxDuration)
            } catch {
                statusMessage = "Recorder error: \(error.localizedDescription)"
                return
            }

            startEngineForWaveform()
            startCountdown()
            locationManager.startUpdatingLocation()

            statusMessage = nil
            uploadFailed = false
            isRecording = true
        }
    }

    // MARK: - Stop

    private func stopRecording() {
        isRecording = false
        isPaused = false
        countdownTimer?.cancel()
        countdownTimer = nil
        audioRecorder?.stop()
        stopEngine()
        locationManager.stopUpdatingLocation()
        // Don't restore playback session yet — preview needs audio too; upload/dismiss handles it

        guard recordingURL != nil else { return }
        setupPreviewPlayer()
        isPreviewingRecording = true
    }

    private func resetToIdle() {
        isRecording = false
        isPaused = false
        isUploading = false
        isPreviewingRecording = false
        isPlayingPreview = false
        previewProgress = 0
        statusMessage = nil
        uploadFailed = false
        timeRemaining = Self.maxDuration
        progress = 1.0
        waveformSamples = Array(repeating: 0.05, count: 60)
        audioRecorder = nil
        recordingURL = nil
    }

    // MARK: - Session management

    private func restorePlaybackSession() {
        guard !playbackRestored else { return }
        playbackRestored = true
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("RecordingViewModel: failed to restore playback session: \(error)")
        }
        if playerWasPlaying {
            AudioPlayerService.shared.resume()
        }
    }

    /// Called by RecordView.onDisappear to clean up if user navigates away mid-session.
    func cleanup() {
        if isRecording || isPaused { cancelRecording(); return }
        if isPreviewingRecording {
            stopPreviewPlayer()
            if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
            recordingURL = nil
        }
        restorePlaybackSession()
    }

    // MARK: - Preview playback

    private func setupPreviewPlayer() {
        guard let url = recordingURL else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            previewPlayer = try AVAudioPlayer(contentsOf: url)
            previewPlayer?.prepareToPlay()
            previewProgress = 0
            previewPlayer?.play()
            isPlayingPreview = true
            startPreviewTimer()
        } catch {
            statusMessage = "Could not load preview: \(error.localizedDescription)"
        }
    }

    private func startPreviewTimer() {
        previewTimer = Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let player = self.previewPlayer else { return }
                if player.isPlaying {
                    self.previewProgress = player.currentTime / max(player.duration, 0.001)
                } else {
                    self.isPlayingPreview = false
                    self.previewProgress = 1.0
                    self.previewTimer?.cancel()
                }
            }
    }

    private func stopPreviewPlayer() {
        previewTimer?.cancel()
        previewTimer = nil
        previewPlayer?.stop()
        previewPlayer = nil
        isPlayingPreview = false
        previewProgress = 0
        isPreviewingRecording = false
    }

    // MARK: - AVAudioEngine waveform tap

    private func startEngineForWaveform() {
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = Self.rmsLevels(from: buffer, count: 60)
            Task { @MainActor in
                self.waveformSamples = samples
            }
        }
        do {
            try audioEngine.start()
        } catch {
            // Waveform won't update, but recording continues — not fatal
        }
    }

    private func stopEngine() {
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        waveformSamples = Array(repeating: 0.05, count: 60)
    }

    private static func rmsLevels(from buffer: AVAudioPCMBuffer, count: Int) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else {
            return Array(repeating: 0.05, count: count)
        }
        let frameCount = Int(buffer.frameLength)
        let chunkSize = max(1, frameCount / count)
        return (0..<count).map { i in
            let start = i * chunkSize
            let end   = min(start + chunkSize, frameCount)
            guard end > start else { return 0.05 }
            let slice = UnsafeBufferPointer(start: channel.advanced(by: start), count: end - start)
            let rms = sqrt(slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count))
            return min(max(rms * 3, 0.05), 1.0)
        }
    }

    // MARK: - Countdown

    private func startCountdown() {
        timeRemaining = Self.maxDuration
        progress = 1.0
        resumeCountdown()
    }

    private func resumeCountdown() {
        countdownTimer = Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.timeRemaining -= 0.25
                self.progress = max(0, self.timeRemaining / Self.maxDuration)
                if self.timeRemaining <= 0 {
                    self.stopRecording()
                }
            }
    }

    // MARK: - Upload

    private func uploadClip(url: URL) {
        isUploading = true
        statusMessage = nil

        Task {
            do {
                let data = try Data(contentsOf: url)
                let fileName = "\(UUID().uuidString).m4a"
                let path = fileName

                let session = try await SupabaseService.shared.client.auth.session
                let userId = session.user.id

                let lat = includeLocation ? lastLocation?.coordinate.latitude : nil
                let lng = includeLocation ? lastLocation?.coordinate.longitude : nil
                let maxDuration = Self.maxDuration

                // Reverse geocode to city name — stored for display; exact coords never shown in UI
                var locationDisplay: String? = nil
                if let lat, let lng {
                    locationDisplay = await reverseGeocode(lat: lat, lng: lng)
                }

                let clipId = UUID()

                // Upload + DB insert both covered by 30-second timeout
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        _ = try await SupabaseService.shared.client.storage
                            .from("audio")
                            .upload(path, data: data, options: FileOptions(contentType: "audio/mp4"))

                        let remaining = await self.timeRemaining
                        let row = ClipInsert(id: clipId, user_id: userId, audio_url: path, lat: lat, lng: lng, duration_seconds: Int(maxDuration - remaining), location_display: locationDisplay, channel_id: self.channelId)
                        try await SupabaseService.shared.client
                            .from("clips")
                            .insert(row)
                            .execute()

                        if let channelId = self.channelId {
                            try await ChannelService.shared.postClipToChannel(channelId: channelId, clipId: clipId)
                        }
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                        throw URLError(.timedOut)
                    }
                    try await group.next()
                    group.cancelAll()
                }

                // Increment clip_count — non-fatal if the RPC fails
                struct IncrementParams: Encodable { let user_id: UUID }
                _ = try? await SupabaseService.shared.client
                    .rpc("increment_clip_count", params: IncrementParams(user_id: userId))
                    .execute()

                isUploading = false
                uploadFailed = false
                statusMessage = "Posted!"
                try? FileManager.default.removeItem(at: url)
                NotificationCenter.default.post(name: .clipPosted, object: nil)
                restorePlaybackSession()
                // Auto-reset to idle after 2 seconds
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self.resetToIdle()
                }

            } catch {
                isUploading = false
                uploadFailed = true
                statusMessage = "Upload failed: \(error.localizedDescription)"
                try? FileManager.default.removeItem(at: url)
                restorePlaybackSession()
            }
        }
    }

    // MARK: - Permission

    private func requestMicPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }
}

// MARK: - CLLocationManagerDelegate

@available(iOS 17.0, *)
extension RecordingViewModel: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in self.lastLocation = loc }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }
}

// MARK: - Supabase row model

private struct ClipInsert: Encodable {
    let id: UUID
    let user_id: UUID
    let audio_url: String
    let lat: Double?
    let lng: Double?
    let duration_seconds: Int
    let location_display: String?
    let channel_id: UUID?
}

@available(iOS 17.0, *)
extension RecordingViewModel {
    private func reverseGeocode(lat: Double, lng: Double) async -> String? {
        await withCheckedContinuation { continuation in
            CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lng)) { placemarks, _ in
                let p = placemarks?.first
                continuation.resume(returning: p?.locality ?? p?.administrativeArea ?? p?.country)
            }
        }
    }
}
