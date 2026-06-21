import Foundation
import CoreLocation
import Combine

enum LocalFilter: CaseIterable {
    case new, listenedTo
    var label: String { self == .new ? "New" : "Listened To" }
}

@MainActor
final class LocalViewModel: NSObject, ObservableObject {

    // MARK: - Published

    @Published var clips: [Clip] = []
    @Published var outerClips: [Clip] = []
    @Published var userLocation: CLLocation?
    @Published var authStatus: CLAuthorizationStatus = .notDetermined
    @Published var isLoading = false
    @Published var isDriveMode = false
    @Published var error: String?
    @Published var filter: LocalFilter = .new
    @Published private(set) var listenedClipIDs: Set<UUID> = []
    @Published var radiusMiles: Double = 2.0
    @Published var radiusCenter: CLLocationCoordinate2D?

    // MARK: - Computed

    var filteredClips: [Clip] {
        switch filter {
        case .new:        return clips.filter { !listenedClipIDs.contains($0.id) }
        case .listenedTo: return clips.filter {  listenedClipIDs.contains($0.id) }
        }
    }

    var newClipCount: Int { clips.filter { !listenedClipIDs.contains($0.id) }.count }

    var radiusMilesLabel: String {
        radiusMiles < 10 ? String(format: "%.1f mi", radiusMiles) : "\(Int(radiusMiles)) mi"
    }

    // MARK: - Private

    private let locationManager = CLLocationManager()
    private var cancellables = Set<AnyCancellable>()
    private var persistentCancellables = Set<AnyCancellable>()
    private var isRefreshingDriveQueue = false
    private var radiusDebounceTask: Task<Void, Never>?

    static let metersPerMile: Double = 1609.344

