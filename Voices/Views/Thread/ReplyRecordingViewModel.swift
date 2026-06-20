import AVFoundation
import Combine
import Supabase
import SwiftUI

@MainActor
final class ReplyRecordingViewModel: NSObject, ObservableObject {

    let clipId: UUID
    let replyToUserId: UUID?
    let replyToUsername: String?
    var onPosted: (() -> Void)?

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

    // MARK: - Init

    init(clipId: UUID, replyToUserId: UUID? = nil, replyToUsername: String? = nil) {
        self.clipId = clipId
        self.replyToUserId = replyToUserId
        self.replyToUsername = replyToUsername
        super.init()
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
        uploadReply(url: url)
    }

    func cancelRecording() {
        countdownTimer?.cancel()
        countdownTimer = nil
        audioRecorder?.stop()
        stopEngine()
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        resetToIdle()
    }

    func cleanup() {
        if isRecording || isPaused { cancelRecording() }
        if isPreviewingRecording {
            stopPreviewPlayer()
            if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
            recordingURL = nil
        }
    }

    // MARK: - Start

    private func startRecording() {
        Task {
            guard await requestMicPermission() else {
                showPermissionAlert = true
                return
            }

            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: [.defaultToSpeaker, .allowBluetoothHFP])
                try session.setActive(true)
            } catch {
                statusMessage = "Audio session error: \(error.localizedDescription)"
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

    // MARK: - Preview playback

    private func setupPreviewPlayer() {
        guard let url = recordingURL else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            previewPlayer = try AVAudioPlayer(contentsOf: url)
            previewPlayer?.prepareToPlay()
            previewProgress = 0
            // Auto-play so the user hears their recording immediately
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
            Task { @MainActor in self.waveformSamples = samples }
        }
        try? audioEngine.start()
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
                if self.timeRemaining <= 0 { self.stopRecording() }
            }
    }

    // MARK: - Upload

    private func uploadReply(url: URL) {
        isUploading = true
        statusMessage = nil

        Task {
            print("ReplyRecording: starting upload for clip_id=\(clipId)")
            do {
                let data = try Data(contentsOf: url)
                let fileName = "\(UUID().uuidString).m4a"
                let elapsed = Self.maxDuration - self.timeRemaining
                let durationSeconds = max(1, Int(elapsed))

                let session = try await SupabaseService.shared.client.auth.session
                let userId = session.user.id
                print("ReplyRecording: authenticated as user_id=\(userId)")

                _ = try await SupabaseService.shared.client.storage
                    .from("audio")
                    .upload(fileName, data: data, options: FileOptions(contentType: "audio/mp4"))
                print("ReplyRecording: audio uploaded — audio_url=\(fileName)")

                struct ReplyInsert: Encodable {
                    let clip_id: UUID
                    let user_id: UUID
                    let audio_url: String
                    let duration_seconds: Int
                    let reply_to_user_id: UUID?
                    let reply_to_username: String?
                }
                print("ReplyRecording: inserting reply row — clip_id=\(clipId) user_id=\(userId) audio_url=\(fileName) duration=\(durationSeconds)s")
                try await SupabaseService.shared.client
                    .from("replies")
                    .insert(ReplyInsert(clip_id: clipId, user_id: userId,
                                        audio_url: fileName, duration_seconds: durationSeconds,
                                        reply_to_user_id: replyToUserId,
                                        reply_to_username: replyToUsername))
                    .execute()
                print("ReplyRecording: replies INSERT SUCCESS")

                let _ = try? await SupabaseService.shared.client
                    .rpc("increment_reply_count", params: ["p_clip_id": clipId.uuidString])
                    .execute()
                print("ReplyRecording: increment_reply_count RPC called for clip_id=\(clipId.uuidString)")

                isUploading = false
                uploadFailed = false
                statusMessage = "Reply posted!"
                try? FileManager.default.removeItem(at: url)

                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self.onPosted?()
                }

            } catch {
                isUploading = false
                uploadFailed = true
                statusMessage = "Upload failed: \(error.localizedDescription)"
                print("ReplyRecording: UPLOAD/INSERT FAILED — full error: \(error)")
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Permission

    private func requestMicPermission() async -> Bool {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:      return true
        case .denied:       return false
        case .undetermined:
            return await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
        @unknown default:   return false
        }
    }
}
