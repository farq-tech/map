import CoreLocation
import SwiftUI

/// Routing for guidance on this phone — the live trip and «اتجه» from the home map alike:
/// Mapbox (or the company's Valhalla, hidden setting) for streets, the desert router after.
enum NavProviders {
    @MainActor static func standard() -> NavRoutingProvider {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-SaryNavDemo") { return DemoNavProvider() }
        #endif
        let streets = SwitchingRouteProvider(mapbox: MapboxNavRoutingProvider())
        return RestrictedZoneGuardProvider(base: DesertAwareRouteProvider(base: streets))
    }
}

/// My car's colour for «اتجه» without an outing (temporary until #157): the colour the live map
/// last gave me («أنت», `OutingView.colors`), else the white car.
enum MyCarColor {
    static let key = "sary.myCarColor.v1"
    static let fallback: UInt32 = 0xE8EEF0

    static func current(_ d: UserDefaults = .standard) -> UInt32 {
        (d.object(forKey: key) as? NSNumber).map { UInt32(truncating: $0) } ?? fallback
    }

    static func remember(_ c: UInt32, _ d: UserDefaults = .standard) {
        guard current(d) != c || d.object(forKey: key) == nil else { return }
        d.set(NSNumber(value: c), forKey: key)
    }
}

/// Pure decisions of «اتجه» without an outing (unit-tested in HomeFlowTests).
enum StandaloneNavRules {
    enum Gate: Equatable {
        /// iOS has not allowed the location (or refused it): nothing to guide from.
        case needsPermission
        /// Allowed, but no fresh fix yet: «ننتظر موقعك…», guidance starts by itself.
        case waitingForFix
        case ready
    }

    static func gate(canLocate: Bool, fix: DeviceFix?, now: Date) -> Gate {
        guard canLocate else { return .needsPermission }
        return NavFixWait.isFresh(fix, now: now) ? .ready : .waitingForFix
    }

    /// Owner report, Build 38: on a phone lying still iOS sends nothing new (distance filter), so
    /// «اتجه» waited forever for a fix it never asked for. While waiting: ask the GPS for a fresh fix
    /// at its best (no filter), re-check every `recheckS` (the gate depends on the clock, not only on
    /// new fixes), and past `NavFixWait.slowAfterS` say «اطلع لمكان مكشوف», still trying.
    static let recheckS: TimeInterval = 1

    /// Ask for a fresh fix now: allowed, not started, no fresh fix, and not already asked.
    static func needsFreshFixRequest(gate: Gate, started: Bool, alreadyAsked: Bool) -> Bool {
        gate == .waitingForFix && !started && !alreadyAsked
    }

    /// Owner, Build 39: «ننتظر موقعك… · الدقة ±٨ م» with the spinner, forever, though the map followed a
    /// good fix. The screen kept a one-way `started` flag: once guidance had started, anything that
    /// brought it back to idle (`nav.end()` from a disappear/appear, a refused start) left it idle for
    /// good, and the idle card said «ننتظر موقعك» even with the gate ready. Now the guidance phase
    /// itself decides: idle and the gate ready → start (re-checked every second).
    static func shouldStart(gate: Gate, phase: NavPhase, loading: Bool) -> Bool {
        gate == .ready && phase == .idle && !loading
    }

    /// The idle card: «ننتظر موقعك…» only while the gate really waits for a fix.
    static func idleText(gate: Gate, accuracyM: Double?, waitingSince: Date?, now: Date, targetName: String) -> String {
        gate == .ready ? "نبدأ التوجيه إلى \(targetName)…" : waitText(accuracyM: accuracyM, waitingSince: waitingSince, now: now)
    }

    /// One small line under the waiting card (owner's phone, remote diagnosis): accepted / refused fixes
    /// by reason, and the age of the last fix — «مقبولة ٣٠ · مرفوضة: قديمة ١٢ · آخر قراءة قبل ٤ ث».
    static func diagnostics(accepted: Int, rejected: [FixRejection: Int], lastFixAgeS: Double?) -> String {
        let names: [FixRejection: String] = [.stale: "قديمة", .coarse: "ضعيفة", .teleport: "قفزة", .invalid: "غير صالحة"]
        let refused = FixRejection.allCases.compactMap { r -> String? in
            guard let n = rejected[r], n > 0 else { return nil }
            return "\(names[r] ?? r.rawValue) \(ArabicFormat.number(Double(n)))"
        }
        var parts = ["مقبولة \(ArabicFormat.number(Double(accepted)))"]
        parts.append(refused.isEmpty ? "مرفوضة ٠" : "مرفوضة: " + refused.joined(separator: "، "))
        if let a = lastFixAgeS, a.isFinite { parts.append("آخر قراءة قبل \(ArabicFormat.number(a.rounded())) ث") }
        return parts.joined(separator: " · ")
    }

