import AVFoundation
import Combine
import Supabase
import SwiftUI

// MARK: - ViewModel

@MainActor
final class DirectMessageViewModel: NSObject, ObservableObject {
    let recipientId: UUID
    let recipientUsername: String
    let replyToId: UUID?
    var onSent: (() -> Void)?

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

    private static let maxDuration: TimeInterval = 120
    private var timeRemaining: TimeInterval = 120
    private var audioRecorder: AVAudioRecorder?
    private let audioEngine = AVAudioEngine()
    private var recordingURL: URL?
    private var countdownTimer: AnyCancellable?
    private var previewPlayer: AVAudioPlayer?
    private var previewTimer: AnyCancellable?

    var timeRemainingString: String {
        let secs = Int(timeRemaining)
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    init(recipientId: UUID, recipientUsername: String, replyToId: UUID? = nil) {
        self.recipientId = recipientId
        self.recipientUsername = recipientUsername
        self.replyToId = replyToId
        super.init()
    }

    // MARK: - Public

    func toggleRecording() {
        if isRecording || isPaused { stopRecording() } else { startRecording() }
    }

    func pauseRecording() {
        guard isRecording, !isPaused else { return }
        audioRecorder?.pause(); countdownTimer?.cancel(); countdownTimer = nil; stopEngine(); isPaused = true
    }

    func resumeRecording() {
        guard isPaused else { return }
        audioRecorder?.record(); startEngineForWaveform(); resumeCountdown(); isPaused = false
    }

    func postNow() {
        guard isRecording || isPaused else { return }
        stopRecording()
    }

    func togglePreviewPlayback() {
        guard let player = previewPlayer else { return }
        if player.isPlaying {
            player.pause(); previewTimer?.cancel(); isPlayingPreview = false
        } else {
            if previewProgress >= 1.0 { player.currentTime = 0; previewProgress = 0 }
            player.play(); isPlayingPreview = true; startPreviewTimer()
        }
    }

    func discardAndReRecord() {
        stopPreviewPlayer()
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        resetToIdle()
    }

    func confirmSend() {
        stopPreviewPlayer()
        guard let url = recordingURL else { return }
        uploadMessage(url: url)
    }

    func cancelRecording() {
        countdownTimer?.cancel(); countdownTimer = nil
        audioRecorder?.stop(); stopEngine()
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        resetToIdle()
    }

    func cleanup() {
        if isRecording || isPaused { cancelRecording(); return }
        if isPreviewingRecording {
            stopPreviewPlayer()
            if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
            recordingURL = nil
        }
    }

    // MARK: - Recording

    private func startRecording() {
        Task {
            guard await requestMicPermission() else { showPermissionAlert = true; return }
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try session.setActive(true)
            } catch { statusMessage = "Audio session error: \(error.localizedDescription)"; return }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
            recordingURL = url
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 22_050,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            do {
                audioRecorder = try AVAudioRecorder(url: url, settings: settings)
                audioRecorder?.isMeteringEnabled = true
                audioRecorder?.record(forDuration: Self.maxDuration)
            } catch { statusMessage = "Recorder error: \(error.localizedDescription)"; return }
            startEngineForWaveform(); startCountdown()
            statusMessage = nil; uploadFailed = false; isRecording = true
        }
    }

    private func stopRecording() {
        isRecording = false; isPaused = false
        countdownTimer?.cancel(); countdownTimer = nil
        audioRecorder?.stop(); stopEngine()
        guard recordingURL != nil else { return }
        setupPreviewPlayer(); isPreviewingRecording = true
    }

    private func resetToIdle() {
        isRecording = false; isPaused = false; isUploading = false
        isPreviewingRecording = false; isPlayingPreview = false; previewProgress = 0
        statusMessage = nil; uploadFailed = false
        timeRemaining = Self.maxDuration; progress = 1.0
        waveformSamples = Array(repeating: 0.05, count: 60)
        audioRecorder = nil; recordingURL = nil
    }

    // MARK: - Preview

