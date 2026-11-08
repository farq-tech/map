@_spi(Experimental) import MapboxMaps
import UIKit

/// «واقعية القيادة» on the map: smooth motion for every car, plus dust, tyre tracks, body
/// tilt, night lights / day contact shadow and the OSM desert tracks.
///
/// Owned by the outing map's coordinator through a small hook (`ingest` per fix, `pose` and
/// `frame` per display frame, `styleLoaded`): it never draws or replaces the car itself,
/// it only adds its own layers under the cars and nudges the car layer's rotation (3D model)
/// or translation (2D icon). Subtle by design; off in Low Power Mode; Reduce Motion keeps
/// cars on their fixes with no animated effects.
final class MotionFX {
    struct Car {
        var id: String
        /// The car's own Mapbox layer (model or icon), from `Vehicle.ids`.
        var layer: String
        var isMe: Bool
        var pose: MotionPose
        /// Not on a matched drivable street (desert / sand).
        var offRoad: Bool
        /// The car layer exists in the style.
        var drawn: Bool
    }

    static let glowSource = "sary-fx-glow"
    static let glowLayer = "sary-fx-glow"
    static let rutsSource = "sary-fx-ruts"
    static let rutsLayer = "sary-fx-ruts"

    let book = MotionBook()
    let dust = DustSystem()
    private var ruts: [String: TyreTracks.Ruts] = [:]
    private var frameRef: MotionFrame?
    private weak var map: MapView?
    private var styleReady = false
    private var lastFrame: CFTimeInterval?
    private var prefs = DrivingRealismPrefs.snapshot()
    private var prefsAt: CFTimeInterval = 0
    private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var rutsDirty = false
    private var rutsAt: CFTimeInterval = 0
    private var glowEmpty = true
    private var sun: (el: Double, az: Double, at: CFTimeInterval)?
    private var tilt: [String: (pitch: Double, roll: Double, grade: Double?, sampledAt: CFTimeInterval)] = [:]
    private var applied: [String: [Double]] = [:]
    private var layerKind: [String: LayerType] = [:]
    private var osmShown: Bool?
    private let chip = GradeChipView()
    private var chipText: String?
    private var observers: [NSObjectProtocol] = []

    /// Context from the coordinator, refreshed every frame.
    var exploring = false
    var drive = false
    var night = false
    var exaggeration = 1.15

    #if DEBUG
    var demoCamera: ((MapboxMap, Car) -> Void)?
    private var fpsFrames = 0
    private var linkFrames = 0
    private var fpsSince: CFTimeInterval = 0
    private var fpsBag = Set<AnyCancelable>()
    private var probe: [String: (p: LngLat, v: Double)] = [:]
    private var maxDv = 0.0, maxStep = 0.0, maxDvCar = ""

    #endif

