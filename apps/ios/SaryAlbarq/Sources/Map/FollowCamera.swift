import Foundation

/// «تتبعني» / «باتجاهي»: the live map's camera modes (the button where «موقعي» was).
///
/// * `.free` — the map is the person's: nothing moves it.
/// * `.north` («تتبعني») — my car stays centred, north up, flat.
/// * `.heading` («باتجاهي») — the navigation camera: behind my car, the map turned to where I
///   am going (course when moving, the compass when slow), tilted ~58°, the car in the lower
///   part of the clear area so the road ahead shows, zoom from speed.
///
/// Pure (every rule here is unit-tested in `FollowCameraTests`); the map's per-frame driver
/// (`FollowCameraDriver`) turns it into a camera.
enum MapFollowMode: String, Equatable, CaseIterable {
    case free
    case north
    case heading

    /// The button cycles: free → «تتبعني» → «باتجاهي» → free.
    var next: MapFollowMode {
        switch self {
        case .free: return .north
        case .north: return .heading
        case .heading: return .free
        }
    }

    /// The button's glyph (standard iOS location symbols).
    var systemImage: String {
        switch self {
        case .free: return "location"
        case .north: return "location.fill"
        case .heading: return "location.north.line.fill"
        }
    }

    /// The button's caption / VoiceOver label: what the camera does now.
    var label: String {
        switch self {
        case .free: return "موقعي"
        case .north: return "تتبعني"
        case .heading: return "باتجاهي"
        }
    }

    /// VoiceOver hint: what a tap does next.
    var hint: String {
        switch self {
        case .free: return "اضغط لتتبع سيارتك والشمال للأعلى"
        case .north: return "اضغط لتدوير الخريطة مع اتجاه سيرك"
        case .heading: return "اضغط لتحريك الخريطة بحرية"
        }
    }
}

/// The mode, plus «رجّعني للتوجيه»: a pan / pinch / rotate drops a following camera to free;
/// when it was «باتجاهي» the big pill offers it back, and (moving, untouched for a while) it
/// comes back by itself.
struct FollowCameraState: Equatable {
    private(set) var mode: MapFollowMode = .free
    /// «رجّعني للتوجيه» shows (a gesture or «نظرة عامة» left «باتجاهي»).
    private(set) var recenterOffered = false
    /// Last time a finger was on the map (seconds, any clock).
    private(set) var lastTouchAt: TimeInterval?
    /// A finger is on the screen now: never recentre under it.
    private(set) var touching = false
    /// «باتجاهي» was entered by guidance starting (not the button).
    private(set) var auto = false

    /// The button.
    mutating func cycle() {
        mode = mode.next
        recenterOffered = false
        auto = false
    }

    /// Guidance started or resumed («ابدأ الملاحة», «للكل», «استأنف التوجيه», «اسلك هذا المسار», «طريق العودة»).
    mutating func guidanceStarted() {
        mode = .heading
        recenterOffered = false
        auto = true
    }

    /// Guidance ended: the pill has nothing to bring back.
    mutating func guidanceEnded() {
        recenterOffered = false
    }

    /// The person moved the map (pan, pinch, rotate, tilt, double-tap zoom) at `t`.
    mutating func userMovedMap(at t: TimeInterval) {
        lastTouchAt = t
        guard mode != .free else { return }
        if mode == .heading { recenterOffered = true }
        mode = .free
    }

    /// The camera was taken for something else on purpose (a member, the group, a point, «نظرة عامة»).
    /// `offerBack`: «نظرة عامة» while guiding keeps the pill.
    mutating func release(offerBack: Bool = false, at t: TimeInterval? = nil) {
        if offerBack, mode == .heading || recenterOffered { recenterOffered = true } else { recenterOffered = false }
        if let t { lastTouchAt = t }
        mode = .free
        auto = false
    }

    /// Any finger down / up on the screen (resets the auto-recenter clock).
    mutating func touch(down: Bool, at t: TimeInterval) {
        touching = down
        lastTouchAt = t
    }

    /// «رجّعني للتوجيه».
    mutating func recenter() {
        mode = .heading
        recenterOffered = false
    }

    /// Recentre by itself: offered, enabled, nobody touching, untouched for `after` s, moving faster than `minKmh`.
    func shouldAutoRecenter(now: TimeInterval, speedKmh: Double?, prefs: FollowCameraPrefs.Snapshot) -> Bool {
        guard recenterOffered, prefs.autoRecenter, !touching, let s = speedKmh, s > prefs.minKmh else { return false }
        guard let last = lastTouchAt else { return true }
        return now - last >= prefs.afterS
    }
}

/// «ارجع للتوجيه تلقائيًا»: the setting (on by default; 10 s; above 10 km/h).
enum FollowCameraPrefs {
    static let autoKey = "sary.camera.autoRecenter.v1"
    static let afterKey = "sary.camera.autoRecenterAfter.v1"
    static let keys = [autoKey, afterKey]
    static let defaultAfterS: TimeInterval = 10
    static let minKmh = 10.0

