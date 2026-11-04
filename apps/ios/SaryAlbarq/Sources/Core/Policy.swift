import Foundation

/// When to send a fix and how to describe someone else's — a line-for-line port
/// of `apps/web/src/lib/outings/policy.ts`. Change both or neither: the web and
/// the app must describe the same person the same way.
///
/// Three things are never mixed:
///   fix         where the device says it is (and how sure it is)
///   connection  whether it can talk to us now (heartbeats)
///   freshness   how old the last real fix is
enum Policy {
    /// Speed tiers, m/s.
    static let fastMps = 25.0 // 90 km/h
    static let slowMps = 5.5 // 20 km/h
    static let stillMps = 1.5

    /// Never two fixes closer than this, whatever the tier.
    static let sendFloorMs = 1_000.0

    /// Accuracy grades.
    static let goodAccuracyM = 30.0
    static let weakAccuracyM = 60.0
    /// Worse than this, the fix is not sent at all.
    static let sendMaxAccuracyM = 150.0

    /// Above this, a jump is a GPS glitch until the next fix agrees (~200 km/h).
    static let maxPlausibleMps = 55.0

    /// Connection heartbeat (no coordinates) — separate from fixes.
    static let linkHeartbeatMs = 15_000.0

    static let liveMovingMs = 15_000.0
    /// Parked phones get a fresh fix every 30 s; a parked position does not go stale by standing still.
    static let liveParkedMs = 45_000.0
    static let connectionLostMs = 60_000.0

    /// GPS course only while really moving; a parked car gets no arrow.
    static let headingMinSpeedMps = 3.0

    /// A pending fix older than this is dropped rather than sent (server cap is 60 s).
    static let maxSendAgeMs = 55_000.0

    enum TierName: String { case fast, normal, slow }

    struct Tier: Equatable {
        var intervalMs: Double
        var distanceM: Double
    }

    static func baseTier(_ name: TierName) -> Tier {
        switch name {
        case .fast: return Tier(intervalMs: 2_500, distanceM: 50)
        case .normal: return Tier(intervalMs: 4_000, distanceM: 35)
        case .slow: return Tier(intervalMs: 6_000, distanceM: 15)
        }
    }

    static func tierName(speedMps: Double?) -> TierName {
        let s = speedMps ?? 0
        return s >= fastMps ? .fast : s >= slowMps ? .normal : .slow
    }

    /// The person's choice scales the tiers: saver halves the rate, precise speeds it up.
    static func modeScale(_ mode: ShareMode) -> Double {
        switch mode {
        case .precise: return 0.6
        case .balanced: return 1
        case .saver: return 2
        }
    }

    static func tier(speedMps: Double?, mode: ShareMode = .balanced) -> Tier {
        let base = baseTier(tierName(speedMps: speedMps))
        let k = modeScale(mode)
        return Tier(intervalMs: (base.intervalMs * k).rounded(), distanceM: (base.distanceM * k).rounded())
    }

    /// Parked: a fresh real fix this often, so others still see you as there.
    static func heartbeatMs(_ mode: ShareMode = .balanced) -> Double {
        mode == .saver ? 60_000 : 30_000
    }

    enum AccuracyGrade { case good, fair, poor }

    static func accuracyGrade(_ m: Double?) -> AccuracyGrade {
        guard let m, m.isFinite else { return .fair }
        if m <= goodAccuracyM { return .good }
        if m <= weakAccuracyM { return .fair }
        return .poor
    }

    /// Speed the movement implies, after giving both fixes the benefit of their error.
    static func impliedSpeedMps(_ a: DeviceFix, _ b: DeviceFix) -> Double {
        let dt = (b.atMs - a.atMs) / 1000
        if dt <= 0 { return .infinity }
        let slack = (a.accuracy ?? 0) + (b.accuracy ?? 0)
        return max(0, Geo.haversineMeters(a.coordinate, b.coordinate) - slack) / dt
    }

    struct LastSent: Equatable {
        var fix: DeviceFix
        var sentAtMs: Double
    }

    static func shouldSend(_ fix: DeviceFix, last: LastSent?, mode: ShareMode, nowMs: Double) -> Bool {
        if let a = fix.accuracy, a > sendMaxAccuracyM { return false }
        guard let last else { return true }
        if fix.atMs <= last.fix.atMs { return false }
        let since = nowMs - last.sentAtMs
        if since < sendFloorMs { return false }
        let t = tier(speedMps: fix.speed, mode: mode)
        let moved = Geo.haversineMeters(last.fix.coordinate, fix.coordinate)
        if moved >= t.distanceM { return true }
        let moving = (fix.speed ?? 0) >= stillMps || moved >= max(10, fix.accuracy ?? 0)
        if moving && since >= t.intervalMs { return true }
        return since >= heartbeatMs(mode)
    }

