import Foundation

/// «صور عالية الوضوح» — over-zoom satellite enhancement (Real-ESRGAN x4plus on the device).
/// Internal doc: docs/AI-SATELLITE.md. Every rule that decides *whether* enhanced tiles may
/// be drawn lives here, pure and unit-tested (`HiResImageryTests`).
///
/// Safety first: enhancement can invent detail, so it is only for looking around — never
/// while navigating, following a track, in an SOS, or moving faster than 15 km/h.

/// Which map is asking.
enum HiResSurface: String, Equatable {
    /// Exploration mode on the live map (saved places and the place brief live there too).
    case exploration
    /// The point card («تخطيط الطلعة» long-press / a picked point) over the live map.
    case pointView
    /// A saved track / trip summary opened full screen (`TrackDetailView`).
    case trackDetail
    /// Anything else (the trip map, follow mode, previews…): original imagery.
    case off
}

/// Everything the gate needs, captured by the host screen on each update.
struct HiResRequest: Equatable {
    var surface: HiResSurface = .off
    /// The base layer is satellite (nothing to enhance on Standard / Topo).
    var satellite = true
    var navigating = false
    /// Follow mode («اسلك هذا المسار») or «طريق العودة».
    var following = false
    /// My SOS is sending / active, or an incoming SOS is on screen.
    var sos = false
    /// Last GPS speed, m/s (nil = unknown, treated as stopped).
    var speedMps: Double? = nil

    static let off = HiResRequest()
}

/// Device conditions that pause new work (already drawn tiles stay).
struct HiResDeviceState: Equatable {
    var lowPower = false
    var thermal: ProcessInfo.ThermalState = .nominal

    static var current: HiResDeviceState {
        HiResDeviceState(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState)
    }
}

enum HiResDecision: Equatable {
    /// Draw enhanced tiles and enhance new ones.
    case on
    /// Keep what is drawn, start no new inference (Low Power Mode / hot device).
    case paused
    /// Original imagery only: the enhanced layer is removed.
    case off(Reason)

    enum Reason: String, Equatable {
        case remoteKill, userOff, notSatellite, surface, navigating, following, sos, moving, noModel
    }

    var drawsLayer: Bool { if case .off = self { return false } else { return true } }
    var enhancesNew: Bool { self == .on }
}

enum HiResPolicy {
    /// Above this speed the original imagery is shown (15 km/h).
    static let maxSpeedMps = 15.0 / 3.6

    static func decide(_ r: HiResRequest, userOn: Bool, remoteOn: Bool, device: HiResDeviceState, modelAvailable: Bool = true) -> HiResDecision {
        /* Order matters only for the reason reported; every one of these is a hard off. */
        if !remoteOn { return .off(.remoteKill) }
        if !userOn { return .off(.userOff) }
        if !modelAvailable { return .off(.noModel) }
        if r.navigating { return .off(.navigating) }
        if r.following { return .off(.following) }
        if r.sos { return .off(.sos) }
        if let v = r.speedMps, v > maxSpeedMps { return .off(.moving) }
        if r.surface == .off { return .off(.surface) }
        if !r.satellite { return .off(.notSatellite) }
        if device.lowPower || device.thermal == .serious || device.thermal == .critical { return .paused }
        return .on
    }
}

// MARK: - zoom gating

/// Satellite tile pyramid facts for Saudi Arabia (measured in the prototype: Laplacian
/// variance + eye; see the research report). Tiles are Mapbox's 512 px raster tiles.
enum HiResZoom {
    /// Map zoom from which enhancement may show. Owner (build 12): one level before the
    /// imagery stops being sharp, for a clearly visible improvement.
    static let desertMinZoom = 16
    static let cityMinZoom = 18
    /// First tile level that is enhanced (desert z17 ← z16, cities z19 ← z18).
    static let desertFirstTile = 17
    static let cityFirstTile = 19
    /// Deepest tile level with real detail: deeper tiles are Mapbox up-sampling, so they are
    /// never used as a parent (z19 desert is made from the real z17, not the blurry z18).
    static let desertNativeMax = 17
    static let cityNativeMax = 19
    /// The custom source's zoom range (desert z17+, cities z19+).
    static let sourceMinZoom = UInt8(desertFirstTile)
    static let sourceMaxZoom: UInt8 = 22

