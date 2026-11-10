import Foundation

/// «أماكني المحفوظة»: points the person saved, on this device only (never sent anywhere).
struct SavedPlace: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var icon: SavedPlaceIcon
    var lat: Double
    var lng: Double
    var createdAt: Date

    var position: LngLat { LngLat(lng: lng, lat: lat) }

    static let nameMax = 40
}

enum SavedPlaceIcon: String, Codable, CaseIterable, Identifiable {
    case pin, camp, water, fuel, view, car, flag, star

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .pin: return "mappin"
        case .camp: return "tent.fill"
        case .water: return "drop.fill"
        case .fuel: return "fuelpump.fill"
        case .view: return "binoculars.fill"
        case .car: return "car.fill"
        case .flag: return "flag.fill"
        case .star: return "star.fill"
        }
    }

    var label: String {
        switch self {
        case .pin: return "نقطة"
        case .camp: return "مخيم"
        case .water: return "ماء"
        case .fuel: return "بنزين"
        case .view: return "إطلالة"
        case .car: return "موقف"
        case .flag: return "علامة"
        case .star: return "مميز"
        }
    }
}

/// Pure rules for the list (unit-tested).
enum SavedPlaceRules {
    static let maxPlaces = 500

    /// Trimmed, capped; empty becomes «مكان محفوظ».
    static func cleanName(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return t.isEmpty ? "مكان محفوظ" : String(t.prefix(SavedPlace.nameMax))
    }

    /// A valid coordinate on Earth (the map centre always is; a corrupted file may not be).
    static func valid(_ p: LngLat) -> Bool {
        p.lat.isFinite && p.lng.isFinite && abs(p.lat) <= 90 && abs(p.lng) <= 180
    }

    /// Newest first.
    static func sorted(_ l: [SavedPlace]) -> [SavedPlace] { l.sorted { $0.createdAt > $1.createdAt } }
}

/// On-device store (Application Support JSON). Observable for the sheets.
@MainActor
final class SavedPlacesStore: ObservableObject {
    static let shared = SavedPlacesStore()

    @Published private(set) var places: [SavedPlace] = []
    private let url: URL?
    /// Names places saved without one (tests inject their own).
    var namer: PlaceNameResolver = .shared

    init(fileName: String = "saved-places-v1.json") {
        url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent(fileName)
        load()
    }

    private func load() {
        guard let url, let d = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let list = (try? dec.decode([SavedPlace].self, from: d)) ?? []
        places = SavedPlaceRules.sorted(list.filter { SavedPlaceRules.valid($0.position) })
        nameBarePlaces()
    }

    /// «مكان محفوظ» / «نقطة على الخريطة» get the place's real name (`PlaceNamer`), unless renamed meanwhile.
    func nameBarePlaces(resolver: PlaceNameResolver? = nil) {
        let resolver = resolver ?? namer
        let bare = places.filter { PlaceLabel.isGeneric($0.name) }
        guard !bare.isEmpty else { return }
        Task { @MainActor in
            for b in bare {
                let n = await resolver.name(for: b.position, within: 5)
                guard !PlaceLabel.isGeneric(n), let i = places.firstIndex(where: { $0.id == b.id }), PlaceLabel.isGeneric(places[i].name) else { continue }
                places[i].name = SavedPlaceRules.cleanName(n)
                save()
            }
        }
    }

    private func save() {
        guard let url else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(places).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    @discardableResult
    func add(name: String, icon: SavedPlaceIcon, at p: LngLat, now: Date = Date()) -> SavedPlace? {
        guard SavedPlaceRules.valid(p), places.count < SavedPlaceRules.maxPlaces else { return nil }
        let place = SavedPlace(id: UUID().uuidString, name: SavedPlaceRules.cleanName(name), icon: icon, lat: p.lat, lng: p.lng, createdAt: now)
        places = SavedPlaceRules.sorted(places + [place])
        save()
        nameBarePlaces()
        return place
    }

    func update(_ id: String, name: String, icon: SavedPlaceIcon) {
        guard let i = places.firstIndex(where: { $0.id == id }) else { return }
        places[i].name = SavedPlaceRules.cleanName(name)
        places[i].icon = icon
        save()
    }

    func delete(_ id: String) {
        places.removeAll { $0.id == id }
        save()
    }

    /// «احذف حسابي» / reset: forget every saved place on this device.
    func wipe() {
        places = []
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}
