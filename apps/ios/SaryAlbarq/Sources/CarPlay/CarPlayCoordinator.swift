import CarPlay
import Combine
import MapKit
import UIKit

/// Builds and updates every CarPlay template from the phone's open outing.
/// Reads `AppModel.session` (the same `OutingSession` the phone shows); keeps its own
/// frozen `BackTrack` for «طريق العودة»; never sends anything the phone would not.
@MainActor
final class CarPlayCoordinator: NSObject {
    private let scene: CPTemplateApplicationScene
    private let interface: CPInterfaceController
    private let window: CPWindow
    private let mapVC = CarPlayMapViewController()
    private let mapTemplate = CPMapTemplate()

    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private var sessionBag = Set<AnyCancellable>()
    private weak var boundSession: OutingSession?

    // Trip («طريق العودة» / «إلى نقطة التجمع» / «إلى الوجهة»).
    private var tripKind: CarPlayTripKind?
    private var navSession: CPNavigationSession?
    private var backTrack: BackTrack?
    private var maneuverKey: String?
    private var maneuvers: [CPManeuver] = []
    private var usingRoad = false

    // Alerts.
    private var book = CarPlayAlertBook()
    private var shownAlert: (id: String, alert: CPNavigationAlert)?
    private var replacingAlert = false
    private var sosGuard = CarPlaySOSGuard()
    private var sosSheetUp = false

    // Lists.
    private var membersTemplate: CPListTemplate?
    private var outingsTemplate: CPListTemplate?
    private var buttonKey = ""
    private var forcedNight: Bool?
    /// The driver backed out of the «سَرى البارق» list: do not push it again until asked.
    private var outingsClosedByDriver = false

    init(scene: CPTemplateApplicationScene, interface: CPInterfaceController, window: CPWindow) {
        self.scene = scene
        self.interface = interface
        self.window = window
        super.init()
    }

    private var model: AppModel? { AppDelegate.model }
    private var session: OutingSession? { model?.session }

    // MARK: lifecycle

    func start() {
        window.rootViewController = mapVC
        mapTemplate.mapDelegate = self
        mapTemplate.automaticallyHidesNavigationBar = false
        mapTemplate.mapButtons = mapButtons()
        interface.delegate = self
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-SaryCarPlayNight"), i + 1 < args.count { forcedNight = args[i + 1] == "1" }
        #endif
        applyStyle()
        interface.setRootTemplate(mapTemplate, animated: false, completion: nil)
        NotificationCenter.default.publisher(for: .saryModelReady).sink { [weak self] _ in self?.bindModel() }.store(in: &bag)
        NotificationCenter.default.publisher(for: .saryCarPlayFeaturesChanged).sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        bindModel()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        CarPlayHub.setActive(scene.activationState == .foregroundActive)
        refresh()
        #if DEBUG
        debugScript()
        #endif
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        endTrip(cancelled: true)
        bag = []
        sessionBag = []
        CarPlayHub.setActive(false)
    }

    private var modelSink: AnyCancellable?

    private func bindModel() {
        guard let m = model else { return }
        modelSink = m.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
    }

    private func bindSession(_ s: OutingSession?) {
        guard s !== boundSession else { return }
        boundSession = s
        sessionBag = []
        endTrip(cancelled: true)
        book = CarPlayAlertBook()
        guard let s else { return }
        /* A position or event moved: redraw at once (the 1 s timer covers ages). */
        s.objectWillChange.throttle(for: .milliseconds(400), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.refresh() }.store(in: &sessionBag)
        s.location.objectWillChange.throttle(for: .milliseconds(400), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.refresh() }.store(in: &sessionBag)
    }

    // MARK: input

    private func input(_ s: OutingSession) -> CarPlayInput { Self.makeInput(s) }

