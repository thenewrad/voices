import Foundation

/// Central stop-all coordinator so only one audio source plays at a time.
/// Both AudioPlayerService and ReplyPlayerService call this before starting playback.
@MainActor
final class AudioCoordinator {
    static let shared = AudioCoordinator()
    private init() {}

    /// Call before starting a clip in AudioPlayerService.
    func clipPlayerWillStart() {
        ReplyPlayerService.shared.stop()
    }

    /// Call before starting any reply audio (ThreadView queue or ActivityView single).
    func replyPlayerWillStart() {
        AudioPlayerService.shared.pause()
    }
}
