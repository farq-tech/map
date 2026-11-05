import CoreLocation
import UIKit

/// The one owner of `CLLocationManager`.
///
/// Three levels, never confused:
///   * `watchForeground()` — your own dot for distances while the map is open.
///     Nothing leaves the phone.
///   * `startSharing(mode:)` — only while you are sharing in an active outing
///     AND the app is on screen. `allowsBackgroundLocationUpdates` is never
///     turned on, there is no significant-change monitoring and no «دائمًا»
///     request: when the app leaves the foreground the session stops sharing
///     and stops the GPS (owner rule: positions are sent from the foreground only).
///
///   * `startTrail(background:)` — «مساري» is recording: best-for-navigation
///     accuracy, no distance filter, never auto-paused (OsmAnd-like), plus the
///     iOS 17 `CLBackgroundActivitySession` / iOS 18 `CLServiceSession` taken on screen.
///   * `startBackgroundTrail()` — ONLY for «مساري» (the on-device breadcrumb
///     trail): «دائمًا», or «أثناء الاستخدام» with the iOS 17+ background activity
///     session; the person's switch on, and an active/paused outing I belong to.
///     iOS shows the blue location indicator.
///     These fixes go to the trail on this phone and nowhere else: sharing is
///     stopped in the background and `SendGate` refuses any send there.
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
    /// «مساري» is recording: the GPS runs at its best (OsmAnd-like), whatever the share mode.
    @Published private(set) var trailActive = false
    /// On a road (the matcher found one recently): iOS's automotive model; off-road: other navigation.
    var onRoad = true {
        didSet { if trailActive { applyTrailSettings() } }
    }
    /// iOS 17+ `CLBackgroundActivitySession` / iOS 18+ `CLServiceSession` (typed `Any` for the availability checks).
    private var activitySession: AnyObject?
    private var serviceSession: AnyObject?
    private var askedTemporaryFull = false

    private let manager = CLLocationManager()
    private var chosenMode: ShareMode = .balanced
    private var filter = FixFilter()
    private var watching = false
    private var whenInUseContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var alwaysContinuation: CheckedContinuation<Bool, Never>?
    private var alwaysPromptSeen = false

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
    ///
    /// iOS 17+: «أثناء الاستخدام» is enough too — updates started on screen continue with the
    /// screen locked while a `CLBackgroundActivitySession` is held (blue indicator). «دائمًا»
    /// additionally survives iOS terminating the app.
    func startBackgroundTrail() {
        guard canLocate else { return }
        backgroundTrail = true
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.pausesLocationUpdatesAutomatically = false
        if trailActive {
            applyTrailSettings()
        } else if !isSharing {
            manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            manager.distanceFilter = kCLDistanceFilterNone
        }
        manager.startUpdatingLocation()
    }

    /// «مساري» is recording (outing active, switch on, on screen when called): best accuracy,
    /// no distance filter (we decimate in code), never auto-paused; with `background` the
    /// session that keeps it alive with the screen locked is taken now, while on screen.
    func startTrail(background: Bool) {
        guard canLocate else { return }
        let wasActive = trailActive
        trailActive = true
        applyTrailSettings()
        if background {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            if #available(iOS 17.0, *), activitySession == nil { activitySession = CLBackgroundActivitySession() }
        }
        if #available(iOS 18.0, *), serviceSession == nil {
            serviceSession = CLServiceSession(authorization: .whenInUse, fullAccuracyPurposeKey: Self.fullAccuracyPurposeKey)
        }
        askFullAccuracyIfReduced()
        if !wasActive { manager.startUpdatingLocation() }
    }

    func stopTrail() {
        guard trailActive else { return }
        trailActive = false
        if #available(iOS 17.0, *) { (activitySession as? CLBackgroundActivitySession)?.invalidate() }
        if #available(iOS 18.0, *) { (serviceSession as? CLServiceSession)?.invalidate() }
        activitySession = nil
        serviceSession = nil
        if backgroundTrail { stopBackgroundTrail() }
        manager.activityType = .otherNavigation
        if isSharing {
            retune(speed: lastFix?.speed)
        } else if watching {
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = kCLDistanceFilterNone
        } else {
            manager.stopUpdatingLocation()
        }
    }

    /// Info.plist `NSLocationTemporaryUsageDescriptionDictionary` key.
    static let fullAccuracyPurposeKey = "TrailRecording"

    /// «الموقع الدقيق» is off: ask iOS for full accuracy for this outing (once per launch).
    func askFullAccuracyIfReduced() {
        guard accuracyAuthorization == .reducedAccuracy, canLocate, !askedTemporaryFull else { return }
        askedTemporaryFull = true
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.fullAccuracyPurposeKey) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.accuracyAuthorization = self.manager.accuracyAuthorization
            }
        }
    }

    var preciseOff: Bool { accuracyAuthorization == .reducedAccuracy }

    private func applyTrailSettings() {
        let s = LocationTuning.trailSettings(onRoad: onRoad)
        if manager.desiredAccuracy != s.desiredAccuracy { manager.desiredAccuracy = s.desiredAccuracy }
        if manager.distanceFilter != s.distanceFilter { manager.distanceFilter = s.distanceFilter }
        if manager.activityType != s.activityType { manager.activityType = s.activityType }
        manager.pausesLocationUpdatesAutomatically = false
    }

    /// Back to foreground-only. Stops the GPS too unless the map or sharing still needs it.
    func stopBackgroundTrail() {
        guard backgroundTrail else { return }
        backgroundTrail = false
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        if trailActive {
            /* Still recording on screen. */
        } else if isSharing {
            retune(speed: lastFix?.speed)
        } else if watching {
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = kCLDistanceFilterNone
        } else {
            manager.stopUpdatingLocation()
        }
    }

    func watchForeground() {
        guard canLocate, !watching else { return }
        watching = true
        if !isSharing && !trailActive {
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            /* No distance filter: a parked phone still gets fresh fixes, so its age stays honest. */
            manager.distanceFilter = kCLDistanceFilterNone
        }
        manager.startUpdatingLocation()
    }

    func stopWatchingForeground() {
        watching = false
        if !isSharing && !backgroundTrail && !trailActive { manager.stopUpdatingLocation() }
    }

    func startSharing(mode: ShareMode) {
        guard canLocate else { return }
        chosenMode = mode
        filter.reset()
        isSharing = true
        manager.allowsBackgroundLocationUpdates = backgroundTrail
        manager.pausesLocationUpdatesAutomatically = false
        retune(speed: lastFix?.speed)
        manager.startUpdatingLocation()
    }

    func setMode(_ mode: ShareMode) {
        chosenMode = mode
        retune(speed: lastFix?.speed)
    }

    func stopSharing() {
        guard isSharing else { return }
        isSharing = false
        manager.allowsBackgroundLocationUpdates = backgroundTrail
        filter.reset()
        if trailActive || backgroundTrail {
            applyTrailSettings()
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
        /* While «مساري» records, the GPS stays at its best; the send policy still decides what is sent. */
        if trailActive { applyTrailSettings(); return }
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
            if !(st == .authorizedWhenInUse || st == .authorizedAlways) { self.stopTrail(); self.stopBackgroundTrail() }
            if self.trailActive { self.askFullAccuracyIfReduced() }
            if st != .notDetermined, st != .authorizedWhenInUse || self.alwaysPromptSeen { self.finishAlways() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.compactMap(LocationTuning.deviceFix)
        Task { @MainActor in
            for f in fixes {
                if let last = self.lastFix, f.atMs <= last.atMs { continue }
                self.lastFix = f
                /* Every fix goes to the trail (raw log + smoother); no accuracy downgrade when parked:
                 * a coarse chip at a red light used to cost the next minutes of the drive. */
                self.onTrailFix(f)
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
