#if DEBUG
@_spi(Experimental) import MapboxMaps
import UIKit

/// DEBUG only: a six-car convoy over the Nafud dunes (`DemoTrail.dunesRaw`) for the
/// «واقعية القيادة» video and stills. `-demo -SaryMotionDemo [startS]` replaces the map's
/// members with it; my car sends 1 Hz fixes, the others every ~3 s with server latency,
/// exactly what the real map receives. `-SaryMotionCam "zoom,pitch"`, `-SaryMotionRain`,
/// `-SaryMotionCalm` (no wind), `-SaryMotionTilt <deg>` (forces a pitch: axis check).
/// Clearly demo data; never mixed with a real outing.
enum MotionDemo {
    static let args = ProcessInfo.processInfo.arguments
    static let active = args.contains("-SaryMotionDemo")

    static func value(_ k: String) -> String? {
        guard let i = args.firstIndex(of: k), i + 1 < args.count, !args[i + 1].hasPrefix("-") else { return nil }
        return args[i + 1]
    }

    static var startS: Double { value("-SaryMotionDemo").flatMap(Double.init) ?? 20 }
    static var cam: (zoom: Double, pitch: Double) {
        let n = (value("-SaryMotionCam") ?? "").split(separator: ",").compactMap { Double($0) }
        return (n.first ?? 17.4, n.count > 1 ? n[1] : 58)
    }

    struct Car {
        var id: String
        var color: UInt32
        /// Seconds behind the lead along the route.
        var lagS: Double
        /// Metres right of the lead's line.
        var lateral: Double
        /// Seconds between this car's fixes.
        var interval: Double
        var phase: Double
    }

    static let cars: [Car] = [
        Car(id: "demo-me", color: 0xD6452F, lagS: 0, lateral: 0, interval: 1, phase: 0),
        Car(id: "demo-2", color: 0x2F7DD6, lagS: 5, lateral: 1.8, interval: 3, phase: 0.4),
        Car(id: "demo-3", color: 0x3BA55C, lagS: 10, lateral: -1.5, interval: 3.4, phase: 1.1),
        Car(id: "demo-4", color: 0xE8B92E, lagS: 15, lateral: 2.4, interval: 2.8, phase: 2.0),
        Car(id: "demo-5", color: 0x8E5BD6, lagS: 20, lateral: -2.2, interval: 4, phase: 0.7),
        Car(id: "demo-6", color: 0xEEEEEE, lagS: 25, lateral: 0.8, interval: 3.2, phase: 1.6),
    ]

    static let raw: [RawFix] = {
        var r = DemoTrail.dunesRaw()
        /* The recorded outliers belong to the track-precision demo, not to this drive. */
        for i in [200, 350] where i > 0 && i + 1 < r.count {
            r[i].lat = (r[i - 1].lat + r[i + 1].lat) / 2
            r[i].lng = (r[i - 1].lng + r[i + 1].lng) / 2
            r[i].acc = 6
        }
        return r
    }()

    private(set) static var wallStart: Double = 0
    private(set) static var clockStart: CFTimeInterval = 0
    static var timer: Timer?
    static var bearing: Double?

    /// The route at time t (seconds, raw[0] is t = 1).
    static func at(_ t: Double) -> (p: LngLat, speed: Double, course: Double, acc: Double) {
        let i = max(0, min(Double(raw.count - 1), t - 1))
        let a = Int(i.rounded(.down)), b = min(raw.count - 1, a + 1), k = i - Double(a)
        let A = raw[a], B = raw[b]
        let d = MotionTuning.signedDiff(A.crs ?? 0, B.crs ?? 0)
        return (LngLat(lng: A.lng + (B.lng - A.lng) * k, lat: A.lat + (B.lat - A.lat) * k), (A.spd ?? 0) + ((B.spd ?? 0) - (A.spd ?? 0)) * k,
                MotionTuning.norm((A.crs ?? 0) + d * k), A.acc ?? 6)
    }

    /// Every car's latest fix that has "arrived" by now.
    static func members(now: CFTimeInterval) -> [MapMember] {
        let elapsed = now - clockStart
        return cars.map { c in
            let latency = c.id == "demo-me" ? 0.3 : 1.5
            let tau = startS + elapsed - c.lagS - latency
            let fixT = c.interval == 1 ? tau.rounded(.down) : ((tau - c.phase) / c.interval).rounded(.down) * c.interval + c.phase
            let f = at(fixT)
            let q = TrailGeo.lngLat(cos(f.course * .pi / 180) * c.lateral, -sin(f.course * .pi / 180) * c.lateral, ref: f.p)
            let atMs = wallStart + (fixT + c.lagS - startS) * 1000
            return MapMember(id: c.id, position: q, color: c.color, name: c.id, presence: .live,
                             heading: f.speed > 1 ? f.course : nil, accuracyM: f.acc, speedMps: f.speed, atMs: atMs,
                             note: nil, isMe: c.id == "demo-me")
        }
    }
}