    func attach(_ map: MapView) {
        self.map = map
        chip.isHidden = true
        map.addSubview(chip)
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        })
        #if DEBUG
        /* fps of what Mapbox really renders (not the display link), logged every 5 s in the demo. */
        if MotionDemo.active {
            map.mapboxMap.onRenderFrameFinished.observe { [weak self] _ in
                guard let self else { return }
                let t = CACurrentMediaTime()
                self.fpsFrames += 1
                if t - self.fpsSince >= 5 {
                    if self.fpsSince > 0 {
                        NSLog("SaryFPS render=%.1f link=%.1f cars=%d particles=%d maxDv=%.2f(%@) maxStep=%.2f", Double(self.fpsFrames) / (t - self.fpsSince),
                              Double(self.linkFrames) / (t - self.fpsSince), self.book.cars.count, self.dust.particles.count, self.maxDv, self.maxDvCar, self.maxStep)
                        self.maxDv = 0
                        self.maxStep = 0
                    }
                    self.fpsSince = t
                    self.fpsFrames = 0
                    self.linkFrames = 0
                }
            }.store(in: &fpsBag)
        }
        #endif
    }

    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        chip.removeFromSuperview()
    }

    // MARK: fixes → poses

    /// A member's fix (the drawn target). Returns the pose to draw right now.
    func ingest(_ v: MapMember, target: LngLat, course: Double?, now: CFTimeInterval) -> MotionPose? {
        let reduce = UIAccessibility.isReduceMotionEnabled
        let m = book.motion(v.id, isMe: v.isMe)
        m.ingest(MotionFix(position: target, atMs: v.atMs, speedMps: v.speedMps, course: course, accuracyM: v.accuracyM,
                           live: v.presence == .live, approximate: v.approximate),
                 now: now, wallMs: Date().timeIntervalSince1970 * 1000, reduceMotion: reduce)
        return m.pose(now, reduceMotion: reduce)
    }

    func pose(_ id: String, now: CFTimeInterval) -> MotionPose? {
        book.cars[id]?.pose(now, reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }

    func keep(_ ids: Set<String>) {
        book.keep(ids)
        ruts = ruts.filter { ids.contains($0.key) }
        tilt = tilt.filter { ids.contains($0.key) }
    }

    // MARK: style

    func styleLoaded(_ m: MapboxMap) {
        styleReady = true
        applied.removeAll()
        layerKind.removeAll()
        osmShown = nil
        let ids = m.allLayerIdentifiers.map(\.id)
        /* Ruts and OSM tracks under every trail line; the glow just under the cars. */
        let underTrails = ids.first { $0.hasPrefix("sary-trail-") || $0.hasPrefix("sary-track-") || $0.hasPrefix("sary-explore-") || $0.hasPrefix("sary-nav-") }
        OffroadTracks.add(m, below: underTrails, visible: false)
        for src in [Self.rutsSource, Self.glowSource] where !m.sourceExists(withId: src) {
            var s = GeoJSONSource(id: src)
            s.data = .featureCollection(FeatureCollection(features: []))
            try? m.addSource(s)
        }
        /* One centre line per stretch, drawn twice with a pixel offset that follows the car's own
         * on-screen scale, so the two ruts always sit under the drawn wheels at any zoom. */
        for side in [-1.0, 1.0] {
            let id = Self.rutsLayer + (side < 0 ? "-l" : "-r")
            guard !m.layerExists(withId: id) else { continue }
            FXLog.add(m, [
                "id": id, "type": "line", "source": Self.rutsSource, "minzoom": 14.5,
                "layout": ["line-join": "round", "line-cap": "round"],
                "paint": [
                    "line-color": "#7d5e3a", "line-blur": 0.5,
                    "line-width": TyreTracks.zoomExpression(metres: TyreTracks.rutWidthM, min: 0.7),
                    "line-offset": TyreTracks.zoomExpression(metres: side * TyreTracks.halfTrackM, min: 0),
                    "line-opacity": ["interpolate", ["linear"], ["zoom"], 14.5, 0, 15.8, ["get", "o"]] as [Any],
                    "line-emissive-strength": 0.6,
                ] as [String: Any],
            ], layerPosition: underTrails.map { .below($0) })
        }
        if !m.layerExists(withId: Self.glowLayer) {
            let below = ids.first { $0.hasPrefix("sary-vehicle") }
            FXLog.add(m, [
                "id": Self.glowLayer, "type": "circle", "source": Self.glowSource,
                "layout": ["circle-sort-key": ["get", "z"]] as [String: Any],
                "paint": [
                    "circle-radius": ["interpolate", ["exponential", 2], ["zoom"], 10, ["get", "px"], 22, ["*", ["get", "px"], 4096]] as [Any],
                    "circle-color": ["get", "c"], "circle-opacity": ["get", "o"], "circle-blur": ["get", "b"],
                    "circle-pitch-alignment": "map", "circle-pitch-scale": "map",
                    "circle-emissive-strength": 0.9,
                ] as [String: Any],
            ], layerPosition: below.map { .below($0) })
        }
        glowEmpty = true
        rutsDirty = true
    }

    // MARK: frames

    /// Effects for this frame. Returns true while anything is still changing (keep the display link).
    func frame(_ m: MapboxMap, now: CFTimeInterval, cars: [Car]) -> Bool {
        let dt = lastFrame.map { min(0.1, max(0, now - $0)) } ?? 1.0 / 60
        lastFrame = now
        #if DEBUG
        linkFrames += 1
        /* Smoothness probe: the largest frame-to-frame change of drawn speed (m/s) and position step. */
        for c in cars {
            let p = c.pose.position
            if let q = probe[c.id], dt > 0 {
                let v = Vehicle.distanceMeters(q.p, p) / dt
                if abs(v - q.v) > maxDv, now - fpsSince > 0.5 { maxDvCar = c.id }
                if now - fpsSince > 0.5 { maxDv = max(maxDv, abs(v - q.v)) }
                maxStep = max(maxStep, Vehicle.distanceMeters(q.p, p))
                probe[c.id] = (p, v)
            } else { probe[c.id] = (p, 0) }
        }
        #endif
        if now - prefsAt > 1 {
            prefsAt = now
            prefs = DrivingRealismPrefs.snapshot()
            dust.wind = DrivingWeather.wind
        }
        let reduce = UIAccessibility.isReduceMotionEnabled
        /* The car is drawn larger than life until street zoom: effects scale with it. */
        let scale = Vehicle.scaleAt(zoom: m.cameraState.zoom)
        if frameRef == nil, let c = cars.first { frameRef = MotionFrame(origin: c.pose.position) }
        guard styleReady, let ref = frameRef else { return false }
        var more = false
        let me = cars.first(where: \.isMe)
        #if DEBUG
        if let me, let cam = demoCamera { cam(m, me) }
        #endif

        /* OSM desert tracks: exploration, or my car off-road. */
        let osm = OffroadTracks.visible(pref: prefs.osmTracks, exploring: exploring, offRoad: me?.offRoad ?? false)
        if osm != osmShown {
            osmShown = osm
            OffroadTracks.setVisible(m, osm)
        }

        /* Sun, from where I am (or the first car), every 30 s. */
        if let at = (me ?? cars.first)?.pose.position, sun == nil || now - sun!.at > 30 {
            let d = Date()
            sun = (SunLight.elevationDeg(d, lat: at.lat, lng: at.lng), CarLights.sunAzimuthDeg(d, lat: at.lat, lng: at.lng), now)
        }

        // Dust
        let dustOn = prefs.dust && !lowPower && !reduce
        if dustOn {
            let moving = cars.filter { $0.pose.moving }.count
            for c in cars {
                let kmh = c.pose.speedMps * 3.6
                guard let h = c.pose.heading,
                      DustGate.emits(speedKmh: kmh, onPavedRoad: !c.offRoad, raining: DrivingWeather.raining, enabled: true,
                                     lowPower: lowPower, reduceMotion: reduce, moving: c.pose.moving) else { continue }
                dust.emit(car: c.id, at: ref.local(c.pose.position), heading: h, speedMps: c.pose.speedMps, dt: dt, now: now,
                          driving: drive, activeCars: moving, scale: scale)
            }
        } else if !dust.isEmpty {
            dust.clear()
        }
        dust.step(dt: dt, now: now)

        // Tyre tracks
        if prefs.tracks && !lowPower {
            for c in cars {
                guard let h = c.pose.heading else { continue }
                let r = ruts[c.id] ?? TyreTracks.Ruts()
                ruts[c.id] = r
                if r.add(ref.local(c.pose.position), heading: h, at: now, sand: c.offRoad, moving: c.pose.moving) { rutsDirty = true }
            }
        } else if !ruts.isEmpty {
            ruts.removeAll()
            rutsDirty = true
        }
        if rutsDirty, now - rutsAt > 0.25 {
            rutsAt = now
            rutsDirty = false
            m.updateGeoJSONSource(withId: Self.rutsSource, geoJSON: .featureCollection(rutFeatures(ref, now: now)))
        }
        if !ruts.isEmpty { more = more || cars.contains { $0.pose.moving } }

        // Body tilt + bob
        for c in cars where c.drawn {
            more = applyBody(m, c, now: now, dt: dt, reduce: reduce) || more
        }

        // Glow: dust, lights, shadows
        var feats: [Feature] = []
        let lat = ref.origin.lat
        func circle(_ p: MotionVec, r: Double, color: String, o: Double, blur: Double, z: Double, emissive: Double) {
            guard o > 0.004 else { return }
            var f = Feature(geometry: .point(Point(ref.world(p).coordinate)))
            f.properties = ["px": .number(r * 1024 / (78_271.517 * cos(lat * .pi / 180))), "c": .string(color), "o": .number(o),
                            "b": .number(blur), "z": .number(z), "e": .number(emissive)]
            feats.append(f)
        }
        let el = sun?.el ?? 30
        let lights = prefs.lights && !lowPower
        let lightsOn = lights && CarLights.lightsOn(elevationDeg: el, forcedNight: night)
        let shadow = lights && !night ? CarLights.shadow(elevationDeg: el, azimuthDeg: sun?.az ?? 0) : nil
        for c in cars where c.drawn {
            let p = ref.local(c.pose.position)
            let h = c.pose.heading ?? 0
            if let s = shadow {
                let back = MotionVec.heading(h, -(tilt[c.id]?.pitch ?? 0) / BodyDynamics.maxPitchDeg * 0.8)
                circle(p + (s.offset + back) * scale, r: 2.6 * scale, color: "#000000", o: s.opacity * (drive ? 0.8 : 1), blur: 0.85, z: 0, emissive: 0)
            }
            if lightsOn, c.pose.moving {
                /* Owner 2026-11-07: «شوي زيادة، مو مرة». Measured on satellite at night: the old
                 * pale, fully blurred beam added ~0.5% brightness ahead of the car (invisible).
                 * Now a visible soft glow that fades with distance, reach 23 m → 27 m. */
                let k = drive ? 0.85 : 1.0
                for (d, r, o) in [(5.0, 2.3, 0.62), (10.0, 3.6, 0.46), (16.0, 4.9, 0.30), (22.0, 6.0, 0.17), (27.0, 6.8, 0.08)] {
                    circle(p + MotionVec.heading(h, d * scale), r: r * scale, color: "#fff1c4", o: o * k, blur: 0.75, z: 1, emissive: 1)
                }
                for s in [-0.7, 0.7] {
                    circle(p + MotionVec.heading(h, -2.55 * scale) + MotionVec.heading(h + 90, s * scale), r: 0.75 * scale, color: "#ff2a1a", o: 0.55 * k, blur: 1, z: 1, emissive: 1)
                }
            }
        }
        for part in dust.particles {
            /* At night dust is only seen where light falls on it: dimmer and greyer. */
            circle(part.p, r: part.radius(now), color: lightsOn ? "#a99a80" : "#efe3c8", o: part.opacity(now) * (lightsOn ? 0.5 : 1), blur: 1, z: 2, emissive: 0.85)
        }
        if !feats.isEmpty || !glowEmpty {
            m.updateGeoJSONSource(withId: Self.glowSource, geoJSON: .featureCollection(FeatureCollection(features: feats)))
            glowEmpty = feats.isEmpty
        }
        more = more || !dust.isEmpty || (lightsOn && cars.contains { $0.pose.moving })

        // Grade chip by my car
        updateChip(m, me: me)
        return more
    }

    private func rutFeatures(_ ref: MotionFrame, now: CFTimeInterval) -> FeatureCollection {
        var feats: [Feature] = []
        for r in ruts.values {
            for piece in TyreTracks.pieces(r.samples, now: now) {
                var f = Feature(geometry: .lineString(LineString(piece.points.map { ref.world($0).coordinate })))
                f.properties = ["o": .number(piece.opacity)]
                feats.append(f)
            }
        }
        return FeatureCollection(features: feats)
    }

    /// Terrain tilt (sampled ~10 Hz, smoothed) and the suspension bob, onto the car's own layer.
    private func applyBody(_ m: MapboxMap, _ c: Car, now: CFTimeInterval, dt: Double, reduce: Bool) -> Bool {
        let on = prefs.tilt && !lowPower
        var t = tilt[c.id] ?? (0, 0, nil, 0)
        var target = (pitch: 0.0, roll: 0.0)
        var grade: Double? = t.grade
        if on, let h = c.pose.heading {
            if now - t.sampledAt > 0.1 {
                t.sampledAt = now
                let pos = c.pose.position
                func at(_ along: Double, _ across: Double) -> Double? {
                    let o = MotionVec.heading(h, along) + MotionVec.heading(h + 90, across)
                    let q = MotionFrame(origin: pos).world(o)
                    return m.elevation(at: q.coordinate)
                }
                if let f = at(BodyDynamics.alongM, 0), let b = at(-BodyDynamics.alongM, 0),
                   let l = at(0, -BodyDynamics.acrossM), let r = at(0, BodyDynamics.acrossM) {
                    /* Drawn on the exaggerated terrain: tilt with it; the grade in real metres. */
                    target = BodyDynamics.tilt(front: f, back: b, left: l, right: r)
                    grade = BodyDynamics.gradePercent(front: f / exaggeration, back: b / exaggeration)
                } else {
                    grade = nil
                }
                #if DEBUG
                if let f = MotionDemo.forcedTilt { target = (f, 0) }
                #endif
                tilt[c.id] = (BodyDynamics.smooth(t.pitch, target.pitch, dt: 0.1), BodyDynamics.smooth(t.roll, target.roll, dt: 0.1), grade, now)
            }
        } else {
            tilt[c.id] = (BodyDynamics.smooth(t.pitch, 0, dt: dt), BodyDynamics.smooth(t.roll, 0, dt: dt), nil, t.sampledAt)
        }
        let s = tilt[c.id]!
        let seed = Double(abs(c.id.hashValue % 997)) / 97
        let bob: (pitch: Double, roll: Double) = on && !reduce ? BodyDynamics.bob(t: now, speedKmh: c.pose.speedMps * 3.6, offRoad: c.offRoad, seed: seed) : (0, 0)
        let k = drive ? 0.5 : 1.0
        let pitch = s.pitch + bob.pitch * k, roll = s.roll + bob.roll * k
        let kind = layerKind[c.layer] ?? (try? m.layer(withId: c.layer))?.type
        if let kind { layerKind[c.layer] = kind }
        var value: [Double]
        var property: String
        switch kind {
        case .model?:
            property = "model-rotation"
            value = BodyDynamics.modelRotation(heading: c.pose.heading, pitch: pitch, roll: roll)
        case .symbol?:
            /* 2D icon: a tiny shift forward on a climb plus the bob; the shadow says the rest. */
            property = "icon-translate"
            let shift = BodyDynamics.iconShift(pitch: pitch, bob: bob.pitch * k)
            let fwd = MotionVec.heading(c.pose.heading ?? 0, pitch / BodyDynamics.maxPitchDeg * 1.5)
            value = [fwd.x, -fwd.y + shift.car]
            if applied[c.layer] == nil { try? m.setLayerProperty(for: c.layer, property: "icon-translate-anchor", value: "map") }
        default:
            return false
        }
        let last = applied[c.layer]
        let changed = last == nil || zip(last!, value).contains { abs($0 - $1) > 0.02 } || property == "model-rotation"
        if changed {
            try? m.setLayerProperty(for: c.layer, property: property, value: value)
            applied[c.layer] = value
        }
        let settling = abs(s.pitch - target.pitch) > 0.05 || abs(s.roll - target.roll) > 0.05
        return (bob.pitch != 0 || bob.roll != 0) || (on && settling) || (!on && (abs(s.pitch) > 0.05 || abs(s.roll) > 0.05))
    }

    private func updateChip(_ m: MapboxMap, me: Car?) {
        guard let me, prefs.tilt, !lowPower, let map else {
            chip.isHidden = true
            chipText = nil
            return
        }
        let text = BodyDynamics.gradeChip(grade: tilt[me.id]?.grade, shown: chipText != nil, speedKmh: me.pose.speedMps * 3.6, driving: drive)
        if text != chipText {
            chipText = text
            chip.set(text, night: night)
        }
        guard text != nil else { chip.isHidden = true; return }
        let pt = m.point(for: me.pose.position.coordinate)
        guard pt.x >= 0, pt.y >= 0, map.bounds.contains(pt) else { chip.isHidden = true; return }
        chip.isHidden = false
        let s = chip.bounds.size
        chip.center = CGPoint(x: pt.x, y: pt.y + 30 + s.height / 2)
    }
}