    /// The CarPlay input from the phone's open outing (shared with the DEBUG phone preview).
    static func makeInput(_ s: OutingSession) -> CarPlayInput {
        let fix = s.location.lastFix
        let src = CarPlayFeatures.source
        var i = CarPlayInput(view: s.view, myFix: fix, isSharingNow: s.isSharingNow,
                             course: fix.flatMap { Policy.trustedHeading($0.heading, speed: $0.speed) },
                             destination: src?.carPlayDestination(), trip: src?.carPlayTripProgress(), stuck: src?.carPlayStuckMembers() ?? [],
                             convoy: src?.carPlayConvoy(), now: Date())
        #if DEBUG
        debugDecorate(&i, session: s)
        #endif
        return i
    }

    // MARK: refresh

    private func refresh() {
        bindSession(session)
        applyStyle()
        guard let s = session, s.view != nil else {
            showNoOuting()
            return
        }
        hideNoOuting()
        let i = input(s)
        let g = updateTrip(i, session: s)
        mapVC.show(mapContent(i, session: s))
        updateButtons(i)
        updateAlerts(i, guidance: g)
        updateMembersList(i)
    }

    private func applyStyle() {
        let dark = forcedNight ?? (interface.carTraitCollection.userInterfaceStyle == .dark)
        mapVC.night = dark
        mapTemplate.guidanceBackgroundColor = dark ? UIColor(red: 0.02, green: 0.13, blue: 0.13, alpha: 1) : UIColor(red: 0.02, green: 0.2, blue: 0.2, alpha: 1)
        mapTemplate.tripEstimateStyle = dark ? .dark : .light
    }

    private func mapContent(_ i: CarPlayInput, session s: OutingSession) -> CarPlayMapContent {
        var c = CarPlayMapContent()
        c.cars = CarPlayPresenter.mapCars(i)
        let runs = tripKind == .wayBack ? Trail.runs(backTrack?.path ?? s.trail.points) : s.trail.runs
        c.trailSolid = runs.solid
        c.trailGaps = runs.gaps
        c.start = (tripKind == .wayBack ? backTrack?.startPoint : nil) ?? s.trail.start?.position
        c.rally = CarPlayPresenter.rally(i)
        c.destination = CarPlayPresenter.destination(i)
        if usingRoad { c.routeLine = CarPlayFeatures.roadNavigation?.carPlayRoadProgress()?.routeLine ?? [] }
        c.highlightTrail = tripKind == .wayBack
        return c
    }

    // MARK: buttons

