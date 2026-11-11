import Foundation

/// A point as Mapbox and the web write it: longitude first.
struct LngLat: Equatable {
    var lng: Double
    var lat: Double
}

/// How each car is drawn — port of `apps/web/src/lib/sary/vehicleLayer.ts`.
///
/// It stays readable at every zoom: about the same on-screen size up to street
/// zoom, then its true size (≈4.9 m) once that is larger.
enum Vehicle {
    /// How a car is drawn: the 2D glossy icon (default), else the 3D model (CarIcon falls back
    /// to it if its images are missing; the modelled SUV falls back to the procedural one).
    enum Marker { case icon, model }
    static var marker: Marker = ProcessInfo.processInfo.arguments.contains("-SaryCar3D") ? .model : .icon

    /// Degrees added to a compass heading so the model's nose (+Z in glTF) points that way.
    static let modelHeadingOffset = 180.0
    /// On-screen length the car keeps until its true size is larger.
    static let screenPx = 26.0
    static let carLengthM = 4.9
    /// Metres per CSS pixel at zoom 0 around Saudi latitudes (cos 25°).
    static let mppZ0 = 156_543.03 * cos(25 * Double.pi / 180)
    /// Spot under your own car (the web's default spot colour).
    static let mySpotHex: UInt32 = 0xE8862E

    static func scaleAt(zoom: Double) -> Double {
        max(1, screenPx * (mppZ0 / pow(2, zoom)) / carLengthM)
    }

    /// Height grows much less than length and width, so an enlarged car does not
    /// stand over the buildings. (Exported by the web too, but its layer currently
    /// scales all three axes alike; we do the same to match it.)
    static func heightScale(_ s: Double) -> Double {
        ((1 + (s - 1) * 0.25) * 100).rounded() / 100
    }

    /// `model-scale` by zoom: one linear stop per zoom 4…22, rounded to 0.01, exactly as the web.
    static var scaleStops: [(zoom: Double, scale: Double)] {
        (4 ... 22).map { z in (Double(z), (scaleAt(zoom: Double(z)) * 100).rounded() / 100) }
    }

    static var scaleExpression: [Any] {
        var e: [Any] = ["interpolate", ["linear"], ["zoom"]]
        for s in scaleStops { e += [s.zoom, ["literal", [s.scale, s.scale, s.scale]]] }
        return e
    }

    static func rotation(_ heading: Double?) -> [Double] {
        let h = heading.flatMap { $0.isFinite ? $0 : nil } ?? 0
        return [0, 0, ((h + modelHeadingOffset).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)]
    }

    /// One model per body colour: `sary-suv-d6452f`.
    static func modelId(_ rgb: UInt32) -> String { "sary-suv-" + hex(rgb) }

    static func hex(_ rgb: UInt32) -> String { String(format: "%06x", rgb & 0xFFFFFF) }

    /// Layer ids for one car. Same naming as the web: "" is your own car, else `peer-<id>`.
    static func ids(_ key: String) -> (source: String, layer: String, spot: String) {
        key.isEmpty
            ? ("sary-vehicle", "sary-vehicle-3d", "sary-vehicle-spot")
            : ("sary-vehicle-\(key)", "sary-vehicle-3d-\(key)", "sary-vehicle-spot-\(key)")
    }

    /// The halo layer under my own car (`myHaloLayer`).
    static func haloId(_ spot: String) -> String { spot + "-halo" }

    /// My position, readable over pale sand and dark imagery alike: a soft dark disc (contrast on
    /// sand) inside a white ring (contrast at night), about the car's on-screen size, flat on the map.
    static func myHaloLayer(id: String, source: String) -> [String: Any] {
        [
            "id": id, "type": "circle", "source": source,
            "paint": [
                "circle-radius": ["interpolate", ["linear"], ["zoom"], 10, 18, 16.5, 22, 19, 32] as [Any],
                "circle-color": "#06101F", "circle-opacity": 0.28, "circle-blur": 0.1,
                "circle-stroke-color": "#ffffff", "circle-stroke-width": LivePulse.restRingWidth, "circle-stroke-opacity": LivePulse.restRingOpacity,
                "circle-pitch-alignment": "map", "circle-emissive-strength": 1,
                /* The live breath (`LivePulse`): Mapbox eases the ring between beats. */
                "circle-stroke-width-transition": ["duration": LivePulse.transitionMs, "delay": 0] as [String: Any],
                "circle-stroke-opacity-transition": ["duration": LivePulse.transitionMs, "delay": 0] as [String: Any],
            ] as [String: Any],
        ]
    }

