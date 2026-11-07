import Foundation

/// The outing's destination kept on this phone while the server has no plan
/// endpoint yet (`PUT /api/outings/:id/plan` answers 404 until server PR #30 is
/// deployed). `pending` = still to be sent; `PlanModel` sends it the first time
/// the plan loads from the server, and then forgets it.
enum LocalDestinationStore {
    struct Entry: Codable, Equatable {
        var destination: OutingDestination
        var pending: Bool
        var savedAt: Date
    }

    static let prefix = "sary.plan.localDestination.v1."

    static func load(_ outingId: String, defaults: UserDefaults = .standard) -> Entry? {
        guard let d = defaults.data(forKey: prefix + outingId) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: d)
    }

    static func save(_ outingId: String, _ e: Entry, defaults: UserDefaults = .standard) {
        guard let d = try? JSONEncoder().encode(e) else { return }
        defaults.set(d, forKey: prefix + outingId)
    }

    static func clear(_ outingId: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: prefix + outingId)
    }

    static func forgetAll(defaults: UserDefaults = .standard) {
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(prefix) { defaults.removeObject(forKey: k) }
    }
}

/// «أماكن سابقة» in «وين رايحين؟»: the last destinations chosen on this phone (newest first).
enum RecentPlaces {
    static let key = "sary.create.recentPlaces.v1"
    static let max = 6

    static func load(defaults: UserDefaults = .standard) -> [OutingDestination] {
        guard let d = defaults.data(forKey: key) else { return [] }
        let all = (try? JSONDecoder().decode([OutingDestination].self, from: d)) ?? []
        /* Older bare «نقطة على الخريطة» entries are named in the background; the next load shows the names. */
        if defaults === UserDefaults.standard, all.contains(where: { PlaceLabel.isGeneric($0.name) }) { nameInBackground() }
        return all
    }

    /// One background naming pass at a time (`PlaceNamer`).
    private static var naming = false
    private static let namingLock = NSLock()

    static func nameInBackground() {
        namingLock.lock()
        defer { namingLock.unlock() }
        guard !naming else { return }
        naming = true
        Task.detached(priority: .utility) {
            await resolveNames()
            namingLock.lock(); naming = false; namingLock.unlock()
        }
    }

    static func add(_ p: OutingDestination, defaults: UserDefaults = .standard) {
        var all = load(defaults: defaults).filter { Geo.haversineMeters(.init(lat: $0.lat, lng: $0.lng), .init(lat: p.lat, lng: p.lng)) > 50 }
        all.insert(p, at: 0)
        if let d = try? JSONEncoder().encode(Array(all.prefix(max))) { defaults.set(d, forKey: key) }
        /* A bare «نقطة على الخريطة» gets its real name in the background (`PlaceNamer`). */
        if defaults === UserDefaults.standard, PlaceLabel.isGeneric(p.name) { nameInBackground() }
    }

    static func forget(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}

/// The one honest sentence for a destination that is only on this phone.
enum LocalDestinationCopy {
    static let note = "الوجهة محفوظة في جوالك فقط حتى يتوفر حفظها على الخادم، والعيال ما يشوفونها في التطبيق بعد. نرسلها تلقائيًا أول ما يتوفر."
}
