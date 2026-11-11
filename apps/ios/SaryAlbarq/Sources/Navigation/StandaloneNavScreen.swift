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
        guard let p = progress, r.distanceM > 0, r.coordinates.count > 2 else { return r.coordinates }
        let done = max(0, r.distanceM - p.distanceRemainingM)
        var acc = 0.0
        for i in 1..<r.coordinates.count {
            let seg = Vehicle.distanceMeters(r.coordinates[i - 1], r.coordinates[i])
            if acc + seg >= done {
                let u = seg > 0 ? (done - acc) / seg : 0
                let a = r.coordinates[i - 1], b = r.coordinates[i]
                return [LngLat(lng: a.lng + (b.lng - a.lng) * u, lat: a.lat + (b.lat - a.lat) * u)] + r.coordinates[i...]
            }
            acc += seg
        }
        return Array(r.coordinates.suffix(2))
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

    var body: some View {
        let p = theme.palette
        let me = location.lastFix.map { LngLat(lng: $0.lng, lat: $0.lat) }
        let gate = StandaloneNavRules.gate(canLocate: location.canLocate, fix: location.lastFix, now: Date())
        ZStack {
            PlanMapView(route: StandaloneNavRules.line(phase: nav.phase, active: nav.active, progress: nav.progress, offRoad: nav.offRoad,
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
            let sharer = location
            nav.myFix = { [weak sharer] in sharer?.lastFix }
            nav.toast = { t in show(t) }
            location.watchForeground()
            begin()
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
            case .waitingForFix, .ready: status("ننتظر موقعك، ونبدأ على طول", busy: true)
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
        guard StandaloneNavRules.gate(canLocate: location.canLocate, fix: location.lastFix, now: Date()) == .ready else {
            if location.canLocate { location.watchForeground() }
            return
        }
        started = true
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
            var pts = StandaloneNavRules.line(phase: nav.phase, active: nav.active, progress: nav.progress, offRoad: nav.offRoad, me: me, target: target.position)
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