    private func mapButtons() -> [CPMapButton] {
        func button(_ symbol: String, _ label: String, _ action: @escaping (CarPlayCoordinator) -> Void) -> CPMapButton {
            let b = CPMapButton { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated { action(self) }
            }
            b.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))
            b.accessibilityLabel = label
            return b
        }
        return [
            button("location.fill", "موقعي") { $0.mapVC.follow() },
            button("person.3.fill", "المجموعة") { $0.fitGroup() },
            button("plus.magnifyingglass", "تكبير") { $0.mapVC.zoom(by: 1) },
            button("minus.magnifyingglass", "تصغير") { $0.mapVC.zoom(by: -1) },
        ]
    }

    private func bar(_ title: String, _ action: @escaping (CarPlayCoordinator) -> Void) -> CPBarButton {
        CPBarButton(title: title) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { action(self) }
        }
    }

    private func updateButtons(_ i: CarPlayInput) {
        let mySOS = i.view?.me?.sos != nil
        let leading = tripKind != nil ? "إنهاء" : "طريق الرجعة"
        let sos = mySOS ? "ألغِ النداء" : "نداء"
        let key = "\(leading)|\(sos)"
        guard key != buttonKey else { return }
        buttonKey = key
        mapTemplate.leadingNavigationBarButtons = [
            tripKind != nil ? bar("إنهاء") { $0.endTrip(cancelled: true) } : bar("طريق الرجعة") { $0.startTrip(.wayBack) },
            bar("العيال") { $0.showMembers() },
        ]
        mapTemplate.trailingNavigationBarButtons = [
            bar("إلى…") { $0.showTrips() },
            bar(sos) { $0.sosPressed() },
        ]
    }

    private func fitGroup() {
        guard let s = session else { return }
        let i = input(s)
        var extra: [LngLat] = []
        if let r = CarPlayPresenter.rally(i) { extra.append(r.position) }
        mapVC.fitGroup(extra: extra)
    }

    // MARK: no outing

    private func showNoOuting() {
        let key = "none"
        if buttonKey != key {
            buttonKey = key
            mapTemplate.leadingNavigationBarButtons = []
            mapTemplate.trailingNavigationBarButtons = [bar("الطلعات") { $0.pushOutings() }]
        }
        if let s = boundSession?.location.lastFix ?? model?.location.lastFix {
            var c = CarPlayMapContent()
            c.cars = [CarPlayMapCar(id: "me", position: LngLat(lng: s.lng, lat: s.lat), color: Vehicle.mySpotHex, label: "أنت",
                                    live: Date().timeIntervalSince1970 * 1000 - s.atMs < 30_000, heading: Policy.trustedHeading(s.heading, speed: s.speed), isMe: true)]
            mapVC.show(c)
        }
        if let t = outingsTemplate {
            t.updateSections(outingSections())
        } else if !outingsClosedByDriver {
            pushOutings()
        }
        if shownAlert != nil { mapTemplate.dismissNavigationAlert(animated: false) { _ in } ; shownAlert = nil }
    }

    private func hideNoOuting() {
        outingsClosedByDriver = false
        guard outingsTemplate != nil else { return }
        outingsTemplate = nil
        buttonKey = ""
        interface.popToRootTemplate(animated: true, completion: nil)
    }

    private func pushOutings() {
        outingsClosedByDriver = false
        let t = CPListTemplate(title: "سَرى البارق", sections: outingSections())
        t.emptyViewTitleVariants = ["ابدأ من الجوال"]
        outingsTemplate = t
        interface.pushTemplate(t, animated: false, completion: nil)
    }

    private func outingSections() -> [CPListSection] {
        let start = CPListItem(text: "ابدأ من الجوال", detailText: "أنشئ طلعة أو انضم لها من الجوال وأنت واقف",
                               image: UIImage(systemName: "iphone"))
        start.handler = { _, done in done() }
        var sections = [CPListSection(items: [start], header: "ما فيه طلعة مفتوحة", sectionIndexTitle: nil)]
        let open = (model?.current ?? []).filter { $0.status != .ended }.prefix(6)
        if !open.isEmpty {
            let items = open.map { o -> CPListItem in
                let state: String
                switch o.status {
                case .active: state = "شغّالة"
                case .paused: state = "متوقفة مؤقتًا"
                case .created: state = "ما بدأت"
                case .ended: state = "انتهت"
                }
                let item = CPListItem(text: o.name, detailText: "\(state) · \(ArabicFormat.number(Double(o.member_count))) أعضاء",
                                      image: UIImage(systemName: "car.2.fill"))
                item.handler = { [weak self] _, done in
                    MainActor.assumeIsolated { self?.model?.open(o.id) }
                    done()
                }
                return item
            }
            sections.append(CPListSection(items: items, header: "افتح طلعة", sectionIndexTitle: nil))
        }
        return sections
    }

    // MARK: members («الأصحاب»)

    private func showMembers() {
        guard let s = session else { return }
        let t = CPListTemplate(title: "العيال", sections: memberSections(input(s)))
        t.emptyViewTitleVariants = ["ما فيه أحد غيرك في الطلعة"]
        membersTemplate = t
        interface.pushTemplate(t, animated: true, completion: nil)
    }

    private func updateMembersList(_ i: CarPlayInput) {
        guard let t = membersTemplate else { return }
        guard interface.templates.contains(where: { $0 === t }) else { membersTemplate = nil; return }
        t.updateSections(memberSections(i))
    }

    private func memberSections(_ i: CarPlayInput) -> [CPListSection] {
        let rows = CarPlayPresenter.memberRows(i)
        let items = rows.map { r -> CPListItem in
            let item = CPListItem(text: r.name, detailText: r.detail, image: Self.dot(r.color, live: r.isLive, alert: r.sos || r.stuck))
            item.handler = { [weak self] _, done in
                MainActor.assumeIsolated { self?.memberTapped(r) }
                done()
            }
            return item
        }
        return [CPListSection(items: items, header: CarPlayPresenter.mySharingLine(i), sectionIndexTitle: nil)]
    }

    private func memberTapped(_ r: CarPlayMemberRow) {
        var actions: [CPAlertAction] = []
        if let p = r.position {
            actions.append(CPAlertAction(title: "أظهره", style: .default) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.interface.dismissTemplate(animated: false, completion: nil)
                    self?.interface.popToRootTemplate(animated: true, completion: nil)
                    self?.mapVC.center(on: p)
                }
            })
        }
        if let phone = r.phone {
            actions.append(CPAlertAction(title: "اتصال", style: .default) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.interface.dismissTemplate(animated: true, completion: nil)
                    self?.call(phone)
                }
            })
        }
        actions.append(CPAlertAction(title: "رجوع", style: .cancel) { [weak self] _ in
            MainActor.assumeIsolated { self?.interface.dismissTemplate(animated: true, completion: nil) }
        })
        interface.presentTemplate(CPAlertTemplate(titleVariants: ["\(r.name)\n\(r.detail)", r.shortName], actions: actions), animated: true, completion: nil)
    }

    private func call(_ e164: String) {
        let digits = e164.filter { $0.isNumber || $0 == "+" }
        guard let u = URL(string: "tel:\(digits)") else { return }
        scene.open(u, options: nil, completionHandler: nil)
    }

    static func dot(_ rgb: UInt32, live: Bool, alert: Bool) -> UIImage {
        let size = CGSize(width: 28, height: 28)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let r = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
            let color = UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: live ? 1 : 0.4)
            color.setFill()
            ctx.cgContext.fillEllipse(in: r)
            (alert ? UIColor.systemRed : (live ? UIColor.white : UIColor.gray)).setStroke()
            ctx.cgContext.setLineWidth(alert ? 4 : 2.5)
            ctx.cgContext.strokeEllipse(in: r)
        }
    }

    // MARK: trips

    private func showTrips() {
        guard let s = session else { return }
        let i = input(s)
        var items: [CPListItem] = []
        for kind in CarPlayPresenter.availableTrips(i, trail: s.trail) {
            let detail: String
            switch kind {
            case .wayBack:
                let d = s.trail.start.flatMap { st in i.myPosition.map { Vehicle.distanceMeters($0, st.position) } }
                detail = "على مسارك المسجّل" + (d.map { " · البداية على بعد \(ArabicFormat.distance($0))" } ?? "")
            case .rally:
                let r = CarPlayPresenter.rally(i)!
                detail = (CarPlayPresenter.distanceAndDirection(from: i.myPosition, to: r.position)?.text ?? r.label) + " · اتجاه تقريبي"
            case .destination:
                let d = CarPlayPresenter.destination(i)!
                detail = CarPlayPresenter.tripLine(i)
                    ?? (CarPlayPresenter.distanceAndDirection(from: i.myPosition, to: d.position)?.text ?? d.label) + " · اتجاه تقريبي"
            }
            let icon = kind == .wayBack ? "arrow.uturn.backward" : (kind == .rally ? "flag.fill" : "mappin.and.ellipse")
            let item = CPListItem(text: kind.title, detailText: detail, image: UIImage(systemName: icon))
            item.handler = { [weak self] _, done in
                MainActor.assumeIsolated {
                    self?.interface.popToRootTemplate(animated: true, completion: nil)
                    self?.startTrip(kind)
                }
                done()
            }
            items.append(item)
        }
        let pan = CPListItem(text: "حرّك الخريطة", detailText: "بالأسهم على الشاشة", image: UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right"))
        pan.handler = { [weak self] _, done in
            MainActor.assumeIsolated {
                self?.interface.popToRootTemplate(animated: true, completion: nil)
                self?.mapTemplate.showPanningInterface(animated: true)
            }
            done()
        }
        var tools = [pan]
        if let src = CarPlayFeatures.source, src.carPlayStuckReportSupported {
            let stuck = CPListItem(text: "غرّزت", detailText: "يوصل للعيال إنك تحتاج سحبة", image: UIImage(systemName: "exclamationmark.triangle.fill"))
            stuck.handler = { [weak self] _, done in
                MainActor.assumeIsolated { self?.confirmStuck() }
                done()
            }
            tools.append(stuck)
        }
        var sections: [CPListSection] = []
        if !items.isEmpty { sections.append(CPListSection(items: items, header: "وين تبي؟", sectionIndexTitle: nil)) }
        sections.append(CPListSection(items: tools, header: nil, sectionIndexTitle: nil))
        let t = CPListTemplate(title: "إلى…", sections: sections)
        interface.pushTemplate(t, animated: true, completion: nil)
    }

    private func confirmStuck() {
        let yes = CPAlertAction(title: "نعم، غرّزت", style: .destructive) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.interface.dismissTemplate(animated: true, completion: nil)
                _ = CarPlayFeatures.source?.carPlayReportStuck()
                self?.interface.popToRootTemplate(animated: true, completion: nil)
            }
        }
        let no = CPAlertAction(title: "لا", style: .cancel) { [weak self] _ in
            MainActor.assumeIsolated { self?.interface.dismissTemplate(animated: true, completion: nil) }
        }
        interface.presentTemplate(CPAlertTemplate(titleVariants: ["تبلّغ العيال إنك غرّزت؟"], actions: [yes, no]), animated: true, completion: nil)
    }

    private func targetFor(_ kind: CarPlayTripKind, _ i: CarPlayInput) -> (position: LngLat, label: String)? {
        switch kind {
        case .wayBack: return (backTrack?.startPoint ?? session?.trail.start?.position).map { ($0, "نقطة البداية") }
        case .rally: return CarPlayPresenter.rally(i)
        case .destination: return CarPlayPresenter.destination(i)
        }
    }

    func startTrip(_ kind: CarPlayTripKind) {
        guard let s = session else { return }
        endTrip(cancelled: true)
        let i = input(s)
        if kind == .wayBack {
            guard let bt = BackTrack(s.trail) else {
                info("ما فيه مسار مسجّل بعد", "يبدأ التسجيل أول ما تتحرك")
                return
            }
            backTrack = bt
        }
        guard let target = targetFor(kind, i) else { return }
        /* A road route when the turn-by-turn provider can make one; else trail / straight line. */
        usingRoad = kind != .wayBack && (CarPlayFeatures.roadNavigation?.carPlayStartRoadRoute(to: target.position, label: target.label) ?? false)
        let origin = i.myPosition.map { MKMapItem(placemark: MKPlacemark(coordinate: $0.coordinate)) } ?? MKMapItem.forCurrentLocation()
        let dest = MKMapItem(placemark: MKPlacemark(coordinate: target.position.coordinate))
        dest.name = target.label
        let info: String = usingRoad ? "طريق بالسيارة" : (kind == .wayBack ? "على مسارك المسجّل" : "اتجاه تقريبي · بدون طرق")
        let choice = CPRouteChoice(summaryVariants: [kind.title], additionalInformationVariants: [info], selectionSummaryVariants: [info])
        let trip = CPTrip(origin: origin, destination: dest, routeChoices: [choice])
        tripKind = kind
        navSession = mapTemplate.startNavigationSession(for: trip)
        maneuverKey = nil
        buttonKey = ""
        mapVC.follow()
        refresh()
    }

    private func endTrip(cancelled: Bool) {
        if let n = navSession { cancelled ? n.cancelTrip() : n.finishTrip() }
        if usingRoad { CarPlayFeatures.roadNavigation?.carPlayStopRoadRoute() }
        navSession = nil
        tripKind = nil
        backTrack = nil
        maneuvers = []
        maneuverKey = nil
        usingRoad = false
        buttonKey = ""
    }

    /// Guidance for the active trip, pushed into the CPNavigationSession.
    private func updateTrip(_ i: CarPlayInput, session s: OutingSession) -> CarPlayGuidance? {
        guard let kind = tripKind, let nav = navSession else { return nil }
        let road = CarPlayFeatures.roadNavigation
        let progress = usingRoad ? road?.carPlayRoadProgress() : nil
        let g = CarPlayGuide.pick(road: progress, roadActive: usingRoad && road?.carPlayRoadActive == true, kind: kind) {
            switch kind {
            case .wayBack:
                guard var bt = backTrack, let me = i.myPosition else { return CarPlayGuide.waiting(.wayBack) }
                let st = bt.update(me)
                backTrack = bt
                return CarPlayGuide.wayBack(st, course: i.course)
            case .rally, .destination:
                guard let t = targetFor(kind, i) else { return CarPlayGuide.waiting(kind) }
                return CarPlayGuide.straight(kind, from: i.myPosition, to: t.position, course: i.course)
            }
        }
        /* Maneuvers: the road provider's own list, or our one guidance card. */
        var cards: [(text: [String], symbol: String, distanceM: Double?)] = []
        if g.phase == .road, let p = progress {
            cards = p.maneuvers.prefix(2).map { ([$0.instruction, $0.shortInstruction ?? $0.instruction], $0.symbol, $0.distanceM) }
        } else {
            cards = [(["\(g.instruction) · \(g.detail)", g.instruction], g.symbol, g.remainingM)]
        }
        let key = cards.map { $0.text.joined() + $0.symbol }.joined(separator: "|")
        if key != maneuverKey {
            maneuverKey = key
            maneuvers = cards.map { c in
                let m = CPManeuver()
                m.instructionVariants = c.text
                m.symbolImage = UIImage(systemName: c.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 64, weight: .bold))?
                    .withTintColor(.white, renderingMode: .alwaysOriginal)
                if let d = c.distanceM { m.initialTravelEstimates = Self.estimates(d, speed: i.myFix?.speed) }
                return m
            }
            nav.upcomingManeuvers = maneuvers
        }
        if let first = maneuvers.first, let d = cards.first?.distanceM {
            nav.updateEstimates(Self.estimates(d, speed: i.myFix?.speed), for: first)
        }
        let remaining = progress?.remainingM ?? g.remainingM
        if let remaining, let trip = trips.first {
            let est = progress.map { CPTravelEstimates(distanceRemaining: Measurement(value: $0.remainingM, unit: .meters), timeRemaining: $0.remainingS) }
                ?? Self.estimates(remaining, speed: i.myFix?.speed)
            mapTemplate.updateEstimates(est, for: trip)
        }
        if g.arrived {
            let title = g.instruction
            endTrip(cancelled: false)
            present(CPNavigationAlert(titleVariants: [title], subtitleVariants: [kind.title + " انتهى"], image: UIImage(systemName: "flag.checkered"),
                                      primaryAction: CPAlertAction(title: "تمام", style: .default) { _ in }, secondaryAction: nil, duration: 8),
                    id: "arrived:\(kind.rawValue)")
            return nil
        }
        return g
    }

    private var trips: [CPTrip] { navSession.map { [$0.trip] } ?? [] }

    /// Time only from the car's real speed: no speed, no invented ETA.
    static func estimates(_ meters: Double, speed: Double?) -> CPTravelEstimates {
        let t: TimeInterval = (speed ?? 0) > 2 ? meters / speed! : 0
        return CPTravelEstimates(distanceRemaining: Measurement(value: max(0, meters), unit: UnitLength.meters), timeRemaining: t)
    }

    // MARK: alerts

    private func updateAlerts(_ i: CarPlayInput, guidance: CarPlayGuidance?) {
        let current = CarPlayAlerts.current(i, guidance: guidance)
        let next = book.next(from: current)
        if let shown = shownAlert, !shown.id.hasPrefix("arrived:"), !current.contains(where: { $0.id == shown.id }) {
            /* It no longer stands (SOS cleared, back on the trail). */
            replacingAlert = true
            mapTemplate.dismissNavigationAlert(animated: true) { [weak self] _ in MainActor.assumeIsolated { self?.replacingAlert = false } }
            shownAlert = nil
        }
        guard let a = next, a.id != shownAlert?.id else { return }
        /* An arrival card is not replaced by anything less urgent than a help request. */
        if let shown = shownAlert, shown.id.hasPrefix("arrived:"), !a.sticky { return }
        present(navAlert(a), id: a.id)
    }

    private func present(_ alert: CPNavigationAlert, id: String) {
        if shownAlert != nil {
            replacingAlert = true
            mapTemplate.dismissNavigationAlert(animated: false) { [weak self] _ in MainActor.assumeIsolated { self?.replacingAlert = false } }
        }
        shownAlert = (id, alert)
        mapTemplate.present(navigationAlert: alert, animated: true)
    }

    private func navAlert(_ a: CarPlayAlert) -> CPNavigationAlert {
        let id = a.id
        let done: (CarPlayCoordinator) -> Void = { $0.book.handle(id); $0.shownAlert = nil }
        func action(_ title: String, _ style: CPAlertAction.Style, _ then: @escaping (CarPlayCoordinator) -> Void) -> CPAlertAction {
            CPAlertAction(title: title, style: style) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated { done(self); then(self) }
            }
        }
        var primary: CPAlertAction
        var secondary: CPAlertAction?
        switch a.kind {
        case .friendSOS, .stuck:
            let pos = a.position
            primary = action("أظهره", .default) { c in if let pos { c.mapVC.center(on: pos) } }
            if let phone = a.phone {
                secondary = action("اتصال", .default) { c in c.call(phone) }
            } else {
                secondary = action("تمام", .cancel) { _ in }
            }
        case .offTrack:
            primary = action("تمام", .default) { _ in }
        case .convoyGap, .arrived:
            primary = action("تمام", .default) { _ in }
        }
        let image: UIImage? = {
            switch a.kind {
            case .friendSOS: return UIImage(systemName: "sos.circle.fill")?.withTintColor(.systemRed, renderingMode: .alwaysOriginal)
            case .stuck: return UIImage(systemName: "exclamationmark.triangle.fill")?.withTintColor(.systemOrange, renderingMode: .alwaysOriginal)
            case .offTrack: return UIImage(systemName: "arrow.uturn.backward.circle.fill")
            case .convoyGap: return UIImage(systemName: "car.2.fill")
            case .arrived: return UIImage(systemName: "flag.checkered")
            }
        }()
        return CPNavigationAlert(titleVariants: [a.title], subtitleVariants: [a.subtitle], image: image,
                                 primaryAction: primary, secondaryAction: secondary, duration: a.durationS)
    }

    private func info(_ title: String, _ subtitle: String) {
        present(CPNavigationAlert(titleVariants: [title], subtitleVariants: [subtitle], image: nil,
                                  primaryAction: CPAlertAction(title: "تمام", style: .default) { [weak self] _ in
                                      MainActor.assumeIsolated { self?.shownAlert = nil }
                                  }, secondaryAction: nil, duration: 6), id: "arrived:info")
    }

    // MARK: my SOS (two deliberate steps)

    private func sosPressed() {
        guard let s = session, !sosSheetUp else { return }
        let active = s.view?.me?.sos != nil
        _ = sosGuard.press(active: active)
        presentSOSSheet(active: active)
    }

    private func presentSOSSheet(active: Bool) {
        sosSheetUp = true
        let title = active ? "توقف نداء الاستغاثة؟ (أنا بخير)" : "ترسل نداء استغاثة لكل الطلعة؟"
        let yes = CPAlertAction(title: active ? "نعم، أنا بخير" : "نعم، أرسل النداء", style: active ? .default : .destructive) { [weak self] _ in
            MainActor.assumeIsolated { self?.sosConfirmed() }
        }
        let no = CPAlertAction(title: "لا", style: .cancel) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sosGuard.dismiss()
                self?.sosSheetUp = false
                self?.interface.dismissTemplate(animated: true, completion: nil)
            }
        }
        interface.presentTemplate(CPAlertTemplate(titleVariants: [title], actions: [yes, no]), animated: true, completion: nil)
    }

    private func sosConfirmed() {
        interface.dismissTemplate(animated: true, completion: nil)
        sosSheetUp = false
        guard let s = session else { return }
        let active = s.view?.me?.sos != nil
        switch sosGuard.confirm(active: active) {
        case .send: Task { await s.raiseSOS(); self.refresh() }
        case .cancel: Task { await s.cancelSOS(); self.refresh() }
        case .askConfirm, .askCancel: presentSOSSheet(active: active)
        case .nothing: break
        }
    }

    // MARK: DEBUG (screenshots / simulator only)

    #if DEBUG
    static func debugDecorate(_ i: inout CarPlayInput, session s: OutingSession) {
        let args = ProcessInfo.processInfo.arguments
        guard s.isDemo, var v = i.view else { return }
        let friends = v.orderedMembers.filter { $0.user_id != v.myId }
        if args.contains("-SaryCarPlayFriendSOS"), let f = friends.first, let p = v.positions[f.user_id] {
            v.apply(.sos(userId: f.user_id, sos: SosInfo(at: ISODate.string(i.now.addingTimeInterval(-40)),
                                                         fix: SosFix(lat: p.lat, lng: p.lng, accuracy: 8, recorded_at: p.recorded_at)), refresh: false))
        }
        if args.contains("-SaryCarPlayRally"), v.snapshot.outing.rally == nil {
            v.apply(.rally(RallyInfo(lat: 24.7178, lng: 46.6852, label: "عند الطلحة", set_at: nil, set_by: nil)))
        }
        if args.contains("-SaryCarPlayDestination"), i.destination == nil {
            i.destination = CarPlayDestination(position: LngLat(lng: 46.7105, lat: 24.7402), label: "روضة خريم")
        }
        i.view = v
    }

    /// `-SaryCarPlayShow members|trips|wayback|rally|destination|sos|pan` after the map is up.
    private func debugScript() {
        let args = ProcessInfo.processInfo.arguments
        guard let k = args.firstIndex(of: "-SaryCarPlayShow"), k + 1 < args.count else { return }
        let what = args[k + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            switch what {
            case "members": self.showMembers()
            case "trips": self.showTrips()
            case "wayback": self.startTrip(.wayBack)
            case "rally": self.startTrip(.rally)
            case "destination": self.startTrip(.destination)
            case "sos": self.sosPressed()
            case "pan": self.mapTemplate.showPanningInterface(animated: true)
            case "group": self.fitGroup()
            default: break
            }
        }
    }
    #endif
}

