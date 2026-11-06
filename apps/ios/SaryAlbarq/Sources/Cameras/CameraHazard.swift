import Foundation
import Combine

/// The proposed Arabic voice lines. We DO NOT synthesize audio here — these are
/// the texts to approve and later record in «صوت سرى»; until then the read-only
/// hook may read them with the device voice. We never say a speed-limit number
/// we are not sure of (see `CameraHazardConfig.speakLimitMinConfidence`).
enum CameraVoice {
    /// «انتبه، كاميرا على بُعد ٥٠٠ متر» — the approach line, distance rounded.
    static func approach(_ meters: Int, kind: CameraKind) -> String {
        "انتبه، \(kind.arabicIndefinite) على بُعد \(ArabicDigits.meters(meters))"
    }

    /// «كاميرا رصد قدّامك» — the imminent line, no distance.
    static func imminent(_ kind: CameraKind) -> String {
        kind == .red_light ? "كاميرا إشارة قدّامك" : "كاميرا رصد قدّامك"
    }
}

extension CameraKind {
    /// «كاميرا رصد» / «كاميرا متنقلة» … for the voice line (indefinite form).
    var arabicIndefinite: String {
        switch self {
        case .fixed: return "كاميرا رصد"
        case .mobile: return "كاميرا متنقلة"
        case .red_light: return "كاميرا إشارة"
        case .avg_speed: return "كاميرا رصد متوسط السرعة"
        }
    }
}

/// Arabic-Indic numerals, so the spoken/shown text matches the rest of the app.
enum ArabicDigits {
    static func string(_ n: Int) -> String {
        let map = ["٠", "١", "٢", "٣", "٤", "٥", "٦", "٧", "٨", "٩"]
        let s = String(abs(n))
        return (n < 0 ? "-" : "") + s.map { map[Int(String($0))!] }.joined()
    }

    /// «٥٠٠ متر» / «١٫٢ كم» for a rounded distance.
    static func meters(_ m: Int) -> String {
        if m >= 1000 {
            let km = Double(m) / 1000
            let oneDp = (km * 10).rounded() / 10
            let whole = Int(oneDp)
            let frac = Int((oneDp - Double(whole)) * 10 + 0.5)
            return frac == 0 ? "\(string(whole)) كم" : "\(string(whole))٫\(string(frac)) كم"
        }
        return "\(string(m)) متر"
    }
}

struct CameraHazardConfig {
    /// How far off the route a camera may sit and still count as on this road.
    /// A camera on a parallel street or the opposite carriageway is excluded.
    var corridorM: Double = 60
    /// The approach alert distance («على بُعد ٥٠٠ متر»).
    var approachM: Double = 500
    /// The imminent alert distance («قدّامك»).
    var imminentM: Double = 120
    /// A camera this far behind the driver is considered passed and retired.
    var passMarginM: Double = 25
    /// When a camera has a bearing, the route's heading at it must agree within
    /// this, so we never alert for a camera facing the other way.
    var bearingToleranceDeg: Double = 55
    /// Below this confidence the camera draws on the map but does not alert.
    var alertMinConfidence: Double = 0.3
    /// Only speak the posted limit when we are at least this confident of it.
    var speakLimitMinConfidence: Double = 0.85

    static let `default` = CameraHazardConfig()
}

/// One alert, ready for the UI banner and for the read-only voice hook.
struct CameraAlert: Equatable {
    enum Tier: Equatable { case approach, imminent }
    var camera: SpeedCamera
    var tier: Tier
    /// Along-route metres remaining to the camera at the moment it fired.
    var distanceM: Int
    /// The Arabic line to show / read. Audio is NOT produced here.
    var text: String
}

/// A camera pinned to a position along the route.
struct ProjectedCamera: Equatable {
    var camera: SpeedCamera
    /// Distance from the route start to the camera's projection, metres.
    var along: Double
    /// Perpendicular distance from the route to the camera, metres.
    var offset: Double
}

