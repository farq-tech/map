import Combine
import SwiftUI
import UIKit

/// Screen points the map reports (cars, flag) — kept apart from the main
/// controller so 30 Hz camera updates only redraw the edge-arrow layer.
@MainActor
final class MapOverlayModel: ObservableObject {
    @Published var projection = MapProjection(points: [:], rally: nil, bearing: 0, size: .zero)
}

/// Which modal is up over the live sheet.
enum LiveModal: Identifiable, Equatable {
    case participant(String)
    case note
    case stations
    case consent
    case rallyLabel(LngLat, moving: Bool)
    /// Our explainer before the notification permission prompt.
    case notify
    /// «احفظ الخريطة بلا إنترنت» for this outing's area.
    case offlineMaps
    /// The weather sheet (area, destination, wadis, NCM link).
    case weather
    /// «الطقس هنا» for a picked / searched point.
    case weatherAt(OutingDestination)
    /// Our explainer before asking iOS for «دائمًا» (the screen-locked trail).
    case trailAlways
    /// «تخطيط الطلعة»: point card, my coordinates, search, the plan editor.
    case plan(LivePlanModal)

    var id: String {
        switch self {
        case let .participant(id): return "p:\(id)"
        case .note: return "note"
        case .stations: return "stations"
        case .consent: return "consent"
        case .rallyLabel: return "rally"
        case .notify: return "notify"
        case .offlineMaps: return "offline"
        case .weather: return "weather"
        case let .weatherAt(p): return "weather:\(p.lat),\(p.lng)"
        case .trailAlways: return "trailAlways"
        case let .plan(m): return m.id
        }
    }
}

/// The wiring layer for the live outing: owns the screen's local state, feeds
/// `LiveOutingPresenter` with the session's real data, and turns the contract's
/// actions into session/API calls. Views stay free of logic.
@MainActor
final class LiveOutingController: ObservableObject {
    let session: OutingSession
    let location: LocationSharer
    let appearance: AppearanceSettings
    let overlay = MapOverlayModel()
    /// Return timer, «غرّزت», sunset & way back (`Sources/Safety`).
    let safety: SafetyController
    /// Shared waypoints and convoy mode (contract §3, §4).
    let features: OutingFeaturesModel
    /// Weather, wind, dust, rain and wadi floods (Sources/Weather).
    let weather: OutingWeather
    /// «تخطيط الطلعة» for this outing (set by the host; the weather reads destination + route).
    weak var planModel: PlanModel?
    var onExit: () -> Void = {}
    /// «حفظ» my number (wired to the profile endpoint by the host).
    var savePhone: (String?) -> Void = { _ in }
    /// The in-app notifications switch (registers / unregisters this device for push).
    var setPush: (Bool) -> Void = { _ in }
    /// The notification explainer was already shown on this device.
    var pushExplained: () -> Bool = { true }

    @Published var sheetDetent: SheetDetentUI = .peek
    @Published var selectedTab: LiveTabUI = .participants
    @Published var alerts: [LiveAlertUI] = []
    @Published var ptt: PTTStateUI = .idle
    @Published var acknowledgedSOS: Set<String> = []
    @Published var heardClips: Set<String> = []
    @Published var clipPlayback: [String: VoicePlaybackUI] = [:]
    @Published var camera: MapCameraRequest?
    @Published var following = false
    @Published var picking: (moving: Bool, active: Bool) = (false, false)
    @Published var modal: LiveModal?
    @Published var inviteLink: String?
    @Published var isRevoking = false
    @Published var statusExpanded = false
    @Published var confirm: LiveConfirm?
    @Published var stations: LoadPhaseUI<[StationUI]> = .loading
    @Published var toastText: String?
    @Published var notificationsOn: Bool {
        didSet { UserDefaults.standard.set(notificationsOn, forKey: "sary.outings.notify.v1") }
    }
    @Published var shareItem: URL?
    /// «طريق العودة»: a frozen copy of my trail being retraced (nil when off).
    @Published private(set) var backTrack: BackTrack?
    @Published private(set) var backTrackStatus: BackTrackStatus?
    /// «أظهر مسارات الأصحاب» (this device).
    @Published var showFriendTrails: Bool {
        didSet { UserDefaults.standard.set(showFriendTrails, forKey: TrailPrefs.friendsKey) }
    }
    /// Friends' last ~30 minutes, from the positions this phone already receives. Memory only.
    private(set) var friendTrails = FriendTrails()

    private var bag = Set<AnyCancellable>()
    private var lastView: OutingView?
    private var stationList: [OutdoorAPI.Station] = []
    private let recorder = VoiceRecorder()
    private let player = VoicePlayer()
    private var pttTimer: Timer?
    private var alertTimers: [String: Timer] = [:]
    /// Last note shown per member, so a note heard nearby and then from the server alerts once.
    private var alertedNotes: [String: (text: String, at: Date)] = [:]