    // MARK: - Init

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        refreshListenedClipIDs()
        AudioPlayerService.shared.$currentIndex
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] (_: Int) in self?.refreshListenedClipIDs() }
            .store(in: &persistentCancellables)
    }

    func refreshListenedClipIDs() {
        let strings = UserDefaults.standard.stringArray(forKey: "listenedClipIDs") ?? []
        listenedClipIDs = Set(strings.compactMap { UUID(uuidString: $0) })
    }

    // MARK: - Location

    func requestLocationAndFetch() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.requestLocation()
        case .denied, .restricted:
            error = "Location access denied. Enable it in Settings to see nearby clips."
        @unknown default:
            break
        }
    }

    // MARK: - Fetch

    func fetchNearbyClips() async {
        guard let center = radiusCenter ?? userLocation?.coordinate else { return }
        await fetchClips(around: center)
    }

    // Called by the view when the user pans the map (drive mode off)
    func updateRadiusCenter(_ coord: CLLocationCoordinate2D) async {
        radiusCenter = coord
        await fetchNearbyClips()
    }

    // Called when the radius slider value changes — debounces to avoid hammering Supabase
    func onRadiusChanged() {
        radiusDebounceTask?.cancel()
        radiusDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await fetchNearbyClips()
        }
    }

    private static let clipSelect = "id, user_id, audio_url, lat, lng, created_at, play_count, reply_count, duration_seconds, title, transcript, like_count, location_display, profiles!clips_user_id_fkey(username, avatar_url, beep_tone)"

    private func fetchClips(around center: CLLocationCoordinate2D) async {
        isLoading = true
        defer { isLoading = false }
        error = nil

        let lat = center.latitude
        let lng = center.longitude
        let latDelta = radiusMiles / 69.0
        let lngDelta = latDelta / cos(lat * .pi / 180)

        do {
            let raw: [Clip] = try await SupabaseService.shared.client
                .from("clips")
                .select(Self.clipSelect)
                .gte("lat", value: "\(lat - latDelta)")
                .lte("lat", value: "\(lat + latDelta)")
                .gte("lng", value: "\(lng - lngDelta)")
                .lte("lng", value: "\(lng + lngDelta)")
                .limit(200)
                .execute()
                .value

            let hidden = UserRelationshipService.shared.hiddenUserIDs
            let centerLoc = CLLocation(latitude: lat, longitude: lng)

            var inner: [(Clip, Double)] = []

            for clip in raw {
                if let uid = clip.user_id, hidden.contains(uid) { continue }
                guard let d = distanceMiles(from: centerLoc, to: clip) else { continue }
                if d <= radiusMiles {
                    inner.append((clip, d))
                }
            }

            clips = inner.sorted { $0.1 < $1.1 }.map(\.0)

            // Pin drops for every other geotagged post, anywhere — so the user can
            // spot locations with a lot of activity outside their current radius.
            let insideIDs = Set(clips.map(\.id))
            let allRaw: [Clip] = try await SupabaseService.shared.client
                .from("clips")
                .select(Self.clipSelect)
                .not("lat", operator: .is, value: "null")
                .not("lng", operator: .is, value: "null")
                .limit(500)
                .execute()
                .value

            outerClips = allRaw.filter { clip in
                if insideIDs.contains(clip.id) { return false }
                if let uid = clip.user_id, hidden.contains(uid) { return false }
                return true
            }

            print("LocalViewModel: \(clips.count) within radius, \(outerClips.count) outer pins")
        } catch {
            self.error = error.localizedDescription
            print("LocalViewModel.fetchClips error: \(error)")
        }
    }

    // MARK: - Distance

    func distanceMiles(from location: CLLocation, to clip: Clip) -> Double? {
        guard let lat = clip.lat, let lng = clip.lng else { return nil }
        return location.distance(from: CLLocation(latitude: lat, longitude: lng)) / Self.metersPerMile
    }

    func distanceMilesString(to clip: Clip) -> String? {
        guard let location = userLocation, let d = distanceMiles(from: location, to: clip) else { return nil }
        let miles = max(1, Int(d.rounded()))
        return miles == 1 ? "within 1 mile" : "within \(miles) miles"
    }

    // MARK: - Drive Mode

    func toggleDriveMode() {
        isDriveMode.toggle()
        if isDriveMode {
            if let loc = userLocation {
                radiusCenter = loc.coordinate
            }
            locationManager.distanceFilter = 15
            locationManager.startUpdatingLocation()
            AudioPlayerService.shared.onQueueExhausted = { [weak self] in
                await self?.refreshDriveQueue()
            }
            startDriveMode()
        } else {
            locationManager.distanceFilter = kCLDistanceFilterNone
            locationManager.stopUpdatingLocation()
            AudioPlayerService.shared.onQueueExhausted = nil
            cancellables.removeAll()
            AudioPlayerService.shared.pause()
        }
    }

    private func startDriveMode() {
        observeTrackChanges()
        Task { await refreshDriveQueue() }
    }

    // Each time the player moves on to a new clip, refresh the nearby-clips list
    // from the user's current position and rebuild the upcoming queue from it —
    // without disturbing the clip that's currently playing.
    private func observeTrackChanges() {
        cancellables.removeAll()
        AudioPlayerService.shared.$currentIndex
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isDriveMode, !self.isRefreshingDriveQueue else { return }
                Task { await self.refreshDriveQueue() }
            }
            .store(in: &cancellables)
    }

    private func refreshDriveQueue() async {
        guard !isRefreshingDriveQueue else { return }
        isRefreshingDriveQueue = true
        defer { isRefreshingDriveQueue = false }
        await fetchNearbyClips()
        let upcoming = filteredClips
        let player = AudioPlayerService.shared
        if player.currentClip == nil {
            // Nothing playing (queue empty/ran dry) — start fresh from the new list.
            guard !upcoming.isEmpty else { return }
            player.loadQueue(upcoming, startAt: 0)
        } else {
            player.setUpcomingQueue(upcoming)
            if !player.isPlaying {
                // The previous clip finished while we were fetching — resume
                // with whatever just got queued up, so playback never stalls.
                await player.playNextIfAvailable()
            }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocalViewModel: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            let isFirstFix = self.userLocation == nil
            self.userLocation = loc
            if isFirstFix {
                // Set initial radius center on first GPS fix
                self.radiusCenter = loc.coordinate
                await self.fetchNearbyClips()
            } else if self.isDriveMode {
                // Drive mode: the radius circle follows the user continuously, but
                // the clip list/queue only refreshes when the next post starts
                // (see observeTrackChanges/refreshDriveQueue), so it stays put
                // while a post is playing.
                self.radiusCenter = loc.coordinate
                if !AudioPlayerService.shared.isPlaying {
                    // Playback isn't active (queue ran dry/nothing nearby yet) —
                    // retry from the new position so posts keep going.
                    await self.refreshDriveQueue()
                }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        print("LocalViewModel location error: \(error)")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authStatus = manager.authorizationStatus
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            case .denied, .restricted:
                self.error = "Location access denied. Enable it in Settings."
            default:
                break
            }
        }
    }
}