    ///   live     a real fix recent enough for its motion (15 s moving, 45 s parked)
    ///   recent   reachable, but the last fix is older — «آخر موقع معروف»
    ///   lost     nothing heard for 60 s — «انقطع الاتصال»
    enum Freshness: String { case live, recent, lost }

    static func freshness(fixAgeMs: Double, speedMps: Double?, lastSeenAgeMs: Double?) -> Freshness {
        let seenAge = min(lastSeenAgeMs ?? .infinity, fixAgeMs)
        let moving = (speedMps ?? 0) >= stillMps
        if fixAgeMs <= (moving ? liveMovingMs : liveParkedMs) { return .live }
        return seenAge > connectionLostMs ? .lost : .recent
    }

    static func trustedHeading(_ heading: Double?, speed: Double?) -> Double? {
        guard let heading, heading.isFinite else { return nil }
        guard let speed, speed.isFinite, speed >= headingMinSpeedMps else { return nil }
        return (heading.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Serialise a device fix for the wire. Age is measured on this device's clock, now.
    static func wireFix(_ fix: DeviceFix, mode: ShareMode, nowMs: Double) -> WireFix {
        WireFix(
            lat: fix.lat, lng: fix.lng, accuracy: fix.accuracy, heading: fix.heading,
            speed: fix.speed, mode: mode, age_ms: max(0, (nowMs - fix.atMs).rounded())
        )
    }
}

/// A fix from this device, as CoreLocation reported it (negative values already mapped to nil).
struct DeviceFix: Equatable {
    var lat: Double
    var lng: Double
    var accuracy: Double?
    var heading: Double?
    var speed: Double?
    /// Device timestamp of the fix, ms since 1970.
    var atMs: Double

    var coordinate: Geo.LatLng { Geo.LatLng(lat: lat, lng: lng) }
}

/// Holds back an implausible jump until the next fix confirms it, so one bad
/// reading never moves you across the dunes on everyone's map.
struct FixFilter {
    private(set) var trusted: DeviceFix?
    private(set) var suspect: DeviceFix?

    mutating func accept(_ fix: DeviceFix) -> DeviceFix? {
        if let a = fix.accuracy, a > Policy.sendMaxAccuracyM { return nil }
        if let t = trusted, fix.atMs <= t.atMs { return nil }
        /* No reference, or the reference is too old to judge a jump by. */
        guard let t = trusted, fix.atMs - t.atMs <= 120_000 else { return trust(fix) }
        if Policy.impliedSpeedMps(t, fix) <= Policy.maxPlausibleMps { return trust(fix) }
        /* Implausible from the trusted fix — but if it agrees with the previous suspect, the jump was real. */
        if let s = suspect, Policy.impliedSpeedMps(s, fix) <= Policy.maxPlausibleMps { return trust(fix) }
        suspect = fix
        return nil
    }

    private mutating func trust(_ fix: DeviceFix) -> DeviceFix {
        trusted = fix
        suspect = nil
        return fix
    }

    mutating func reset() {
        trusted = nil
        suspect = nil
    }
}

enum Geo {
    struct LatLng: Equatable {
        var lat: Double
        var lng: Double
    }

    static let earthRadiusM = 6_371_000.0 // same as sary/domain.ts

    static func haversineMeters(_ a: LatLng, _ b: LatLng) -> Double {
        let r = Double.pi / 180
        let dLat = (b.lat - a.lat) * r
        let dLng = (b.lng - a.lng) * r
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.lat * r) * cos(b.lat * r) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * earthRadiusM * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from a to b, degrees clockwise from north.
    static func bearingDeg(_ a: LatLng, _ b: LatLng) -> Double {
        let r = Double.pi / 180
        let y = sin((b.lng - a.lng) * r) * cos(b.lat * r)
        let x = cos(a.lat * r) * sin(b.lat * r) - sin(a.lat * r) * cos(b.lat * r) * cos((b.lng - a.lng) * r)
        return (atan2(y, x) / r + 360).truncatingRemainder(dividingBy: 360)
    }

    private static let dirsAr = ["شمال", "شمال شرق", "شرق", "جنوب شرق", "جنوب", "جنوب غرب", "غرب", "شمال غرب"]

    static func directionLabel(_ deg: Double) -> String {
        let n = (deg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let i = Int((n / 45).rounded()) % 8
        return dirsAr[i]
    }
}