    init(session: OutingSession, location: LocationSharer, appearance: AppearanceSettings, featuresBackend: OutingFeaturesBackend? = nil) {
        self.session = session
        self.location = location
        self.appearance = appearance
        safety = Self.makeSafety(for: session)
        features = OutingFeaturesModel(session: session, backend: featuresBackend ?? DemoFeaturesBackend(myId: session.myUserId, notDeployed: true))
        notificationsOn = UserDefaults.standard.object(forKey: "sary.outings.notify.v1") as? Bool ?? true
        showFriendTrails = TrailPrefs.friends()
        inviteLink = session.storedInviteURL()?.absoluteString
        weather = OutingWeather(outingId: session.id, tracksMap: true)
        weather.onAlert = { [weak self] a in self?.pushAlert(LiveAlertUI(id: a.id, kind: .weather(a)), ttl: 45) }
        #if DEBUG
        /* Screenshots: `-SaryLiveSheet half|full`, `-SaryLiveModal weather`. */
        let shotArgs = ProcessInfo.processInfo.arguments
        func arg(_ k: String) -> String? { shotArgs.firstIndex(of: k).flatMap { $0 + 1 < shotArgs.count ? shotArgs[$0 + 1] : nil } }
        if let d = arg("-SaryLiveSheet") { sheetDetent = d == "full" ? .full : d == "half" ? .half : .peek }
        if arg("-SaryLiveModal") == "weather" { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.modal = .weather } }
        #endif
        session.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.sessionChanged() }
        }.store(in: &bag)
        location.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.locationChanged() }
        }.store(in: &bag)
        player.onProgress = { [weak self] id, p in self?.setPlayback(id, .playing(progress: p)) }
        player.onFinish = { [weak self] id in self?.setPlayback(id, .idle) }
        lastView = session.displayView
        features.pushAlert = { [weak self] a, ttl in self?.pushAlert(a, ttl: ttl) }
        features.dismissAlert = { [weak self] id in self?.dismissAlert(id) }
        features.toast = { [weak self] t in self?.toast(t) }
        features.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }.store(in: &bag)
        features.start()
        #if DEBUG
        if session.isDemo, ProcessInfo.processInfo.arguments.contains("-demoTrail") { seedDemoTrails() }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-SaryBackTrack") {
            let delay = i + 1 < args.count ? Double(args[i + 1]) ?? 2.5 : 2.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.startBackTrack() }
        }
        #endif
        if let v = session.displayView { ingestFriends(v) }
        attachSafety()
        /* The point card's «أضف نقطة» (the single map long-press) opens the shared-waypoint
           composer; after the card's sheet has gone, so the two sheets never race. */
        /* «الطقس هنا» on the point card. */
        PointActions.weatherHook = { [weak self] p in
            guard let self else { return }
            self.modal = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                self?.showWeather(at: OutingDestination(name: "هذه النقطة", lat: p.lat, lng: p.lng))
            }
        }
        PointActions.addWaypointHook = { [weak self] outingId, p in
            guard let self, outingId == self.session.id else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.features.compose(at: p) }
        }
        session.onNearbyEvent = { [weak self] e in self?.nearbyEvent(e) }
    }

    /// «غرّزت» heard phone to phone (SOS and notes show through the merged picture).
    private func nearbyEvent(_ e: MeshEvent) {
        guard e.k == .stuck, let v = session.displayView, let m = v.members[e.u] else { return }
        let text = ["غرّز", e.text].compactMap { $0 }.joined(separator: " · ") + " · عبر الأجهزة القريبة"
        pushAlert(LiveAlertUI(id: "stuck:\(e.id)", kind: .note(senderName: m.display_name, senderColor: v.colors[e.u] ?? 0xFFFFFF, text: text)), ttl: 60)
    }

    // MARK: state

    var input: LivePresenterInput {
        let nearby = session.meshOverlay
        return LivePresenterInput(
            view: nearby.view,
            myFix: location.lastFix,
            gpsState: location.gpsState,
            locationAuthorized: location.canLocate,
            link: session.link,
            closed: session.closedReason,
            wantsToShare: session.wantsToShare,
            isSharingNow: session.isSharingNow,
            sosSending: session.sosSending,
            acknowledgedSOS: acknowledgedSOS,
            alerts: alerts,
            ptt: ptt,
            sheetDetent: sheetDetent,
            selectedTab: selectedTab,
            inviteLink: inviteLink,
            isRevoking: isRevoking,
            driveMode: appearance.prefs.driveMode.ui,
            nightMode: appearance.prefs.nightMode.ui,
            notificationsOn: notificationsOn,
            batterySharing: session.batterySharing,
            heardClips: heardClips,
            mapBearing: overlay.projection.bearing,
            now: Date(),
            nearbyVia: nearby.viaNearby,
            nearbyCars: session.mesh.running ? session.mesh.nearbyCars : 0
        )
    }

    var ui: LiveOutingUIState { LiveOutingPresenter.state(input) }

    /// The outing's area for offline maps: every car (and the rally point), padded to a few km.
    var offlineSuggestion: OfflinePlan.Box? {
        var pts = mapMembers(theme: .default).map(\.position)
        if let r = rallyPoint { pts.append(r.position) }
        guard let first = pts.first else { return nil }
        var b = OfflinePlan.Box(west: first.lng, south: first.lat, east: first.lng, north: first.lat)
        for p in pts { b.west = min(b.west, p.lng); b.east = max(b.east, p.lng); b.south = min(b.south, p.lat); b.north = max(b.north, p.lat) }
        let pad = 0.03
        return OfflinePlan.Box(west: b.west - pad, south: b.south - pad, east: b.east + pad, north: b.north + pad)
    }

    func mapMembers(theme: SaryTheme) -> [MapMember] {
        let i = input
        let parts = Dictionary(LiveOutingPresenter.participants(i).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let showNames = theme.nameDisplay == .always
        return LiveOutingPresenter.mapMembers(i, hideNotes: theme.drive).map { m in
            var m = m
            let p = parts[m.id]
            let presence: ParticipantPresence = m.presence == .live ? .live : .stale(since: Date(timeIntervalSince1970: m.atMs / 1000))
            /* Ages tick in whole minutes on the chip; quantised so the annotation is not rebuilt every second. */
            let chipNow = Date(timeIntervalSince1970: (i.now.timeIntervalSince1970 / 30).rounded(.down) * 30)
            let convoyRole = features.convoyRole(m.id)
            if showNames || m.isMe || convoyRole != nil {
                m.chip = NameChipUI(name: m.name, color: m.color, isMe: m.isMe, presence: presence, hasVoice: p?.hasVoice ?? false, now: chipNow,
                                    stuck: safety.isStuck(m.id), convoy: convoyRole.map(ConvoyBadgeUI.init), viaNearby: m.viaNearby)
            }
            if let n = m.note { m.bubble = NoteBubbleUI(text: n, color: m.color) }
            return m
        }
    }

    var rallyPoint: MapRallyPoint? {
        guard let r = session.view?.snapshot.outing.rally else { return nil }
        return MapRallyPoint(position: LngLat(lng: r.lng, lat: r.lat), label: r.label ?? "")
    }

    private func sessionChanged() {
        /* The server's picture with nearby cars' news laid over it. */
        guard let v = session.displayView else { return }
        ingestFriends(v)
        defer { lastView = v }
        guard let prev = lastView else { return }
        /* New notes from friends and new clips become cards in the alert lane. The
           same note heard first from a nearby car and then from the server is one card. */
        for (uid, m) in v.members where uid != v.myId {
            if let n = m.note, prev.members[uid]?.note != n, LiveOutingPresenter.activeNote(n, view: v, now: Date()) != nil {
                if let last = alertedNotes[uid], last.text == n.text, Date().timeIntervalSince(last.at) < LiveOutingPresenter.noteTTL { continue }
                alertedNotes[uid] = (n.text, Date())
                pushAlert(LiveAlertUI(id: "note:\(uid):\(n.at)", kind: .note(senderName: m.display_name, senderColor: v.colors[uid] ?? 0xFFFFFF, text: n.text)), ttl: 20)
            }
        }
        for c in v.clips where c.user_id != v.myId && !prev.clips.contains(where: { $0.id == c.id }) {
            let name = v.members[c.user_id]?.display_name ?? ""
            pushAlert(LiveAlertUI(id: "voice:\(c.id)", kind: .voice(VoiceClipUI(id: c.id, senderName: name, senderColor: v.colors[c.user_id] ?? 0xFFFFFF,
                                                                                durationSeconds: max(1, Int((Double(c.duration_ms) / 1000).rounded())), playback: .idle))), ttl: 60)
        }
        /* A friend cleared their SOS: forget we acknowledged it. */
        acknowledgedSOS = acknowledgedSOS.filter { key in v.members.contains { $0.key == key.split(separator: "|").first.map(String.init) && $0.value.sos != nil } }
        updateAuto()
        checkConvoy()
        feedWeather()
        if session.closedReason != nil, modal != nil { modal = nil }
        objectWillChange.send()
    }

    private func locationChanged() {
        updateBackTrack()
        updateAuto()
        checkConvoy()
        feedWeather()
        objectWillChange.send()
    }

    /// Feed the automatic drive / night modes from the real fix.
    private func updateAuto() {
        guard let f = location.lastFix else { return }
        let drive = (f.speed ?? 0) > 7
        if appearance.autoDrive != drive { appearance.autoDrive = drive }
        let night = SunLight.preset(Date(), lat: f.lat, lng: f.lng) == .night
        if appearance.autoNight != night { appearance.autoNight = night }
    }

    /// Convoy alerts from the cars drawn right now (live ones only; see `OutingFeaturesModel.liveCars`).
    private func checkConvoy() {
        guard session.view?.convoy?.isOn == true else { return features.evaluateConvoy(members: []) }
        features.evaluateConvoy(members: LiveOutingPresenter.mapMembers(input, hideNotes: true))
    }

    /// Waypoints for the map.
    var mapWaypoints: [MapWaypoint] {
        features.waypoints.map { MapWaypoint(id: $0.id, position: $0.position, kind: $0.kind, title: $0.title) }
    }

    // MARK: «مساري» / «طريق العودة» / friends' trails

    private func ingestFriends(_ v: OutingView) {
        for (uid, p) in v.positions where uid != v.myId {
            guard let d = LiveOutingPresenter.deviceDate(p.recorded_at, view: v) else { continue }
            friendTrails.ingest(uid, lat: p.lat, lng: p.lng, atMs: d.timeIntervalSince1970 * 1000, accuracy: p.accuracy)
        }
        friendTrails.prune(nowMs: Date().timeIntervalSince1970 * 1000, keep: Set(v.positions.keys))
    }

    var myTrailColor: UInt32 {
        guard let v = session.view else { return Vehicle.mySpotHex }
        return v.colors[v.myId] ?? Vehicle.mySpotHex
    }

    /// Everything the map draws for trails. Friends' trails end at their last real fix and fade
    /// with it: an old position never looks live.
    func mapTrails(members: [MapMember]) -> MapTrails {
        let t = session.trail
        let runs = t.runs
        var out = MapTrails()
        if t.points.count >= 2 {
            out.mine = MapTrails.Line(id: "me", color: myTrailColor, solid: runs.solid, gaps: runs.gaps)
        }
        out.start = t.start?.position
        out.highlight = backTrack != nil
        out.gapLabels = runs.gaps
            .map { (mid: LngLat(lng: ($0[0].lng + $0[1].lng) / 2, lat: ($0[0].lat + $0[1].lat) / 2), len: Vehicle.distanceMeters($0[0], $0[1])) }
            .filter { $0.len >= 150 }
            .sorted { $0.len > $1.len }
            .prefix(2).map(\.mid)
        if showFriendTrails {
            for m in members where !m.isMe {
                guard var pts = friendTrails.byId[m.id], !pts.isEmpty else { continue }
                /* The line ends exactly at the car (its last real fix), never beyond it. */
                if let last = pts.last, Vehicle.distanceMeters(last.position, m.position) > 1 {
                    pts.append(TrailPoint(lat: m.position.lat, lng: m.position.lng, t: m.atMs))
                }
                guard pts.count >= 2 else { continue }
                let r = Trail.runs(pts)
                let op: Double = m.presence == .live ? 0.6 : (m.presence == .recent ? 0.3 : 0.18)
                out.friends.append(MapTrails.Line(id: m.id, color: m.color, opacity: op, solid: r.solid, gaps: r.gaps))
            }
        }
        return out
    }

    var trailCard: TrailCardUIState {
        let t = session.trail
        var startDist: Double?
        if let s = t.start, let f = location.lastFix { startDist = Vehicle.distanceMeters(s.position, LngLat(lng: f.lng, lat: f.lat)) }
        return TrailCardUIState(recordedMeters: t.recordedLengthM, pointCount: t.points.count, gapCount: t.gapCount, startDistanceMeters: startDist,
                                isRecording: session.trailRecordingAllowed, recordingOn: TrailPrefs.record(), backgroundOn: TrailPrefs.background(),
                                backgroundAllowed: session.hasAlwaysPermission, recordingInBackground: session.recordingInBackground,
                                showFriends: showFriendTrails, backTrackActive: backTrack != nil)
    }

    func startBackTrack() {
        guard let bt = BackTrack(session.trail) else {
            toast("ما فيه مسار مسجّل بعد. يبدأ التسجيل أول ما تتحرك.")
            return
        }
        backTrack = bt
        following = false
        modal = nil
        updateBackTrack()
        var pts = bt.path.map(\.position)
        if let f = location.lastFix { pts.append(LngLat(lng: f.lng, lat: f.lat)) }
        lowerSheetThenAsk(.fit(pts))
    }

    func stopBackTrack() {
        backTrack = nil
        backTrackStatus = nil
    }

    private func updateBackTrack() {
        guard var bt = backTrack else { return }
        /* Only a recent fix: an old one would point the wrong way. */
        guard let f = location.lastFix, Date().timeIntervalSince1970 * 1000 - f.atMs < 60_000 else {
            backTrackStatus = nil
            return
        }
        let st = bt.update(LngLat(lng: f.lng, lat: f.lat))
        if bt != backTrack { backTrack = bt }
        if st.arrived && backTrackStatus?.arrived != true { toast("وصلت نقطة البداية") }
        if st != backTrackStatus { backTrackStatus = st }
    }

    var backTrackUI: BackTrackUI? {
        guard backTrack != nil else { return nil }
        guard let st = backTrackStatus else {
            return BackTrackUI(phase: .waitingFix, arrowDegrees: 0, directionLabel: "", relativeToCourse: false, onGap: false)
        }
        /* Moving with a trusted course: the arrow is relative to where the car points; otherwise to the top of the map. */
        let course = location.lastFix.flatMap { Policy.trustedHeading($0.heading, speed: $0.speed) }
        let ref = course ?? overlay.projection.bearing
        let phase: BackTrackUI.Phase = st.arrived ? .arrived : (st.offTrack ? .offTrack : .onTrail)
        return BackTrackUI(phase: phase, remainingMeters: st.remainingM, offsetMeters: st.offsetM,
                           arrowDegrees: LiveOutingPresenter.relative(st.bearing, mapBearing: ref),
                           directionLabel: Geo.directionLabel(st.bearing), relativeToCourse: course != nil, onGap: st.onGap)
    }

    func clearTrail() {
        stopBackTrack()
        session.clearTrail()
        toast("مسحنا مسارك لهذه الطلعة من جوالك")
    }

    func setTrailRecording(_ on: Bool) {
        session.setTrailRecording(on)
        if !on { stopBackTrack() }
    }

    /// «سجّل مساري والشاشة مقفلة»: on asks for «دائمًا» (after our explainer) when iOS has not allowed it yet.
    func setBackgroundTrail(_ on: Bool) {
        session.setBackgroundTrail(on)
        if on && !session.hasAlwaysPermission { modal = .trailAlways }
        objectWillChange.send()
    }

    /// After I start sharing for the first time: offer the screen-locked trail once.
    func offerAlwaysIfNeeded() {
        guard TrailPrefs.background(), !session.hasAlwaysPermission, location.canLocate,
              !UserDefaults.standard.bool(forKey: TrailPrefs.explainedKey) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.modal == nil, self.session.wantsToShare else { return }
            self.modal = .trailAlways
        }
    }

    func allowAlways() {
        UserDefaults.standard.set(true, forKey: TrailPrefs.explainedKey)
        modal = nil
        Task {
            let ok = await location.requestAlways()
            toast(ok ? "مسارك يُسجَّل حتى والشاشة مقفلة" : "الإذن «أثناء الاستخدام» فقط: يُسجَّل مسارك والتطبيق مفتوح")
            objectWillChange.send()
        }
    }

    func laterAlways() {
        UserDefaults.standard.set(true, forKey: TrailPrefs.explainedKey)
        modal = nil
    }

    func openAppSettings() {
        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
    }

    #if DEBUG
    /// Screenshots / UI tests: a trail into the demo outing with one unrecorded stretch, and friends' recent trails.
    private func seedDemoTrails() {
        session.seedDemoTrail(DemoTrail.mine(now: Date()))
        guard let v = session.view else { return }
        for (uid, p) in v.positions {
            let end = (LiveOutingPresenter.deviceDate(p.recorded_at, view: v) ?? Date()).timeIntervalSince1970 * 1000
            for q in DemoTrail.friend(to: LngLat(lng: p.lng, lat: p.lat), seed: uid, endMs: end - 5_000) {
                friendTrails.ingest(uid, lat: q.lat, lng: q.lng, atMs: q.t, accuracy: 8)
            }
        }
    }
    #endif

    // MARK: alerts

    func pushAlert(_ a: LiveAlertUI, ttl: TimeInterval) {
        alerts.removeAll { $0.id == a.id }
        alerts.insert(a, at: 0)
        if alerts.count > 6 { alerts.removeLast(alerts.count - 6) }
        alertTimers[a.id]?.invalidate()
        alertTimers[a.id] = Timer.scheduledTimer(withTimeInterval: ttl, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismissAlert(a.id) }
        }
    }

    func toast(_ text: String) {
        pushAlert(LiveAlertUI(id: "toast:\(UUID().uuidString)", kind: .toast(text)), ttl: 2.5)
    }

    func dismissAlert(_ id: String) {
        alertTimers[id]?.invalidate()
        alertTimers[id] = nil
        alerts.removeAll { $0.id == id }
    }

    private func setPlayback(_ clipId: String, _ p: VoicePlaybackUI) {
        clipPlayback[clipId] = p
        if let i = alerts.firstIndex(where: { $0.id == "voice:\(clipId)" }), case var .voice(c) = alerts[i].kind {
            c.playback = p
            alerts[i].kind = .voice(c)
        }
    }

    // MARK: camera

    private func ask(_ kind: MapCameraRequest.Kind) {
        camera = MapCameraRequest(kind: kind, id: (camera?.id ?? 0) + 1)
    }

    /// Lower the sheet, then move the camera once it has settled (the clear area changes size).
    private func lowerSheetThenAsk(_ kind: MapCameraRequest.Kind) {
        guard sheetDetent != .peek else { return ask(kind) }
        sheetDetent = .peek
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.ask(kind) }
    }

    func show(member id: String) {
        lowerSheetThenAsk(id == session.view?.myId ? .me : .withMember(id))
        following = false
    }

    // MARK: actions (the contract)

    var actions: LiveOutingActions {
        var a = LiveOutingActions()
        a.back = { [weak self] in self?.back() }
        a.warningTapped = { w in
            if w == .locationOff, let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
        }
        a.alertTapped = { [weak self] id in
            guard let self else { return }
            if self.safetyAlertTapped(id) { return }
            let parts = id.split(separator: ":").map(String.init)
            if parts.first == "note", parts.count > 1 { self.show(member: parts[1]) }
            if parts.first == "convoy", parts.count > 2 { self.show(member: parts[2]) }
            if parts.first == "convoy", parts.count == 2, let t = self.session.view?.convoy?.tail_user_id { self.show(member: t) }
            if parts.first == "waypoint", parts.count > 1 { self.features.modal = .waypoint(parts[1]) }
            if id.hasPrefix("weather") { self.modal = .weather }
        }
        a.dismissAlert = { [weak self] id in self?.dismissAlert(id) }
        a.voice = VoiceBannerActions(
            play: { [weak self] id in self?.togglePlay(id) },
            dismiss: { [weak self] id in self?.dismissAlert("voice:\(id)") }
        )
        a.locateMe = { [weak self] in
            guard let self else { return }
            if self.location.lastFix == nil { self.toast("ننتظر أول قراءة من GPS") }
            self.following = true
            self.ask(.me)
        }
        a.fitGroup = { [weak self] in
            self?.following = false
            self?.ask(.group)
        }
        a.openNoteComposer = { [weak self] in self?.modal = .note }
        a.openNearestStations = { [weak self] in self?.openStations() }
        a.sos = SOSActions(
            trigger: { [weak self] in Task { await self?.session.raiseSOS() } },
            imOK: { [weak self] in Task { await self?.session.cancelSOS() } },
            show: { [weak self] alertId in self?.showSOS(alertId) },
            call: { [weak self] alertId in
                guard let self, let uid = alertId.split(separator: "|").first.map(String.init) else { return }
                self.acknowledgedSOS.insert(alertId)
                self.dial(uid, whatsApp: false)
            }
        )
        a.ptt = PTTActions(
            pressBegan: { [weak self] in self?.pttBegan() },
            pressEnded: { [weak self] in self?.pttEnded() },
            cancelled: { [weak self] in self?.pttCancelled() }
        )
        a.setSheetDetent = { [weak self] d in self?.sheetDetent = d }
        a.selectTab = { [weak self] t in self?.selectedTab = t }
        a.participantsTab = ParticipantsTabActions(
            openParticipant: { [weak self] id in self?.openParticipant(id) },
            addMyPhone: { [weak self] in self?.selectedTab = .settings },
            rallyShow: { [weak self] in
                guard let self, let r = self.rallyPoint else { return }
                self.lowerSheetThenAsk(.point(r.position))
            },
            rallyGo: { [weak self] in
                guard let r = self?.rallyPoint else { return }
                Directions.open(lat: r.position.lat, lng: r.position.lng, name: r.label.isEmpty ? "نقطة التجمع" : r.label)
            },
            rallyMove: { [weak self] in self?.startPicking(moving: true) },
            rallyRemove: { [weak self] in Task { await self?.session.clearRally() } },
            rallyCreate: { [weak self] in self?.startPicking(moving: false) }
        )
        a.inviteTab = InviteTabActions(
            copyLink: { [weak self] in
                guard let self, let l = self.inviteLink else { return }
                UIPasteboard.general.string = l
                self.toast("تم نسخ الرابط")
            },
            shareLink: { [weak self] in
                guard let self, let l = self.inviteLink else { return }
                self.shareItem = URL(string: l)
            },
            revokeLink: { [weak self] in self?.newLink() }
        )
        a.settingsTab = SettingsTabActions(
            setSharingPaused: { [weak self] paused in self?.setSharingPaused(paused) },
            setDriveMode: { [weak self] m in self?.appearance.prefs.driveMode = SaryTriMode(m) },
            setNightMode: { [weak self] m in self?.appearance.prefs.nightMode = SaryTriMode(m) },
            saveMyPhone: { [weak self] p in self?.savePhone(p) },
            setNotifications: { [weak self] on in
                guard let self else { return }
                self.notificationsOn = on
                /* Never the system prompt directly: our explainer first, once. */
                if on && !self.pushExplained() { self.modal = .notify } else { self.setPush(on) }
            },
            setBatterySharing: { [weak self] on in self?.session.batterySharing = on },
            pauseOrResumeOuting: { [weak self] in
                guard let self, let st = self.session.view?.status else { return }
                Task { await self.session.setStatus(st == .paused ? "resume" : st == .created ? "start" : "pause") }
            },
            endOuting: { [weak self] in Task { await self?.session.setStatus("end") } },
            leaveOuting: { [weak self] in
                guard let self else { return }
                Task { if await self.session.leave() { self.onExit() } }
            }
        )
        return a
    }

    func back() {
        if session.isSharingNow { confirm = .backWhileSharing } else { onExit() }
    }

    func setSharingPaused(_ paused: Bool) {
        if paused {
            Task { await session.stopSharing() }
        } else if session.hasConsent {
            Task {
                await session.beginSharing()
                offerAlwaysIfNeeded()
            }
        } else {
            modal = .consent
        }
    }

    func acceptConsent() {
        modal = nil
        Task {
            await session.beginSharing()
            offerAlwaysIfNeeded()
        }
    }

    func startOuting() { Task { await session.setStatus("start") } }

    // MARK: participants

    func openParticipant(_ id: String) {
        if id == session.view?.myId {
            modal = .note
        } else {
            modal = .participant(id)
        }
    }

    func participantCard(_ id: String) -> ParticipantCardUIState? {
        guard let p = LiveOutingPresenter.participants(input).first(where: { $0.id == id }), let v = session.view else { return nil }
        return ParticipantCardUIState(participant: p, now: Date(), canManage: v.iOwn && !p.isMe && p.role != .leader,
                                      isBusy: session.busy.contains("member:\(id)"), errorMessage: nil)
    }

    func participantActions(_ id: String) -> ParticipantCardActions {
        ParticipantCardActions(
            call: { [weak self] in self?.dial(id, whatsApp: false) },
            whatsApp: { [weak self] in self?.dial(id, whatsApp: true) },
            showOnMap: { [weak self] in
                self?.modal = nil
                self?.show(member: id)
            },
            promoteCoLeader: { [weak self] in
                guard let self else { return }
                let on = self.session.view?.members[id]?.co_leader != true
                Task { await self.session.setCoLeader(id, on: on) }
            },
            removeMember: { [weak self] in
                guard let self else { return }
                Task {
                    await self.session.removeMember(id)
                    if self.session.view?.members[id] == nil { self.modal = nil }
                }
            },
            close: { [weak self] in self?.modal = nil }
        )
    }

    func dial(_ uid: String, whatsApp: Bool) {
        guard let phone = session.view?.members[uid]?.phone, !phone.isEmpty else { return }
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        let url = whatsApp ? URL(string: "https://wa.me/\(digits.replacingOccurrences(of: "+", with: ""))") : URL(string: "tel:\(digits)")
        if let url { UIApplication.shared.open(url) }
    }

    // MARK: SOS

    func showSOS(_ alertId: String) {
        acknowledgedSOS.insert(alertId)
        guard let uid = alertId.split(separator: "|").first.map(String.init), let v = session.displayView else { return }
        if let f = v.members[uid]?.sos?.fix, v.positions[uid] == nil {
            lowerSheetThenAsk(.point(LngLat(lng: f.lng, lat: f.lat)))
        } else {
            show(member: uid)
        }
    }

    // MARK: rally

    private func startPicking(moving: Bool) {
        sheetDetent = .peek
        picking = (moving, true)
    }

    func cancelPicking() { picking = (false, false) }

    func picked(_ p: LngLat) {
        guard picking.active else { return }
        let moving = picking.moving
        picking = (false, false)
        modal = .rallyLabel(p, moving: moving)
    }

    func saveRally(_ p: LngLat, label: String) {
        modal = nil
        let clean = ServerRules.cleanText(label, max: 40)
        Task {
            if await session.setRally(lat: p.lat, lng: p.lng, label: clean) { toast("تم تحديد نقطة التجمع") }
        }
    }

    // MARK: invite

    func newLink() {
        isRevoking = true
        Task {
            if let u = await session.newInviteURL() {
                inviteLink = u.absoluteString
                toast("رابط جديد جاهز، والقديم توقف")
            }
            isRevoking = false
        }
    }

    // MARK: stations

    func openStations() {
        modal = .stations
        loadStations()
    }

    func loadStations() {
        guard let f = location.lastFix else {
            stations = .error("ننتظر موقعك من GPS لنبحث حولك")
            return
        }
        stations = .loading
        let origin = f.coordinate
        Task {
            do {
                var got = try await OutdoorAPI.fuel(bbox: OutdoorAPI.coarseBbox(lat: origin.lat, lng: origin.lng))
                if got.count < 3 {
                    let wide = try await OutdoorAPI.fuel(bbox: OutdoorAPI.coarseBbox(lat: origin.lat, lng: origin.lng, grid: 0.25, half: 0.5))
                    let seen = Set(got.map(\.id))
                    got += wide.filter { !seen.contains($0.id) }
                }
                stationList = got
                let rows = got.map { s -> StationUI in
                    let p = Geo.LatLng(lat: s.lat, lng: s.lng)
                    return StationUI(id: s.id, name: s.name ?? s.brand ?? "محطة وقود", distanceMeters: Geo.haversineMeters(origin, p),
                                     bearingDegrees: LiveOutingPresenter.relative(Geo.bearingDeg(origin, p), mapBearing: overlay.projection.bearing),
                                     detail: s.brand.flatMap { $0 == s.name ? nil : $0 })
                }.sorted { $0.distanceMeters < $1.distanceMeters }.prefix(6)
                stations = rows.isEmpty ? .empty : .loaded(Array(rows))
            } catch {
                stations = .error("تعذّر جلب المحطات، حاول مرة ثانية")
            }
        }
    }

    var stationActions: NearestStationsActions {
        NearestStationsActions(
            go: { [weak self] id in
                guard let s = self?.stationList.first(where: { $0.id == id }) else { return }
                Directions.open(lat: s.lat, lng: s.lng, name: s.name ?? "محطة وقود")
            },
            show: { [weak self] id in
                guard let self, let s = self.stationList.first(where: { $0.id == id }) else { return }
                self.modal = nil
                self.lowerSheetThenAsk(.point(LngLat(lng: s.lng, lat: s.lat)))
            },
            retry: { [weak self] in self?.loadStations() },
            close: { [weak self] in self?.modal = nil }
        )
    }

    // MARK: push-to-talk

    private func pttBegan() {
        guard ptt == .idle else { return }
        guard session.view?.status != .ended else { return }
        ptt = .arming
        Task {
            let ok = recorder.hasPermission ? true : await recorder.requestPermission()
            guard ok else {
                ptt = .idle
                toast("اسمح بالميكروفون من الإعدادات لتستخدم «اضغط وتكلم»")
                return
            }
            /* The finger lifted while iOS asked: nothing to record, they press again. */
            guard ptt == .arming else { return }
            let started = await recorder.start()
            guard started else {
                ptt = .idle
                toast("تعذّر تشغيل الميكروفون")
                return
            }
            ptt = .recording(seconds: 0)
            pttTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, case .recording = self.ptt else { return }
                    if self.recorder.isRecording { self.ptt = .recording(seconds: self.recorder.elapsed) } else { self.pttEnded() }
                }
            }
        }
    }

    private func pttEnded() {
        pttTimer?.invalidate()
        pttTimer = nil
        if ptt == .arming { ptt = .idle; return }
        guard case .recording = ptt else { return }
        let got = recorder.stop()
        guard let clip = got else {
            ptt = .idle
            toast("اضغط مطولًا وتكلّم، ثم ارفع إصبعك")
            return
        }
        ptt = .sending
        Task {
            let sent = await session.sendClip(clip.data, durationMs: clip.durationMs)
            ptt = .idle
            if sent != nil { toast("وصل صوتك للمجموعة") }
        }
    }

    private func pttCancelled() {
        pttTimer?.invalidate()
        pttTimer = nil
        recorder.cancel()
        ptt = .idle
    }

    private func togglePlay(_ clipId: String) {
        if player.playingId == clipId { player.stop(); return }
        guard let clip = session.view?.clips.first(where: { $0.id == clipId }) else {
            toast("انتهت صلاحية هذا التسجيل")
            return
        }
        setPlayback(clipId, .loading)
        Task {
            do {
                let data = try await session.clipAudio(clip)
                heardClips.insert(clipId)
                if !player.play(data, id: clipId) { setPlayback(clipId, .idle) }
            } catch {
                setPlayback(clipId, .idle)
                toast("انتهت صلاحية هذا التسجيل")
            }
        }
    }
}

/// Destructive questions asked before acting.
enum LiveConfirm: Identifiable, Equatable {
    case backWhileSharing
    var id: Int { 0 }
}

/// Directions in Apple Maps (no third party sees the request from us).
enum Directions {
    static func open(lat: Double, lng: Double, name: String) {
        var c = URLComponents(string: "https://maps.apple.com/")!
        c.queryItems = [.init(name: "daddr", value: "\(lat),\(lng)"), .init(name: "q", value: name)]
        if let u = c.url { UIApplication.shared.open(u) }
    }
}