    struct Snapshot: Equatable {
        var autoRecenter = true
        var afterS: TimeInterval = FollowCameraPrefs.defaultAfterS
        var minKmh = FollowCameraPrefs.minKmh
    }

    static func snapshot(_ d: UserDefaults = .standard) -> Snapshot {
        var s = Snapshot()
        s.autoRecenter = d.object(forKey: autoKey) as? Bool ?? true
        if let a = d.object(forKey: afterKey) as? Double, a >= 3 { s.afterS = a }
        return s
    }

    static func setAuto(_ on: Bool, _ d: UserDefaults = .standard) { d.set(on, forKey: autoKey) }
    static func setAfter(_ s: TimeInterval, _ d: UserDefaults = .standard) { d.set(s, forKey: afterKey) }
}

// MARK: - heading

/// Where «باتجاهي» points: the course while really moving, the compass when slow or stopped.
/// Hysteresis on speed (no flip-flop around the threshold), a dead-band on the compass (a
/// phone in a cup holder must not spin the map), and the last good direction kept otherwise.
struct FollowHeadingSource: Equatable {
    /// Course takes over above this…
    static let courseOnKmh = 6.0
    /// …and hands back to the compass below this.
    static let courseOffKmh = 3.5
    /// The compass moves the map only when it turned at least this much from what is shown…
    static let compassDeadbandDeg = 12.0
    /// …and only when it is this accurate (CLHeading.headingAccuracy; negative = invalid).
    static let compassMaxErrorDeg = 35.0

    enum Source: Equatable { case course, compass, held }

    private(set) var usingCourse = false
    private(set) var bearing: Double?
    private(set) var source: Source = .held

    /// One sample: ground speed (km/h), the car's course (the smoothed pose's heading), the
    /// compass (true heading) and its error. Returns the bearing to aim at (nil: never known).
    @discardableResult
    mutating func update(speedKmh: Double?, course: Double?, compass: Double?, compassError: Double?) -> Double? {
        let v = max(0, speedKmh ?? 0)
        if usingCourse {
            if v < Self.courseOffKmh || course == nil { usingCourse = false }
        } else if v >= Self.courseOnKmh, course != nil {
            usingCourse = true
        }
        if usingCourse, let c = course {
            bearing = FollowMath.norm(c)
            source = .course
            return bearing
        }
        if let h = compass, h.isFinite, h >= 0, let e = compassError, e >= 0, e <= Self.compassMaxErrorDeg {
            if let b = bearing {
                if abs(FollowMath.delta(b, h)) >= Self.compassDeadbandDeg {
                    bearing = FollowMath.norm(h)
                    source = .compass
                }
            } else {
                bearing = FollowMath.norm(h)
                source = .compass
            }
            return bearing
        }
        /* No compass (simulator, interference): a course that is still known, else hold. */
        if bearing == nil, let c = course { bearing = FollowMath.norm(c) }
        source = .held
        return bearing
    }
}

// MARK: - zoom, pitch, placement

enum FollowZoom {
    /// Speed (km/h) → zoom for «باتجاهي»: closer in town, further out on the highway.
    static let curve: [(kmh: Double, zoom: Double)] = [(0, 17.4), (15, 17.1), (40, 16.5), (70, 15.9), (100, 15.3), (130, 14.8)]
    static let headingPitch = 58.0
    /// «باتجاهي»: the car sits this far down the clear area (0 = top, 1 = bottom).
    static let carScreenShare = 0.74
    /// «تتبعني» keeps the person's zoom, but never further out than this.
    static let northMinZoom = 14.0

    static func zoom(kmh: Double?) -> Double {
        let v = max(0, kmh ?? 0)
        guard let first = curve.first, let last = curve.last else { return 16 }
        if v <= first.kmh { return first.zoom }
        if v >= last.kmh { return last.zoom }
        for i in 1..<curve.count where v <= curve[i].kmh {
            let a = curve[i - 1], b = curve[i]
            let u = (v - a.kmh) / (b.kmh - a.kmh)
            return a.zoom + (b.zoom - a.zoom) * u
        }
        return last.zoom
    }

    /// Camera padding (top, bottom) that puts the camera centre — my car — at `share` of the
    /// clear area (between our top chrome and the sheet): 0.5 is its middle.
    static func padding(clearTop: Double, clearBottom: Double, height: Double, share: Double) -> (top: Double, bottom: Double) {
        let clear = max(1, height - clearTop - clearBottom)
        /* The camera centre is the middle of the padded area: (top + height − bottom) / 2. */
        let y = clearTop + share * clear
        let twice = 2 * y - height
        return twice >= 0 ? (twice, 0) : (0, -twice)
    }
}

// MARK: - smoothing