/// Projects points onto a route polyline (local tangent-plane, good at city scale).
enum RouteGeometry {
    /// Local metres relative to a reference point (equirectangular).
    private static func xy(_ p: LngLat, ref: LngLat) -> (x: Double, y: Double) {
        let r = Double.pi / 180
        let x = (p.lng - ref.lng) * r * cos(ref.lat * r) * 6_371_000
        let y = (p.lat - ref.lat) * r * 6_371_000
        return (x, y)
    }

    /// Cumulative along-route distance at each vertex.
    static func cumulative(_ route: [LngLat]) -> [Double] {
        var out = [0.0]
        out.reserveCapacity(route.count)
        for i in 1..<max(1, route.count) {
            out.append(out[i - 1] + Vehicle.distanceMeters(route[i - 1], route[i]))
        }
        return out
    }

    /// Nearest point on the route to `p`: its along-distance and perpendicular offset.
    static func project(_ p: LngLat, route: [LngLat], cumulative cum: [Double]) -> (along: Double, offset: Double)? {
        guard route.count >= 2 else { return nil }
        var best: (along: Double, offset: Double)? = nil
        for i in 0..<(route.count - 1) {
            let a = route[i], b = route[i + 1]
            let A = xy(a, ref: a), B = xy(b, ref: a), P = xy(p, ref: a)
            let abx = B.x - A.x, aby = B.y - A.y
            let len2 = abx * abx + aby * aby
            let t = len2 <= 0 ? 0 : max(0, min(1, ((P.x - A.x) * abx + (P.y - A.y) * aby) / len2))
            let cx = A.x + t * abx, cy = A.y + t * aby
            let off = ((P.x - cx) * (P.x - cx) + (P.y - cy) * (P.y - cy)).squareRoot()
            let seg = len2.squareRoot()
            let along = cum[i] + t * seg
            if best == nil || off < best!.offset { best = (along, off) }
        }
        return best
    }

    /// Route heading (deg from north) at along-distance `s`.
    static func heading(at s: Double, route: [LngLat], cumulative cum: [Double]) -> Double? {
        guard route.count >= 2 else { return nil }
        for i in 0..<(route.count - 1) where cum[i + 1] >= s {
            return Vehicle.bearing(route[i], route[i + 1])
        }
        return Vehicle.bearing(route[route.count - 2], route[route.count - 1])
    }
}

/// Pure, testable: projects the cameras on a route, then on each position update
/// returns at most one alert — once per camera per tier, never repeating.
final class CameraHazardEngine {
    let config: CameraHazardConfig
    private(set) var projected: [ProjectedCamera] = []
    private var route: [LngLat] = []
    private var cum: [Double] = []
    /// Tiers already fired per camera id — the whole point of «no repeat».
    private var fired: [String: Set<CameraAlert.Tier>] = [:]

    init(config: CameraHazardConfig = .default) { self.config = config }

    /// Set (or re-set after a reroute) the route and the cameras to watch. The
    /// fired record is kept, so the same physical camera never re-alerts across a
    /// reroute; a camera no longer on the route simply drops out.
    func load(route: [LngLat], cameras: [SpeedCamera]) {
        self.route = route
        cum = RouteGeometry.cumulative(route)
        projected = cameras.compactMap { cam in
            guard let pr = RouteGeometry.project(cam.position, route: route, cumulative: cum),
                  pr.offset <= config.corridorM else { return nil }
            if let b = cam.bearing, let h = RouteGeometry.heading(at: pr.along, route: route, cumulative: cum) {
                let diff = abs(((b - h).truncatingRemainder(dividingBy: 360) + 540).truncatingRemainder(dividingBy: 360) - 180)
                if diff > config.bearingToleranceDeg { return nil } // faces the other way
            }
            return ProjectedCamera(camera: cam, along: pr.along, offset: pr.offset)
        }.sorted { $0.along < $1.along }
        // Forget cameras that are no longer on the route.
        let ids = Set(projected.map(\.camera.id))
        fired = fired.filter { ids.contains($0.key) }
    }

