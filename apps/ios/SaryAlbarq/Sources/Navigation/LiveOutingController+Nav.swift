import SwiftUI

/// «الملاحة» wiring on the live outing: where navigation starts from, what the
/// map draws, the control cluster while guiding. Kept here so the controller
/// itself only carries a few hooks.
extension LiveOutingController {
    static func navProvider(session: OutingSession) -> NavRoutingProvider {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-SaryNavDemo") { return DemoNavProvider() }
        #endif
        /* Mapbox by default; «مزوّد المسارات» (hidden setting) can switch to the company's Valhalla. */
        return SwitchingRouteProvider(mapbox: MapboxNavRoutingProvider())
    }

    // MARK: starting points

    /// Every target this outing offers, for «إلى أين؟».
    var navPickerRows: [NavTargetPicker.Row] {
        var rows: [NavTargetPicker.Row] = []
        let my = location.lastFix.map { LngLat(lng: $0.lng, lat: $0.lat) }
        func away(_ p: LngLat) -> String? { my.map { SaryFormat.distance(meters: Vehicle.distanceMeters($0, p)) } }
        if case let .success(t) = NavTargets.destination(navDestination()) {
            rows.append(.init(id: "destination", title: "الوجهة", subtitle: [t.name, away(t.position)].compactMap { $0 }.joined(separator: " · "),
                              icon: "flag.checkered", color: Color(rgb: 0x2B7BF0), result: .success(t)))
        }
        if case let .success(t) = NavTargets.rally(rallyPoint) {
            rows.append(.init(id: "rally", title: "نقطة التجمع", subtitle: [t.name, away(t.position)].compactMap { $0 }.joined(separator: " · "),
                              icon: SaryIcon.rally, color: nil, result: .success(t)))
        }
        if case let .success(t) = NavTargets.planRouteEnd(navPlanRoute()) {
            rows.append(.init(id: "planEnd", title: t.name, subtitle: away(t.position), icon: "point.topleft.down.to.point.bottomright.curvepath",
                              color: nil, result: .success(t)))
        }
        let i = input
        guard let v = session.view else { return rows }
        for p in LiveOutingPresenter.participants(i) where !p.isMe {
            let r = memberTarget(p.id)
            let sub: String
            switch r {
            case let .success(t): sub = away(t.position) ?? "مباشر"
            case let .failure(e):
                if case let .memberStale(_, since) = e { sub = SaryFormat.lastUpdate(since: since, now: Date()) + " · موقع قديم" } else { sub = "لا يشارك موقعه" }
            }
            rows.append(.init(id: "member.\(p.id)", title: "روح لـ\(p.name)", subtitle: sub, icon: "person.fill",
                              color: Color(rgb: v.colors[p.id] ?? 0x888888), result: r))
        }
        return rows
    }

    func memberTarget(_ id: String) -> Result<NavTarget, NavRefusal> {
        guard let v = session.view, let p = LiveOutingPresenter.participants(input).first(where: { $0.id == id }) else { return .failure(.missing) }
        let pos = LiveOutingPresenter.position(of: id, in: v, myFix: location.lastFix).map { LngLat(lng: $0.lng, lat: $0.lat) }
        return NavTargets.member(id: id, name: p.name, isMe: p.isMe, position: pos, presence: p.presence)
    }

    func openNavPicker() {
        sheetDetent = .peek
        modal = .navPicker
    }

    /// «ابدأ الملاحة» from anywhere: refuse honestly, or open the route options.
    func navigate(_ r: Result<NavTarget, NavRefusal>) {
        switch r {
        case let .failure(e):
            toast(e.message)
        case let .success(t):
            guard location.lastFix != nil else { return toast(NavRefusal.noFix.message) }
            backTrackOffForNav()
            following = false
            sheetDetent = .peek
            nav.plan(to: t)
            navCameraKey += 1
            modal = .navOptions
        }
    }

    func navigate(to t: NavTarget) { navigate(.success(t)) }

