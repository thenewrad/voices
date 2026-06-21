import SwiftUI

@available(iOS 17.0, *)
struct RecordView: View {
    @StateObject private var vm: RecordingViewModel
    @State private var showCancelAlert = false
    @Environment(\.dismiss) private var dismiss

    private let channelName: String?

    init(channelId: UUID? = nil, channelName: String? = nil) {
        _vm = StateObject(wrappedValue: RecordingViewModel(channelId: channelId))
        self.channelName = channelName
    }

    private var isActive: Bool { vm.isRecording || vm.isPaused }
    private var isPreview: Bool { vm.isPreviewingRecording }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                recordHeader

                VStack(spacing: 28) {
                    Spacer()

                    if isPreview {
                        previewContent
                    } else {
                        recordingContent
                    }

                    Spacer()
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isPreview)
            }
            .background(AppTheme.canvasBlack.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.canvasBlack, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if isActive {
                            showCancelAlert = true
                        } else if isPreview {
                            vm.discardAndReRecord()
                            dismiss()
                        } else {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .onChange(of: vm.statusMessage) { msg in
                if msg == "Posted!" {
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        dismiss()
                    }
                }
            }
            .onChange(of: isActive) { active in
                UIApplication.shared.isIdleTimerDisabled = active
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
                vm.cleanup()
            }
            .alert("Microphone Access", isPresented: $vm.showPermissionAlert) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Voices needs microphone access to record. Enable it in Settings.")
            }
            .confirmationDialog(
                "Discard this recording?",
                isPresented: $showCancelAlert,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) { vm.cancelRecording(); dismiss() }
                Button("Keep Recording", role: .cancel) {}
            } message: {
                Text("The recording will be permanently deleted.")
            }
        }
    }

    // MARK: - Recording UI

    @ViewBuilder
    private var recordingContent: some View {
        WaveformView(samples: vm.waveformSamples)
            .frame(height: 80)
            .padding(.horizontal, 24)
            .opacity(vm.isRecording && !vm.isPaused ? 1 : 0.3)
            .animation(.easeInOut(duration: 0.3), value: vm.isRecording && !vm.isPaused)

        CountdownBarView(progress: vm.progress)
            .frame(height: 8)
            .padding(.horizontal, 24)

        Text(vm.timeRemainingString)
            .font(.system(.title3, design: .monospaced).bold())
            .foregroundStyle(
                vm.isPaused ? AppTheme.gold :
                vm.isRecording ? AppTheme.rust : .secondary
            )
            .animation(.easeInOut(duration: 0.2), value: vm.isPaused)

        HStack(spacing: 28) {
            if isActive {
                Button {
                    vm.isPaused ? vm.resumeRecording() : vm.pauseRecording()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 64, height: 64)
                            .overlay(Circle().stroke(AppTheme.gold.opacity(0.5), lineWidth: 1.5))
                        Image(systemName: vm.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(AppTheme.gold)
                    }
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }

            Button { vm.toggleRecording() } label: {
                ZStack {
                    Circle()
                        .fill(isActive ? Color.red : AppTheme.rust)
                        .frame(width: 88, height: 88)
                        .shadow(
                            color: (isActive ? Color.red : AppTheme.rust).opacity(0.4),
                            radius: 12, x: 0, y: 6
                        )
                    Image(systemName: isActive ? "stop.fill" : "mic.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .scaleEffect(vm.isRecording && !vm.isPaused ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: vm.isRecording)
            .disabled(vm.isUploading)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isActive)

        if isActive {
            HStack(spacing: 40) {
                Button("Cancel") { showCancelAlert = true }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Button("Post Now") { vm.postNow() }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppTheme.gold)
                    .disabled(vm.isUploading)
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }

        Group {
            if vm.isUploading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Uploading…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if let msg = vm.statusMessage {
                Text(msg)
                    .font(.subheadline.bold())
                    .foregroundStyle(vm.uploadFailed ? .red : AppTheme.gold)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(height: 32)
        .animation(.easeInOut, value: vm.statusMessage)
    }

    // MARK: - Preview UI

    @ViewBuilder
    private var previewContent: some View {
        Text("Review your clip")
            .font(.title3.bold())
            .foregroundStyle(.white)

        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(AppTheme.gold)
                    .frame(width: geo.size.width * CGFloat(vm.previewProgress))
                    .animation(.linear(duration: 0.05), value: vm.previewProgress)
            }
        }
        .frame(height: 4)
        .padding(.horizontal, 24)

        Button { vm.togglePreviewPlayback() } label: {
            ZStack {
                Circle()
                    .fill(AppTheme.rust)
                    .frame(width: 88, height: 88)
                    .shadow(color: AppTheme.rust.opacity(0.4), radius: 12, x: 0, y: 6)
                Image(systemName: vm.isPlayingPreview ? "pause.fill" : "play.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)

        HStack(spacing: 40) {
            Button("Re-record") { vm.discardAndReRecord() }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            Button("Post") { vm.confirmPost() }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppTheme.gold)
                .disabled(vm.isUploading)
        }

        Group {
            if vm.isUploading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Uploading…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if let msg = vm.statusMessage {
                Text(msg)
                    .font(.subheadline.bold())
                    .foregroundStyle(vm.uploadFailed ? .red : AppTheme.gold)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(height: 32)
        .animation(.easeInOut, value: vm.statusMessage)
    }

    // MARK: - Header

    private var recordHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(channelName.map { "Post to \($0)" } ?? "Drop a Vox")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
            Text(channelName != nil
                ? "This clip will be posted to the channel."
                : "Post what's on your mind. Your posts will be tagged to the place you dropped it for others to find.")
                .font(.footnote)
                .foregroundStyle(AppTheme.gold)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Text("Turn on to add your post to the discovery map")
                    .font(.footnote)
                    .foregroundStyle(vm.includeLocation ? .primary : .secondary)
                Spacer()
                Toggle("", isOn: $vm.includeLocation)
                    .labelsHidden()
                    .tint(AppTheme.gold)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .background(AppTheme.canvasBlack)
        .overlay(alignment: .bottom) {
            Divider().overlay(Color(hex: "3A2820"))
        }
    }
}

// MARK: - Waveform view

struct WaveformView: View {
    let samples: [Float]

    var body: some View {
        GeometryReader { geo in
            let barCount = Int(geo.size.width / 4)
            let displaySamples = resample(samples, to: barCount)

            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(displaySamples.enumerated()), id: \.offset) { _, sample in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(AppTheme.gradient)
                        .frame(width: 2, height: max(4, CGFloat(sample) * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func resample(_ input: [Float], to count: Int) -> [Float] {
        guard count > 0 else { return [] }
        if input.isEmpty { return Array(repeating: 0.05, count: count) }
        return (0..<count).map { i in
            let idx = Float(i) / Float(count) * Float(input.count)
            let lo = Int(idx)
            let hi = min(lo + 1, input.count - 1)
            let frac = idx - Float(lo)
            return input[lo] * (1 - frac) + input[hi] * frac
        }
    }
}

// MARK: - Countdown bar

struct CountdownBarView: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))

                RoundedRectangle(cornerRadius: 4)
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
        }
    }
}

#Preview {
    if #available(iOS 17.0, *) {
        RecordView()
    }
}