    /// The waiting line: «ننتظر موقعك… · الدقة ±N م», then the open-sky hint (the live screen's words).
    static func waitText(accuracyM: Double?, waitingSince: Date?, now: Date) -> String {
        NavFixWait.text(accuracyM: accuracyM, slow: waitSlow(waitingSince: waitingSince, now: now))
    }

    static func waitSlow(waitingSince: Date?, now: Date) -> Bool {
        guard let since = waitingSince else { return false }
        return now.timeIntervalSince(since) >= NavFixWait.slowAfterS
    }

    /// The line on the map: what is left of the road route (and the straight last part to an
    /// off-road target), or the straight line still to go. Nothing while planning / arrived.
    static func line(phase: NavPhase, active: NavRoute?, progress: NavProgress?, offRoad: NavOffRoadLeg?, me: LngLat?, target: LngLat) -> [LngLat] {
        switch phase {
        case .guiding:
            guard let r = active else { return [] }
            var pts = remaining(r, progress: progress)
            if let leg = offRoad, let last = pts.last, Vehicle.distanceMeters(last, leg.to) > 5 { pts.append(leg.to) }
            return pts
        case .offRoad:
            return [me ?? offRoad?.from ?? target, target]
        case .idle, .planning, .arrived:
            return []
        }
    }

    /// The part of the route still ahead (the same cut as the live map's line).
    static func remaining(_ r: NavRoute, progress: NavProgress?) -> [LngLat] {
        NavRouteMetrics.remaining(r, progress: progress)
    }

    /// The follow camera moves at most this often (each move eases; every fix would shake).
    static let followEveryS: TimeInterval = 3

    static func followDue(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= followEveryS
    }
}

/// «اتجه» on the home place card: turn-by-turn on this phone with no outing and no Sary server —
/// the same `NavSession` (routing, voice, off-road arrow, retries offline) and the same guidance
/// panels as the live map, over the plan map. Nothing is sent to anyone; the road route needs
/// the internet (Mapbox), and without it the honest straight-line arrow guides while it retries.
struct StandaloneNavScreen: View {
    let target: NavTarget
    var close: () -> Void
    @EnvironmentObject private var location: LocationSharer
    @EnvironmentObject private var model: AppModel
    @Environment(\.sary) private var theme
    @StateObject private var nav = NavSession(provider: NavProviders.standard())
    @State private var started = false
    @State private var toast: String?
    @State private var camera: PlanCamera?
    @State private var cameraSeq = 1
    @State private var cameraAt: Date?
    @State private var followMe = true
    @State private var asking = false
    /// When «اتجه» started waiting for a fix (the 45 s open-sky hint counts from here).
    @State private var waitingSince: Date?
    /// The clock the gate is read with: ticks every second while waiting.
    @State private var now = Date()
    /// «سرعة المركبة» on this screen (the same smoothing as the live trip's speedometer).
    @StateObject private var speed = SpeedModel()

