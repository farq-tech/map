import Foundation

// «الوضع الواقعي» — Apple MapKit's realistic 3D imagery, for LOOKING at a place.
//
// Rules (docs: owner request, build 12):
// - Not for navigation: driving / turn-by-turn / follow stay on Mapbox. Closed while guiding or
//   moving faster than `RealisticRules.maxKmh`.
// - Needs the network (Apple streams the imagery; nothing is cached or saved by us).
// - Apple's own attribution / «Legal» stays visible (MapKit draws it; we never hide it).
// - Apple tiles never go into Mapbox, and Mapbox data never needs Apple tiles: this mode is
//   its own SwiftUI `Map`, fed only our overlays (cars, tracks, markers).
// Everything here is pure (unit-tested in `RealisticTests`).

/// What one «الوضع الواقعي» screen shows.
struct RealisticScene: Identifiable, Equatable {
    struct Member: Equatable, Identifiable {
        var id: String
        var name: String
        var position: LngLat
        var color: UInt32
        var isMe: Bool
        var heading: Double?
        /// Not live: drawn faded, with its last-known position.
        var stale: Bool
    }

    struct Marker: Equatable, Identifiable {
        enum Kind: String, Equatable { case destination, rally, place, waypoint, point }
        var id: String
        var title: String
        var position: LngLat
        var kind: Kind
        var systemImage: String
    }

    var id = UUID().uuidString
    /// «الوضع الواقعي · …» subtitle (the place / track name).
    var title: String
    /// Where the camera looks first (nil: fit everything below).
    var focus: LngLat?
    var members: [Member] = []
    /// A recorded / GPX track (coloured by speed when it has speeds).
    var track: TrackLine?
    /// The planned route (dashed).
    var plan: [LngLat] = []
    var markers: [Marker] = []
    /// Opened while guidance runs (should not happen: the entry is hidden; the screen refuses).
    var navigating = false
    /// Where the scene came from (analytics-free; for the accessibility value of the screen).
    var origin: String = ""
    /// Open at this camera (the trip map's own, «اعرضها بالوضع الواقعي»); nil: frame the scene.
    var camera: RealisticRules.Camera?

    static func == (a: RealisticScene, b: RealisticScene) -> Bool {
        a.id == b.id && a.title == b.title && a.focus == b.focus && a.members == b.members && a.track == b.track
            && a.plan == b.plan && a.markers == b.markers && a.navigating == b.navigating && a.camera == b.camera
    }

    /// Every point the scene draws (for the first framing).
    var allPoints: [LngLat] {
        var pts = members.map(\.position) + plan + markers.map(\.position)
        if let t = track { pts += t.points }
        return pts
    }
}

/// Can «الوضع الواقعي» open / stay open right now.
enum RealisticGate: Equatable {
    case ok
    /// Faster than 15 km/h: this is a stopped / parked view.
    case moving
    /// Turn-by-turn is running (navigation stays on Mapbox).
    case navigating
    /// No network: Apple's imagery is streamed, never stored.
    case offline

    var allowsMap: Bool { self == .ok }

    var title: String {
        switch self {
        case .ok: return ""
        case .moving: return "الوضع الواقعي متاح وأنت واقف"
        case .navigating: return "الوضع الواقعي لا يعمل أثناء الملاحة"
        case .offline: return "يحتاج إنترنت"
        }
    }

    var detail: String {
        switch self {
        case .ok: return ""
        case .moving: return "خفّف تحت ١٥ كم/س أو وقّف، والقيادة تبقى على خريطة الرحلة."
        case .navigating: return "الملاحة والتتبع على خريطة الرحلة. أوقف الملاحة ثم افتحه."
        case .offline: return "الصور الواقعية ثلاثية الأبعاد من Apple تُحمَّل مباشرة ولا تُحفظ على الجهاز. اتصل بالإنترنت وجرّب مرة ثانية."
        }
    }

    var systemImage: String {
        switch self {
        case .ok: return "checkmark"
        case .moving: return "car.side.fill"
        case .navigating: return "arrow.triangle.turn.up.right.diamond.fill"
        case .offline: return "wifi.slash"
        }
    }
}

enum RealisticRules {
    /// Above this (km/h) the realistic view closes / refuses.
    static let maxKmh = 15.0

    /// Navigation first, then movement, then the network.
    static func gate(speedMps: Double?, moving: Bool = false, navigating: Bool, online: Bool) -> RealisticGate {
        if navigating { return .navigating }
        let kmh = max(0, speedMps ?? 0) * 3.6
        if moving || kmh > maxKmh + 1e-9 { return .moving }
        if !online { return .offline }
        return .ok
    }

    // MARK: overlays

    /// Our map members → realistic annotations: the same colours, lost cars dropped (an old
    /// position must not look live on a photoreal map), recent ones faded.
    static func members(_ ms: [MapMember]) -> [RealisticScene.Member] {
        ms.filter { $0.presence != .lost || $0.isMe }
            .map { RealisticScene.Member(id: $0.id, name: $0.name, position: $0.position, color: $0.color, isMe: $0.isMe,
                                         heading: $0.presence == .live ? $0.heading : nil, stale: $0.presence != .live) }
            /* Me last, so my car draws on top. */
            .sorted { a, b in !a.isMe && b.isMe }
    }