    /// «اتجه» on a card (a waypoint, a fuel station, a silent member's last fix): our own
    /// guidance on this map, never another app. While guiding, ask first («نغيّر الوجهة…؟»).
    func directions(_ r: Result<NavTarget, NavRefusal>) {
        if case let .failure(e) = r { return toast(e.message) }
        guard case let .success(t) = r else { return }
        guard location.lastFix != nil else { return toast(NavRefusal.noFix.message) }
        modal = nil
        let ask = Self.directionsNeedsConfirm(nav.phase)
        /* After the card's sheet has gone (a dialog or sheet over a closing one is dropped). */
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            if ask { self.confirm = .retarget(t) } else { self.navigate(.success(t)) }
        }
    }

    /// Guidance is on (or being planned): a new «اتجه» would replace it, so we ask.
    static func directionsNeedsConfirm(_ phase: NavPhase) -> Bool {
        phase == .guiding || phase == .offRoad || phase == .planning
    }

    /// «غيّر»: re-plan to the new target. The trip's own guidance comes back by itself once this
    /// one ends (`TripAutoNav`: idle → start); a person's own target is in «أدوات ← الطريق».
    func retarget(to t: NavTarget) {
        if case .retarget = confirm { confirm = nil }
        let wasAuto = nav.auto
        let hadTarget = nav.target != nil
        navigate(.success(t))
        guard hadTarget, nav.target == t else { return }
        toast(Self.retargetHint(wasAuto: wasAuto))
    }

    static func retargetHint(wasAuto: Bool) -> String {
        wasAuto ? "يرجع توجيه الرحلة للوجهة لما تنهي هذا التوجيه" : "ترجع للوجهة من أدوات ← الطريق"
    }

    /// «روح له»: refused in the card itself (with the reason) when their position is old.
    func navigateToMember(_ id: String) {
        let r = memberTarget(id)
        if case let .failure(e) = r {
            cardMessage[id] = e.message
            return
        }
        cardMessage[id] = nil
        modal = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.navigate(r) }
    }

    /// A long press on the map: «ابدأ الملاحة إلى هنا».
    func navLongPressed(_ p: LngLat) {
        guard !nav.isActive else { return }
        navigate(NavTargets.point(p))
    }

    func startNav() {
        /* Start first: closing the options sheet while still planning would cancel the plan. */
        nav.start()
        modal = nil
        sheetDetent = .peek
    }

    func endNav() {
        /* «أوقف التوجيه» on the trip's own guidance: paused on this phone until «استأنف». */
        if nav.auto, nav.phase != .arrived { pauseAutoNav() }
        nav.end()
        stopAutoFollow()
        modal = nil
    }

    /// The options sheet went away without «ابدأ».
    func navOptionsClosed() {
        if nav.phase == .planning { nav.cancelPlanning() }
    }

    func navUserMovedMap() {
        if nav.isActive, nav.camera != .free { nav.camera = .free }
    }

    /// «افتح في Google Maps» / «افتح في Waze» in the route options: the person explicitly picks another app.
    func openExternally(_ app: ExternalNav.App) {
        guard let t = nav.target else { return }
        ExternalNav.open(app, t.position)
    }

    private func backTrackOffForNav() {
        if backTrack != nil { stopBackTrack() }
    }

    // MARK: the map

    var mapNav: MapNavDrawing {
        var d = MapNavDrawing()
        guard nav.phase != .idle, let t = nav.target else { return d }
        d.target = t.position
        d.targetName = t.name
        d.targetNote = t.staleNote()
        switch nav.phase {
        case .planning:
            let sel = nav.selectedId ?? nav.routes.first?.id
            d.routes = nav.routes.map { .init(id: $0.id, coordinates: $0.coordinates, selected: $0.id == sel) }
            if let best = nav.routes.first {
                d.labels = nav.routes.map { r in
                    .init(id: r.id, at: Self.labelPoint(r, others: nav.routes),
                          text: "\(NavText.remaining(seconds: r.durationS)) · \(SaryFormat.distance(meters: r.distanceM))" + (r.id == best.id ? "" : " · \(NavRouteChoice.delta(r, best: best))"),
                          selected: r.id == sel)
                }
            }
            var pts = nav.routes.flatMap { $0.coordinates }
            pts.append(t.position)
            if let f = location.lastFix { pts.append(LngLat(lng: f.lng, lat: f.lat)) }
            d.camera = .fit(pts, bottomShare: 0.55)
            d.cameraKey = navCameraKey * 1000 + nav.routes.count
        case .guiding:
            if let r = nav.active { d.routes = [.init(id: r.id, coordinates: Self.remaining(r, progress: nav.progress), selected: true)] }
            d.camera = navCamera()
            d.cameraKey = navCameraKey * 1000 + 500
        case .offRoad, .arrived:
            d.camera = nav.phase == .arrived ? nil : navCamera()
            d.cameraKey = navCameraKey * 1000 + 500
        case .idle:
            break
        }
        if let leg = nav.offRoad, nav.phase != .arrived {
            var from = leg.from
            if nav.phase == .offRoad || nav.direct, let f = location.lastFix { from = LngLat(lng: f.lng, lat: f.lat) }
            d.offRoad = [from, leg.to]
        }
        return d
    }

    private func navCamera() -> MapNavDrawing.Camera? {
        switch nav.camera {
        /* Following my car is the map's own frame-by-frame camera («باتجاهي», `mapFollowMode`). */
        case .follow, .free: return nil
        case .overview:
            var pts = nav.active.map { Self.remaining($0, progress: nav.progress) } ?? []
            if let t = nav.target { pts.append(t.position) }
            if let f = location.lastFix { pts.append(LngLat(lng: f.lng, lat: f.lat)) }
            return .fit(pts, bottomShare: 0.2)
        }
    }

    /// The part of the route still ahead (the line shrinks behind the car).
    static func remaining(_ r: NavRoute, progress: NavProgress?) -> [LngLat] {
        guard let p = progress, r.distanceM > 0, r.coordinates.count > 2 else { return r.coordinates }
        let done = max(0, r.distanceM - p.distanceRemainingM)
        var acc = 0.0
        for i in 1..<r.coordinates.count {
            let seg = Vehicle.distanceMeters(r.coordinates[i - 1], r.coordinates[i])
            if acc + seg >= done {
                let u = seg > 0 ? (done - acc) / seg : 0
                let a = r.coordinates[i - 1], b = r.coordinates[i]
                let cut = LngLat(lng: a.lng + (b.lng - a.lng) * u, lat: a.lat + (b.lat - a.lat) * u)
                return [cut] + r.coordinates[i...]
            }
            acc += seg
        }
        return Array(r.coordinates.suffix(2))
    }

    /// Where to hang an alternative's label: a point on it far from the other routes.
    static func labelPoint(_ r: NavRoute, others: [NavRoute]) -> LngLat {
        let c = r.coordinates
        guard c.count > 4 else { return c.first ?? LngLat(lng: 0, lat: 0) }
        let rest = others.filter { $0.id != r.id }.flatMap { o in stride(from: 0, to: o.coordinates.count, by: max(1, o.coordinates.count / 60)).map { o.coordinates[$0] } }
        var best = c[c.count / 2], bestD = -1.0
        for i in stride(from: c.count / 5, to: c.count * 4 / 5, by: max(1, c.count / 40)) {
            let d = rest.map { Vehicle.distanceMeters($0, c[i]) }.min() ?? 0
            if d > bestD { bestD = d; best = c[i] }
        }
        return best
    }

    // MARK: the control cluster while navigating

    /// While guiding: the camera button («تتبعني» / «باتجاهي») and «نظرة عامة» (voice and steps sit in the guidance bar).
    var navControlItems: [SaryMapControlItem] {
        [
            cameraModeItem,
            .init(id: "nav.overview", systemImage: "map.fill", label: "نظرة عامة", accessibilityID: "nav.overview", isActive: nav.camera == .overview),
        ]
    }

    func navControlTapped(_ id: String) {
        switch id {
        case "nav.overview":
            if nav.camera == .overview {
                recenterCamera()
            } else {
                nav.camera = .overview
                navCameraKey += 1
                followCam.release(offerBack: true, at: Date().timeIntervalSince1970)
                followCamTimerCheck()
            }
        case "nav.follow": recenterCamera()
        case "nav.mute": nav.muted.toggle()
        case "nav.steps": modal = .navSteps
        default: break
        }
    }

    /// Where the car points (for the off-road arrow): a trusted course, else the map's bearing.
    var navReferenceBearing: Double {
        location.lastFix.flatMap { Policy.trustedHeading($0.heading, speed: $0.speed) } ?? overlay.projection.bearing
    }

    /// «روح له» target moved a lot: suggest refreshing (a new destination is a new billed trip, so not automatic).
    var navMemberMovedMeters: Double? {
        guard let t = nav.target, t.source == .member, nav.phase == .guiding, let id = t.memberId,
              case let .success(now) = memberTarget(id) else { return nil }
        return NavTargets.memberMoved(t, now: now.position)
    }
}