    static func carKey(_ userId: String) -> String {
        "peer-" + userId.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// A car whose fix is not live is drawn grey (QA build 15: not just faded — clearly "old").
    static let staleRGB: UInt32 = 0x8E8E93

    /// The colour a car is drawn in: its own while live, grey once the fix is old.
    static func displayColor(_ color: UInt32, _ f: Policy.Freshness) -> UInt32 {
        f == .live ? color : staleRGB
    }

    /// Model opacity by freshness: an old fix is visibly not live.
    static func opacity(_ f: Policy.Freshness) -> Double {
        switch f {
        case .live: return 1
        case .recent: return 0.7
        case .lost: return 0.4
        }
    }

    static func distanceMeters(_ a: LngLat, _ b: LngLat) -> Double {
        let r = Double.pi / 180
        let x = (b.lng - a.lng) * r * cos((a.lat + b.lat) / 2 * r)
        let y = (b.lat - a.lat) * r
        return (x * x + y * y).squareRoot() * 6_371_000
    }

    /// Compass bearing from a to b, 0 = north, 90 = east.
    static func bearing(_ a: LngLat, _ b: LngLat) -> Double {
        let r = Double.pi / 180
        let x = (b.lng - a.lng) * cos((a.lat + b.lat) / 2 * r)
        let y = b.lat - a.lat
        return ((atan2(x, y) / r).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }
}

/// DEBUG car previews: `-SaryCarCam "zoom,pitch,bearing[,lat,lng]"` (screenshots of the cars at a
/// given zoom / pitch; centred on the group unless a point is given).
enum CarCam {
    static func parse(_ args: [String]) -> (zoom: Double, pitch: Double, bearing: Double, at: LngLat?)? {
        guard let i = args.firstIndex(of: "-SaryCarCam"), i + 1 < args.count else { return nil }
        let n = args[i + 1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard let z = n.first, (0 ... 22).contains(z) else { return nil }
        return (z, n.count > 1 ? min(85, max(0, n[1])) : 0, n.count > 2 ? n[2] : 0, n.count > 4 ? LngLat(lng: n[4], lat: n[3]) : nil)
    }
}

/// Which car a tap on the map meant. Model layers are not hit-testable through the
/// native SDK's layer interactions, so a tap is matched to the nearest drawn car on screen.
enum CarHit {
    /// Half the car's on-screen length plus a finger's margin, never under 28 pt.
    static func radius(zoom: Double, metersPerPoint: Double) -> Double {
        guard metersPerPoint > 0 else { return 28 }
        let lengthPt = Vehicle.carLengthM * Vehicle.scaleAt(zoom: zoom) / metersPerPoint
        return max(28, lengthPt / 2 + 6)
    }

    /// The id of the nearest point within `radius` of `tap`, or nil.
    static func nearest(_ tap: (x: Double, y: Double), _ cars: [(id: String, x: Double, y: Double)], radius: Double) -> String? {
        var best: (String, Double)?
        for c in cars {
            let d = ((c.x - tap.x) * (c.x - tap.x) + (c.y - tap.y) * (c.y - tap.y)).squareRoot()
            if d <= radius, d < (best?.1 ?? .infinity) { best = (c.id, d) }
        }
        return best?.0
    }
}

/// Interpolation between real fixes only (port of `motion.ts`): never past the last fix.
enum Motion {
    static let maxTweenMs = 1_000.0
    /// Farther than this (a reconnect, a long gap) the car jumps: a slide would be fiction.
    static let snapDistanceM = 2_000.0

    static func easeInOut(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
    }

    static func lerp(_ a: LngLat, _ b: LngLat, _ t: Double) -> LngLat {
        let k = easeInOut(t)
        return LngLat(lng: a.lng + (b.lng - a.lng) * k, lat: a.lat + (b.lat - a.lat) * k)
    }

    static func tweenMs(gapMs: Double, distanceM: Double, reducedMotion: Bool) -> Double {
        if reducedMotion || distanceM > snapDistanceM || !gapMs.isFinite { return 0 }
        return min(maxTweenMs, max(300, gapMs * 0.5))
    }
}

/// Basemap light from the clock and where we are, no network (port of `outings/sun.ts`).
enum SunLight {
    enum Preset: String { case dawn, day, dusk, night }

    static func elevationDeg(_ date: Date, lat: Double, lng: Double) -> Double {
        let rad = Double.pi / 180
        let d = date.timeIntervalSince1970 / 86_400 + 2_440_587.5 - 2_451_545.0
        let g = (357.529 + 0.98560028 * d) * rad
        let q = 280.459 + 0.98564736 * d
        let L = (q + 1.915 * sin(g) + 0.02 * sin(2 * g)) * rad
        let e = (23.439 - 0.00000036 * d) * rad
        let ra = atan2(cos(e) * sin(L), cos(L))
        let dec = asin(sin(e) * sin(L))
        let gmst = (18.697374558 + 24.06570982441908 * d).truncatingRemainder(dividingBy: 24)
        let ha = (gmst * 15 + lng) * rad - ra
        let phi = lat * rad
        return asin(sin(phi) * sin(dec) + cos(phi) * cos(dec) * cos(ha)) / rad
    }

    /// Day above a few degrees, dusk/dawn through civil twilight, night once the sun is 6° under.
    static func preset(_ date: Date, lat: Double, lng: Double) -> Preset {
        let el = elevationDeg(date, lat: lat, lng: lng)
        if el > 4 { return .day }
        if el <= -6 { return .night }
        let later = elevationDeg(date.addingTimeInterval(600), lat: lat, lng: lng)
        return later > el ? .dawn : .dusk
    }
}

/// "Keep everyone on screen" (port of the web's `groupBounds` / keep-group check in OutingLive.tsx).
enum GroupFraming {
    /// ~60 m around: enough to see the street, close enough that two cars side by side separate.
    static let pad = 0.0006
    static let maxZoom = 17.5
    /// Room under the top bar for a name and a note over a car (the web adds 70 px;
    /// our chip sits a little higher over the car, so a two-line note needs more).
    static let noteRoom = 110.0

    struct Bounds: Equatable {
        var west: Double, south: Double, east: Double, north: Double
    }

    static func bounds(_ pts: [LngLat]) -> Bounds? {
        guard !pts.isEmpty else { return nil }
        var w = Double.infinity, s = Double.infinity, e = -Double.infinity, n = -Double.infinity
        for p in pts {
            w = min(w, p.lng); e = max(e, p.lng)
            s = min(s, p.lat); n = max(n, p.lat)
        }
        return Bounds(west: w - pad, south: s - pad, east: e + pad, north: n + pad)
    }

    /// Whether anyone is outside the visible area, inset a little (8 % / 12 % on the web) so a
    /// car at the very edge counts as off screen.
    static func anyOffScreen(_ pts: [LngLat], view: Bounds, insetX: Double = 0.08, insetY: Double = 0.12) -> Bool {
        let dx = (view.east - view.west) * insetX, dy = (view.north - view.south) * insetY
        return pts.contains { p in
            p.lng < view.west + dx || p.lng > view.east - dx || p.lat < view.south + dy || p.lat > view.north - dy
        }
    }
}

// MARK: - Live markers

/// The breathing ring on live things only (my position while my fix is live, the rally flag
/// while the outing runs). One slow beat timer drives it, never a per-frame loop: each beat
/// sets a style value and Mapbox's own paint transition (or one SwiftUI phase cycle for the
/// flag) eases it. The breath is inhale → exhale → hold, so the map idles a third of the time.
/// Stopped in the background, under Reduce Motion, in drive mode and in Low Power Mode. Pure (`FollowCameraTests`).
enum LivePulse {
    enum Phase: Equatable { case inhale, exhale, hold }

    /// One beat, seconds (also the paint transition length): half of the design system's
    /// live breath (`SaryMotion.livePulsePeriod`), so the map breathes like every «مباشر» dot.
    static let beat: TimeInterval = SaryMotion.livePulsePeriod / 2
    static var transitionMs: Int { Int((beat * 1000).rounded()) }

    static func phase(_ beat: Int) -> Phase {
        switch ((beat % 3) + 3) % 3 {
        case 1: return .inhale
        case 2: return .exhale
        default: return .hold
        }
    }

    /// The design system's loop rule (`SaryMotionPolicy.loop(.live, …)`: not live, background,
    /// Reduce Motion or drive mode → off), plus Low Power Mode (the map would render for it).
    static func shouldRun(live: Bool, foreground: Bool, reduceMotion: Bool, drive: Bool, lowPower: Bool) -> Bool {
        SaryMotionPolicy.loop(.live, active: live && !lowPower, reduceMotion: reduceMotion, drive: drive, sceneActive: foreground) != .off
    }

    /// My halo's white ring: at rest as `Vehicle.myHaloLayer` draws it; on the inhale it widens and softens.
    static func haloRing(_ p: Phase) -> (width: Double, opacity: Double) {
        p == .inhale ? (4.5, 0.5) : (restRingWidth, restRingOpacity)
    }

    static let restRingWidth = 2.5
    static let restRingOpacity = 0.9
}

/// A member joining or leaving: the car fades (and its ground spot scales) in or out through
/// Mapbox paint transitions, never a frame loop. Instant under Reduce Motion.
enum MemberFade {
    static let seconds: TimeInterval = 0.35
    /// The fresh layers render once at zero before the fade-in target is set (a transition
    /// needs a drawn starting value).
    static let revealDelay: TimeInterval = 0.06
    static var transition: [String: Any] { ["duration": Int(seconds * 1000), "delay": 0] }
}