    var body: some View {
        let p = theme.palette
        let me = location.lastFix.map { LngLat(lng: $0.lng, lat: $0.lat) }
        let gate = StandaloneNavRules.gate(canLocate: location.canLocate, fix: location.lastFix, now: now)
        ZStack {
            PlanMapView(route: StandaloneNavRules.line(phase: nav.phase, active: nav.active, progress: nav.shownProgress, offRoad: nav.offRoad,
                                                       me: me, target: target.position),
                        destination: OutingDestination(name: target.name, lat: target.position.lat, lng: target.position.lng),
                        camera: camera, theme: theme, userLocation: me,
                        userCar: MyCarColor.current(),
                        userHeading: location.lastFix.flatMap { Policy.trustedHeading($0.heading, speed: $0.speed) })
                .ignoresSafeArea()
                .accessibilityIdentifier("standaloneNav.map")
            VStack(spacing: theme.space(.s)) {
                top(gate)
                if let toast {
                    Text(toast).saryText(.callout, weight: .bold).foregroundStyle(p.textPrimary)
                        .padding(.horizontal, theme.space(.m)).padding(.vertical, theme.space(.s))
                        .saryGlass(Capsule(), role: .control)
                        .onTapGesture { self.toast = nil }
                        .accessibilityIdentifier("standaloneNav.toast")
                }
                Spacer()
                HStack(alignment: .bottom) {
                    speedReadout
                    Spacer()
                    MapTiltButton()
                    Button { toggleCamera(me) } label: {
                        Image(systemName: followMe ? "map.fill" : "location.fill").font(.system(size: 17, weight: .bold))
                            .frame(width: 48, height: 48)
                    }
                    .foregroundStyle(p.textPrimary)
                    .saryGlass(Circle(), role: .control, interactive: true)
                    .accessibilityLabel(Text(followMe ? "نظرة عامة" : "تابعني"))
                    .accessibilityIdentifier("standaloneNav.camera")
                    Button { nav.muted.toggle() } label: {
                        Image(systemName: nav.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 17, weight: .bold))
                            .frame(width: 48, height: 48)
                    }
                    .foregroundStyle(p.textPrimary)
                    .saryGlass(Circle(), role: .control, interactive: true)
                    .accessibilityLabel(Text(nav.muted ? "الصوت مكتوم" : "الصوت"))
                    .accessibilityIdentifier("standaloneNav.mute")
                }
                bottom
            }
            .padding(theme.space(.m))
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-SaryParkedPhone") {
                location.debugParkPhone(at: LngLat(lng: 46.6744, lat: 24.7113), ageS: 300)
            }
            #endif
            let sharer = location
            nav.myFix = { [weak sharer] in sharer?.lastFix }
            nav.toast = { t in show(t) }
            location.watchForeground()
            begin()
        }
        #if DEBUG
        .task {
            /* `-SaryNavResetOnce <s>`: s seconds after guidance starts it is brought back to idle once
             * (as a disappear/appear does) — the Build 39 regression path. */
            let a = ProcessInfo.processInfo.arguments
            guard let i = a.firstIndex(of: "-SaryNavResetOnce"), i + 1 < a.count, let s = Double(a[i + 1]) else { return }
            while !Task.isCancelled, nav.phase == .idle || nav.phase == .planning { try? await Task.sleep(for: .seconds(0.5)) }
            try? await Task.sleep(for: .seconds(s))
            nav.end()
        }
        #endif
        .task {
            /* Re-check every second while waiting: the gate reads the clock, and a still phone sends
             * no new fix to trigger `onChange` (owner report, Build 38). */
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(StandaloneNavRules.recheckS))
                if nav.phase == .idle { now = Date(); begin() }
            }
        }
        .onChange(of: location.lastFix) { _, f in
            guard let f else { return }
            if nav.phase == .idle { begin() }
            nav.ingest(f)
            speed.ingest(f)
            follow(LngLat(lng: f.lng, lat: f.lat))
        }
        .onChange(of: location.canLocate) { _, _ in begin() }
        .onChange(of: model.online) { was, now in if now && !was { nav.retryNow() } }
        .onDisappear {
            nav.end()
            location.endFreshFixRequest()
            location.stopWatchingForeground()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("standaloneNav.screen")
    }

    // MARK: chrome

    /// My speed with the posted limit (as the live trip's guidance), or the limit alone until a
    /// speed is read. Respects «نبّهني إذا تجاوزت» (SpeedPrefs).
    @ViewBuilder
    private var speedReadout: some View {
        /* No speedometer / posted limit on foot («مشي»). */
        let guiding = nav.phase == .guiding && !nav.travelMode.isWalk
        if guiding && speed.everRead {
            let over = SpeedPrefs.alertOn() && (speed.current.kmh ?? 0) > Double(SpeedPrefs.limitKmh())
            NavSpeedCluster(ui: SpeedometerUI(current: speed.current, trip: nil, overLimit: over), limit: nav.progress?.speedLimitKmh)
                .accessibilityIdentifier("standaloneNav.speed")
        } else if guiding, let k = nav.progress?.speedLimitKmh {
            NavSpeedLimitSign(kmh: k)
                .accessibilityIdentifier("standaloneNav.speedLimit")
        }
    }

    @ViewBuilder
    private func top(_ gate: StandaloneNavRules.Gate) -> some View {
        switch nav.phase {
        case .guiding:
            NavManeuverBanner(nav: nav)
        case .offRoad:
            NavOffRoadPanel(nav: nav, reference: location.lastFix.flatMap { Policy.trustedHeading($0.heading, speed: $0.speed) } ?? 0)
        case .arrived:
            NavArrivalCard(nav: nav, end: close)
        case .planning:
            status("نحسب الطريق إلى \(target.name)…", busy: true)
        case .idle:
            switch gate {
            case .needsPermission: permissionCard
            case .waitingForFix, .ready:
                let slow = gate == .waitingForFix && StandaloneNavRules.waitSlow(waitingSince: waitingSince, now: now)
                VStack(alignment: .leading, spacing: theme.space(.xs)) {
                    status(StandaloneNavRules.idleText(gate: gate, accuracyM: location.quality.lastAccuracyM ?? location.lastFix?.accuracy,
                                                       waitingSince: waitingSince, now: now, targetName: target.name), busy: !slow)
                    Text(StandaloneNavRules.diagnostics(accepted: location.quality.accepted, rejected: location.quality.rejected,
                                                        lastFixAgeS: location.lastFix.map { (now.timeIntervalSince1970 * 1000 - $0.atMs) / 1000 }))
                        .saryText(.caption).foregroundStyle(theme.palette.textSecondary)
                        .padding(.horizontal, theme.space(.m))
                        .accessibilityIdentifier("standaloneNav.diagnostics")
                }
            }
        }
    }

    private func status(_ text: String, busy: Bool) -> some View {
        let p = theme.palette
        return HStack(spacing: theme.space(.m)) {
            if busy { ProgressView().tint(p.textPrimary) }
            Text(text).saryText(.headline).foregroundStyle(p.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(theme.space(.m))
        .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .panel)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("standaloneNav.status")
    }

    private var permissionCard: some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: theme.space(.s)) {
            Text("نحتاج موقعك عشان نوجّهك").saryText(.headline, weight: .bold).foregroundStyle(p.textPrimary)
            Text("موقعك يبقى على جوالك، ما يروح لأحد.").saryText(.footnote).foregroundStyle(p.textSecondary)
            Button {
                asking = true
                Task {
                    if location.authorization == .notDetermined {
                        _ = await location.requestWhenInUse()
                    } else if let u = URL(string: UIApplication.openSettingsURLString) {
                        _ = await UIApplication.shared.open(u)
                    }
                    asking = false
                    begin()
                }
            } label: {
                SaryButtonLabel(title: location.authorization == .notDetermined ? "اسمح بالموقع" : "افتح الإعدادات", systemImage: SaryIcon.locate, busy: asking)
            }
            .buttonStyle(.sary(.primary))
            .accessibilityIdentifier("standaloneNav.allow")
        }
        .padding(theme.space(.m))
        .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .panel)
    }

    @ViewBuilder
    private var bottom: some View {
        if nav.phase == .guiding || nav.phase == .offRoad {
            NavBottomBar(nav: nav, end: close)
                .padding(.vertical, theme.space(.m))
                .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .panel)
        } else if nav.phase != .arrived {
            Button(action: close) { SaryButtonLabel(title: "إلغاء", systemImage: SaryIcon.close) }
                .buttonStyle(.sary(.secondary))
                .accessibilityIdentifier("standaloneNav.cancel")
        }
    }

    // MARK: actions

    /// Starts once: permission and a fresh fix first (the wait is said on screen, never silent).
    private func begin() {
        guard nav.phase == .idle, !nav.loading else { return }
        let gate = StandaloneNavRules.gate(canLocate: location.canLocate, fix: location.lastFix, now: Date())
        guard StandaloneNavRules.shouldStart(gate: gate, phase: nav.phase, loading: nav.loading) else {
            if gate == .waitingForFix, waitingSince == nil { waitingSince = Date() }
            /* The GPS at its best, no distance filter, until a fresh fix comes (as the live screen's wait). */
            if StandaloneNavRules.needsFreshFixRequest(gate: gate, started: false, alreadyAsked: location.wantsFreshFix) {
                location.requestFreshFix()
            }
            return
        }
        started = true
        waitingSince = nil
        nav.startImmediately(to: target)
        if let f = location.lastFix { follow(LngLat(lng: f.lng, lat: f.lat), force: true) }
    }

    private func follow(_ me: LngLat, force: Bool = false) {
        guard followMe, force || StandaloneNavRules.followDue(last: cameraAt, now: Date()) else { return }
        cameraAt = Date()
        cameraSeq += 1
        camera = PlanCamera(kind: .point(me, zoom: 16), id: cameraSeq)
    }

    private func toggleCamera(_ me: LngLat?) {
        followMe.toggle()
        if followMe, let me {
            follow(me, force: true)
        } else {
            var pts = StandaloneNavRules.line(phase: nav.phase, active: nav.active, progress: nav.shownProgress, offRoad: nav.offRoad, me: me, target: target.position)
            pts.append(target.position)
            if let me { pts.append(me) }
            cameraSeq += 1
            camera = PlanCamera(kind: .fit(pts), id: cameraSeq)
        }
    }

    private func show(_ t: String) {
        toast = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if toast == t { toast = nil } }
    }
}