    /// Major Saudi built-up areas (south, west, north, east). Outside these: desert rules.
    static let cities: [(s: Double, w: Double, n: Double, e: Double)] = [
        (24.45, 46.45, 25.05, 47.00), // Riyadh
        (21.25, 39.05, 21.95, 39.35), // Jeddah
        (21.30, 39.70, 21.52, 40.00), // Makkah
        (24.35, 39.45, 24.60, 39.75), // Madinah
        (26.10, 49.90, 26.60, 50.25), // Dammam · Khobar · Dhahran
        (26.90, 49.55, 27.10, 49.75), // Jubail
        (21.20, 40.30, 21.35, 40.50), // Taif
        (18.15, 42.45, 18.35, 42.85), // Abha · Khamis Mushait
        (26.25, 43.85, 26.45, 44.05), // Buraidah · Unaizah (north)
        (28.33, 36.48, 28.45, 36.65), // Tabuk
        (27.45, 41.62, 27.58, 41.75), // Hail
        (25.30, 49.50, 25.45, 49.65), // Al-Hofuf · Al-Mubarraz
    ]

    static func isCity(lat: Double, lng: Double) -> Bool {
        cities.contains { lat >= $0.s && lat <= $0.n && lng >= $0.w && lng <= $0.e }
    }

    static func minZoom(lat: Double, lng: Double) -> Int { isCity(lat: lat, lng: lng) ? cityMinZoom : desertMinZoom }
    static func nativeMax(lat: Double, lng: Double) -> Int { isCity(lat: lat, lng: lng) ? cityNativeMax : desertNativeMax }
    static func firstTile(lat: Double, lng: Double) -> Int { isCity(lat: lat, lng: lng) ? cityFirstTile : desertFirstTile }

    /// Does the map at this zoom and centre want the enhanced layer at all?
    static func wantsLayer(zoom: Double, lat: Double, lng: Double) -> Bool {
        zoom >= Double(minZoom(lat: lat, lng: lng))
    }

    /// The tile to enhance for a requested tile, or nil when it is drawn as Mapbox serves it
    /// (shallower than `firstTile`). Parent = one level up, or the deepest real level when
    /// that is shallower; at most 2 levels up.
    static func plan(_ t: HiResTileID) -> HiResTilePlan? {
        let c = t.center
        let native = nativeMax(lat: c.lat, lng: c.lng)
        guard Int(t.z) >= firstTile(lat: c.lat, lng: c.lng) else { return nil }
        let parentZ = max(Int(t.z) - 2, min(Int(t.z) - 1, native))
        let f = 1 << (Int(t.z) - parentZ)
        let parent = HiResTileID(z: UInt8(parentZ), x: t.x / UInt32(f), y: t.y / UInt32(f))
        let span = 512 / f
        return HiResTilePlan(tile: t, parent: parent, factor: f,
                             cropX: Int(t.x % UInt32(f)) * span, cropY: Int(t.y % UInt32(f)) * span, cropSize: span)
    }
}

struct HiResTileID: Hashable, CustomStringConvertible {
    var z: UInt8
    var x: UInt32
    var y: UInt32

    var description: String { "\(z)/\(x)/\(y)" }

    /// Centre of the tile (Web Mercator).
    var center: LngLat {
        let n = pow(2.0, Double(z))
        let lng = (Double(x) + 0.5) / n * 360 - 180
        let lat = atan(sinh(Double.pi * (1 - 2 * (Double(y) + 0.5) / n))) * 180 / .pi
        return LngLat(lng: lng, lat: lat)
    }

    static func containing(lat: Double, lng: Double, z: Int) -> HiResTileID {
        let n = pow(2.0, Double(z))
        let x = Int((lng + 180) / 360 * n)
        let r = lat * .pi / 180
        let y = Int((1 - log(tan(r) + 1 / cos(r)) / .pi) / 2 * n)
        return HiResTileID(z: UInt8(z), x: UInt32(max(0, x)), y: UInt32(max(0, y)))
    }
}

/// How a requested tile is made: crop `cropSize` px at (cropX, cropY) out of the 512 px
/// parent, enhance ×4 (a 128 crop is first doubled to the model's 256 input), and scale
/// the result to the 512 px display tile.
struct HiResTilePlan: Equatable {
    var tile: HiResTileID
    var parent: HiResTileID
    /// Effective magnification (2 or 4).
    var factor: Int
    var cropX: Int
    var cropY: Int
    var cropSize: Int
}

// MARK: - badge state

/// Which enhanced tiles are on screen right now: the «مُحسّنة» badge shows while any is.
struct HiResVisibleSet: Equatable {
    private(set) var delivered = Set<HiResTileID>()
    private(set) var needed = Set<HiResTileID>()

    var badge: Bool { !delivered.intersection(needed).isEmpty }

    mutating func required(_ t: HiResTileID) { needed.insert(t) }
    mutating func notNeeded(_ t: HiResTileID) { needed.remove(t); delivered.remove(t) }
    mutating func delivered(_ t: HiResTileID) { delivered.insert(t) }
    mutating func reset() { delivered.removeAll(); needed.removeAll() }
}