    static func markers(destination: OutingDestination?, rally: MapRallyPoint?, waypoints: [MapWaypoint] = [], places: [SavedPlace] = []) -> [RealisticScene.Marker] {
        var out: [RealisticScene.Marker] = []
        if let d = destination {
            out.append(.init(id: "destination", title: d.name.isEmpty ? "الوجهة" : d.name, position: LngLat(lng: d.lng, lat: d.lat),
                             kind: .destination, systemImage: "flag.checkered"))
        }
        if let r = rally {
            out.append(.init(id: "rally", title: r.label.isEmpty ? "نقطة التجمع" : r.label, position: r.position, kind: .rally, systemImage: SaryIcon.rally))
        }
        out += waypoints.map { .init(id: "wp:\($0.id)", title: $0.title, position: $0.position, kind: .waypoint, systemImage: "mappin.and.ellipse") }
        out += places.map { .init(id: "place:\($0.id)", title: $0.name, position: $0.position, kind: .place, systemImage: $0.icon.systemImage) }
        return out
    }

    /// One colour stop along the track: `location` 0…1 by recorded distance.
    struct Stop: Equatable { var location: Double; var rgb: UInt32 }

    /// The speed gradient along `line` (same ramp as the Mapbox track: light slow → dark fast),
    /// nil when the line has no speeds. Neighbours of the same colour merge; at most `maxStops`.
    static func speedStops(_ line: TrackLine, maxStops: Int = 48) -> [Stop]? {
        guard line.isDrawable, line.hasSpeeds else { return nil }
        let n = line.points.count - 1
        var cum = [0.0]
        for i in 0..<n { cum.append(cum[i] + Vehicle.distanceMeters(line.points[i], line.points[i + 1])) }
        let total = cum[n]
        guard total > 0 else { return nil }
        var stops: [Stop] = []
        var lastKnown: Double?
        for i in 0..<n {
            let s = (line.gaps[i] ? nil : line.speeds[i]) ?? lastKnown
            guard let s else { continue }
            lastKnown = s
            let kmh = (s * 3.6 / TrackGradient.binKmh).rounded() * TrackGradient.binKmh
            let rgb = TrackGradient.rgb(kmh: kmh)
            let mid = (cum[i] + cum[i + 1]) / 2 / total
            if stops.last?.rgb == rgb { continue }
            stops.append(Stop(location: mid, rgb: rgb))
        }
        guard !stops.isEmpty else { return nil }
        if stops.count > maxStops {
            let step = Double(stops.count - 1) / Double(maxStops - 1)
            stops = (0..<maxStops).map { stops[Int((Double($0) * step).rounded())] }
        }
        /* Pin the ends so the whole line is coloured. */
        stops[0].location = 0
        if stops.count > 1 { stops[stops.count - 1].location = 1 } else { stops.append(Stop(location: 1, rgb: stops[0].rgb)) }
        return stops
    }

    // MARK: camera

    struct Camera: Equatable {
        var center: LngLat
        /// Metres from the camera to the centre.
        var distance: Double
        var heading: Double
        var pitch: Double
    }

    static let tiltedPitch = 65.0
    /// MapKit allows up to ≈69° close in; less from far away (it clamps on its own).
    /// A camera set before the map has loaded is clamped to ≈30°: tilt in after this.
    static let flyInDelayNs: UInt64 = 1_500_000_000
    static let minDistance = 450.0
    static let maxDistance = 60_000.0

    /// The first view: tilted 3D on the focus, or on the middle of everything drawn, far enough to see it all.
    static func initialCamera(_ scene: RealisticScene) -> Camera? {
        if var c = scene.camera {
            /* The trip map's camera, within what MapKit can show. */
            c.distance = min(max(c.distance, minDistance), maxDistance)
            c.pitch = min(max(c.pitch, 0), tiltedPitch)
            return c
        }
        let pts = scene.allPoints
        guard let center = scene.focus ?? bboxCenter(pts) else { return nil }
        var span = 0.0
        for p in pts { span = max(span, PlanGeo.meters(center, p)) }
        /* A focus (a point, the crosshair): a close look — MapKit only allows a steep 3D tilt close
         * in (≈65° at 1–2 km, ≈34° from 4 km up). A group / track: ~2.6× its radius so it all fits. */
        let d = scene.focus != nil ? 1_200 : span * 2.6
        return Camera(center: center, distance: min(max(d, minDistance), maxDistance), heading: 0, pitch: tiltedPitch)
    }

    /// Mapbox's vertical field of view (36.87°): the camera sits 1.5 view-heights from the centre, in pixels.
    static let mapboxCameraToCenter = 0.5 / tan(36.8699 * .pi / 360)

    /// A Mapbox camera (zoom on 512-pt tiles, pitch, bearing) as MapKit's: same centre, heading and
    /// tilt, and the camera-to-centre distance that zoom means on a view `viewHeight` points tall.
    static func camera(fromMapbox center: LngLat, zoom: Double, pitch: Double, bearing: Double, viewHeight: Double) -> Camera {
        let metresPerPoint = 40_075_016.686 * cos(center.lat * .pi / 180) / (512 * pow(2, zoom))
        let d = mapboxCameraToCenter * max(viewHeight, 1) * metresPerPoint
        let heading = (bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return Camera(center: center, distance: d, heading: heading, pitch: pitch)
    }

    static func bboxCenter(_ pts: [LngLat]) -> LngLat? {
        guard let f = pts.first else { return nil }
        var w = f.lng, e = f.lng, s = f.lat, n = f.lat
        for p in pts { w = min(w, p.lng); e = max(e, p.lng); s = min(s, p.lat); n = max(n, p.lat) }
        return LngLat(lng: (w + e) / 2, lat: (s + n) / 2)
    }

    /// «طيران درون»: one orbit step around the same centre — heading advances, the rest holds.
    static let droneStepDegrees = 12.0
    static let droneStepSeconds = 1.6

    static func droneStep(_ c: Camera) -> Camera {
        var n = c
        n.heading = (c.heading + droneStepDegrees).truncatingRemainder(dividingBy: 360)
        n.pitch = max(c.pitch, 55)
        return n
    }
}