// MARK: - CPMapTemplateDelegate

extension CarPlayCoordinator: CPMapTemplateDelegate {
    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, panWith direction: CPMapTemplate.PanDirection) {
        MainActor.assumeIsolated {
            let step: CGFloat = 120
            var dx: CGFloat = 0, dy: CGFloat = 0
            if direction.contains(.left) { dx -= step }
            if direction.contains(.right) { dx += step }
            if direction.contains(.up) { dy -= step }
            if direction.contains(.down) { dy += step }
            mapVC.pan(dx: dx, dy: dy)
        }
    }

    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, didUpdatePanGestureWithTranslation translation: CGPoint, velocity: CGPoint) {
        MainActor.assumeIsolated { mapVC.pan(dx: -translation.x / 6, dy: -translation.y / 6, animated: false) }
    }

    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, displayStyleFor maneuver: CPManeuver) -> CPManeuverDisplayStyle {
        .leadingSymbol
    }

    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, didDismiss navigationAlert: CPNavigationAlert, dismissalContext: CPNavigationAlert.DismissalContext) {
        MainActor.assumeIsolated {
            guard !replacingAlert, let shown = shownAlert, shown.alert === navigationAlert else { return }
            /* Timed out or dismissed by the system: the driver has seen it. */
            book.handle(shown.id)
            shownAlert = nil
        }
    }

    nonisolated func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
        MainActor.assumeIsolated {
            navSession = nil
            endTrip(cancelled: true)
            refresh()
        }
    }
}

extension CarPlayCoordinator: CPInterfaceControllerDelegate {
    nonisolated func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        MainActor.assumeIsolated {
            if aTemplate === membersTemplate, !interface.templates.contains(where: { $0 === aTemplate }) { membersTemplate = nil }
            if aTemplate === outingsTemplate, !interface.templates.contains(where: { $0 === aTemplate }) {
                outingsTemplate = nil
                outingsClosedByDriver = true
            }
            if aTemplate is CPAlertTemplate { sosSheetUp = false }
        }
    }
}
