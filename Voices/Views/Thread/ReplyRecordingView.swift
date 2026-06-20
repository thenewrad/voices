import SwiftUI

struct ReplyRecordingView: View {
    @StateObject private var vm: ReplyRecordingViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showCancelAlert = false

    private var isActive: Bool { vm.isRecording || vm.isPaused }
    private var isPreview: Bool { vm.isPreviewingRecording }

    init(clipId: UUID, replyToUserId: UUID? = nil, replyToUsername: String? = nil, onPosted: @escaping () -> Void) {
        let viewModel = ReplyRecordingViewModel(clipId: clipId, replyToUserId: replyToUserId, replyToUsername: replyToUsername)
        viewModel.onPosted = onPosted
        _vm = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 20) {
            // Drag handle
            Capsule()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 12)

            VStack(spacing: 2) {
                Text(isPreview ? "Review your reply" : "Reply")
                    .font(.headline.bold())
                if let target = vm.replyToUsername, !isPreview {
                    Text("replying to @\(target)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isPreview)

            Spacer(minLength: 0)

            if isPreview {
                previewContent
            } else {
                recordingContent
            }

            // Status / upload indicator
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

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity)
        .background(AppTheme.canvasBlack.ignoresSafeArea())
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isPreview)
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
            Text("Voices needs microphone access to record replies. Enable it in Settings.")
        }
        .confirmationDialog(
            "Discard this reply?",
            isPresented: $showCancelAlert,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                vm.cancelRecording()
                dismiss()
            }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text("The recording will be permanently deleted.")
        }
    }

    // MARK: - Recording UI

    @ViewBuilder
    private var recordingContent: some View {
        WaveformView(samples: vm.waveformSamples)
            .frame(height: 60)
            .padding(.horizontal, 24)
            .opacity(vm.isRecording && !vm.isPaused ? 1 : 0.3)
            .animation(.easeInOut(duration: 0.3), value: vm.isRecording && !vm.isPaused)

        CountdownBarView(progress: vm.progress)
            .frame(height: 6)
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
                            .frame(width: 56, height: 56)
                            .overlay(Circle().stroke(AppTheme.gold.opacity(0.5), lineWidth: 1.5))
                        Image(systemName: vm.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 20, weight: .semibold))
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
                        .frame(width: 80, height: 80)
                        .shadow(
                            color: (isActive ? Color.red : AppTheme.rust).opacity(0.4),
                            radius: 12, x: 0, y: 6
                        )
                    Image(systemName: isActive ? "stop.fill" : "mic.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(vm.isUploading)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isActive)

        if isActive {
            HStack(spacing: 40) {
                Button("Cancel") { showCancelAlert = true }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Button("Post") { vm.postNow() }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppTheme.gold)
                    .disabled(vm.isUploading)
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    // MARK: - Preview UI

    @ViewBuilder
    private var previewContent: some View {
        // Playback progress bar
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

        // Play / pause
        Button { vm.togglePreviewPlayback() } label: {
            ZStack {
                Circle()
                    .fill(AppTheme.rust)
                    .frame(width: 80, height: 80)
                    .shadow(color: AppTheme.rust.opacity(0.4), radius: 12, x: 0, y: 6)
                Image(systemName: vm.isPlayingPreview ? "pause.fill" : "play.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)

        // Re-record / Post
        HStack(spacing: 40) {
            Button("Re-record") { vm.discardAndReRecord() }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            Button("Post") { vm.confirmPost() }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppTheme.gold)
                .disabled(vm.isUploading)
        }
    }
}
