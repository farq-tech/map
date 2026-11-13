import CoreLocation
import Foundation

/// How hard to drive the GPS for a given share mode, motion and battery — pure,
/// so the choices are tested rather than buried in a delegate.
///
/// The send policy (`Policy.shouldSend`) decides what reaches the server; this
/// decides what the chip spends getting fixes. We keep `distanceFilter` off
/// while sharing because a parked car still has to send a fresh fix every
/// 30–60 s (its heartbeat), and with a distance filter a parked phone gets no
/// callbacks at all and its last fix would age past the server's 60 s limit.
enum LocationTuning {
    struct Settings: Equatable {
        var desiredAccuracy: CLLocationAccuracy
        var distanceFilter: CLLocationDistance
    }

    /// Battery protection: below this charge, unplugged, we drop to saver.
    static let lowBatteryLevel: Float = 0.2

    /// The mode actually used: the person's choice, unless the battery says otherwise.
    static func effectiveMode(chosen: ShareMode, lowPowerMode: Bool, batteryLevel: Float, charging: Bool) -> ShareMode {
        if charging { return chosen }
        let low = lowPowerMode || (batteryLevel >= 0 && batteryLevel < lowBatteryLevel)
        return low ? .saver : chosen
    }

    static func settings(mode: ShareMode, speedMps: Double?) -> Settings {
        let tier = Policy.tierName(speedMps: speedMps)
        let parked = (speedMps ?? 0) < Policy.stillMps
        switch mode {
        case .precise:
            /* At rest, precise means a precise *position*, not constant navigation-grade sampling.
               Keep ten-metre requested accuracy for the convoy heartbeat; moving uses best/nav. */
            return Settings(desiredAccuracy: parked ? kCLLocationAccuracyNearestTenMeters : (tier == .fast ? kCLLocationAccuracyBestForNavigation : kCLLocationAccuracyBest),
                            distanceFilter: kCLDistanceFilterNone)
        case .balanced:
            return Settings(desiredAccuracy: parked ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyBest,
                            distanceFilter: kCLDistanceFilterNone)
        case .saver:
            /* Ten-metre accuracy keeps the GPS duty-cycled; the 60 s parked heartbeat still gets a fix. */
            return Settings(desiredAccuracy: parked ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyNearestTenMeters,
                            distanceFilter: kCLDistanceFilterNone)
        }
    }

    struct TrailSettings: Equatable {
        var desiredAccuracy: CLLocationAccuracy
        var distanceFilter: CLLocationDistance
        var activityType: CLActivityType
    }

    /// «مساري» recording (OsmAnd-like): the best the chip can do, every fix (decimated in
    /// code, smoothed by `TrailKalman`), the automotive model on roads and the generic
    /// navigation model off-road (no road snapping in the desert).
    static func trailSettings(onRoad: Bool) -> TrailSettings {
        TrailSettings(desiredAccuracy: kCLLocationAccuracyBestForNavigation,
                      distanceFilter: kCLDistanceFilterNone,
                      activityType: onRoad ? .automotiveNavigation : .otherNavigation)
    }

    /// CoreLocation → our fix. Negative accuracy means "invalid"; negative speed/course "unknown".
    static func deviceFix(_ l: CLLocation) -> DeviceFix? {
        guard l.horizontalAccuracy >= 0 else { return nil }
        return DeviceFix(
            lat: l.coordinate.latitude,
            lng: l.coordinate.longitude,
            accuracy: l.horizontalAccuracy,
            heading: l.course >= 0 ? l.course : nil,
            speed: l.speed >= 0 ? l.speed : nil,
            atMs: l.timestamp.timeIntervalSince1970 * 1000,
            speedAccuracy: l.speedAccuracy >= 0 ? l.speedAccuracy : nil,
            courseAccuracy: l.courseAccuracy >= 0 ? l.courseAccuracy : nil
        )
    }

    /// Where the fix came from (`CLLocation.sourceInformation`, iOS 15+), for «جودة GPS».
    static func sourceLabel(_ l: CLLocation) -> String {
        guard let s = l.sourceInformation else { return "device" }
        if s.isSimulatedBySoftware { return "simulated" }
        if s.isProducedByAccessory { return "accessory" }
        return "device"
    }

