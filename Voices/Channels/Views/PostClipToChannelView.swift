import SwiftUI

/// Lets a creator/mod/admin pick one of their own clips and post it to a channel.
struct PostClipToChannelView: View {
    @Environment(\.dismiss) private var dismiss

    let channelId: UUID
    let onPosted: () -> Void

    @State private var myClips: [ClipDetail] = []
    @State private var selectedClipId: UUID?
    @State private var isLoading = false
    @State private var isPosting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if myClips.isEmpty {
                    ChannelEmptyState(
                        title: "No clips yet",
                        systemImage: "waveform",
                        description: "Record a clip first, then post it to a channel."
                    )
                } else {
                    List(myClips, selection: $selectedClipId) { clip in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(clip.title.isEmpty ? "Untitled clip" : clip.title)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text(clip.durationSeconds.formattedDuration)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedClipId == clip.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(AppTheme.gold)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selectedClipId = clip.id }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Post a Clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") { Task { await post() } }
                        .disabled(selectedClipId == nil || isPosting)
                        .overlay {
                            if isPosting { ProgressView().scaleEffect(0.7) }
                        }
                }
            }
            .task { await loadMyClips() }
            .alert("Error", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func loadMyClips() async {
        guard let userId = SupabaseService.shared.client.auth.currentUser?.id else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            myClips = try await SupabaseService.shared.client
                .from("clips")
                .select("id, audio_url, duration_seconds, title, transcript, play_count, like_count, created_at")
                .eq("user_id", value: userId)
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func post() async {
        guard let clipId = selectedClipId else { return }
        isPosting = true
        defer { isPosting = false }
        do {
            try await ChannelService.shared.postClipToChannel(channelId: channelId, clipId: clipId)
            onPosted()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
