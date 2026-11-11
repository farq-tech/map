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
    /// `.place` trips: where to («روح لفلان», a searched / recent place).
    private var placeTarget: (position: LngLat, label: String, memberId: String?)?
    /// The trip preview («الأسرع / الأقصر») while the phone plans road routes.
    private var preview: (kind: CarPlayTripKind, target: (position: LngLat, label: String, memberId: String?), since: Date)?
    private var previewTrip: CPTrip?
    private var previewRouteId: String?
    private var pausedForReroute = false
    private var recents = CarPlayRecents.load()

    // Search.
    private var searchTask: Task<Void, Never>?
    private var searchResults: [PlaceSearch.Place] = []

    // Walkie-talkie.
    private var recordingAlertUp = false

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
        if let t = s.voiceNotes.carPlayTalking { i.talking = CarPlayTalking(noteId: t.id, userId: t.userId, name: t.name) }
        if let src, let v = s.view {
            for m in v.orderedMembers where m.user_id != v.myId {
                if let r = src.carPlayPresenceReason(m.user_id) { i.presenceReasons[m.user_id] = r }
            }
        }
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
        updatePreview(i)
        let g = updateTrip(i, session: s)
        mapVC.show(mapContent(i, session: s))
        updateRecording(s)
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
        if preview != nil, let road = CarPlayFeatures.roadNavigation {
            let opts = road.carPlayRouteOptions()
            c.routeLine = (opts.first { $0.id == previewRouteId } ?? opts.first)?.line ?? []
            if let t = preview?.target, tripKindForPin(preview!.kind) { c.destination = (t.position, t.label) }
        }
        if tripKind == .place, let t = placeTarget { c.destination = (t.position, t.label) }
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
            button("person.3.fill", "الربع") { $0.fitGroup() },
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
        let recording = session?.voiceNotes.carPlayRecording == true
        let leading = preview != nil ? SaryCopy.cancel : (tripKind == .wayBack ? SaryCopy.endBackTrack : tripKind != nil ? SaryCopy.stopGuidance : SaryCopy.backTrack)
        let talk = recording ? "أرسل" : "اضغط وسجّل"
        let sos = mySOS ? "ألغِ النداء" : "نداء"
        let key = "\(leading)|\(talk)|\(sos)"
        guard key != buttonKey else { return }
        buttonKey = key
        let first: CPBarButton
        if preview != nil {
            first = bar(leading) { $0.cancelPreview() }
        } else if tripKind != nil {
            /* Name the action (the word dictionary): «أنهِ الرجعة» / «أوقف التوجيه», never a bare «إنهاء». */
            first = bar(leading) { $0.endTrip(cancelled: true) }
        } else {
            first = bar(leading) { $0.startTrip(.wayBack) }
        }
        /* «اضغط وسجّل» → «أرسل»: the phone's own talk button (tap, talk, tap). */
        mapTemplate.leadingNavigationBarButtons = [first, bar(talk) { $0.talkPressed() }]
        mapTemplate.trailingNavigationBarButtons = [
            bar("وين؟") { $0.showTrips() },
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
        let t = CPListTemplate(title: "الربع", sections: memberSections(input(s)))
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

    /// «وين نروح؟»: search, the outing's points, «روح لفلان», recent places, tools.
    private func showTrips() {
        guard let s = session else { return }
        let t = CPListTemplate(title: "وين نروح؟", sections: destinationSections(input(s), session: s))
        t.emptyViewTitleVariants = ["ما فيه وجهة بعد"]
        interface.pushTemplate(t, animated: true, completion: nil)
    }

    private func destinationSections(_ i: CarPlayInput, session s: OutingSession) -> [CPListSection] {
        let search = CPListItem(text: "ابحث عن مكان", detailText: "في السعودية", image: UIImage(systemName: "magnifyingglass"))
        search.handler = { [weak self] _, done in
            MainActor.assumeIsolated { self?.showSearch() }
            done()
        }
        let members = CPListItem(text: "الربع", detailText: CarPlayPresenter.mySharingLine(i), image: UIImage(systemName: "person.3.fill"))
        members.handler = { [weak self] _, done in
            MainActor.assumeIsolated { self?.showMembers() }
            done()
        }
        var sections = [CPListSection(items: [search, members], header: nil, sectionIndexTitle: nil)]
        for sec in CarPlayDestinations.sections(i, trail: s.trail, recents: recents) {
            let items = sec.rows.map { r -> CPListItem in
                let item = CPListItem(text: r.title, detailText: r.detail, image: UIImage(systemName: r.symbol))
                item.isEnabled = r.action != .disabled
                item.handler = { [weak self] _, done in
                    MainActor.assumeIsolated { self?.destinationTapped(r.action) }
                    done()
                }
                return item
            }
            sections.append(CPListSection(items: items, header: sec.header, sectionIndexTitle: nil))
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
        sections.append(CPListSection(items: tools, header: "أدوات", sectionIndexTitle: nil))
        return sections
    }

    private func destinationTapped(_ a: CarPlayDestinationRow.Action) {
        interface.popToRootTemplate(animated: true, completion: nil)
        switch a {
        case let .trip(kind): startTrip(kind)
        case let .member(id, name, p): startPlace(p, label: CarPlayPresenter.shortName(name), memberId: id)
        case let .place(name, p): startPlace(p, label: name, memberId: nil)
        case .disabled: break
        }
    }

    /// A searched / recent place, or «روح لفلان».
    func startPlace(_ p: LngLat, label: String, memberId: String?) {
        if memberId == nil {
            recents.add(name: label, at: p)
            recents.save()
        }
        placeTarget = (p, label, memberId)
        startTrip(.place)
    }

    // MARK: search («ابحث عن مكان»)

    private func showSearch() {
        let t = CPSearchTemplate()
        t.delegate = self
        interface.pushTemplate(t, animated: true, completion: nil)
    }

    fileprivate func search(_ text: String, completion: @escaping ([CPListItem]) -> Void) {
        searchTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { searchResults = []; completion([]); return }
        let near = session.flatMap { input($0).myPosition }
        searchTask = Task { [weak self] in
            /* Typing settles first (CarPlay limits keyboard use; dictation sends whole words). */
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let found: [PlaceSearch.Place]
            var note: String?
            do { found = try await PlaceSearch.search(q, near: near) } catch {
                found = []
                note = (error as? PlaceSearch.SearchError)?.arabic ?? "تعذّر البحث الآن"
            }
            guard !Task.isCancelled, let self else { return }
            self.searchResults = found
            var items = found.prefix(12).map { p -> CPListItem in
                let d = CarPlayPresenter.distanceAndDirection(from: near, to: p.point)?.text
                let item = CPListItem(text: p.name, detailText: [d, p.detail].compactMap { $0 }.joined(separator: " · "),
                                      image: UIImage(systemName: "mappin.circle.fill"))
                item.userInfo = p.id
                return item
            }
            if items.isEmpty { items = [CPListItem(text: note ?? "ما لقينا شي", detailText: nil)] }
            completion(Array(items))
        }
    }

    fileprivate func searchPicked(_ item: CPListItem) {
        guard let id = item.userInfo as? String, let p = searchResults.first(where: { $0.id == id }) else { return }
        interface.popToRootTemplate(animated: true, completion: nil)
        startPlace(p.point, label: p.name, memberId: nil)
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
        interface.presentTemplate(CPAlertTemplate(titleVariants: ["تبلّغ الربع إنك غرّزت؟"], actions: [yes, no]), animated: true, completion: nil)
    }

    private func targetFor(_ kind: CarPlayTripKind, _ i: CarPlayInput) -> (position: LngLat, label: String)? {
        switch kind {
        case .wayBack: return (backTrack?.startPoint ?? session?.trail.start?.position).map { ($0, "نقطة البداية") }
        case .rally: return CarPlayPresenter.rally(i)
        case .destination: return CarPlayPresenter.destination(i)
        case .place: return placeTarget.map { ($0.position, $0.label) }
        }
    }

    private func tripKindForPin(_ k: CarPlayTripKind) -> Bool { k == .place }

    private func tripTitle(_ kind: CarPlayTripKind) -> String {
        kind == .place ? (placeTarget.map { "إلى \($0.label)" } ?? kind.title) : kind.title
    }

    func startTrip(_ kind: CarPlayTripKind) {
        guard let s = session else { return }
        let keepPlace = placeTarget
        endTrip(cancelled: true)
        placeTarget = keepPlace
        let i = input(s)
        if kind == .wayBack {
            guard let bt = BackTrack(s.trail) else {
                info("ما فيه مسار مسجّل بعد", "يبدأ التسجيل أول ما تتحرك")
                return
            }
            backTrack = bt
        }
        guard let target = targetFor(kind, i) else { return }
        /* A road target: plan on the phone and show the trip preview («الأسرع / الأقصر»). */
        if kind != .wayBack, let road = CarPlayFeatures.roadNavigation,
           road.carPlayPlanRoadRoute(to: target.position, label: target.label, memberId: kind == .place ? placeTarget?.memberId : nil) {
            preview = (kind, (target.position, target.label, kind == .place ? placeTarget?.memberId : nil), Date())
            previewTrip = nil
            previewRouteId = nil
            buttonKey = ""
            refresh()
            return
        }
        beginSession(kind, target: target, road: false, choice: nil)
    }

    /// Starts the CPNavigationSession (road: on the chosen route; else trail / straight line).
    private func beginSession(_ kind: CarPlayTripKind, target: (position: LngLat, label: String), road: Bool, choice: CPRouteChoice?, trip: CPTrip? = nil) {
        usingRoad = road
        let me = session.flatMap { input($0).myPosition }
        let t: CPTrip
        if let trip, let choice, road {
            t = trip
            _ = choice
        } else {
            let origin = me.map { MKMapItem(placemark: MKPlacemark(coordinate: $0.coordinate)) } ?? MKMapItem.forCurrentLocation()
            let dest = MKMapItem(placemark: MKPlacemark(coordinate: target.position.coordinate))
            dest.name = target.label
            let info: String = road ? "طريق بالسيارة" : (kind == .wayBack ? "على مسارك المسجّل" : "اتجاه تقريبي · بدون طرق")
            let c = CPRouteChoice(summaryVariants: [tripTitle(kind)], additionalInformationVariants: [info], selectionSummaryVariants: [info])
            t = CPTrip(origin: origin, destination: dest, routeChoices: [c])
        }
        tripKind = kind
        navSession = mapTemplate.startNavigationSession(for: t)
        maneuverKey = nil
        pausedForReroute = false
        buttonKey = ""
        mapVC.follow()
        refresh()
    }

    // MARK: trip preview («الأسرع / الأقصر»)

    static let previewTimeoutS: TimeInterval = 15

    private func updatePreview(_ i: CarPlayInput) {
        guard let p = preview, let road = CarPlayFeatures.roadNavigation else { return }
        let options = road.carPlayRouteOptions()
        if previewTrip == nil, !options.isEmpty {
            let me = i.myPosition
            let origin = me.map { MKMapItem(placemark: MKPlacemark(coordinate: $0.coordinate)) } ?? MKMapItem.forCurrentLocation()
            let dest = MKMapItem(placemark: MKPlacemark(coordinate: p.target.position.coordinate))
            dest.name = p.target.label
            let trip = CPTrip(origin: origin, destination: dest, routeChoices: CarPlayManeuverMapper.routeChoices(options))
            trip.userInfo = tripTitle(p.kind)
            previewTrip = trip
            previewRouteId = trip.routeChoices.first?.userInfo as? String
            let text = CPTripPreviewTextConfiguration(startButtonTitle: CarPlayManeuverMapper.previewText.start,
                                                      additionalRoutesButtonTitle: CarPlayManeuverMapper.previewText.more,
                                                      overviewButtonTitle: CarPlayManeuverMapper.previewText.overview)
            mapTemplate.showTripPreviews([trip], textConfiguration: text)
            mapVC.fitGroup(extra: [p.target.position])
            return
        }
        /* No road route (desert, no network): the honest straight line instead. */
        if previewTrip == nil, road.carPlayPlanFailed || Date().timeIntervalSince(p.since) > Self.previewTimeoutS {
            let kind = p.kind
            let target = (p.target.position, p.target.label)
            road.carPlayStopRoadRoute()
            preview = nil
            beginSession(kind, target: target, road: false, choice: nil)
        }
    }

    private func cancelPreview() {
        guard preview != nil else { return }
        mapTemplate.hideTripPreviews()
        CarPlayFeatures.roadNavigation?.carPlayStopRoadRoute()
        preview = nil
        previewTrip = nil
        previewRouteId = nil
        placeTarget = nil
        buttonKey = ""
        refresh()
    }

    fileprivate func previewStarted(_ trip: CPTrip, choice: CPRouteChoice) {
        guard let p = preview, let road = CarPlayFeatures.roadNavigation else { return }
        mapTemplate.hideTripPreviews()
        let id = (choice.userInfo as? String) ?? road.carPlayRouteOptions().first?.id
        preview = nil
        previewTrip = nil
        if let id { road.carPlayStartGuidance(routeId: id) }
        beginSession(p.kind, target: (p.target.position, p.target.label), road: id != nil, choice: choice, trip: trip)
    }

    private func endTrip(cancelled: Bool) {
        if let n = navSession { cancelled ? n.cancelTrip() : n.finishTrip() }
        if usingRoad || preview != nil { CarPlayFeatures.roadNavigation?.carPlayStopRoadRoute() }
        if preview != nil { mapTemplate.hideTripPreviews() }
        preview = nil
        previewTrip = nil
        placeTarget = nil
        pausedForReroute = false
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
            case .rally, .destination, .place:
                guard let t = targetFor(kind, i) else { return CarPlayGuide.waiting(kind) }
                return CarPlayGuide.straight(kind, from: i.myPosition, to: t.position, course: i.course)
            }
        }
        /* Rerouting: CarPlay shows «نحسب طريق ثاني…» until the new route's maneuvers come. */
        if g.phase == .road, let p = progress, p.rerouting {
            if !pausedForReroute {
                pausedForReroute = true
                nav.pauseTrip(for: .rerouting, description: "نحسب طريق ثاني…")
            }
            return g
        }
        if pausedForReroute { pausedForReroute = false; maneuverKey = nil }
        /* Maneuvers: the road provider's own list, or our one guidance card. */
        var cards: [CarPlayRoadManeuver] = []
        if g.phase == .road, let p = progress {
            cards = Array(p.maneuvers.prefix(2))
        } else {
            cards = [CarPlayRoadManeuver(instruction: "\(g.instruction) · \(g.detail)", shortInstruction: g.instruction,
                                         distanceM: g.remainingM ?? 0, symbol: g.symbol)]
        }
        let key = cards.map { $0.instruction + $0.symbol + ($0.cpManeuverType ?? "") + "\($0.lanes.count)" }.joined(separator: "|")
        if key != maneuverKey {
            maneuverKey = key
            maneuvers = cards.map { CarPlayManeuverMapper.maneuver($0, speed: i.myFix?.speed) }
            if #available(iOS 18.0, *) {
                var guidances: [CPLaneGuidance] = []
                for (k, c) in cards.enumerated() {
                    guard let lg = CarPlayManeuverMapper.laneGuidance(c, turn: nil) else { continue }
                    guidances.append(lg)
                    maneuvers[k].linkedLaneGuidance = lg
                }
                if !guidances.isEmpty { nav.add(guidances) }
                nav.currentLaneGuidance = guidances.first
            }
            nav.upcomingManeuvers = maneuvers
        }
        if let first = maneuvers.first, let c = cards.first {
            let d = g.phase == .road ? c.distanceM : (g.remainingM ?? 0)
            nav.updateEstimates(CarPlayManeuverMapper.estimates(distanceM: d, durationS: c.durationS, speed: i.myFix?.speed), for: first)
        }
        let remaining = progress?.remainingM ?? g.remainingM
        if let remaining, let trip = trips.first {
            /* Road: the router's remaining time (Mapbox traffic ETA). Else only from real speed. */
            let est = progress.map { CarPlayManeuverMapper.tripEstimates(remainingM: $0.remainingM, remainingS: $0.remainingS, speed: i.myFix?.speed) }
                ?? Self.estimates(remaining, speed: i.myFix?.speed)
            mapTemplate.updateEstimates(est, for: trip)
        }
        if g.arrived {
            let title = g.instruction
            endTrip(cancelled: false)
            present(CPNavigationAlert(titleVariants: [title], subtitleVariants: [tripTitle(kind) + " انتهى"], image: UIImage(systemName: "flag.checkered"),
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
            let name = a.title.components(separatedBy: " ").prefix(a.title.hasPrefix("أبو ") || a.title.hasPrefix("أم ") ? 2 : 1).joined(separator: " ")
            let memberId = a.memberId
            if let pos {
                /* «اتجه له»: road route to where their help request is (preview first). */
                primary = action("اتجه له", .default) { c in c.startPlace(pos, label: name, memberId: memberId) }
            } else {
                primary = action("تمام", .default) { _ in }
            }
            if let phone = a.phone {
                secondary = action("اتصال", .default) { c in c.call(phone) }
            } else if let pos {
                secondary = action("أظهره", .cancel) { c in c.mapVC.center(on: pos) }
            } else {
                secondary = action("تمام", .cancel) { _ in }
            }
        case .talking:
            primary = action("وقّف", .default) { c in c.session?.voiceNotes.carPlayStopPlaying() }
            secondary = action("تمام", .cancel) { _ in }
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
            case .talking: return UIImage(systemName: "waveform.circle.fill")?.withTintColor(.systemTeal, renderingMode: .alwaysOriginal)
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

    // MARK: walkie-talkie («اضغط وسجّل»)

    private func talkPressed() {
        guard let s = session else { return }
        s.voiceNotes.carPlayTalkTapped()
        buttonKey = ""
        refresh()
    }

    /// While recording: a big card «تكلّم… نسجّل» with «أرسل» / «احذف».
    private func updateRecording(_ s: OutingSession) {
        let rec = s.voiceNotes.carPlayRecording
        guard rec != recordingAlertUp else { return }
        recordingAlertUp = rec
        if rec {
            let send = CPAlertAction(title: "أرسل", style: .default) { [weak self] _ in
                MainActor.assumeIsolated { self?.recordingAlertUp = false; self?.shownAlert = nil; self?.talkPressed() }
            }
            let drop = CPAlertAction(title: "احذف", style: .destructive) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.recordingAlertUp = false
                    self?.shownAlert = nil
                    self?.session?.voiceNotes.carPlayCancelRecording()
                    self?.buttonKey = ""
                    self?.refresh()
                }
            }
            present(CPNavigationAlert(titleVariants: ["تكلّم… نسجّل"], subtitleVariants: ["للطلعة كلها · دقيقة بالأكثر"],
                                      image: UIImage(systemName: "mic.circle.fill")?.withTintColor(.systemRed, renderingMode: .alwaysOriginal),
                                      primaryAction: send, secondaryAction: drop, duration: 0), id: "arrived:recording")
        } else if shownAlert?.id == "arrived:recording" {
            replacingAlert = true
            mapTemplate.dismissNavigationAlert(animated: true) { [weak self] _ in MainActor.assumeIsolated { self?.replacingAlert = false } }
            shownAlert = nil
        }
        buttonKey = ""
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
        if args.contains("-SaryCarPlayTalk"), i.talking == nil, let f = friends.first {
            i.talking = CarPlayTalking(noteId: "debug-talk", userId: f.user_id, name: f.display_name)
        }
        i.view = v
    }

    /// `-SaryCarPlayShow members|trips|dest|search|place|talk|wayback|rally|destination|sos|pan` after the map is up.
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
            case "dest": self.showTrips()
            case "search": self.showTrips(); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showSearch() }
            case "talk": self.talkPressed()
            case "place":
                /* A road trip in Riyadh (King Fahd Rd → Kingdom Centre area): preview, then guidance. */
                self.startPlace(LngLat(lng: 46.6753, lat: 24.7114), label: "برج المملكة", memberId: nil)
                if args.contains("-SaryCarPlayGo") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                        if let t = self.previewTrip, let c = t.routeChoices.first { self.previewStarted(t, choice: c) }
                    }
                }
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

    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, startedTrip trip: CPTrip, using routeChoice: CPRouteChoice) {
        MainActor.assumeIsolated { previewStarted(trip, choice: routeChoice) }
    }

    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, selectedPreviewFor trip: CPTrip, using routeChoice: CPRouteChoice) {
        MainActor.assumeIsolated {
            previewRouteId = routeChoice.userInfo as? String
            refresh()
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

extension CarPlayCoordinator: CPSearchTemplateDelegate {
    nonisolated func searchTemplate(_ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String, completionHandler: @escaping ([CPListItem]) -> Void) {
        MainActor.assumeIsolated { search(searchText, completion: completionHandler) }
    }

    nonisolated func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem, completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated { searchPicked(item) }
        completionHandler()
    }
}
