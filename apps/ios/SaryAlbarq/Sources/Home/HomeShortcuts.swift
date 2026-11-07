import Foundation

/// «البيت» and «الشغل» on the home sheet: two places kept on this phone only (never sent).
enum HomeShortcut: String, CaseIterable, Identifiable, Codable {
    case home, work

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "البيت"
        case .work: return "الشغل"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .work: return "briefcase.fill"
        }
    }
}

enum HomeShortcutStore {
    static let key = "sary.home.shortcuts.v1"

    static func load(defaults: UserDefaults = .standard) -> [HomeShortcut: OutingDestination] {
        guard let d = defaults.data(forKey: key),
              let raw = try? JSONDecoder().decode([String: OutingDestination].self, from: d) else { return [:] }
        var out: [HomeShortcut: OutingDestination] = [:]
        for (k, v) in raw {
            if let s = HomeShortcut(rawValue: k), PlanGeo.valid(lat: v.lat, lng: v.lng) { out[s] = v }
        }
        return out
    }

    static func set(_ s: HomeShortcut, _ d: OutingDestination?, defaults: UserDefaults = .standard) {
        var all = load(defaults: defaults)
        all[s] = d
        let raw = Dictionary(uniqueKeysWithValues: all.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) { defaults.set(data, forKey: key) }
    }

    static func forget(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}

/// The category chips over the home map and in the raised sheet. Everyday places first,
/// then the desert (our difference): نفود، روضة، فيضة، مخيمات، أمطار وربيع.
struct HomeCategory: Identifiable, Equatable {
    var id: String
    var label: String
    var systemImage: String
    /// What the place search is asked.
    var query: String
    /// A desert category (drawn with the sand tint).
    var desert = false

    static let city: [HomeCategory] = [
        .init(id: "restaurants", label: "مطاعم", systemImage: "fork.knife", query: "مطعم"),
        .init(id: "cafes", label: "مقاهي", systemImage: "cup.and.saucer.fill", query: "مقهى"),
        .init(id: "mosques", label: "مساجد", systemImage: "building.columns.fill", query: "مسجد"),
        .init(id: "fuel", label: "محطات وقود", systemImage: "fuelpump.fill", query: "محطة وقود"),
    ]

    static let desertOnes: [HomeCategory] = [
        .init(id: "nufud", label: "نفود", systemImage: "mountain.2.fill", query: "نفود", desert: true),
        .init(id: "rawda", label: "روضة", systemImage: "leaf.fill", query: "روضة", desert: true),
        .init(id: "faydah", label: "فيضة", systemImage: "drop.fill", query: "فيضة", desert: true),
        .init(id: "camps", label: "مخيمات", systemImage: "tent.fill", query: "مخيم", desert: true),
        .init(id: "rain", label: "أمطار وربيع", systemImage: "cloud.rain.fill", query: "روضة ربيع", desert: true),
    ]

    /// The order on the map: two everyday, then the desert, then the rest (one row that scrolls).
    static let all: [HomeCategory] = city + desertOnes
}

/// Pure rules for the home sheet (unit-tested in HomeFlowTests).
enum HomeSheetRules {
    /// Collapsed: the search bar, the shortcuts and one line of what is happening.
    static let collapsedHeight: Double = 200
    /// Raised: most of the screen, the map still peeks above.
    static func expandedHeight(screen: Double) -> Double { max(collapsedHeight, screen * 0.82) }

    /// Where the sheet settles after a drag: `translation` > 0 is downwards.
    static func settle(expanded: Bool, translation: Double, velocity: Double) -> Bool {
        let push = translation + velocity * 0.15
        if expanded { return push < 90 }
        return push < -60
    }
}
