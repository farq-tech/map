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
        return DesertAwareRouteProvider(base: streets)
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

    var body: some View {
        let p = theme.palette
        let me = location.lastFix.map { LngLat(lng: $0.lng, lat: $0.lat) }
        let gate = StandaloneNavRules.gate(canLocate: location.canLocate, fix: location.lastFix, now: now)
        ZStack {
            PlanMapView(route: StandaloneNavRules.line(phase: nav.phase, active: nav.active, progress: nav.shownProgress, offRoad: nav.offRoad,
                                                       me: me, target: target.position),
                        destination: OutingDestination(name: target.name, lat: target.position.lat, lng: target.position.lng),
                        camera: camera, theme: theme, userLocation: me)
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
                HStack {
                    Spacer()
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
        .task {
            /* Re-check every second while waiting: the gate reads the clock, and a still phone sends
             * no new fix to trigger `onChange` (owner report, Build 38). */
            while !Task.isCancelled && !started {
                try? await Task.sleep(for: .seconds(StandaloneNavRules.recheckS))
                now = Date()
                begin()
            }
        }
        .onChange(of: location.lastFix) { _, f in
            guard let f else { return }
            if !started { begin() }
            nav.ingest(f)
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
                let slow = StandaloneNavRules.waitSlow(waitingSince: waitingSince, now: now)
                status(StandaloneNavRules.waitText(accuracyM: location.quality.lastAccuracyM ?? location.lastFix?.accuracy,
                                                   waitingSince: waitingSince, now: now), busy: !slow)
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
        guard !started else { return }
        let gate = StandaloneNavRules.gate(canLocate: location.canLocate, fix: location.lastFix, now: Date())
        guard gate == .ready else {
            if gate == .waitingForFix, waitingSince == nil { waitingSince = Date() }
            /* The GPS at its best, no distance filter, until a fresh fix comes (as the live screen's wait). */
            if StandaloneNavRules.needsFreshFixRequest(gate: gate, started: started, alreadyAsked: location.wantsFreshFix) {
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
