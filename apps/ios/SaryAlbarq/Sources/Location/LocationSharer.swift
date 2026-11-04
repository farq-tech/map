import CoreLocation
import UIKit

/// The one owner of `CLLocationManager`.
///
/// Three levels, never confused:
///   * `watchForeground()` — your own dot for distances while the map is open.
///     Nothing leaves the phone.
///   * `startSharing(mode:)` — only while you are sharing in an active outing.
///     With «دائمًا» (owner decision, 2026-11) sharing is also armed for the
///     background: `allowsBackgroundLocationUpdates` + the blue indicator, a
///     `CLBackgroundActivitySession` (iOS 17+) / `CLServiceSession` (iOS 18+),
///     significant-location-change monitoring and a small exit region as
///     backstops that relaunch the app if iOS terminates it. With «أثناء
///     الاستخدام» only, nothing of that is turned on and the session stops
///     sharing when the app leaves the screen.
///
///   * `startBackgroundTrail()` — «مساري» (the on-device breadcrumb trail),
///     only with «دائمًا» permission, the person's switch on, and an
///     active/paused outing I belong to. These fixes go to the trail on this
///     phone and nowhere else.
///
/// `pausesLocationUpdatesAutomatically` is false while sharing: iOS's
/// auto-pause fires when the phone looks stationary, and a parked convoy
/// (tea stop, stuck in sand) is exactly when others most need to see you.
@MainActor
final class LocationSharer: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var accuracyAuthorization: CLAccuracyAuthorization
    @Published private(set) var lastFix: DeviceFix?
    @Published private(set) var isSharing = false
    @Published private(set) var effectiveMode: ShareMode = .balanced

    /// Every accepted fix while sharing (after the glitch filter).
    var onFix: (DeviceFix) -> Void = { _ in }
    /// Every fix at all (foreground watch, sharing, or background trail): for the on-device trail only.
    var onTrailFix: (DeviceFix) -> Void = { _ in }
    /// Recording the trail with the screen locked (see `startBackgroundTrail`).
    @Published private(set) var backgroundTrail = false
    /// Sharing is armed to keep going off screen («دائمًا» + sharing).
    @Published private(set) var backgroundShare = false
    /// The app is off screen (set by the session): background accuracy tiers apply.
    private(set) var offScreen = false
    /// iOS authorization changed (the session re-checks its gate).
    var onAuthorizationChange: () -> Void = {}

    private let manager = CLLocationManager()
    private var chosenMode: ShareMode = .balanced
    private var filter = FixFilter()
    private var watching = false
    private var whenInUseContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var alwaysContinuation: CheckedContinuation<Bool, Never>?
    private var alwaysPromptSeen = false
    /// `CLBackgroundActivitySession` (iOS 17+) while sharing is armed for the background.
    private var activitySession: AnyObject?
    /// `CLServiceSession(authorization: .always)` (iOS 18+) while sharing is armed.
    private var serviceSession: AnyObject?
    private var regionCenter: DeviceFix?
    static let backstopRegionId = "sary.share.backstop"
    static let backstopRadiusM = 200.0

    override init() {
        authorization = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        super.init()
        manager.delegate = self
        /* Off-road: .otherNavigation keeps the same "navigation" treatment as .automotiveNavigation
         * (no auto-pause, best accuracy) without road-snapping a car that is in the dunes. */
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = false
        /* Backstops survive the process: drop any left from an earlier run. A share that
         * resumes at launch (AppModel → OutingSession) arms them again right away. */
        manager.stopMonitoringSignificantLocationChanges()
        for r in manager.monitoredRegions where r.identifier == Self.backstopRegionId { manager.stopMonitoring(for: r) }
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(powerChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(powerChanged), name: UIDevice.batteryLevelDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(powerChanged), name: UIDevice.batteryStateDidChangeNotification, object: nil)
    }

    var canLocate: Bool { effectiveAuthorization == .authorizedWhenInUse || effectiveAuthorization == .authorizedAlways }
    var hasAlways: Bool { effectiveAuthorization == .authorizedAlways }

    #if DEBUG
    /// Unit tests only: stands in for the iOS permission so the sharing path can be exercised.
    var testAuthorization: CLAuthorizationStatus?
    private var effectiveAuthorization: CLAuthorizationStatus { testAuthorization ?? authorization }
    #else
    private var effectiveAuthorization: CLAuthorizationStatus { authorization }
    #endif

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

    /// Step 2 (only for the screen-locked trail, after our explainer): ask iOS for «دائمًا».
    /// iOS shows this prompt at most once; if it does not show it, or the person keeps
    /// «أثناء الاستخدام», this answers false and the trail stays foreground-only.
    func requestAlways() async -> Bool {
        if hasAlways { return true }
        guard canLocate else { return false }
        return await withCheckedContinuation { c in
            alwaysContinuation = c
            alwaysPromptSeen = false
            let center = NotificationCenter.default
            var tokens: [NSObjectProtocol] = []
            tokens.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.alwaysPromptSeen = true }
            })
            tokens.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.alwaysPromptSeen else { return }
                    /* The prompt closed; the new status may land a moment later. */
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.finishAlways() }
                }
            })
            alwaysTokens = tokens
            manager.requestAlwaysAuthorization()
            /* No prompt at all (iOS already asked once): answer with what we have. */
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, !self.alwaysPromptSeen else { return }
                self.finishAlways()
            }
        }
    }

    private var alwaysTokens: [NSObjectProtocol] = []

    private func finishAlways() {
        guard let c = alwaysContinuation else { return }
        alwaysContinuation = nil
        alwaysTokens.forEach { NotificationCenter.default.removeObserver($0) }
        alwaysTokens = []
        c.resume(returning: manager.authorizationStatus == .authorizedAlways)
    }

    /// Keep the GPS on for the trail while the app is in the background («دائمًا» only).
    /// The caller (the session) decides when: switch on, outing active/paused, I am a member.
    func startBackgroundTrail() {
        guard hasAlways else { return }
        backgroundTrail = true
        applyBackgroundMode()
        manager.pausesLocationUpdatesAutomatically = false
        if !isSharing {
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = Self.backgroundTrailDistanceM
        }
        manager.startUpdatingLocation()
    }

    /// Back to foreground-only. Stops the GPS too unless the map or sharing still needs it.
    func stopBackgroundTrail() {
        guard backgroundTrail else { return }
        backgroundTrail = false
        applyBackgroundMode()
        if isSharing {
            retune(speed: lastFix?.speed)
        } else if watching {
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = kCLDistanceFilterNone
        } else {
            manager.stopUpdatingLocation()
        }
    }

    static let backgroundTrailDistanceM = 15.0

    func watchForeground() {
        guard canLocate, !watching else { return }
        watching = true
        if !isSharing {
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            /* No distance filter: a parked phone still gets fresh fixes, so its age stays honest. */
            manager.distanceFilter = kCLDistanceFilterNone
        }
        manager.startUpdatingLocation()
    }

    func stopWatchingForeground() {
        watching = false
        if !isSharing && !backgroundTrail { manager.stopUpdatingLocation() }
    }

    func startSharing(mode: ShareMode) {
        guard canLocate else { return }
        chosenMode = mode
        filter.reset()
        isSharing = true
        manager.pausesLocationUpdatesAutomatically = false
        if hasAlways { armBackgroundSharing() }
        applyBackgroundMode()
        retune(speed: lastFix?.speed)
        manager.startUpdatingLocation()
    }

    /// «دائمًا» + sharing: keep the GPS and the app alive off screen as much as iOS allows.
    private func armBackgroundSharing() {
        guard !backgroundShare else { return }
        backgroundShare = true
        if activitySession == nil { activitySession = CLBackgroundActivitySession() }
        if #available(iOS 18.0, *), serviceSession == nil {
            serviceSession = CLServiceSession(authorization: .always)
        }
        /* Backstop: relaunches the app in the background if iOS terminates it (~500 m moves). */
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
    }

    private func disarmBackgroundSharing() {
        guard backgroundShare else { return }
        backgroundShare = false
        manager.stopMonitoringSignificantLocationChanges()
        for r in manager.monitoredRegions where r.identifier == Self.backstopRegionId { manager.stopMonitoring(for: r) }
        regionCenter = nil
        (activitySession as? CLBackgroundActivitySession)?.invalidate()
        activitySession = nil
        if #available(iOS 18.0, *) { (serviceSession as? CLServiceSession)?.invalidate() }
        serviceSession = nil
    }

    private func applyBackgroundMode() {
        let on = (backgroundTrail || backgroundShare) && hasAlways
        if manager.allowsBackgroundLocationUpdates != on { manager.allowsBackgroundLocationUpdates = on }
        if manager.showsBackgroundLocationIndicator != on { manager.showsBackgroundLocationIndicator = on }
    }

    /// The session tells us when the app leaves / returns to the screen.
    func setOffScreen(_ off: Bool) {
        offScreen = off
        retune(speed: lastFix?.speed)
    }

    /// A small exit region around me, re-armed as I move: if iOS has terminated the app,
    /// leaving it relaunches the app in the background sooner than a significant change would.
    private func rearmRegion(_ f: DeviceFix) {
        guard backgroundShare, CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        if let c = regionCenter, Geo.haversineMeters(c.coordinate, f.coordinate) < Self.backstopRadiusM / 2, f.atMs - c.atMs < 120_000 { return }
        regionCenter = f
        let r = CLCircularRegion(center: CLLocationCoordinate2D(latitude: f.lat, longitude: f.lng), radius: Self.backstopRadiusM, identifier: Self.backstopRegionId)
        r.notifyOnEntry = false
        r.notifyOnExit = true
        manager.startMonitoring(for: r)
    }

    func setMode(_ mode: ShareMode) {
        chosenMode = mode
        retune(speed: lastFix?.speed)
    }

    func stopSharing() {
        disarmBackgroundSharing()
        guard isSharing else { applyBackgroundMode(); return }
        isSharing = false
        applyBackgroundMode()
        filter.reset()
        if backgroundTrail {
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = Self.backgroundTrailDistanceM
        } else if watching {
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            /* No distance filter: a parked phone still gets fresh fixes, so its age stays honest. */
            manager.distanceFilter = kCLDistanceFilterNone
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
        if offScreen && backgroundShare {
            /* Off screen: best when moving, reduced when parked (BackgroundCadence). */
            let a = BackgroundCadence.accuracy(BackgroundCadence.motion(speedMps: speed))
            if manager.desiredAccuracy != a.desiredAccuracy { manager.desiredAccuracy = a.desiredAccuracy }
            if manager.distanceFilter != a.distanceFilter { manager.distanceFilter = a.distanceFilter }
            return
        }
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
            if st != .authorizedAlways { self.stopBackgroundTrail(); self.disarmBackgroundSharing(); self.applyBackgroundMode() }
            if st == .authorizedAlways, self.isSharing { self.armBackgroundSharing(); self.applyBackgroundMode() }
            self.onAuthorizationChange()
            if st != .notDetermined, st != .authorizedWhenInUse || self.alwaysPromptSeen { self.finishAlways() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.compactMap(LocationTuning.deviceFix)
        Task { @MainActor in
            for f in fixes {
                if let last = self.lastFix, f.atMs <= last.atMs { continue }
                self.lastFix = f
                self.onTrailFix(f)
                if self.backgroundTrail && !self.isSharing {
                    /* Known to be parked: let the chip rest; moving or unknown: ten-metre fixes
                     * (an unknown speed never keeps it coarse, so the trail always picks up again). */
                    let parked = f.speed.map { $0 < 0.5 } ?? false
                    let acc = parked ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyNearestTenMeters
                    if self.manager.desiredAccuracy != acc { self.manager.desiredAccuracy = acc }
                }
                guard self.isSharing else { continue }
                if let ok = self.filter.accept(f) {
                    self.rearmRegion(ok)
                    self.onFix(ok)
                }
                /* Cheap: only touches the manager when the tier's settings change. */
                self.retune(speed: f.speed)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        /* kCLErrorLocationUnknown is transient; the next fix will come. */
    }
}
