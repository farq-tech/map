import CoreLocation
import UIKit

/// The one owner of `CLLocationManager`.
///
/// Two levels, never confused:
///   * `watchForeground()` — your own dot for distances while the map is open.
///     Nothing leaves the phone; no background updates.
///   * `startSharing(mode:)` — only while you are sharing in an active outing.
///     This is the only place `allowsBackgroundLocationUpdates` becomes true,
///     and `stopSharing()` sets it back to false.
///
/// `pausesLocationUpdatesAutomatically` is false while sharing: iOS's
/// auto-pause fires when the phone looks stationary, and a parked convoy
/// (tea stop, stuck in sand) is exactly when others most need to see you. Once
/// auto-paused, updates only resume when the app returns to the foreground, so
/// you would silently vanish. The battery cost is managed instead by the share
/// mode, `LocationTuning` (lower accuracy when parked, saver on low battery)
/// and the send policy.
@MainActor
final class LocationSharer: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var accuracyAuthorization: CLAccuracyAuthorization
    @Published private(set) var lastFix: DeviceFix?
    @Published private(set) var isSharing = false
    @Published private(set) var effectiveMode: ShareMode = .balanced

    /// Every accepted fix while sharing (after the glitch filter).
    var onFix: (DeviceFix) -> Void = { _ in }

    private let manager = CLLocationManager()
    private var chosenMode: ShareMode = .balanced
    private var filter = FixFilter()
    private var watching = false
    private var whenInUseContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    override init() {
        authorization = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        super.init()
        manager.delegate = self
        manager.activityType = .otherNavigation // off-road: not road-snapped like .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = false
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(powerChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(powerChanged), name: UIDevice.batteryLevelDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(powerChanged), name: UIDevice.batteryStateDidChangeNotification, object: nil)
    }

    var canLocate: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }
    var hasAlways: Bool { authorization == .authorizedAlways }

    var gpsState: GpsState {
        let age = lastFix.map { Date().timeIntervalSince1970 * 1000 - $0.atMs }
        return LocationTuning.gpsState(auth: authorization, lastAccuracy: lastFix?.accuracy, lastFixAgeMs: age)
    }

    /// Step 1: When-In-Use. Returns the resulting status.
    func requestWhenInUse() async -> CLAuthorizationStatus {
        guard authorization == .notDetermined else { return authorization }
        return await withCheckedContinuation { c in
            whenInUseContinuation = c
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Step 2 (after our Arabic explanation): Always, so iOS can relaunch the
    /// app for significant moves if it was terminated mid-outing. Optional —
    /// sharing with the screen locked works with When-In-Use too, because the
    /// updates start in the foreground with background updates allowed.
    func requestAlways() {
        if authorization == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
    }

    func watchForeground() {
        guard canLocate, !watching else { return }
        watching = true
        if !isSharing {
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = 10
        }
        manager.startUpdatingLocation()
    }

    func stopWatchingForeground() {
        watching = false
        if !isSharing { manager.stopUpdatingLocation() }
    }

    func startSharing(mode: ShareMode) {
        guard canLocate else { return }
        chosenMode = mode
        filter.reset()
        isSharing = true
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.pausesLocationUpdatesAutomatically = false
        retune(speed: lastFix?.speed)
        manager.startUpdatingLocation()
        /* Safety net: if iOS terminates the app, a significant move relaunches it (needs Always). */
        if hasAlways, CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
    }

    func setMode(_ mode: ShareMode) {
        chosenMode = mode
        retune(speed: lastFix?.speed)
    }

    func stopSharing() {
        guard isSharing else { return }
        isSharing = false
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
        filter.reset()
        if watching {
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = 10
        } else {
            manager.stopUpdatingLocation()
        }
    }

    @objc private func powerChanged() {
        Task { @MainActor in self.retune(speed: self.lastFix?.speed) }
    }

    private func retune(speed: Double?) {
        let d = UIDevice.current
        effectiveMode = LocationTuning.effectiveMode(
            chosen: chosenMode,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            batteryLevel: d.batteryLevel,
            charging: d.batteryState == .charging || d.batteryState == .full
        )
        guard isSharing else { return }
        let s = LocationTuning.settings(mode: effectiveMode, speedMps: speed)
        if manager.desiredAccuracy != s.desiredAccuracy { manager.desiredAccuracy = s.desiredAccuracy }
        if manager.distanceFilter != s.distanceFilter { manager.distanceFilter = s.distanceFilter }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let st = manager.authorizationStatus
        let acc = manager.accuracyAuthorization
        Task { @MainActor in
            self.authorization = st
            self.accuracyAuthorization = acc
            if st != .notDetermined, let c = self.whenInUseContinuation {
                self.whenInUseContinuation = nil
                c.resume(returning: st)
            }
            if !(st == .authorizedWhenInUse || st == .authorizedAlways) { self.stopSharing() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.compactMap(LocationTuning.deviceFix)
        Task { @MainActor in
            for f in fixes {
                if let last = self.lastFix, f.atMs <= last.atMs { continue }
                self.lastFix = f
                guard self.isSharing else { continue }
                if let ok = self.filter.accept(f) { self.onFix(ok) }
                /* Cheap: only touches the manager when the tier's settings change. */
                self.retune(speed: f.speed)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        /* kCLErrorLocationUnknown is transient; the next fix will come. */
    }
}