    private func setupPreviewPlayer() {
        guard let url = recordingURL else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            previewPlayer = try AVAudioPlayer(contentsOf: url)
            previewPlayer?.prepareToPlay(); previewProgress = 0
            previewPlayer?.play(); isPlayingPreview = true; startPreviewTimer()
        } catch { statusMessage = "Could not load preview: \(error.localizedDescription)" }
    }

    private func startPreviewTimer() {
        previewTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard let self, let player = self.previewPlayer else { return }
                if player.isPlaying {
                    self.previewProgress = player.currentTime / max(player.duration, 0.001)
                } else {
                    self.isPlayingPreview = false; self.previewProgress = 1.0; self.previewTimer?.cancel()
                }
            }
    }

    private func stopPreviewPlayer() {
        previewTimer?.cancel(); previewTimer = nil
        previewPlayer?.stop(); previewPlayer = nil
        isPlayingPreview = false; previewProgress = 0; isPreviewingRecording = false
    }

    // MARK: - Waveform

    private func startEngineForWaveform() {
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let rms = Self.rmsLevels(from: buffer, count: 60)
            Task { @MainActor in self.waveformSamples = rms }
        }
        try? audioEngine.start()
    }

    private func stopEngine() {
        if audioEngine.isRunning { audioEngine.inputNode.removeTap(onBus: 0); audioEngine.stop() }
        waveformSamples = Array(repeating: 0.05, count: 60)
    }

    private static func rmsLevels(from buffer: AVAudioPCMBuffer, count: Int) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return Array(repeating: 0.05, count: count) }
        let frameCount = Int(buffer.frameLength); let chunkSize = max(1, frameCount / count)
        return (0..<count).map { i in
            let start = i * chunkSize, end = min(start + chunkSize, frameCount)
            guard end > start else { return 0.05 }
            let slice = UnsafeBufferPointer(start: channel.advanced(by: start), count: end - start)
            let rms = sqrt(slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count))
            return min(max(rms * 3, 0.05), 1.0)
        }
    }

    // MARK: - Countdown

    private func startCountdown() { timeRemaining = Self.maxDuration; progress = 1.0; resumeCountdown() }

    private func resumeCountdown() {
        countdownTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.timeRemaining -= 0.25
                self.progress = max(0, self.timeRemaining / Self.maxDuration)
                if self.timeRemaining <= 0 { self.stopRecording() }
            }
    }

    // MARK: - Upload

    private func uploadMessage(url: URL) {
        isUploading = true; statusMessage = nil
        Task {
            do {
                let data = try Data(contentsOf: url)
                let fileName = "\(UUID().uuidString).m4a"
                let elapsed = Self.maxDuration - timeRemaining
                let durationSeconds = max(1, Int(elapsed))
                let session = try await SupabaseService.shared.client.auth.session
                let senderId = session.user.id

                _ = try await SupabaseService.shared.client.storage
                    .from("audio")
                    .upload(fileName, data: data, options: FileOptions(contentType: "audio/mp4"))

                struct DMInsert: Encodable {
                    let sender_id: UUID; let recipient_id: UUID
                    let audio_url: String; let duration_seconds: Int; let reply_to_id: UUID?
                }
                try await SupabaseService.shared.client
                    .from("direct_messages")
                    .insert(DMInsert(sender_id: senderId, recipient_id: recipientId,
                                     audio_url: fileName, duration_seconds: durationSeconds,
                                     reply_to_id: replyToId))
                    .execute()

                try? FileManager.default.removeItem(at: url)
                isUploading = false; uploadFailed = false; statusMessage = "Sent!"
                Task { try? await Task.sleep(nanoseconds: 1_500_000_000); self.onSent?() }
            } catch {
                try? FileManager.default.removeItem(at: url)
                isUploading = false; uploadFailed = true
                statusMessage = "Failed to send: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Permission

    private func requestMicPermission() async -> Bool {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
            }
        @unknown default: return false
        }
    }
}

// MARK: - View

struct DirectMessageRecordingView: View {
    @StateObject private var vm: DirectMessageViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showCancelAlert = false

    private var isActive: Bool { vm.isRecording || vm.isPaused }
    private var isPreview: Bool { vm.isPreviewingRecording }

    init(recipientId: UUID, recipientUsername: String, replyToId: UUID? = nil, onSent: @escaping () -> Void) {
        let viewModel = DirectMessageViewModel(recipientId: recipientId, recipientUsername: recipientUsername, replyToId: replyToId)
        viewModel.onSent = onSent
        _vm = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 20) {
            Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 36, height: 4).padding(.top, 12)

