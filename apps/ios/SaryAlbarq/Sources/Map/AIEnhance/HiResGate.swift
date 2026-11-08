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
    /// Above this speed (driving, 8 km/h) no new tile is enhanced: only the ones already in RAM
    /// stay, with «تفاصيل الرمال» and `SandGrade` (heat: full enhancement only when stopped).
    static let enhanceSpeedMps = 8.0 / 3.6

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
        if let v = r.speedMps, v > enhanceSpeedMps { return .paused }
        return .on
    }

    /// The level actually run: the person's choice, «خفيف» once the device is warm (`.fair`).
    /// (From `.serious` nothing new is enhanced at all: `decide` pauses.)
    static func level(_ chosen: HiResLevel, device: HiResDeviceState) -> HiResLevel {
        device.thermal == .nominal ? chosen : .light
    }
}

/// «قوي» (default) or «خفيف»: how hard the model works (layers sheet → «صور عالية الوضوح»).
enum HiResLevel: String, CaseIterable, Identifiable, Equatable {
    case strong, light

    var id: String { rawValue }
    var label: String { self == .strong ? "قوي" : "خفيف" }
}

/// Everything that differs between the levels (and in a city), in one place.
struct HiResProfile: Equatable {
    var level: HiResLevel
    /// The side (px) the model's result is merged and checked at; handed to Mapbox at 512
    /// (`HiResEnhancer.tileSize`).
    var outputSize: Int
    /// How much of the model's fine detail is kept.
    var gain: Float
    /// Frequency-split radius as a multiple of one source pixel (bigger = the model shapes a
    /// wider band; ≥ 4 is full SR with a local colour transfer from the photo).
    var splitScale: Float
    /// Unsharp-mask amount (radius ≈ half a source pixel) after the merge.
    var sharpen: Float
    /// Local-contrast ("clarity") amount, radius ≈ 6 source pixels.
    var localContrast: Float
    /// Tiles around the view enhanced ahead of time (rings at the current tile zoom) and
    /// whether the next zoom's tiles under the centre are too.
    var prefetchRing: Int
    var prefetchDeeper: Bool
    /// Hard budget of model runs per minute (heat).
    var inferencesPerMinute: Int

    /// «قوي» in the open desert: the model's full super-resolution (owner, round 3: the single-tile
    /// test), its picture kept down to 8 source px; above that (colour, tone, the dunes' broad
    /// shading) comes from the photo — a local colour transfer, so the sand stays `SandGrade`
    /// orange and tiles meet without seams. A light unsharp mask, no clarity.
    static let strong = HiResProfile(level: .strong, outputSize: 1024, gain: 1, splitScale: 8, sharpen: 0.3,
                                     localContrast: 0, prefetchRing: 1, prefetchDeeper: true, inferencesPerMinute: 90)
    /// Full SR (the model shapes everything finer than the colour transfer's scale).
    var fullSR: Bool { splitScale >= 4 }
    static let light = HiResProfile(level: .light, outputSize: 512, gain: 0.85, splitScale: 1, sharpen: 0.15,
                                    localContrast: 0.04, prefetchRing: 1, prefetchDeeper: false, inferencesPerMinute: 36)
    /// Cities, whatever the level: light and building-preserving (no clarity, the photo's
    /// own band; buildings, streets and their edges are the photo's).
    static func city(_ level: HiResLevel) -> HiResProfile {
        HiResProfile(level: .light, outputSize: level == .strong ? 1024 : 512, gain: 0.7, splitScale: 1, sharpen: 0.12,
                     localContrast: 0, prefetchRing: level == .strong ? 1 : 0, prefetchDeeper: false,
                     inferencesPerMinute: level == .strong ? 60 : 36)
    }

    static func of(_ level: HiResLevel, city: Bool) -> HiResProfile {
        city ? .city(level) : (level == .strong ? .strong : .light)
    }
}

/// A sliding one-minute budget of model runs (heat): `take` says whether one may start now.
struct HiResRateLimit: Equatable {
    var perMinute: Int
    private(set) var starts: [Double] = []

