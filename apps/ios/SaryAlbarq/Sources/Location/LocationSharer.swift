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
///   * `startTrail(background:)` — «مساري» is recording: best-for-navigation
///     accuracy, no distance filter, never auto-paused (OsmAnd-like), the activity
///     type follows the road matcher (`.automotiveNavigation` on a street,
///     `.otherNavigation` off-road), plus the iOS 17 `CLBackgroundActivitySession` /
///     iOS 18 `CLServiceSession` taken on screen. While it records it wins over the
///     share tiers below: the GPS is always at its best; what is SENT is still
///     decided by `Policy` / `BackgroundCadence` and gated by `SendGate`.
///   * `startBackgroundTrail()` — «مساري» (the on-device breadcrumb trail) with the
///     screen locked: «دائمًا», or «أثناء الاستخدام» with the iOS 17+ background
///     activity session; the person's switch on, and an active/paused outing I
///     belong to. These fixes go to the trail on this phone and nowhere else.
///
/// One manager, one set of background flags: `allowsBackgroundLocationUpdates` and
/// the blue indicator are on while either the trail (any location permission) or
/// a background share («دائمًا» only) needs them, and off when neither does.
///
/// `pausesLocationUpdatesAutomatically` is false while sharing: iOS's
/// auto-pause fires when the phone looks stationary, and a parked convoy
/// (tea stop, stuck in sand) is exactly when others most need to see you.
@MainActor
final class LocationSharer: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var accuracyAuthorization: CLAccuracyAuthorization
    /// The latest fix the quality gate believes (`FixQualityGate`), exactly as CoreLocation gave it:
    /// never smoothed (SOS, mesh, navigation, the trip log use it as is).
    @Published private(set) var lastFix: DeviceFix?
    /// My dot as the map draws it: `lastFix` through `DisplaySmoother` (anchored when parked,
    /// light Kalman on the move, heading only when the course is trustworthy). Display only.
    @Published private(set) var displayFix: DeviceFix?
    /// «جودة GPS» (developer readout).
    @Published private(set) var quality = GpsQualityStats()
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
    /// «مساري» asked to keep recording with the screen locked (taken on screen, see `startTrail`).
    private var trailWantsBackground = false
    /// On a road (the matcher found one recently): iOS's automotive model; off-road: other navigation.
    var onRoad = true {
        didSet { if trailActive { applyTrailSettings() } }
    }
    /// The trail's iOS 17+ `CLBackgroundActivitySession` / iOS 18+ `CLServiceSession` (typed `AnyObject` for the availability checks).
    private var trailActivitySession: AnyObject?
    private var trailServiceSession: AnyObject?
    /// Purpose keys already asked this launch (iOS shows the prompt at most once per key anyway).
    private var askedTemporaryFull: Set<String> = []
    private var gate = FixQualityGate()
    private var smoother = DisplaySmoother()
    private var motion: MotionClass = .parked
    private var recentFixTimes: [Double] = []
    /// What the manager is set to (nil: nothing needs the GPS).
    private(set) var plan: LocationTuning.Plan?
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
    private var shareActivitySession: AnyObject?
    /// `CLServiceSession(authorization: .always)` (iOS 18+) while sharing is armed.
    private var shareServiceSession: AnyObject?
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
    /// Tests that drive fixes by hand: ignore the simulator's own GPS (its location leaks
    /// in whenever the host app holds the permission, and races the scripted fixes).
    var ignoresSystemFixes = false
    /// UI tests: my last fix as given (no gate), e.g. one 5 minutes old.
    func debugSetLastFix(_ f: DeviceFix) {
        lastFix = f
        displayFix = f
    }
    private var effectiveAuthorization: CLAuthorizationStatus { testAuthorization ?? authorization }
    #else
    private var effectiveAuthorization: CLAuthorizationStatus { authorization }
    #endif

    var gpsState: GpsState {
        let age = lastFix.map { Date().timeIntervalSince1970 * 1000 - $0.atMs }
        return LocationTuning.gpsState(auth: authorization, lastAccuracy: lastFix?.accuracy, lastFixAgeMs: age)
    }

    /// Back on screen (e.g. from Settings): read what iOS says now, without waiting for the delegate.
    func refreshAuthorization() {
        let st = manager.authorizationStatus, acc = manager.accuracyAuthorization
        if st != authorization { authorization = st }
        if acc != accuracyAuthorization { accuracyAuthorization = acc }
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
        applyBackgroundMode()
        manager.pausesLocationUpdatesAutomatically = false
        applySettings()
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
            trailWantsBackground = true
            if trailActivitySession == nil { trailActivitySession = CLBackgroundActivitySession() }
            applyBackgroundMode()
        }
        if #available(iOS 18.0, *), trailServiceSession == nil {
            trailServiceSession = CLServiceSession(authorization: .whenInUse, fullAccuracyPurposeKey: Self.fullAccuracyPurposeKey)
        }
        askFullAccuracyIfReduced()
        if !wasActive { manager.startUpdatingLocation() }
    }

    func stopTrail() {
        guard trailActive else { return }
        trailActive = false
        trailWantsBackground = false
        (trailActivitySession as? CLBackgroundActivitySession)?.invalidate()
        if #available(iOS 18.0, *) { (trailServiceSession as? CLServiceSession)?.invalidate() }
        trailActivitySession = nil
        trailServiceSession = nil
        if backgroundTrail { stopBackgroundTrail() }
        applyBackgroundMode()
        applySettings()
        if plan == nil { manager.stopUpdatingLocation() }
    }

    /// Info.plist `NSLocationTemporaryUsageDescriptionDictionary` key: «مساري» recording.
    static let fullAccuracyPurposeKey = "TrailRecording"
    /// Info.plist `NSLocationTemporaryUsageDescriptionDictionary` key: sharing with the convoy during a trip.
    static let tripPurposeKey = "ConvoyTrip"

    /// «الموقع الدقيق» is off: ask iOS for full accuracy for this outing (once per launch).
    func askFullAccuracyIfReduced(purposeKey: String = LocationSharer.fullAccuracyPurposeKey) {
        guard accuracyAuthorization == .reducedAccuracy, canLocate, !askedTemporaryFull.contains(purposeKey) else { return }
        askedTemporaryFull.insert(purposeKey)
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: purposeKey) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.accuracyAuthorization = self.manager.accuracyAuthorization
            }
        }
    }

    /// For permission / onboarding screens (owned elsewhere): with «الموقع الدقيق» off, ask iOS for
    /// precise location for this trip (iOS's own sheet, our Najdi purpose string). Answers true when
    /// precise location is on afterwards. Asks at most once per launch; a no-op when already precise.
    @discardableResult
    func requestPreciseForTrip() async -> Bool {
        guard canLocate else { return false }
        guard accuracyAuthorization == .reducedAccuracy else { return true }
        guard !askedTemporaryFull.contains(Self.tripPurposeKey) else { return false }
        askedTemporaryFull.insert(Self.tripPurposeKey)
        let acc: CLAccuracyAuthorization = await withCheckedContinuation { c in
            manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.tripPurposeKey) { [weak self] _ in
                Task { @MainActor in c.resume(returning: self?.manager.accuracyAuthorization ?? .reducedAccuracy) }
            }
        }
        accuracyAuthorization = acc
        return acc == .fullAccuracy
    }

    var preciseOff: Bool { accuracyAuthorization == .reducedAccuracy }

    private func applyTrailSettings() { applySettings() }

    /// What every use needs right now (see `LocationTuning.plan`).
    var need: LocationTuning.Need {
        LocationTuning.Need(watching: watching, sharing: isSharing, trail: trailActive || backgroundTrail,
                            offScreen: offScreen, backgroundShare: backgroundShare, mode: effectiveMode,
                            motion: motion, speedMps: lastFix?.speed, onRoad: onRoad, urgent: wantsFreshFix)
    }

    /// The one place the manager's accuracy, distance filter and activity type are set.
    /// Touches the manager only when something changed (cheap to call on every fix).
    private func applySettings() {
        let p = LocationTuning.plan(need)
        plan = p
        let described = LocationTuning.describe(p)
        if quality.settings != described { quality.settings = described }
        guard let p else { return }
        if manager.desiredAccuracy != p.desiredAccuracy { manager.desiredAccuracy = p.desiredAccuracy }
        if manager.distanceFilter != p.distanceFilter { manager.distanceFilter = p.distanceFilter }
        if manager.activityType != p.activityType { manager.activityType = p.activityType }
        /* Never auto-paused: a parked convoy (tea stop, stuck in sand) is when others most need you. */
        if manager.pausesLocationUpdatesAutomatically { manager.pausesLocationUpdatesAutomatically = false }
    }

    /// Back to foreground-only. Stops the GPS too unless the map or sharing still needs it.
    func stopBackgroundTrail() {
        guard backgroundTrail else { return }
        backgroundTrail = false
        applyBackgroundMode()
        applySettings()
        if plan == nil { manager.stopUpdatingLocation() }
    }

    /// Guidance waits for a fix («ننتظر موقعك…»): the GPS at its best, no filter, until a fresh one
    /// comes (`ingest` lowers it again). Starts the updates if nothing else had.
    private(set) var wantsFreshFix = false

    func requestFreshFix() {
        guard canLocate else { return }
        wantsFreshFix = true
        if !watching { watching = true }
        applySettings()
        manager.startUpdatingLocation()
    }

    func endFreshFixRequest() {
        guard wantsFreshFix else { return }
        wantsFreshFix = false
        applySettings()
    }

    func watchForeground() {
        guard canLocate, !watching else { return }
        watching = true
        applySettings()
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
        manager.pausesLocationUpdatesAutomatically = false
        /* «دائمًا»: everything. «أثناء الاستخدام» on screen (iOS 17+): the background activity
         * session (blue indicator) keeps the updates — and the share — going with the screen locked
         * until the trip ends; only a relaunch after iOS kills the app needs «دائمًا». */
        if hasAlways || UIApplication.shared.applicationState != .background { armBackgroundSharing() }
        applyBackgroundMode()
        retune(speed: lastFix?.speed)
        manager.startUpdatingLocation()
        /* «الموقع الدقيق» off: the convoy sees you kilometres off (and fixes over 150 m are not sent). */
        askFullAccuracyIfReduced(purposeKey: Self.tripPurposeKey)
    }

    /// Sharing: keep the GPS and the app alive off screen as much as iOS allows, for the whole trip.
    /// «أثناء الاستخدام»: the activity session only (taken on screen). «دائمًا»: plus the
    /// significant-change / region backstops that relaunch the app after iOS terminates it.
    private func armBackgroundSharing() {
        if !backgroundShare {
            backgroundShare = true
            if shareActivitySession == nil { shareActivitySession = CLBackgroundActivitySession() }
        }
        guard hasAlways else { return }
        if #available(iOS 18.0, *), shareServiceSession == nil {
            shareServiceSession = CLServiceSession(authorization: .always, fullAccuracyPurposeKey: Self.tripPurposeKey)
        }
        /* Backstop: relaunches the app in the background if iOS terminates it (~500 m moves). */
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
    }

    /// The share keeps going off screen right now: «دائمًا», or «أثناء الاستخدام» with the
    /// background activity session held (iOS 17+). The session's `SendGate` reads this.
    var sharesInBackground: Bool { backgroundShare && canLocate && (hasAlways || shareActivitySession != nil) }

    private func disarmBackgroundSharing() {
        guard backgroundShare else { return }
        backgroundShare = false
        manager.stopMonitoringSignificantLocationChanges()
        for r in manager.monitoredRegions where r.identifier == Self.backstopRegionId { manager.stopMonitoring(for: r) }
        regionCenter = nil
        (shareActivitySession as? CLBackgroundActivitySession)?.invalidate()
        shareActivitySession = nil
        if #available(iOS 18.0, *) { (shareServiceSession as? CLServiceSession)?.invalidate() }
        shareServiceSession = nil
    }

    /// The one place the background flags are set: the trail needs any location permission
    /// (iOS 17+ activity session), a background share needs «دائمًا».
    private func applyBackgroundMode() {
        let on = ((backgroundTrail || trailWantsBackground) && canLocate) || sharesInBackground
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
        guard backgroundShare, hasAlways, CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
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
        applySettings()
        if plan == nil { manager.stopUpdatingLocation() }
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
        /* While «مساري» records, the GPS stays at its best (on screen and off); the send
         * policy (`Policy` on screen, `BackgroundCadence` off screen) still decides what is sent.
         * Off screen with a background share: best when moving, reduced when parked. */
        motion = MotionClass.next(motion, speedMps: speed)
        if quality.motion != motion { quality.motion = motion }
        applySettings()
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
            /* «أثناء الاستخدام» keeps the share (activity session) but not the relaunch backstops. */
            if !(st == .authorizedWhenInUse || st == .authorizedAlways) { self.disarmBackgroundSharing() }
            if st == .authorizedWhenInUse, self.backgroundShare {
                self.manager.stopMonitoringSignificantLocationChanges()
                for r in self.manager.monitoredRegions where r.identifier == Self.backstopRegionId { self.manager.stopMonitoring(for: r) }
            }
            if self.isSharing, st == .authorizedAlways || UIApplication.shared.applicationState != .background { self.armBackgroundSharing() }
            self.applyBackgroundMode()
            if self.trailActive { self.askFullAccuracyIfReduced() }
            self.onAuthorizationChange()
            if st != .notDetermined, st != .authorizedWhenInUse || self.alwaysPromptSeen { self.finishAlways() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map { (LocationTuning.deviceFix($0), LocationTuning.sourceLabel($0)) }
        Task { @MainActor in
            #if DEBUG
            if self.ignoresSystemFixes { return }
            #endif
            for (f, source) in fixes { self.ingest(f, source: source, nowMs: Date().timeIntervalSince1970 * 1000) }
        }
    }

    /// One fix from CoreLocation (nil: invalid accuracy). Internal for tests (`GpsQualityTests`).
    func ingest(_ fix: DeviceFix?, source: String = "device", nowMs: Double) {
        guard let f = fix else { gate.countInvalid(); return publishStats(nil, source: source, nowMs: nowMs) }
        guard case let .accept(ok) = gate.judge(f, nowMs: nowMs) else { return publishStats(f, source: source, nowMs: nowMs) }
        lastFix = ok
        displayFix = smoother.update(ok)
        if wantsFreshFix, nowMs - ok.atMs < GpsQuality.staleMs { wantsFreshFix = false; applySettings() }
        publishStats(ok, source: source, nowMs: nowMs)
        /* Every believable fix goes to the trail (raw log + its own smoother); no accuracy downgrade
         * when parked: a coarse chip at a red light used to cost the next minutes of the drive. */
        onTrailFix(ok)
        /* Cheap: only touches the manager when the tier's settings change. */
        retune(speed: ok.speed)
        guard isSharing else { return }
        if let sent = filter.accept(ok) {
            rearmRegion(sent)
            onFix(sent)
        }
    }

    private func publishStats(_ f: DeviceFix?, source: String, nowMs: Double) {
        var q = quality
        if let f {
            recentFixTimes.append(nowMs)
            recentFixTimes.removeAll { nowMs - $0 > 10_000 }
            q.lastAccuracyM = f.accuracy
            q.lastSpeedAccuracy = f.speedAccuracy
            q.lastCourseAccuracy = f.courseAccuracy
            q.lastAgeMs = max(0, nowMs - f.atMs)
        }
        q.hz = GpsQualityStats.rate(recentFixTimes)
        q.source = source
        q.accepted = gate.accepted
        q.rejected = gate.rejected
        q.precise = accuracyAuthorization != .reducedAccuracy
        q.headingSource = displayFix.flatMap { $0.heading } != nil ? .course : .none
        if q != quality { quality = q }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        /* kCLErrorLocationUnknown is transient; the next fix will come. */
    }
}