            VStack(spacing: 2) {
                Text(isPreview ? "Review your message" : "Voice Message")
                    .font(.headline.bold())
                Text("to @\(vm.recipientUsername)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .animation(.easeInOut(duration: 0.2), value: isPreview)

            Spacer(minLength: 0)

            if isPreview { previewContent } else { recordingContent }

            Group {
                if vm.isUploading {
                    HStack(spacing: 8) { ProgressView(); Text("Sending…").font(.subheadline).foregroundStyle(.secondary) }
                } else if let msg = vm.statusMessage {
                    Text(msg).font(.subheadline.bold())
                        .foregroundStyle(vm.uploadFailed ? .red : AppTheme.gold)
                        .multilineTextAlignment(.center).padding(.horizontal, 32)
                }
            }
            .frame(height: 32).animation(.easeInOut, value: vm.statusMessage)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity)
        .background(AppTheme.canvasBlack.ignoresSafeArea())
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isPreview)
        .onChange(of: isActive) { active in UIApplication.shared.isIdleTimerDisabled = active }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; vm.cleanup() }
        .alert("Microphone Access", isPresented: $vm.showPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Voices needs microphone access. Enable it in Settings.") }
        .confirmationDialog("Discard this message?", isPresented: $showCancelAlert, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { vm.cancelRecording(); dismiss() }
            Button("Keep Recording", role: .cancel) {}
        } message: { Text("The recording will be permanently deleted.") }
    }

    @ViewBuilder
    private var recordingContent: some View {
        WaveformView(samples: vm.waveformSamples)
            .frame(height: 60).padding(.horizontal, 24)
            .opacity(vm.isRecording && !vm.isPaused ? 1 : 0.3)
            .animation(.easeInOut(duration: 0.3), value: vm.isRecording && !vm.isPaused)

        CountdownBarView(progress: vm.progress).frame(height: 6).padding(.horizontal, 24)

        Text(vm.timeRemainingString)
            .font(.system(.title3, design: .monospaced).bold())
            .foregroundStyle(vm.isPaused ? AppTheme.gold : vm.isRecording ? AppTheme.rust : .secondary)
            .animation(.easeInOut(duration: 0.2), value: vm.isPaused)

        HStack(spacing: 28) {
            if isActive {
                Button { vm.isPaused ? vm.resumeRecording() : vm.pauseRecording() } label: {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.08)).frame(width: 56, height: 56)
                            .overlay(Circle().stroke(AppTheme.gold.opacity(0.5), lineWidth: 1.5))
                        Image(systemName: vm.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 20, weight: .semibold)).foregroundStyle(AppTheme.gold)
                    }
                }
                .buttonStyle(.plain).transition(.scale.combined(with: .opacity))
            }
            Button { vm.toggleRecording() } label: {
                ZStack {
                    Circle().fill(isActive ? Color.red : AppTheme.rust).frame(width: 80, height: 80)
                        .shadow(color: (isActive ? Color.red : AppTheme.rust).opacity(0.4), radius: 12, x: 0, y: 6)
                    Image(systemName: isActive ? "stop.fill" : "mic.fill")
                        .font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain).disabled(vm.isUploading)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isActive)

        if isActive {
            HStack(spacing: 40) {
                Button("Cancel") { showCancelAlert = true }
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Button("Send Now") { vm.postNow() }
                    .font(.subheadline.weight(.bold)).foregroundStyle(AppTheme.gold)
                    .disabled(vm.isUploading)
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(AppTheme.gold)
                    .frame(width: geo.size.width * CGFloat(vm.previewProgress))
                    .animation(.linear(duration: 0.05), value: vm.previewProgress)
            }
        }
        .frame(height: 4).padding(.horizontal, 24)

        Button { vm.togglePreviewPlayback() } label: {
            ZStack {
                Circle().fill(AppTheme.rust).frame(width: 80, height: 80)
                    .shadow(color: AppTheme.rust.opacity(0.4), radius: 12, x: 0, y: 6)
                Image(systemName: vm.isPlayingPreview ? "pause.fill" : "play.fill")
                    .font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)

        HStack(spacing: 40) {
            Button("Re-record") { vm.discardAndReRecord() }
                .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Button("Send") { vm.confirmSend() }
                .font(.subheadline.weight(.bold)).foregroundStyle(AppTheme.gold)
                .disabled(vm.isUploading)
        }
    }
}