    init(perMinute: Int) { self.perMinute = perMinute }

    /// Seconds until the next run may start (0 = now).
    func wait(now: Double) -> Double {
        let recent = starts.filter { now - $0 < 60 }
        guard recent.count >= perMinute, let first = recent.first else { return 0 }
        return 60 - (now - first)
    }

    mutating func take(now: Double, count: Int = 1) -> Bool {
        starts.removeAll { now - $0 >= 60 }
        guard starts.count < perMinute else { return false }
        for _ in 0..<count { starts.append(now) }
        return true
    }
}

/// The live map's closest zoom with «صور عالية الوضوح»: the imagery's real detail + 2 levels
/// (desert z17 → 19, cities z19 → 21) while enhancement runs, the plain imagery cap otherwise
/// (never a blurry over-zoom). Soft: the camera bound sits a little past the cap, and the
/// camera eases back to the cap when the pinch is let go (a rubber band).
enum HiResZoomCap {
    static let levelsPastNative = 2
    /// How far past the cap a pinch may stretch before the hard bound.
    static let overshoot = 0.4

    static func cap(lat: Double, lng: Double, base: Double, enhancing: Bool) -> Double {
        guard enhancing else { return base }
        return max(base, Double(HiResZoom.nativeMax(lat: lat, lng: lng) + levelsPastNative))
    }

    /// The `CameraBoundsOptions.maxZoom` to set.
    static func bound(cap: Double, base: Double) -> Double { cap > base ? cap + overshoot : cap }

    /// Where to ease back to after a gesture, nil when the zoom is fine.
    static func settle(zoom: Double, cap: Double) -> Double? { zoom > cap + 0.01 ? cap : nil }
}

// MARK: - zoom gating

/// Satellite tile pyramid facts for Saudi Arabia (measured in the prototype: Laplacian
/// variance + eye; see the research report). Tiles are Mapbox's 512 px raster tiles.
enum HiResZoom {
    /// Map zoom from which enhancement may show. «خفيف» (build 12): one level before the
    /// imagery stops being sharp. «قوي»: the open desert from z14 (owner, round 3).
    static let desertMinZoom = 16
    static let strongDesertMinZoom = 14
    static let cityMinZoom = 18
    /// First tile level that is enhanced («خفيف»: desert z17 ← z16, cities z19 ← z18; «قوي»:
    /// desert z14+, the tile itself made ×2 sharper up to the real detail's depth).
    static let desertFirstTile = 17
    static let strongDesertFirstTile = 14
    static let cityFirstTile = 19
    /// Deepest tile level with real detail: deeper tiles are Mapbox up-sampling, so they are
    /// never used as a parent (z19 desert is made from the real z17, not the blurry z18).
    static let desertNativeMax = 17
    static let cityNativeMax = 19
    /// The custom source's zoom range (desert z17+, cities z19+).
    static let sourceMinZoom = UInt8(strongDesertFirstTile)
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

    /// A city box above, or anywhere `SandGrade` is not in its open-desert look
    /// (`sarySand` ≤ 0.5: `UrbanAreas` and its 3 km edge). Desert rules need `sarySand` > 0.5.
    static func isCity(lat: Double, lng: Double) -> Bool {
        cities.contains { lat >= $0.s && lat <= $0.n && lng >= $0.w && lng <= $0.e }
            || SandGrade.sand(urban: UrbanAreas.weight(lat: lat, lng: lng)) <= 0.5
    }

    static func minZoom(lat: Double, lng: Double, level: HiResLevel = .light) -> Int {
        isCity(lat: lat, lng: lng) ? cityMinZoom : (level == .strong ? strongDesertMinZoom : desertMinZoom)
    }
    static func nativeMax(lat: Double, lng: Double) -> Int { isCity(lat: lat, lng: lng) ? cityNativeMax : desertNativeMax }
    static func firstTile(lat: Double, lng: Double, level: HiResLevel = .light) -> Int {
        isCity(lat: lat, lng: lng) ? cityFirstTile : (level == .strong ? strongDesertFirstTile : desertFirstTile)
    }