#if DEBUG
extension LiveOutingController {
    /// Simulator runs and screenshots:
    ///   `-SaryNavTo "lat,lng[,name]"` plans to a point (after `-SaryNavDelay` s, default 4),
    ///   `-SaryNavStart` starts as soon as the routes are in,
    ///   `-SaryNavState reroute|offroad|arrived|direct` freezes a phase (with `-SaryNavDemo`).
    func navDebugLaunch() {
        let args = ProcessInfo.processInfo.arguments
        func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if args.contains("-SaryNavPicker") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.openNavPicker() }
        }
        guard let to = arg("-SaryNavTo") else { return }
        let parts = to.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, let lat = Double(parts[0]), let lng = Double(parts[1]) else { return }
        let name = parts.count > 2 ? parts[2] : nil
        let delay = arg("-SaryNavDelay").flatMap(Double.init) ?? 4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            /* On a clean simulator the first fix can come late (the permission prompt): wait for it
             * rather than be refused with «ننتظر أول قراءة من GPS». */
            self?.navWhenFixIn(tries: 80) { [weak self] in
            guard let self else { return }
            self.navigate(NavTargets.point(LngLat(lng: lng, lat: lat), name: name))
            guard args.contains("-SaryNavStart") || arg("-SaryNavState") != nil else { return }
            self.navWhenRoutesIn(tries: 40) { [weak self] in
                /* The demo router answers at once, while the options sheet is still sliding in:
                 * clearing `modal` mid-presentation leaves the sheet up over the guidance. Start
                 * once it is on screen, as a person tapping «ابدأ» would. */
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    guard let self else { return }
                    if let st = arg("-SaryNavState") { self.navFreeze(st) } else { self.startNav() }
                }
            }
            }
        }
    }

    private func navWhenFixIn(tries: Int, _ go: @escaping () -> Void) {
        if location.lastFix != nil || tries <= 0 { return go() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.navWhenFixIn(tries: tries - 1, go) }
    }

    private func navWhenRoutesIn(tries: Int, _ go: @escaping () -> Void) {
        if !nav.loading, !nav.routes.isEmpty || nav.direct { return go() }
        guard tries > 0 else { return NavLog.log("no routes: %@", nav.error ?? "-") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.navWhenRoutesIn(tries: tries - 1, go) }
    }

    private func navFreeze(_ st: String) {
        guard let t = nav.target, let r = nav.routes.first else { return }
        modal = nil
        /* At the start of the route (the line begins at my car), the first turn ahead. */
        let first = r.steps.first?.distanceM ?? 480
        let p = NavProgress(stepIndex: 1, distanceToManeuverM: first, distanceRemainingM: r.distanceM, durationRemainingS: r.durationS, speedLimitKmh: 80)
        let leg = nav.offRoad ?? NavOffRoad.direct(from: r.end ?? t.position, to: t.position)
        switch st {
        case "reroute": nav.debugSet(phase: .guiding, target: t, routes: [r], progress: p, offRoad: nav.offRoad, rerouting: true)
        case "offroad": nav.debugSet(phase: .offRoad, target: t, routes: [r], progress: nil, offRoad: leg)
        case "arrived": nav.debugSet(phase: .arrived, target: t, routes: [r], progress: nil, offRoad: nil)
        default: nav.debugSet(phase: .guiding, target: t, routes: [r], progress: p, offRoad: nav.offRoad)
        }
        sheetDetent = .peek
        if ProcessInfo.processInfo.arguments.contains("-SaryNavSteps") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.modal = .navSteps }
        }
    }
}