extension OutingMapboxView.Coordinator {
    /// `-SaryMotionDemo`: feed the convoy at 10 Hz (members change only when a fix "arrives").
    func startDemo() {
        guard MotionDemo.active, MotionDemo.timer == nil else { return }
        MotionDemo.debugEnvironment()
        MotionDemo.begin()
        keepGroup = false
        let cam = MotionDemo.cam
        /* `-SaryMotionLook "lat,lng,zoom"`: hold the camera on a place (OSM desert tracks check). */
        let look = (MotionDemo.value("-SaryMotionLook") ?? "").split(separator: ",").compactMap { Double($0) }
        if look.count == 3 {
            fx.demoCamera = { m, _ in
                m.setCamera(to: CameraOptions(center: CLLocationCoordinate2D(latitude: look[0], longitude: look[1]), zoom: look[2], bearing: 0, pitch: 0))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [weak self] in
                guard let m = self?.map?.mapboxMap else { return }
                NSLog("SaryOSM layers=%@ vis=%@", OffroadTracks.layerIds.filter { m.layerExists(withId: $0) }.joined(separator: ","),
                      String(describing: m.layerProperty(for: OffroadTracks.casingLayer, property: "visibility").value))
                m.querySourceFeatures(for: RoadSnap.source, options: SourceQueryOptions(sourceLayerIds: ["road"], filter: ["match", ["get", "class"], ["track", "path"], true, false])) { r in
                    if case let .success(f) = r {
                        var seen: [String: Int] = [:]
                        for q in f {
                            let p = q.queriedFeature.feature.properties ?? [:]
                            func str(_ k: String) -> String { if case let .string(s)?? = p[k] { return s }; return "-" }
                            seen["\(str("class"))|\(str("type"))|\(str("surface"))", default: 0] += 1
                        }
                        NSLog("SaryOSM source tracks=%d %@", f.count, seen.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
                    }
                }
                m.queryRenderedFeatures(with: CGRect(x: 0, y: 0, width: 400, height: 800), options: RenderedQueryOptions(layerIds: OffroadTracks.layerIds, filter: nil)) { r in
                    if case let .success(f) = r {
                        let kinds = f.compactMap { q -> String? in
                            if case let .string(t)?? = q.queriedFeature.feature.properties?["type"] { return t }
                            return nil
                        }
                        NSLog("SaryOSM rendered=%d types=%@", f.count, Set(kinds).sorted().joined(separator: ","))
                    }
                }
            }
        } else {
        fx.demoCamera = { m, me in
            guard let raw = me.pose.heading else { return }
            /* `-SaryMotionSide`: look at the car's left side (nose to the screen's right). */
            let h = MotionDemo.args.contains("-SaryMotionSide") ? MotionTuning.norm(raw - 90) : raw
            let b = MotionDemo.bearing ?? h
            let nb = MotionTuning.norm(b + MotionTuning.signedDiff(b, h) * 0.02)
            MotionDemo.bearing = nb
            m.setCamera(to: CameraOptions(center: me.pose.position.coordinate, padding: UIEdgeInsets(top: 0, left: 0, bottom: 260, right: 0),
                                          zoom: cam.zoom, bearing: nb, pitch: cam.pitch))
        }
        }
        MotionDemo.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.syncDemo()
        }
    }

    func syncDemo() {
        guard MotionDemo.clockStart > 0 else { return }
        keepGroup = false
        sync(MotionDemo.members(now: CACurrentMediaTime()))
    }
}

extension MotionDemo {
    static func begin() {
        wallStart = Date().timeIntervalSince1970 * 1000
        clockStart = CACurrentMediaTime()
    }

    static func debugEnvironment() {
        let wind: DustWind? = args.contains("-SaryMotionCalm") ? nil : DustWind(fromDeg: 300, kmh: 22)
        DrivingWeather.debugSet(wind: wind, raining: args.contains("-SaryMotionRain"))
        if let t = value("-SaryMotionTilt").flatMap(Double.init) { forcedTilt = t }
    }

    /// Axis check: a fixed pitch on every car.
    static var forcedTilt: Double?
}
#endif
