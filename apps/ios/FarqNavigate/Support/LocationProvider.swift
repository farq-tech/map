import CoreLocation
import Foundation

/// Where the phone is, or nothing.
///
/// Never a fallback coordinate. A map that quietly claims you are downtown when
/// it does not know is worse than a map that says it does not know, and every
/// distance shown here rests on this being a real fix.
@MainActor
final class LocationProvider: NSObject, ObservableObject {
    @Published private(set) var location: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var isDenied = false

    private let manager = CLLocationManager()

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        /* Ten metres: enough movement to matter on a street, few enough updates
         * to leave the battery alone while the map is merely open. */
        manager.distanceFilter = 10
    }

    func request() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            isDenied = true
        default:
            manager.startUpdatingLocation()
        }
    }

    func stop() { manager.stopUpdatingLocation() }
}

extension LocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didChangeAuthorization status: CLAuthorizationStatus
    ) {
        Task { @MainActor in
            authorization = status
            isDenied = (status == .denied || status == .restricted)
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let latest = locations.last else { return }
        Task { @MainActor in location = latest }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        /* A failure is not a reason to invent a position. */
    }
}
