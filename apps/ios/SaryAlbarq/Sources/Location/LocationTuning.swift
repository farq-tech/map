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
            return Settings(desiredAccuracy: tier == .fast ? kCLLocationAccuracyBestForNavigation : kCLLocationAccuracyBest,
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
            speedAccuracy: l.speedAccuracy >= 0 ? l.speedAccuracy : nil
        )
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