enum FollowMath {
    static func norm(_ d: Double) -> Double { (d.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }

    /// Shortest signed turn from `a` to `b`, in (-180, 180].
    static func delta(_ a: Double, _ b: Double) -> Double {
        var d = norm(b) - norm(a)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// Exponential approach with time constant `tau` over `dt` seconds.
    static func approach(_ from: Double, _ to: Double, dt: Double, tau: Double) -> Double {
        guard tau > 0, dt > 0 else { return to }
        return from + (to - from) * (1 - exp(-dt / tau))
    }

    /// Bearing approach along the short way, at most `maxRate` °/s (no whip-around).
    static func approachBearing(_ from: Double, _ to: Double, dt: Double, tau: Double, maxRate: Double) -> Double {
        let d = delta(from, to)
        var step = d * (tau > 0 && dt > 0 ? 1 - exp(-dt / tau) : 1)
        let cap = maxRate * max(0, dt)
        step = max(-cap, min(cap, step))
        return norm(from + step)
    }

    /// Smoothstep 0…1.
    static func ease(_ t: Double) -> Double {
        let x = max(0, min(1, t))
        return x * x * (3 - 2 * x)
    }
}

/// The camera a frame asks for (no map types: unit-tested).
struct FollowCameraPose: Equatable {
    var center: LngLat
    var zoom: Double
    var bearing: Double
    var pitch: Double
    var topPadding: Double
    var bottomPadding: Double
}

/// Frame-by-frame camera for «تتبعني» / «باتجاهي»: eases in from wherever the camera was
/// (`entryS`), then tracks the car's smoothed pose exactly (no lag) while zoom, bearing,
/// pitch and padding glide (no jitter: the bearing turns at most `maxTurnDegS`).
struct FollowCameraSmoother: Equatable {
    static let entryS = 0.9
    static let bearingTau = 0.45
    static let maxTurnDegS = 75.0
    static let zoomTau = 1.6
    static let pitchTau = 0.5
    static let paddingTau = 0.35

    private(set) var mode: MapFollowMode = .free
    private(set) var shown: FollowCameraPose?
    private var start: FollowCameraPose?
    private var enteredAt: TimeInterval = 0
    private var lastAt: TimeInterval?

    /// A new mode, entered from the camera as it is now.
    mutating func enter(_ m: MapFollowMode, from current: FollowCameraPose, at t: TimeInterval) {
        mode = m
        start = current
        shown = current
        enteredAt = t
        lastAt = t
    }

    var entering: Bool { start != nil }

    /// One frame toward `target`. Returns the camera to set and whether it is still moving.
    mutating func step(target: FollowCameraPose, at t: TimeInterval, reduceMotion: Bool = false) -> (pose: FollowCameraPose, settling: Bool) {
        let dt = max(0, min(0.25, t - (lastAt ?? t)))
        lastAt = t
        var s = shown ?? target
        if reduceMotion {
            s = target
        } else {
            s.zoom = FollowMath.approach(s.zoom, target.zoom, dt: dt, tau: Self.zoomTau)
            s.pitch = FollowMath.approach(s.pitch, target.pitch, dt: dt, tau: Self.pitchTau)
            s.topPadding = FollowMath.approach(s.topPadding, target.topPadding, dt: dt, tau: Self.paddingTau)
            s.bottomPadding = FollowMath.approach(s.bottomPadding, target.bottomPadding, dt: dt, tau: Self.paddingTau)
            s.bearing = FollowMath.approachBearing(s.bearing, target.bearing, dt: dt, tau: Self.bearingTau, maxRate: Self.maxTurnDegS)
            s.center = target.center
        }
        var out = s
        if let a = start, !reduceMotion {
            /* Entry: blend from where the camera was, along the short way round. */
            let w = FollowMath.ease((t - enteredAt) / Self.entryS)
            out.center = LngLat(lng: a.center.lng + (s.center.lng - a.center.lng) * w, lat: a.center.lat + (s.center.lat - a.center.lat) * w)
            out.zoom = a.zoom + (s.zoom - a.zoom) * w
            out.pitch = a.pitch + (s.pitch - a.pitch) * w
            out.topPadding = a.topPadding + (s.topPadding - a.topPadding) * w
            out.bottomPadding = a.bottomPadding + (s.bottomPadding - a.bottomPadding) * w
            out.bearing = FollowMath.norm(a.bearing + FollowMath.delta(a.bearing, s.bearing) * w)
            if w >= 1 { start = nil }
        } else {
            start = nil
        }
        shown = s
        let settling = start != nil || abs(s.zoom - target.zoom) > 0.01 || abs(s.pitch - target.pitch) > 0.1
            || abs(FollowMath.delta(s.bearing, target.bearing)) > 0.2 || abs(s.topPadding - target.topPadding) > 0.5
            || abs(s.bottomPadding - target.bottomPadding) > 0.5
        return (out, settling)
    }
}
