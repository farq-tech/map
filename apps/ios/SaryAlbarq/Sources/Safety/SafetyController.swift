import Combine
import Foundation

/// The safety pack for one open outing: «مؤقت الرجوع», «غرّزت» and the sunset /
/// way-back warning. Owns their state, talks to `SafetyBackend` (nil = demo, all
/// local), schedules the reminders and feeds cards into the live alert lane
/// through the hooks the live controller sets. Views read it; they hold no logic.
@MainActor
final class SafetyController: ObservableObject {
    let outingId: String
    let myId: String
    private let backend: SafetyBackend?
    private let scheduler: ReminderScheduling
    private let defaults: UserDefaults
    /// Injectable clock (tests).
    var now: () -> Date = Date.init

    // MARK: return timer
    @Published private(set) var timer: ReturnTimerWire?
    @Published private(set) var timerAvailability: SafetyAvailability = .unknown
    @Published private(set) var timerLoadError: String?
    @Published private(set) var watchURL: URL?
    @Published private(set) var timerBusy = false
    @Published private(set) var remindersAllowed = true
    @Published var editorOpen = false
    /// «تأخرت عن وقت الرجوع» — «وصلت / مدّد».
    @Published var overduePrompt = false
    /// The message (+ link) for the share sheet.
    @Published var shareText: String?

    // MARK: stuck
    @Published private(set) var stuck: [String: StuckReport] = [:]
    @Published private(set) var stuckAvailability: SafetyAvailability = .unknown
    @Published private(set) var stuckBusy = false
    @Published var confirmStuck = false
    @Published private(set) var replyBusy: Set<String> = []

    // MARK: sunset & way back
    @Published private(set) var sunset: Date?
    @Published private(set) var wayBackS: TimeInterval?
    private(set) var speed = MovingSpeed()
    private var warnedSteps: Set<Int> = []
    private var warnedKey: String?
    private var sunsetComputed: (at: Date, lat: Double, lng: Double)?

    @Published var errorText: String?

    // MARK: hooks (set by the live controller)
    var view: () -> OutingView? = { nil }
    var myFix: () -> DeviceFix? = { nil }
    var mapBearing: () -> Double = { 0 }
    /// Metres back to the start along my trail (nil: no trail on this phone).
    var wayBackDistanceM: () -> Double? = { nil }
    var isSharingNow: () -> Bool = { false }
    /// Insert, or update in place, a card in the alert lane.
    var upsertAlert: (LiveAlertUI, TimeInterval) -> Void = { _, _ in }
    var removeAlert: (String) -> Void = { _ in }
    var toast: (String) -> Void = { _ in }
    /// Said aloud (the nav voice: «صوت سرى» clips or the device voice), for warnings that matter while driving.
    var speak: (NavLine) -> Void = { _ in }
    /// «اطلب إنجاد» (wired by the live screen).
    var openEnjad: (Enjad.Situation) -> Void = { _ in }

    private var bag = Set<AnyCancellable>()
    /// Subscriptions the live controller hangs on this object (released with it).
    var retained = Set<AnyCancellable>()
    private var tickTimer: Timer?
    private var lastServerNow: String?
    private var promptedDue: String?

    static let warnedStoreKey = "sary.safety.sunsetWarned.v1"

    /// `seedsDemo`: the `-demo` outing's screenshot states (`-SarySafety`) may be seeded. nil = as before
    /// (any local pack, `backend == nil`); a solo outing passes false: local, but never demo data.
    init(outingId: String, myId: String, backend: SafetyBackend?, seedsDemo: Bool? = nil, scheduler: ReminderScheduling = LocalReminderScheduler(), defaults: UserDefaults = .standard) {
        self.outingId = outingId
        self.myId = myId
        self.backend = backend
        self.seedsDemo = seedsDemo ?? (backend == nil)
        self.scheduler = scheduler
        self.defaults = defaults
        watchURL = WatchLinkStore.load(outingId, defaults: defaults)
        if backend == nil { timerAvailability = .available; stuckAvailability = .available }
    }

    /// No server behind the safety pack (the demo, a solo outing): timers and «غرّزت» stay on this phone.
    var isLocal: Bool { backend == nil }
    /// The demo outing's seeded states are allowed (never in a solo outing, docs/SOLO-OUTING.md).
    let seedsDemo: Bool