/// Screenshots / UI tests without network: a real-shaped route in Riyadh.
final class DemoNavProvider: NavRoutingProvider {
    let name = "Demo"

    /// `-SaryNavOfflineFor <s>`: no network for the first s seconds (`-SaryNavOffline`: never).
    private static let launched = Date()

    func routes(_ r: NavRouteRequest) async throws -> NavRoutePlan {
        try? await Task.sleep(nanoseconds: 300_000_000)
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-SaryNavOffline") { throw NavRoutingError.offline }
        if let i = args.firstIndex(of: "-SaryNavOfflineFor"), i + 1 < args.count, let s = Double(args[i + 1]),
           Date().timeIntervalSince(Self.launched) < s { throw NavRoutingError.offline }
        let o = r.origin, t = r.target.position
        /* An L-shaped road route (north, then east) and a second one (east, then north), ending short of an off-road target. */
        let endsShort = r.target.name.contains("صحراء") || ProcessInfo.processInfo.arguments.contains("-SaryNavOffRoad")
        let end = endsShort ? LngLat(lng: o.lng + (t.lng - o.lng) * 0.7, lat: o.lat + (t.lat - o.lat) * 0.7) : t
        func line(_ a: LngLat, _ b: LngLat, n: Int) -> [LngLat] { (0...n).map { i in LngLat(lng: a.lng + (b.lng - a.lng) * Double(i) / Double(n), lat: a.lat + (b.lat - a.lat) * Double(i) / Double(n)) } }
        let k1 = LngLat(lng: o.lng, lat: end.lat), k2 = LngLat(lng: end.lng, lat: o.lat)
        func route(_ id: String, _ knee: LngLat, first: String, second: String, factor: Double) -> NavRoute {
            let c = line(o, knee, n: 20) + line(knee, end, n: 20).dropFirst()
            let d1 = Vehicle.distanceMeters(o, knee), d2 = Vehicle.distanceMeters(knee, end)
            let turnRight = Vehicle.bearing(knee, end) - Vehicle.bearing(o, knee)
            let dir: NavTurnDirection = ((turnRight + 360).truncatingRemainder(dividingBy: 360)) < 180 ? .right : .left
            let steps = [
                NavStep(maneuver: .init(kind: .depart, direction: nil), roadName: first, location: o, distanceM: d1, durationS: d1 / 14 * factor),
                NavStep(maneuver: .init(kind: .turn, direction: dir), roadName: second, location: knee, distanceM: d2, durationS: d2 / 16 * factor,
                        lanes: [NavLane(directions: [.left], valid: dir == .left), NavLane(directions: [.straight], valid: false),
                                NavLane(directions: [.straight, .right], valid: dir == .right, preferred: dir == .right)],
                        speedLimitKmh: 80),
                NavStep(maneuver: .init(kind: .arrive, direction: nil), roadName: nil, location: end, distanceM: 0, durationS: 0),
            ]
            return NavRoute(id: id, coordinates: c, distanceM: d1 + d2, durationS: (d1 / 14 + d2 / 16) * factor, steps: steps,
                            hasUnpaved: endsShort, hasTolls: false, via: first)
        }
        return NavRoutePlan(routes: [route("demo-a", k1, first: "طريق الملك فهد", second: "طريق مكة المكرمة", factor: 1),
                                     route("demo-b", k2, first: "طريق العليا", second: "طريق الملك عبدالله", factor: 1.18)])
    }
}
#endif
