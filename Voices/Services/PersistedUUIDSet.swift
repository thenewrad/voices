import Foundation

/// Bounded, UserDefaults-backed list of UUIDs (e.g. "clips the user has listened to",
/// "replies the user has played"). `UserDefaults.set` re-serializes the entire array on
/// every write, so an unbounded list gets slower — and the on-disk plist heavier — the
/// longer the app is used. This caps the stored list, dropping the oldest entries once
/// the cap is exceeded.
struct PersistedUUIDSet {
    let key: String
    let cap: Int

    init(key: String, cap: Int = 1000) {
        self.key = key
        self.cap = cap
    }

    func load() -> Set<UUID> {
        let strings = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(strings.compactMap { UUID(uuidString: $0) })
    }

    /// Appends `id` to the persisted list, trimming the oldest entries if it grows past `cap`.
    func insert(_ id: UUID) {
        var ids = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !ids.contains(id.uuidString) else { return }
        ids.append(id.uuidString)
        if ids.count > cap {
            ids.removeFirst(ids.count - cap)
        }
        UserDefaults.standard.set(ids, forKey: key)
    }
}