    /// What the GPS is asked to do right now: every use, every motion, in one place.
    struct Need: Equatable {
        var watching = false
        var sharing = false
        /// «مساري» recording (on screen, or kept alive off screen) or the screen-locked trail.
        var trail = false
        var offScreen = false
        /// Sharing armed for the background («دائمًا»).
        var backgroundShare = false
        var mode: ShareMode = .balanced
        var motion: MotionClass = .parked
        var speedMps: Double?
        /// The road matcher found a road recently (trail only).
        var onRoad = false
        /// Guidance is waiting for a fresh fix («ننتظر موقعك…»): the best the chip can do, now.
        var urgent = false
    }

    struct Plan: Equatable {
        var desiredAccuracy: CLLocationAccuracy
        var distanceFilter: CLLocationDistance
        var activityType: CLActivityType
    }

    /// Activity model: on foot → `.fitness` (pedestrian model, no car smoothing); on a matched road
    /// while recording → `.automotiveNavigation`; everywhere else (the dunes) `.otherNavigation`,
    /// which keeps the navigation treatment without snapping a car to a road it is not on.
    static func activity(_ n: Need) -> CLActivityType {
        if n.motion == .walking { return .fitness }
        if n.trail && n.onRoad && n.motion != .parked { return .automotiveNavigation }
        return .otherNavigation
    }

    /// nil: nothing needs the GPS. The trail wins (best, every fix); then a background share
    /// (`BackgroundCadence`); then the on-screen share tiers; then the plain map dot.
    static func plan(_ n: Need) -> Plan? {
        let act = activity(n)
        if n.trail {
            let t = trailSettings(onRoad: n.onRoad)
            return Plan(desiredAccuracy: n.motion == .walking ? kCLLocationAccuracyBest : t.desiredAccuracy, distanceFilter: t.distanceFilter, activityType: act)
        }
        if n.urgent {
            return Plan(desiredAccuracy: kCLLocationAccuracyBestForNavigation, distanceFilter: kCLDistanceFilterNone, activityType: act)
        }
        if n.sharing {
            if n.offScreen && n.backgroundShare {
                /* Speed unknown: the motion class (hysteresis) decides, never a coarse tier by accident. */
                let m = n.speedMps.map { BackgroundCadence.motion(speedMps: $0) } ?? (n.motion == .parked ? .parked : .moving)
                let a = BackgroundCadence.accuracy(m)
                return Plan(desiredAccuracy: a.desiredAccuracy, distanceFilter: a.distanceFilter, activityType: act)
            }
            let s = settings(mode: n.mode, speedMps: n.speedMps)
            return Plan(desiredAccuracy: s.desiredAccuracy, distanceFilter: s.distanceFilter, activityType: act)
        }
        if n.watching {
            /* No distance filter: a parked phone still gets fresh fixes, so its age stays honest. */
            return Plan(desiredAccuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: kCLDistanceFilterNone, activityType: act)
        }
        return nil
    }

    static func describe(_ p: Plan?) -> String {
        guard let p else { return "off" }
        let a: String
        switch p.desiredAccuracy {
        case kCLLocationAccuracyBestForNavigation: a = "nav"
        case kCLLocationAccuracyBest: a = "best"
        case kCLLocationAccuracyNearestTenMeters: a = "10m"
        case kCLLocationAccuracyHundredMeters: a = "100m"
        default: a = String(format: "%.0fm", p.desiredAccuracy)
        }
        let f = p.distanceFilter == kCLDistanceFilterNone ? "none" : String(format: "%.0fm", p.distanceFilter)
        let t: String
        switch p.activityType {
        case .automotiveNavigation: t = "auto"
        case .otherNavigation: t = "otherNav"
        case .fitness: t = "fitness"
        default: t = "other"
        }
        return "\(a) • \(f) • \(t)"
    }

    static func gpsState(auth: CLAuthorizationStatus, lastAccuracy: Double?, lastFixAgeMs: Double?) -> GpsState {
        switch auth {
        case .denied, .restricted: return .denied
        case .notDetermined: return .unavailable
        default: break
        }
        guard let age = lastFixAgeMs, age < 30_000, let a = lastAccuracy else { return .unavailable }
        return a <= Policy.weakAccuracyM ? .ok : .weak
    }
}