    /// The nearest camera ahead of the driver and its remaining along-distance.
    func nearestAhead(of position: LngLat) -> (camera: SpeedCamera, remainingM: Double)? {
        guard let me = RouteGeometry.project(position, route: route, cumulative: cum) else { return nil }
        for pc in projected where pc.along - me.along >= -config.passMarginM {
            let rem = pc.along - me.along
            if rem >= -config.passMarginM { return (pc.camera, max(0, rem)) }
        }
        return nil
    }

    /// Advance to a new position; returns one alert to speak, or nil. A camera
    /// alerts at most once per tier, and never while below `alertMinConfidence`.
    func advance(to position: LngLat) -> CameraAlert? {
        guard let me = RouteGeometry.project(position, route: route, cumulative: cum) else { return nil }
        for pc in projected {
            let rem = pc.along - me.along
            if rem < -config.passMarginM { continue }           // passed
            if pc.camera.confidence < config.alertMinConfidence { continue }
            var done = fired[pc.camera.id] ?? []
            // Imminent takes precedence; crossing it also closes the approach tier.
            if rem <= config.imminentM {
                if !done.contains(.imminent) {
                    done.insert(.imminent); done.insert(.approach)
                    fired[pc.camera.id] = done
                    return CameraAlert(camera: pc.camera, tier: .imminent, distanceM: Int(rem.rounded()),
                                       text: CameraVoice.imminent(pc.camera.kind))
                }
                continue
            }
            if rem <= config.approachM, !done.contains(.approach) {
                done.insert(.approach); fired[pc.camera.id] = done
                let shown = Int((rem / 50).rounded() * 50)
                return CameraAlert(camera: pc.camera, tier: .approach, distanceM: Int(rem.rounded()),
                                   text: CameraVoice.approach(shown, kind: pc.camera.kind))
            }
            // The first unpassed camera gates the rest: nothing further is nearer.
            if rem > config.approachM { break }
        }
        return nil
    }
}

/// The app-facing provider: an `ObservableObject` the map and a read-only voice
/// hook observe. It never touches `NavSession`/`SaryVoice`; it only publishes.
/// The actual speaking is left to a one-line hook on the guidance side (see the
/// PR notes), which reads `latestAlert.text` and respects the mute switch.
@MainActor
final class CameraHazardProvider: ObservableObject {
    /// Cameras to draw on the map for the current area (set by `CamerasAPI`).
    @Published private(set) var cameras: [SpeedCamera] = []
    /// The most recent alert, for the banner. Cleared when it is spoken/shown.
    @Published private(set) var latestAlert: CameraAlert?
    /// When muted, alerts are still tracked (so a passed point never fires late)
    /// but nothing is published to speak.
    var muted: Bool = false

    private let engine: CameraHazardEngine
    private var route: [LngLat] = []

    init(config: CameraHazardConfig = .default) { engine = CameraHazardEngine(config: config) }

    func setCameras(_ cams: [SpeedCamera]) {
        cameras = cams
        engine.load(route: route, cameras: cams)
    }

    func setRoute(_ route: [LngLat]) {
        self.route = route
        engine.load(route: route, cameras: cameras)
    }

    /// Call as the driver moves. Returns the alert too, for callers that prefer a
    /// return value over observing `latestAlert`.
    @discardableResult
    func update(position: LngLat) -> CameraAlert? {
        guard let alert = engine.advance(to: position) else { return nil }
        if !muted { latestAlert = alert }
        return muted ? nil : alert
    }

    /// The nearest camera ahead, for a small always-on badge (not an alert).
    func nearestAhead(of position: LngLat) -> (camera: SpeedCamera, remainingM: Double)? {
        engine.nearestAhead(of: position)
    }

    func clearAlert() { latestAlert = nil }
}