/// «صعود ١٢٪» beside my car: small, never in the way.
final class GradeChipView: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = 9
        layer.cornerCurve = .continuous
        label.font = UIFont.systemFont(ofSize: 12, weight: .bold)
        label.textAlignment = .center
        addSubview(label)
        accessibilityIdentifier = "map.gradeChip"
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ text: String?, night: Bool) {
        label.text = text
        accessibilityLabel = text.map { $0.replacingOccurrences(of: "▲ ", with: "").replacingOccurrences(of: "▼ ", with: "") + " تقريبًا" }
        backgroundColor = night ? UIColor(white: 0.1, alpha: 0.82) : UIColor(white: 1, alpha: 0.9)
        label.textColor = night ? .white : UIColor(red: 0.2, green: 0.14, blue: 0.08, alpha: 1)
        label.sizeToFit()
        let w = label.bounds.width + 14, h: CGFloat = 20
        bounds = CGRect(x: 0, y: 0, width: w, height: h)
        label.frame = bounds
    }
}

/// Adds a style layer; a refused layer is logged (DEBUG) instead of silently missing.
enum FXLog {
    static func add(_ m: MapboxMap, _ json: [String: Any], layerPosition: LayerPosition?) {
        do { try m.addLayer(with: json, layerPosition: layerPosition) } catch {
            #if DEBUG
            NSLog("SaryFX layer %@ refused: %@", String(describing: json["id"] ?? "?"), String(describing: error))
            #endif
        }
    }
}
