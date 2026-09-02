import Foundation
import CoreLocation

struct ClipDraft {
    let audioURL: URL
    let lat: Double?
    let lng: Double?
    let durationSeconds: Int
    let includeLocation: Bool
    let channelId: UUID?
    let locationDisplay: String?

    var location: CLLocation? {
        guard let lat, let lng else { return nil }
        return CLLocation(latitude: lat, longitude: lng)
    }
}

final class ClipDraftStore {
    static let shared = ClipDraftStore()
    private init() {}

    private let metadataKey = "clip_draft_metadata_v1"

    private var audioFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("clip_draft.m4a")
    }

    var hasDraft: Bool {
        FileManager.default.fileExists(atPath: audioFileURL.path) &&
        UserDefaults.standard.data(forKey: metadataKey) != nil
    }

    func save(audioURL: URL, lat: Double?, lng: Double?, durationSeconds: Int,
              includeLocation: Bool, channelId: UUID?, locationDisplay: String?) throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let dest = audioFileURL
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: audioURL, to: dest)

        struct Meta: Codable {
            let lat: Double?
            let lng: Double?
            let durationSeconds: Int
            let includeLocation: Bool
            let channelId: String?
            let locationDisplay: String?
        }
        let meta = Meta(lat: lat, lng: lng, durationSeconds: durationSeconds,
                        includeLocation: includeLocation,
                        channelId: channelId?.uuidString,
                        locationDisplay: locationDisplay)
        UserDefaults.standard.set(try JSONEncoder().encode(meta), forKey: metadataKey)
    }

    func load() -> ClipDraft? {
        guard hasDraft, let data = UserDefaults.standard.data(forKey: metadataKey) else { return nil }
        struct Meta: Codable {
            let lat: Double?
            let lng: Double?
            let durationSeconds: Int
            let includeLocation: Bool
            let channelId: String?
            let locationDisplay: String?
        }
        guard let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return nil }
        return ClipDraft(
            audioURL: audioFileURL,
            lat: meta.lat, lng: meta.lng,
            durationSeconds: meta.durationSeconds,
            includeLocation: meta.includeLocation,
            channelId: meta.channelId.flatMap { UUID(uuidString: $0) },
            locationDisplay: meta.locationDisplay
        )
    }

    func clear() {
        try? FileManager.default.removeItem(at: audioFileURL)
        UserDefaults.standard.removeObject(forKey: metadataKey)
    }
}
