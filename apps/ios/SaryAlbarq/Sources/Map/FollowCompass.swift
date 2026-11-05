import CoreLocation
import UIKit

/// The phone's compass for «باتجاهي» when slow or stopped: on only while that mode is,
/// true north when known (magnetic otherwise), with its error (`FollowHeadingSource` decides
/// whether to trust it). Its own `CLLocationManager`: heading only, never location.
final class FollowCompass: NSObject, CLLocationManagerDelegate {
    struct Reading: Equatable {
        var heading: Double
        var error: Double
    }

    private var manager: CLLocationManager?
    private(set) var reading: Reading?
    var onChange: () -> Void = {}

    var active = false {
        didSet {
            guard active != oldValue else { return }
            if active { start() } else { stop() }
        }
    }

    private func start() {
        guard CLLocationManager.headingAvailable() else { return }
        let m = manager ?? CLLocationManager()
        manager = m
        m.delegate = self
        m.headingFilter = 2
        m.headingOrientation = .portrait
        m.startUpdatingHeading()
    }

    private func stop() {
        manager?.stopUpdatingHeading()
        reading = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading h: CLHeading) {
        let value = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
        reading = Reading(heading: value, error: h.headingAccuracy)
        onChange()
    }

    /// A calibration figure-8 over the driver's map: never.
    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool { false }
}