    /// Does the map at this zoom and centre want the enhanced layer at all?
    static func wantsLayer(zoom: Double, lat: Double, lng: Double, level: HiResLevel = .light) -> Bool {
        zoom >= Double(minZoom(lat: lat, lng: lng, level: level))
    }

    /// The tile to enhance for a requested tile, or nil when it is drawn as Mapbox serves it
    /// (shallower than `firstTile`). Past the real detail: parent = one level up, or the
    /// deepest real level when that is shallower; at most 2 levels up. At or above the real
    /// detail's depth («قوي», desert): the tile is its own parent (`factor` 1), made ×2 sharper
    /// in four 256 px quarters.
    static func plan(_ t: HiResTileID, level: HiResLevel = .light) -> HiResTilePlan? {
        let c = t.center
        let city = isCity(lat: c.lat, lng: c.lng)
        let native = city ? cityNativeMax : desertNativeMax
        guard Int(t.z) >= firstTile(lat: c.lat, lng: c.lng, level: level) else { return nil }
        if level == .strong, !city, Int(t.z) <= native {
            return HiResTilePlan(tile: t, parent: t, factor: 1, cropX: 0, cropY: 0, cropSize: 512)
        }
        let parentZ = max(Int(t.z) - 2, min(Int(t.z) - 1, native))
        let f = 1 << (Int(t.z) - parentZ)
        let parent = HiResTileID(z: UInt8(parentZ), x: t.x / UInt32(f), y: t.y / UInt32(f))
        let span = 512 / f
        return HiResTilePlan(tile: t, parent: parent, factor: f,
                             cropX: Int(t.x % UInt32(f)) * span, cropY: Int(t.y % UInt32(f)) * span, cropSize: span)
    }

    /// Tiles around a view to enhance ahead of time: `ring` tiles past the visible range at
    /// `z`, then (when `deeper`) the four children of the centre tile. Visible first, nearest
    /// the centre first; at most `limit`.
    static func prefetch(west: Double, south: Double, east: Double, north: Double, z: Int, ring: Int,
                         deeper: Bool, limit: Int = 24) -> [HiResTileID] {
        guard z >= 0, z <= 22 else { return [] }
        let a = HiResTileID.containing(lat: north, lng: west, z: z), b = HiResTileID.containing(lat: south, lng: east, z: z)
        let n = Int64(1) << z
        let x0 = Int64(min(a.x, b.x)) - Int64(ring), x1 = Int64(max(a.x, b.x)) + Int64(ring)
        let y0 = max(0, Int64(min(a.y, b.y)) - Int64(ring)), y1 = min(n - 1, Int64(max(a.y, b.y)) + Int64(ring))
        guard x1 - x0 < 16, y1 - y0 < 16 else { return [] }
        let cx = Double(x0 + x1) / 2, cy = Double(y0 + y1) / 2
        var out: [(HiResTileID, Double)] = []
        for y in y0...y1 {
            for x in x0...x1 {
                let wx = ((x % n) + n) % n
                out.append((HiResTileID(z: UInt8(z), x: UInt32(wx), y: UInt32(y)), (Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)))
            }
        }
        var tiles = out.sorted { $0.1 < $1.1 }.map(\.0)
        if deeper, z < 22 {
            let c = HiResTileID.containing(lat: (north + south) / 2, lng: (west + east) / 2, z: z)
            for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                tiles.append(HiResTileID(z: UInt8(z + 1), x: c.x * 2 + UInt32(dx), y: c.y * 2 + UInt32(dy)))
            }
        }
        return Array(tiles.prefix(limit))
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
/// parent, enhance ×4 (a 128 crop is first doubled to the model's 256 input; a whole 512 px
/// tile is run as four 256 px quarters), and scale the result to the display tile.
struct HiResTilePlan: Equatable {
    var tile: HiResTileID
    var parent: HiResTileID
    /// Magnification over the parent (1 = the tile itself, made sharper; 2 or 4 past the real detail).
    var factor: Int
    /// Model runs this tile costs.
    var inferences: Int { factor == 1 ? 4 : 1 }
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