    /// Wire to the open session: its view changes, its safety events, my GPS, and a 15 s tick.
    func bind(events: AnyPublisher<SafetyEvent, Never>, viewChanged: AnyPublisher<Void, Never>, locationChanged: AnyPublisher<Void, Never>, timers: Bool = true) {
        events.receive(on: DispatchQueue.main).sink { [weak self] e in self?.handle(e) }.store(in: &bag)
        viewChanged.receive(on: DispatchQueue.main).sink { [weak self] in self?.syncView() }.store(in: &bag)
        locationChanged.receive(on: DispatchQueue.main).sink { [weak self] in self?.locationChanged() }.store(in: &bag)
        if timers {
            tickTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
        Task { await load() }
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        bag = []
        retained = []
    }

    // MARK: derived

    var timerPhase: ReturnTimerPhase { ReturnTimerLogic.phase(timer, availability: timerAvailability, now: now()) }
    var myStuck: StuckReport? { stuck[myId] }
    func isStuck(_ uid: String) -> Bool { stuck[uid] != nil }
    var friendsStuck: [StuckReport] { stuck.values.filter { $0.userId != myId }.sorted { $0.at > $1.at } }

    func name(_ uid: String) -> String? { view()?.members[uid]?.display_name }
    func color(_ uid: String) -> UInt32 { view()?.colors[uid] ?? 0xFFFFFF }

    /// «المغرب ٥:١٣ م · طريق العودة ٤٥ دقيقة تقريبًا».
    var sunsetLine: String? {
        guard let s = sunset, s > now().addingTimeInterval(-SunsetWarning.afterSunsetS) else { return nil }
        var t = s > now() ? "المغرب \(SafetyFormat.clock(s))" : "غابت الشمس \(SafetyFormat.clock(s))"
        if let w = wayBackS { t += " · طريق الرجعة \(SafetyFormat.span(minutes: SunsetWarning.roundUp5(w / 60))) تقريبًا" }
        return t
    }

    // MARK: return timer

    func load() async {
        if isLocal { return }
        guard let backend else { return }
        do {
            let box = try await backend.returnTimer(outingId)
            timerAvailability = .available
            timerLoadError = nil
            setTimer(box.timer, link: nil)
        } catch let e as OutingAPIError where e.isNotDeployed {
            timerAvailability = .notDeployed
        } catch let e as OutingAPIError {
            timerLoadError = e.safetyArabic
        } catch {
            timerLoadError = OutingAPIError(code: "network", status: 0).arabic
        }
        remindersAllowed = await scheduler.authorized()
    }

    /// Apply a timer from the server (or the demo), keep reminders and the overdue prompt in step.
    private func setTimer(_ t: ReturnTimerWire?, link: String?) {
        timer = t
        if let link, let u = WatchLinkStore.valid(link) {
            /* «مدّد» (same contact) keeps the contact's earlier link working; the new one is valid too. */
            watchURL = u
            WatchLinkStore.save(outingId, u, defaults: defaults)
        }
        reschedule()
        refreshTimerAlert()
    }

    private func reschedule() {
        let ids = ReturnTimerLogic.reminderIds(outingId)
        guard let t = timer, t.state == .armed, let due = ReturnTimerLogic.due(t) else {
            scheduler.replace([], removing: ids, outingId: outingId)
            return
        }
        scheduler.replace(ReturnTimerLogic.reminders(outingId: outingId, due: due, contact: t.contact_name, now: now()), removing: ids, outingId: outingId)
    }

    private func refreshTimerAlert() {
        let id = "safety:overdue:me"
        if case let .overdue(due, contact) = timerPhase {
            upsertAlert(LiveAlertUI(id: id, kind: .safety(.myTimerOverdue(contact: contact, due: due))), 3 * 3600)
            /* The prompt once per due time (a new «مدّد» time can prompt again). */
            if promptedDue != timer?.due_at {
                promptedDue = timer?.due_at
                overduePrompt = true
            }
        } else {
            removeAlert(id)
            overduePrompt = false
        }
    }

    /// «اضبط المؤقت» from the editor. Opens the share sheet with the message when it worked.
    func arm(due: Date, contact raw: String) async {
        let n = now()
        guard let contact = ReturnTimerLogic.cleanContact(raw) else { errorText = "اكتب اسم اللي يتابعك."; return }
        if ReturnTimerLogic.validate(due: due, contact: contact, now: n) != nil {
            errorText = "اختر وقتًا بعد ١٠ دقائق على الأقل، وخلال ٢٤ ساعة."
            return
        }
        guard await save(due: due, contact: contact) else { return }
        editorOpen = false
        offerShare()
    }

    /// «مدّد ٣٠ دقيقة / ساعة».
    func extend(minutes: Int) async {
        guard let t = timer, let due = ReturnTimerLogic.due(t) else { return }
        let next = ReturnTimerLogic.extended(due: due, byMinutes: minutes, now: now())
        if await save(due: next, contact: t.contact_name) {
            toast("مدّدنا وقت رجوعك إلى \(SafetyFormat.dueLabel(next, now: now())) · الرابط اللي عند \(t.contact_name) يبقى شغال")
        }
    }

    private func save(due: Date, contact: String) async -> Bool {
        timerBusy = true
        defer { timerBusy = false }
        guard let backend else {
            setTimer(ReturnTimerWire(id: "demo", due_at: ISODate.string(due), contact_name: contact, state: .armed), link: nil)
            return true
        }
        do {
            let box = try await backend.setReturnTimer(outingId, dueAt: due, contactName: contact)
            timerAvailability = .available
            setTimer(box.timer ?? ReturnTimerWire(id: "", due_at: ISODate.string(due), contact_name: contact, state: .armed), link: box.watch_url)
            return true
        } catch let e as OutingAPIError where e.isNotDeployed {
            timerAvailability = .notDeployed
            editorOpen = false
            toast("مؤقت الرجوع غير متاح بعد")
        } catch let e as OutingAPIError {
            errorText = e.safetyArabic
        } catch {
            errorText = OutingAPIError(code: "network", status: 0).arabic
        }
        return false
    }

    func offerShare() {
        guard let t = timer, let due = ReturnTimerLogic.due(t) else { return }
        shareText = ReturnTimerLogic.shareMessage(contact: t.contact_name, outingName: view()?.snapshot.outing.name ?? "طلعة", due: due, url: watchURL, now: now())
    }

    /// «وصلت».
    func arrived() async {
        guard let t = timer else { return }
        timerBusy = true
        defer { timerBusy = false }
        do {
            var next = t
            next.state = .arrived
            if let backend {
                let box = try await backend.returnTimerArrived(outingId)
                next = box.timer ?? next
            }
            forgetLink()
            setTimer(next, link: nil)
            toast("الحمد لله على السلامة. وصل الخبر لـ\(t.contact_name)")
        } catch let e as OutingAPIError where e.code == "no_timer" {
            forgetLink()
            setTimer(nil, link: nil)
        } catch let e as OutingAPIError where e.isNotDeployed {
            timerAvailability = .notDeployed
        } catch let e as OutingAPIError {
            errorText = e.safetyArabic
        } catch {
            errorText = OutingAPIError(code: "network", status: 0).arabic
        }
    }

    /// «ألغِ المؤقت»: the link then shows «أُلغي».
    func cancelTimer() async {
        timerBusy = true
        defer { timerBusy = false }
        do {
            try await backend?.cancelReturnTimer(outingId)
            forgetLink()
            setTimer(nil, link: nil)
            toast("ألغينا مؤقت الرجوع")
        } catch let e as OutingAPIError where e.code == "no_timer" {
            forgetLink()
            setTimer(nil, link: nil)
        } catch let e as OutingAPIError where e.isNotDeployed {
            timerAvailability = .notDeployed
        } catch let e as OutingAPIError {
            errorText = e.safetyArabic
        } catch {
            errorText = OutingAPIError(code: "network", status: 0).arabic
        }
    }

    private func forgetLink() {
        watchURL = nil
        WatchLinkStore.save(outingId, nil, defaults: defaults)
    }

    // MARK: stuck

    /// The cluster / sheet «غرّزت»: ask first (a tap, not a hold).
    func askStuck() {
        if stuckAvailability == .notDeployed { toast("«غرّزت» غير متاح بعد"); return }
        confirmStuck = true
    }

    func reportStuck(note: String? = nil) async {
        confirmStuck = false
        let clean = note.flatMap(StuckLogic.cleanNote)
        stuckBusy = true
        defer { stuckBusy = false }
        do {
            try await backend?.reportStuck(outingId, note: clean)
            stuckAvailability = .available
            stuck[myId] = StuckReport(userId: myId, at: now(), note: clean)
            toast(isSharingNow() ? "وصل للأصدقاء إنك غرّزت، ويشوفون مكانك" : "وصل للأصدقاء إنك غرّزت · موقعك غير مُشارَك")
        } catch let e as OutingAPIError where e.isNotDeployed {
            stuckAvailability = .notDeployed
            toast("«غرّزت» غير متاح بعد")
        } catch let e as OutingAPIError {
            errorText = e.safetyArabic
        } catch {
            errorText = OutingAPIError(code: "network", status: 0).arabic
        }
    }

    /// «طلعت».
    func clearStuck() async {
        stuckBusy = true
        defer { stuckBusy = false }
        do {
            try await backend?.clearStuck(outingId)
            stuck[myId] = nil
            toast("الحمد لله، طلعت")
        } catch let e as OutingAPIError where e.isNotDeployed {
            stuckAvailability = .notDeployed
        } catch let e as OutingAPIError {
            errorText = e.safetyArabic
        } catch {
            errorText = OutingAPIError(code: "network", status: 0).arabic
        }
    }

    /// «جاي» / «معي حبل» / «ما أقدر» to a stuck friend.
    func reply(to uid: String, _ kind: StuckReplyKind) async {
        guard uid != myId, stuck[uid] != nil else { return }
        replyBusy.insert(uid)
        defer { replyBusy.remove(uid) }
        do {
            try await backend?.replyStuck(outingId, to: uid, kind: kind)
            stuck[uid]?.replies[myId] = kind
            refreshStuckAlerts()
            toast(kind == .coming ? "وصله إنك جاي" : "وصله ردّك")
        } catch let e as OutingAPIError where e.code == "not_stuck" {
            stuck[uid] = nil
            refreshStuckAlerts()
            toast(e.safetyArabic)
        } catch let e as OutingAPIError where e.isNotDeployed {
            stuckAvailability = .notDeployed
            toast("«غرّزت» غير متاح بعد")
        } catch let e as OutingAPIError {
            errorText = e.safetyArabic
        } catch {
            errorText = OutingAPIError(code: "network", status: 0).arabic
        }
    }

    private func position(of uid: String) -> Geo.LatLng? {
        view()?.positions[uid].map { Geo.LatLng(lat: $0.lat, lng: $0.lng) }
    }

    /// The friend card: how far and which way, from my live fix to their last real one.
    func stuckAlert(_ r: StuckReport) -> StuckAlertUI? {
        guard let v = view(), let m = v.members[r.userId], r.userId != myId else { return nil }
        var dist: Double?, bearing: Double?
        var stale = true
        if let p = position(of: r.userId) {
            stale = v.freshness(of: r.userId, deviceNow: now()) != .live
            if let me = myFix()?.coordinate {
                dist = Geo.haversineMeters(me, p)
                bearing = LiveOutingPresenter.relative(Geo.bearingDeg(me, p), mapBearing: mapBearing())
            }
        }
        var others = r
        others.replies[myId] = nil
        return StuckAlertUI(userId: r.userId, name: m.display_name, color: v.colors[r.userId] ?? 0xFFFFFF, note: r.note,
                            distanceMeters: dist, bearingDegrees: bearing, positionStale: stale, since: r.at,
                            myReply: r.replies[myId], others: others.replies.isEmpty ? nil : StuckLogic.summary(others))
    }

    private var shownStuckAlerts: Set<String> = []

    private func refreshStuckAlerts() {
        var live: Set<String> = []
        for r in friendsStuck {
            guard let ui = stuckAlert(r) else { continue }
            let id = "safety:stuck:\(r.userId)"
            live.insert(id)
            upsertAlert(LiveAlertUI(id: id, kind: .safety(.friendStuck(ui))), StuckLogic.ttl)
        }
        for id in shownStuckAlerts.subtracting(live) { removeAlert(id) }
        shownStuckAlerts = live
    }

    // MARK: inbound

    func handle(_ e: SafetyEvent) {
        let offset = view()?.clockOffsetMs ?? 0
        switch e {
        case let .returnTimer(uid, state, dueAt):
            if uid == myId {
                guard timerAvailability != .notDeployed else { return }
                timerAvailability = .available
                if state == .cancelled { forgetLink(); setTimer(nil, link: nil); return }
                var t = timer ?? ReturnTimerWire(id: "", due_at: dueAt ?? "", contact_name: "", state: state)
                t.state = state
                if let dueAt { t.due_at = dueAt }
                if state == .arrived { forgetLink() }
                setTimer(t, link: nil)
            } else {
                let id = "safety:overdue:\(uid)"
                if state == .overdue, let n = name(uid) {
                    upsertAlert(LiveAlertUI(id: id, kind: .safety(.friendTimerOverdue(name: n, color: color(uid)))), 3600)
                } else {
                    removeAlert(id)
                    if state == .arrived, let n = name(uid) { toast("\(n) ضغط «وصلت»") }
                }
            }
        case let .stuckReply(from, to, kind) where to == myId && from != myId:
            StuckLogic.apply(e, to: &stuck, clockOffsetMs: offset, now: now())
            if let n = name(from) { toast("\(n) \(kind.label)") }
        case let .stuck(uid, _, _) where uid != myId:
            StuckLogic.apply(e, to: &stuck, clockOffsetMs: offset, now: now())
            stuckAvailability = .available
            refreshStuckAlerts()
        default:
            StuckLogic.apply(e, to: &stuck, clockOffsetMs: offset, now: now())
            refreshStuckAlerts()
        }
    }

    /// A new snapshot carries the whole stuck picture (when the server sends it).
    func syncView() {
        guard let v = view() else { return }
        if v.snapshot.server_now != lastServerNow {
            lastServerNow = v.snapshot.server_now
            if let wire = v.snapshot.stuck {
                let snapshot = StuckLogic.fromSnapshot(wire, clockOffsetMs: v.clockOffsetMs, now: now())
                if stuck != snapshot { stuck = snapshot }
                stuckAvailability = .available
            }
        }
        if v.status == .ended {
            if !stuck.isEmpty { stuck = [:] }
        } else {
            var pruned = stuck
            StuckLogic.prune(&pruned, members: Set(v.members.keys), now: now())
            if pruned != stuck { stuck = pruned }
        }
        refreshStuckAlerts()
    }

    func locationChanged() {
        if let f = myFix() { speed.add(speed: f.speed, accuracy: f.accuracy, atMs: f.atMs) }
        updateSunset()
        refreshStuckAlerts()
    }

    /// Every 15 s: overdue by the clock, expired reports, the sunset check.
    func tick() {
        if let t = timer, t.state == .armed { refreshTimerAlert() }
        if let v = view() {
            var pruned = stuck
            StuckLogic.prune(&pruned, members: Set(v.members.keys), now: now())
            if pruned != stuck {
                stuck = pruned
                refreshStuckAlerts()
            }
        }
        updateSunset()
    }

    // MARK: sunset & way back

    func updateSunset() {
        let n = now()
        guard let f = myFix() else { return }
        speed.prune(nowS: n.timeIntervalSince1970)
        /* Sunset moves a minute a day and ~4 min per degree: recompute every 10 min or 20 km. */
        if let c = sunsetComputed, n.timeIntervalSince(c.at) < 600, abs(c.lat - f.lat) < 0.2, abs(c.lng - f.lng) < 0.2 {} else {
            sunset = SunTimes.sunset(near: n, lat: f.lat, lng: f.lng)
            sunsetComputed = (n, f.lat, f.lng)
        }
        wayBackS = WayBack.seconds(remainingM: wayBackDistanceM(), averageMps: speed.average(nowMs: n.timeIntervalSince1970 * 1000))
        guard view()?.status == .active, let s = sunset else { return }
        loadWarned(for: s)
        if let w = SunsetWarning.evaluate(now: n, sunset: s, wayBackS: wayBackS, warned: warnedSteps) {
            warnedSteps.insert(w.step)
            saveWarned()
            upsertAlert(LiveAlertUI(id: "safety:sunset", kind: .safety(.sunset(title: w.title, detail: w.detail))), 120)
            if let way = wayBackS {
                speak(NavLine("\(w.title). \(w.detail)", clips: SunsetWarning.saryClips(toSunsetS: s.timeIntervalSince(n), wayBackS: way), safety: true))
            }
        }
    }

    /// Steps already warned, per outing and per sunset (so a relaunch does not repeat them).
    private func loadWarned(for sunset: Date) {
        let key = "\(outingId)|\(Int(sunset.timeIntervalSince1970 / 3600))"
        guard key != warnedKey else { return }
        warnedKey = key
        let all = defaults.dictionary(forKey: Self.warnedStoreKey) as? [String: [Int]] ?? [:]
        warnedSteps = Set(all[key] ?? [])
    }

    private func saveWarned() {
        guard let warnedKey else { return }
        var all = defaults.dictionary(forKey: Self.warnedStoreKey) as? [String: [Int]] ?? [:]
        /* Only this sunset's steps for this outing; older ones are dropped. */
        all = all.filter { !$0.key.hasPrefix("\(outingId)|") }
        all[warnedKey] = Array(warnedSteps).sorted()
        if all.count > 20 { all = [warnedKey: all[warnedKey] ?? []] }
        defaults.set(all, forKey: Self.warnedStoreKey)
    }

    // MARK: alert lane actions

    var alertActions: SafetyAlertActions {
        SafetyAlertActions(
            reply: { [weak self] uid, k in Task { await self?.reply(to: uid, k) } },
            arrived: { [weak self] in Task { await self?.arrived() } },
            extend: { [weak self] m in Task { await self?.extend(minutes: m) } }
        )
    }

    #if DEBUG
    /// Screenshot / UI-test states on the demo outing (`-SarySafety <state>`).
    func seedDemo(_ state: String) {
        guard seedsDemo else { return }
        let n = now()
        let friend = "00000000-0000-4000-8000-000000000003"
        let other = "00000000-0000-4000-8000-000000000002"
        switch state {
        case "timer":
            setTimer(ReturnTimerWire(id: "demo", due_at: ISODate.string(n.addingTimeInterval(100 * 60)), contact_name: "أم فهد", state: .armed), link: nil)
        case "overdue":
            setTimer(ReturnTimerWire(id: "demo", due_at: ISODate.string(n.addingTimeInterval(-12 * 60)), contact_name: "أم فهد", state: .overdue), link: nil)
        case "stuck-me":
            stuck[myId] = StuckReport(userId: myId, at: n.addingTimeInterval(-240), note: nil,
                                      replies: [other: .coming, friend: .have_rope, "00000000-0000-4000-8000-000000000004": .cant])
        case "stuck-friend":
            stuck[friend] = StuckReport(userId: friend, at: n.addingTimeInterval(-90), note: "غرّزت في طعس", replies: [other: .coming])
            refreshStuckAlerts()
        case "sunset":
            let s = n.addingTimeInterval(62 * 60)
            sunset = s
            wayBackS = 47 * 60
            if let w = SunsetWarning.evaluate(now: n, sunset: s, wayBackS: wayBackS, warned: []) {
                upsertAlert(LiveAlertUI(id: "safety:sunset", kind: .safety(.sunset(title: w.title, detail: w.detail))), 3600)
            }
        case "unavailable":
            timerAvailability = .notDeployed
            stuckAvailability = .notDeployed
        case "confirm-stuck":
            confirmStuck = true
        case "editor":
            editorOpen = true
        default: break
        }
    }
    #endif
}

/// Buttons on the safety cards in the alert lane (passed down by environment, so the
/// shared alert lane keeps its signature).
struct SafetyAlertActions {
    var reply: (_ userId: String, _ kind: StuckReplyKind) -> Void = { _, _ in }
    var arrived: () -> Void = {}
    var extend: (_ minutes: Int) -> Void = { _ in }
}
