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
    /// For someone who consented before sharing went background: sharing now keeps going
    /// with the screen locked; ask iOS for «دائمًا».
    case shareAlways
    /// «الملاحة»: where to, the route options, the remaining steps.
    case navPicker
    case navOptions
    case navSteps
    /// After «ابدأ الطلعة» (the leader): «ابدأ التوجيه للكل» / «لي فقط».
    case navStartChoice
    /// «+»: every less frequent action, grouped (docs/IA-REDESIGN.md §2.3).
    case actions
    /// Exploration: the layer switcher (+ 3D terrain, offline coverage).
    case layers
    /// «أماكني المحفوظة».
    case places
    /// Save a point (the crosshair / a long-pressed point) or rename / re-icon a saved one.
    case placeEdit(SavedPlaceDraft)
    /// GPX tracks (imported / exported) to show in exploration.
    case tracks
    /// «تنبيهات القافلة» rules (same screen as Settings).
    case convoyAlerts
    /// «اطلب إنجاد»: the prefilled help request (the person sends it).
    case enjad(Enjad.Situation)
    /// «المحادثات»: the conversation list, or straight into one conversation.
    case chat(ChatWith?)
    /// «ترددات»: the walkie-talkie's channels (five public + private ones).
    case pttChannels

    var id: String {
        switch self {
        case .actions: return "actions"
        case .layers: return "layers"
        case .places: return "places"
        case let .placeEdit(d): return "placeEdit:\(d.id ?? "new"):\(d.point.lat),\(d.point.lng)"
        case .tracks: return "tracks"
        case .convoyAlerts: return "convoyAlerts"
        case let .enjad(s): return "enjad:\(s.label)"
        case let .chat(w): return "chat:\(w?.wire ?? "")"
        case let .participant(id): return "p:\(id)"
        case .note: return "note"
        case .stations: return "stations"
        case .rallyLabel: return "rally"
        case .notify: return "notify"
        case .offlineMaps: return "offline"
        case .weather: return "weather"
        case let .weatherAt(p): return "weather:\(p.lat),\(p.lng)"
        case .trailAlways: return "trailAlways"
        case let .plan(m): return m.id
        case .shareAlways: return "shareAlways"
        case .navPicker: return "navPicker"
        case .navOptions: return "navOptions"
        case .navSteps: return "navSteps"
        case .navStartChoice: return "navStartChoice"
        case .pttChannels: return "pttChannels"
        }
    }

    /// Only sheets that mean nothing once the trip is over close by themselves when it ends
    /// (guidance, a note to send, a rally label, permission explainers). Safety («اطلب إنجاد»),
    /// the chats, a member's card, the weather… stay until the person closes them.
    var closesWhenTripEnds: Bool {
        switch self {
        case .note, .rallyLabel, .navPicker, .navOptions, .navSteps, .navStartChoice, .shareAlways, .trailAlways, .pttChannels:
            return true
        default:
            return false
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
    /// Back to «طلعاتي» while still a member (the share stays armed for when the trip opens again).
    lazy var onBackToList: () -> Void = { [weak self] in self?.onExit() }
    /// «حفظ» my number (wired to the profile endpoint by the host).
    var savePhone: (String?) -> Void = { _ in }
    /// The in-app notifications switch (registers / unregisters this device for push).
    var setPush: (Bool) -> Void = { _ in }
    /// The notification explainer was already shown on this device.
    var pushExplained: () -> Bool = { true }

    @Published var sheetDetent: SheetDetentUI = .peek
    @Published var selectedTab: LiveTabUI = .trip
    @Published var alerts: [LiveAlertUI] = []
    @Published var acknowledgedSOS: Set<String> = []
    @Published var heardClips: Set<String> = []
    @Published var clipPlayback: [String: VoicePlaybackUI] = [:]
    @Published var camera: MapCameraRequest?
    /// «تتبعني» / «باتجاهي» and «رجّعني للتوجيه» (see `LiveOutingController+FollowCamera.swift`).
    @Published var followCam = FollowCameraState()
    var lastGuidanceOn = false
    var followCamTimer: Timer?
    /// The camera follows my car (either mode). Setting false hands the camera back
    /// (keeping «رجّعني للتوجيه» while guidance is on); true turns «تتبعني» on.
    var following: Bool {
        get { followCam.mode != .free }
        set {
            if newValue { if followCam.mode == .free { followCam.cycle() } } else if followCam.mode != .free { releaseCamera() }
        }
    }
    @Published var picking: (moving: Bool, active: Bool) = (false, false)
    @Published var modal: LiveModal? {
        didSet {
            if oldValue == .navOptions, modal != .navOptions { navOptionsClosed() }
            if case .participant = oldValue, !cardMessage.isEmpty { cardMessage = [:] }
        }
    }
    @Published var inviteLink: String?
    @Published var isRevoking = false
    @Published var statusExpanded = false
    /// The trip header's bell: the queued alerts open under the header.
    @Published var bellOpen = false
    /// «إذاعة الطلعة»'s small control under the header, opened from the header's ♪ («تخفيف الزحمة» ٢).
    @Published var radioBarOpen = false
    /// Tapping «أنت» on the map: my note, or copy / share my location.
    @Published var meMenuOpen = false
    /// «الوضع الواقعي» asked from «الطبقات» (the live screen presents it).
    @Published var realisticRequest = 0
    /// Every alert this screen showed, newest first (behind the bell): nothing is just dropped.
    @Published var alertHistory: [AlertHistoryEntry] = []
    /// «شكل الشاشة»: automatic, or pinned to driving / stopped.
    @Published var contextOverride: LiveContextOverride = LiveContextOverride.saved {
        didSet { if !debugContext { LiveContextOverride.saved = contextOverride } }
    }
    private var debugContext = false
    /// Exploration («استكشاف»): the third context mode, entered by the person (header / «+») or by
    /// panning far from the group while stopped; never while driving (docs/IA-REDESIGN.md §6, stage 4).
    @Published var exploreActive = false
    /// Exploration's base layer (the trip map stays on satellite, the layer offline packs cover).
    @Published var mapLayer: MapLayer = MapLayer.saved {
        didSet { MapLayer.saved = mapLayer }
    }
    @Published var terrain3D = false
    /// Crosshair readout: decimal or degrees-minutes-seconds.
    @Published var coordFormat: CoordinateShare.Format = ExploreRules.savedFormat {
        didSet { ExploreRules.savedFormat = coordFormat }
    }
    /// The crosshair's centre + elevation (its own object: 6 Hz updates redraw the readout only).
    let exploreReading = ExploreReadingModel()
    /// Exploration was entered by panning away (said in the toast); the person's own entry is not.
    var exploreAuto = false
    /// A finger moved the map since the last settle (auto-exploration needs a real pan).
    var userPannedMap = false
    /// «ذكاء القافلة»: separation / unexpected-stop watch (Core/ConvoyWatch.swift).
    var convoyWatch = ConvoyWatch()
    var lastConvoyBuzz = Date.distantPast
    /// Moving > 15 km/h (with hysteresis), from the GPS.
    @Published private(set) var motion = MotionHysteresis()
    /// DEBUG `-SaryChatMoving`: the chat behaves as if the car were moving.
    var debugChatMoving = false
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
    /// «اسلك هذا المسار» (build 10): following any saved track, off-road (nil when off).
    @Published var trackFollow: TrackFollowModel?
    /// My trail as drawn (`TrackDisplay`), rebuilt only when the trail changes.
    var mineTrackCache: (key: String, line: TrackLine)?
    /// The one «خرجت عن المسار» card.
    static let followAlertId = "follow.offtrack"
    var followArrivedSaid = false
    /// «أظهر مسارات الأصحاب» (this device).
    @Published var showFriendTrails: Bool {
        didSet { UserDefaults.standard.set(showFriendTrails, forKey: TrailPrefs.friendsKey) }
    }
    /// Friends' last ~30 minutes, from the positions this phone already receives. Memory only.
    private(set) var friendTrails = FriendTrails()
    /// «سرعة المركبة»: my smoothed speed (see `LiveOutingController+Speed.swift`).
    let speed = SpeedModel()
    var speedState = LiveSpeedState()

    /// Turn-by-turn «الملاحة» (see Sources/Navigation).
    let nav: NavSession
    /// The plan's «الوجهة» and drawn route (wired by the plan feature; nil / empty without it).
    var navDestination: () -> OutingDestination? = { nil }
    var navPlanRoute: () -> [LngLat] = { [] }
    /// «الرحلة»: start → destination → arrival → end, on this phone (`TripTracker`).
    lazy var trip = TripTracker(outingId: session.id)
    /// «ملخص الرحلة» after the end (wired by the host: closes the map, opens the summary).
    var openSummary: () -> Void = {}
    /// «طريق العودة» as a new trip (wired by the host: creates it and opens it).
    var startReturnTrip: () -> Void = {}
    /// «أنهِ الرحلة؟» is asked.
    @Published var tripConfirmEnd = false
    /// Bumps the planning preview's camera fit.
    var navCameraKey = 0
    /// A line for a participant's card («روح له» refused: their position is old).
    @Published var cardMessage: [String: String] = [:]
    /// The trip's automatic guidance on this phone (`TripAutoNav`, LiveOutingController+AutoNav.swift).
    @Published var autoNavState = TripAutoNavState()
    /// The live link was up on the last change (the network coming back retries the road route).
    var autoNavWasOnline = true
    /// «اسلك هذا المسار» started by the off-road leg of the automatic guidance (stopped with it).
    var autoNavFollowId: String?
    /// The person left this screen: no automatic guidance from it any more (reopening starts it again).
    var autoNavLeft = false
    /// The outing closing (ended / left / removed) was handled: the sheet open at that moment
    /// was closed ONCE. Build 11 closed every sheet on every later update, so on an ended trip
    /// «أدوات الطلعة» and anything opened from it vanished about a second after opening.
    var closeHandled = false

    var bag = Set<AnyCancellable>()
    /// CarPlay's view of `nav` (kept here: `CarPlayFeatures.roadNavigation` is weak).
    var carPlayNav: CarPlayNavAdapter?
    private var lastView: OutingView?
    private var stationList: [OutdoorAPI.Station] = []
    /// Plays clips that members on older builds still send («اضغط وتكلم» before «قناة الطلعة»).
    private let player = VoicePlayer()
    private var alertTimers: [String: Timer] = [:]
    /// Last note shown per member, so a note heard nearby and then from the server alerts once.
    private var alertedNotes: [String: (text: String, at: Date)] = [:]

    init(session: OutingSession, location: LocationSharer, appearance: AppearanceSettings, featuresBackend: OutingFeaturesBackend? = nil) {
        self.session = session
        self.location = location
        self.appearance = appearance
        safety = Self.makeSafety(for: session)
        features = OutingFeaturesModel(session: session, backend: featuresBackend ?? DemoFeaturesBackend(myId: session.myUserId, notDeployed: true))
        nav = NavSession(provider: Self.navProvider(session: session))
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
        if let c = arg("-SaryContext").flatMap(LiveContextOverride.init) { debugContext = true; contextOverride = c }
        if arg("-SaryLiveModal") == "actions" { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.modal = .actions } }
        if shotArgs.contains("-SaryExplore") { exploreActive = true }
        if shotArgs.contains("-SaryConvoyIntelDemo") { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.seedConvoyIntelDemo() } }
        if let l = arg("-SaryLayer").flatMap(MapLayer.init) { mapLayer = l }
        /* `-SaryExploreAt 18.2164,42.5053`: centre exploration somewhere with relief (screenshots, UI tests). */
        if let at = arg("-SaryExploreAt") {
            let n = at.split(separator: ",").compactMap { Double($0) }
            if n.count == 2 { DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.ask(.point(LngLat(lng: n[1], lat: n[0]))) } }
        }
        /* «المحادثات»: `-SaryChat home|group`, `-SaryChatMoving` (the driving block without a car). */
        if let c = arg("-SaryChat") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.modal = .chat(c == "group" ? .group : nil) } }
        if shotArgs.contains("-SaryChatMoving") { debugChatMoving = true }
        if let t = arg("-SaryLiveTab") { selectedTab = t == "group" ? .group : t == "more" ? .more : .trip }
        if arg("-SaryLiveModal") == "layers" { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.modal = .layers } }
        if arg("-SaryLiveModal") == "weather" { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.modal = .weather } }
        #endif
        session.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.sessionChanged(); self?.followUpJoin() }
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
        /* «فهد يتكلم الآن — انتظر دورك» and friends, as the usual toast. */
        session.walkie.$notice.compactMap { $0 }.sink { [weak self] t in self?.toast(t) }.store(in: &bag)
        features.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }.store(in: &bag)
        features.start()
        wireChatToasts()
        nav.myFix = { [weak location] in location?.lastFix }
        nav.toast = { [weak self] t in self?.toast(t) }
        /* No spoken turn while the walkie-talkie is talking or playing a friend («قناة الطلعة»). */
        nav.voice.canSpeak = { [weak session] in session?.walkie.floor.state == .idle }
        nav.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.exploreDrivingCheck(); self?.followCamGuidanceCheck(); self?.objectWillChange.send() }
        }.store(in: &bag)
        #if DEBUG
        if session.isDemo, ProcessInfo.processInfo.arguments.contains("-demoTrail") { seedDemoTrails() }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-SarySheetHalf") { sheetDetent = .half }
        if let i = args.firstIndex(of: "-SaryBackTrack") {
            let delay = i + 1 < args.count ? Double(args[i + 1]) ?? 2.5 : 2.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.startBackTrack() }
        }
        if session.isDemo, let i = args.firstIndex(of: "-SaryFollow") {
            /* «اسلك هذا المسار» on the demo dunes track (UI tests, screenshots). */
            let delay = i + 1 < args.count ? Double(args[i + 1]) ?? 2.5 : 2.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                if let s = DemoTrail.dunesSubject() { self?.startFollow(s) }
            }
        }
        #endif
        if let v = session.displayView { ingestFriends(v) }
        attachSafety()
        /* The point card's «أضف نقطة» (the single map long-press) opens the shared-waypoint
           composer; after the card's sheet has gone, so the two sheets never race. */
        session.speedSnapshot = { [weak self] in self?.speed.snapshot }
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
        registerCarPlay()
        registerTrip()
        registerAutoNav()
        #if DEBUG
        pttDebugLaunch()
        navDebugLaunch()
        placeBriefDebugLaunch()
        #endif
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
        var i = LivePresenterInput(
            view: nearby.view,
            /* «أنت» on the map: the smoothed position, not the raw city-canyon fix. */
            myFix: session.smoothedFix(location.lastFix),
            gpsState: location.gpsState,
            locationAuthorized: location.canLocate,
            link: session.link,
            closed: session.closedReason,
            wantsToShare: session.wantsToShare,
            isSharingNow: session.isSharingNow,
            hasAlways: session.hasAlwaysPermission,
            sosSending: session.sosSending,
            acknowledgedSOS: acknowledgedSOS,
            alerts: alerts,
            ptt: pttUI,
            sheetDetent: sheetDetent,
            selectedTab: selectedTab,
            inviteLink: inviteLink,
            isRevoking: isRevoking,
            driveMode: appearance.prefs.driveMode.ui,
            nightMode: appearance.prefs.nightMode.ui,
            notificationsOn: notificationsOn,
            batterySharing: session.batterySharing,
            pttMuted: session.walkie.muted,
            pttLink: PTTLinkText.line(session.linkDiag, nowMs: Date().timeIntervalSince1970 * 1000),
            speakingUserId: speakingUserId,
            heardClips: heardClips,
            mapBearing: overlay.projection.bearing,
            now: Date(),
            nearbyVia: nearby.viaNearby,
            nearbyCars: session.mesh.running ? session.mesh.nearbyCars : 0,
            preciseOff: location.preciseOff
        )
        i.convoyLeaderId = convoyLeaderId
        i.convoyLeaderTitle = ConvoyLeader.title(convoy: session.view?.convoy)
        i.stoppedSince = Dictionary(uniqueKeysWithValues: (session.view?.members.keys.map { $0 } ?? []).compactMap { id in
            convoyWatch.stoppedSince(id).map { (id, $0) }
        })
        if let d = tripDestination {
            i.tripDestination = d
            i.tripArrivals = trip.record.arrivals
            i.myTripRemaining = trip.record.me.arrived ? nil : TripPresenter.myRemaining(tripInput)
        }
        return i
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
        /* Notes above cars are reading material: off while driving (docs/IA-REDESIGN.md §2.6). */
        return LiveOutingPresenter.mapMembers(i, hideNotes: theme.drive || liveContext(drive: theme.drive) == .driving).map { m in
            var m = m
            let p = parts[m.id]
            let presence: ParticipantPresence = m.presence == .live ? .live : .stale(since: Date(timeIntervalSince1970: m.atMs / 1000))
            /* Ages tick in whole minutes on the chip; quantised so the annotation is not rebuilt every second. */
            let chipNow = Date(timeIntervalSince1970: (i.now.timeIntervalSince1970 / 30).rounded(.down) * 30)
            let convoyRole = features.convoyRole(m.id)
            if showNames || m.isMe || convoyRole != nil {
                m.chip = NameChipUI(name: m.name, color: m.color, isMe: m.isMe, presence: presence, hasVoice: p?.hasVoice ?? false, now: chipNow,
                                    stuck: safety.isStuck(m.id), convoy: convoyRole.map(ConvoyBadgeUI.init), viaNearby: m.viaNearby,
                                    speaking: i.speakingUserId == m.id, silentSince: p?.silentSince)
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
        updateSpeed()
        updateTrip()
        autoNavSessionChanged()
        /* The server's picture with nearby cars' news laid over it. */
        guard let v = session.displayView else { return }
        ingestFriends(v)
        defer { lastView = v }
        guard let prev = lastView else { return }
        /* New notes from friends and new clips become cards in the alert lane. The
           same note heard first from a nearby car and then from the server is one card. */
        for (uid, m) in v.members where uid != v.myId {
            if let n = m.note, prev.members[uid]?.note != n, LiveOutingPresenter.activeNote(n, view: v, now: Date()) != nil {
                /* The leader's «ابدأ التوجيه للكل» is a command, not a card (`receiveBroadcasts` says it). */
                if NavBroadcast.isBroadcast(n.text), NavBroadcast.mayBroadcast(senderId: uid, ownerId: v.snapshot.outing.owner_id, senderIsDeputy: m.co_leader == true) { continue }
                if let last = alertedNotes[uid], last.text == n.text, Date().timeIntervalSince(last.at) < LiveOutingPresenter.noteTTL { continue }
                alertedNotes[uid] = (n.text, Date())
                if RallyRecall.isRecall(n.text), let prompt = recallPrompt(from: uid, at: n.at, view: v) {
                    pushAlert(prompt, ttl: 10 * 60)
                    continue
                }
                pushAlert(LiveAlertUI(id: "note:\(uid):\(n.at)", kind: .note(senderName: m.display_name, senderColor: v.colors[uid] ?? 0xFFFFFF, text: n.text)), ttl: 20)
            }
        }
        for c in v.clips where c.user_id != v.myId && !prev.clips.contains(where: { $0.id == c.id }) {
            let name = v.members[c.user_id]?.display_name ?? ""
            pushAlert(LiveAlertUI(id: "voice:\(c.id)", kind: .voice(VoiceClipUI(id: c.id, senderName: name, senderColor: v.colors[c.user_id] ?? 0xFFFFFF,
                                                                                durationSeconds: max(1, Int((Double(c.duration_ms) / 1000).rounded())), playback: .idle))), ttl: 60)
        }
        reconcileSilence(prev: prev, next: v)
        /* A friend cleared their SOS: forget we acknowledged it. */
        acknowledgedSOS = acknowledgedSOS.filter { key in v.members.contains { $0.key == key.split(separator: "|").first.map(String.init) && $0.value.sos != nil } }
        updateAuto()
        if let f = location.lastFix {
            var m = motion
            m.ingest(speedMps: f.speed, at: f.atMs / 1000)
            if m != motion { motion = m }
        }
        exploreDrivingCheck()
        checkConvoy()
        feedWeather()
        if session.closedReason != nil, !closeHandled {
            closeHandled = true
            if modal?.closesWhenTripEnds == true { modal = nil }
        }
        objectWillChange.send()
    }

    private func locationChanged() {
        followUpJoin()
        updateSpeed()
        if let f = location.lastFix { nav.ingest(f) }
        updateBackTrack()
        updateFollow()
        updateTrip()
        autoNavTick()
        updateAuto()
        if let f = location.lastFix {
            var m = motion
            m.ingest(speedMps: f.speed, at: f.atMs / 1000)
            if m != motion { motion = m }
        }
        exploreDrivingCheck()
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
        checkConvoyIntel()
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
    /// `driving`: friends' trails stay off while driving (docs/IA-REDESIGN.md §2.6).
    func mapTrails(members: [MapMember], driving: Bool = false) -> MapTrails {
        /* Road-matched where the matcher is confident, smoothed elsewhere (desert). */
        let shown = session.displayTrail
        let runs = Trail.runs(shown)
        var out = MapTrails()
        if shown.count >= 2 {
            out.mine = MapTrails.Line(id: "me", color: myTrailColor, solid: runs.solid, gaps: runs.gaps)
        }
        out.start = shown.first?.position
        out.highlight = backTrack != nil
        if shown.count >= 2 {
            let key = "\(shown.count)|\(shown.first?.t ?? 0)|\(shown.last?.t ?? 0)|\(shown.last?.lat ?? 0)"
            if mineTrackCache?.key != key { mineTrackCache = (key, TrackDisplay.line(trail: shown)) }
            out.mineTrack = mineTrackCache?.line
        }
        out.followed = trackFollow?.drawLine
        out.gapLabels = runs.gaps
            .map { g -> (mid: LngLat, len: Double) in
                var len = 0.0
                for i in g.indices.dropFirst() { len += Vehicle.distanceMeters(g[i - 1], g[i]) }
                let mid = g.count == 2 ? LngLat(lng: (g[0].lng + g[1].lng) / 2, lat: (g[0].lat + g[1].lat) / 2) : g[g.count / 2]
                return (mid: mid, len: len)
            }
            .filter { $0.len >= 150 }
            .sorted { $0.len > $1.len }
            .prefix(2).map(\.mid)
        if showFriendTrails && !driving {
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
                                backgroundAllowed: session.lockedScreenTrailPossible, recordingInBackground: session.recordingInBackground,
                                showFriends: showFriendTrails, backTrackActive: backTrack != nil,
                                health: session.trailRecordingAllowed ? session.trailHealth : nil,
                                matchOn: TrailMatchPrefs.enabled())
    }

    /// «طريق العودة» along my trail (or, for a return trip, along the trail of the outing it came back from).
    func startBackTrack(along path: [TrailPoint]? = nil) {
        guard let bt = BackTrack(path: path ?? session.displayTrail) else {
            toast("ما فيه مسار مسجّل بعد. يبدأ التسجيل أول ما تتحرك.")
            return
        }
        if trackFollow != nil { stopFollow() }
        backTrack = bt
        followCam.release()
        followCamGuidanceCheck()
        modal = nil
        updateBackTrack()
        var pts = bt.path.map(\.position)
        if let f = location.lastFix { pts.append(LngLat(lng: f.lng, lat: f.lat)) }
        lowerSheetThenAsk(.fit(pts))
    }

    func stopBackTrack() {
        backTrack = nil
        backTrackStatus = nil
        followCamGuidanceCheck()
    }

    private func updateBackTrack() {
        guard var bt = backTrack else { return }
        /* Only a recent fix: an old one would point the wrong way. */
        guard let f = session.smoothedFix(location.lastFix), Date().timeIntervalSince1970 * 1000 - f.atMs < 60_000 else {
            backTrackStatus = nil
            return
        }
        let st = bt.update(LngLat(lng: f.lng, lat: f.lat), accuracy: f.accuracy, atMs: f.atMs)
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

    /// «طابق مساري مع الطرق» (Mapbox Map Matching).
    func setTrailMatching(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: TrailMatchPrefs.key)
        objectWillChange.send()
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
        offerNotificationsInContext(a)
        AlertQueue.record(a, at: Date(), into: &alertHistory)
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

    func ask(_ kind: MapCameraRequest.Kind) {
        /* Looking somewhere on purpose: the follow camera steps aside (the pill stays while guiding). */
        if followCam.mode != .free {
            followCam.release(offerBack: guidanceOn)
            followCamTimerCheck()
        }
        camera = MapCameraRequest(kind: kind, id: (camera?.id ?? 0) + 1)
    }

    /// Lower the sheet, then move the camera once it has settled (the clear area changes size).
    func lowerSheetThenAsk(_ kind: MapCameraRequest.Kind) {
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
            if parts.first == "silent", parts.count > 1 { self.showSilent(parts[1]) }
        }
        a.dismissAlert = { [weak self] id in self?.dismissAlert(id) }
        a.silent = SilentAlertActions(
            go: { [weak self] uid in self?.goToSilent(uid) },
            call: { [weak self] uid in self?.dial(uid, whatsApp: false) }
        )
        a.voice = VoiceBannerActions(
            play: { [weak self] id in self?.togglePlay(id) },
            dismiss: { [weak self] id in self?.dismissAlert("voice:\(id)") }
        )
        a.locateMe = { [weak self] in
            guard let self else { return }
            self.cycleCameraMode()
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
            cancelled: { [weak self] in self?.pttEnded() }
        )
        a.setSheetDetent = { [weak self] d in self?.sheetDetent = d }
        a.selectTab = { [weak self] t in self?.selectedTab = t }
        a.participantsTab = ParticipantsTabActions(
            openParticipant: { [weak self] id in self?.openParticipant(id) },
            addMyPhone: { [weak self] in self?.selectedTab = .more },
            rallyShow: { [weak self] in
                guard let self, let r = self.rallyPoint else { return }
                self.lowerSheetThenAsk(.point(r.position))
            },
            rallyGo: { [weak self] in
                /* «اتجه»: turn-by-turn in the app (Apple Maps stays one tap away in the options). */
                self?.navigate(NavTargets.rally(self?.rallyPoint))
            },
            rallyMove: { [weak self] in self?.startPicking(moving: true) },
            rallyRemove: { [weak self] in Task { await self?.session.clearRally() } },
            rallyCreate: { [weak self] in self?.startPicking(moving: false) },
            rallyRecall: session.view?.iLead == true ? { [weak self] in self?.recallToRally() } : nil
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
            setPTTMuted: { [weak self] on in self?.session.walkie.setMuted(on) },
            pauseOrResumeOuting: { [weak self] in
                guard let self, let st = self.session.view?.status else { return }
                Task { await self.session.setStatus(st == .paused ? "resume" : st == .created ? "start" : "pause") }
            },
            endOuting: { [weak self] in Task { await self?.session.setStatus("end") } },
            leaveOuting: { [weak self] in self?.leaveOuting() }
        )
        return a
    }

    func back() {
        autoNavLeft = true
        if nav.isActive || nav.phase == .planning { nav.end() }
        /* No «أوقف المشاركة»: back to the list keeps the trip's session (and sharing) running
         * (build 15); stopping is «غادر الطلعة» or the trip's end. Say so before leaving the map. */
        if session.isSharingNow || (session.wantsToShare && session.view?.status == .active) { confirm = .backWhileSharing } else { onExit() }
    }

    /// «ارجع للقائمة» from the back dialog: still a member, sharing keeps going off the map.
    func backToList() {
        confirm = nil
        onBackToList()
    }

    /// «غادر الطلعة» — the only way to stop sharing (confirmed first by the caller's dialog).
    func leaveOuting() {
        confirm = nil
        Task { if await session.leave() { onExit() } }
    }

    /// The first alert worth a notification, after an invite join: our explainer, then iOS's prompt.
    /// Never at join itself (owner decision, build 14: location is the only prompt there).
    var notifyOfferPending = false

    private func offerNotificationsInContext(_ a: LiveAlertUI) {
        guard notifyOfferPending, !pushExplained() else { return }
        switch a.kind {
        case .note, .voice, .safety, .silent, .convoy: break
        default: return
        }
        notifyOfferPending = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.modal == nil, !self.pushExplained() else { return }
            self.modal = .notify
        }
    }

    /// Asked once per device (the same key the trail explainer uses: one «دائمًا» covers both).
    static let shareAlwaysAskedKey = "sary.outings.shareAlwaysAsked.v1"

    private func askAlwaysForSharing() async {
        UserDefaults.standard.set(true, forKey: Self.shareAlwaysAskedKey)
        UserDefaults.standard.set(true, forKey: TrailPrefs.explainedKey)
        guard !session.hasAlwaysPermission, location.canLocate else { return }
        let ok = await location.requestAlways()
        toast(ok ? "تستمر المشاركة والشاشة مقفلة حتى توقفها" : "الإذن «أثناء الاستخدام» فقط: تتوقف المشاركة إذا قفلت الشاشة")
        objectWillChange.send()
    }

    /// The app was off screen while sharing with «أثناء الاستخدام» only (sending paused): now it
    /// is back, explain «دائمًا» once, then ask iOS. The contextual upgrade (build 14).
    func offerShareAlwaysIfNeeded() {
        guard !session.hasAlwaysPermission, location.canLocate,
              !UserDefaults.standard.bool(forKey: Self.shareAlwaysAskedKey) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.modal == nil, self.session.wantsToShare else { return }
            self.modal = .shareAlways
        }
    }

    func allowShareAlways() {
        modal = nil
        Task { await askAlwaysForSharing() }
    }

    func laterShareAlways() {
        UserDefaults.standard.set(true, forKey: Self.shareAlwaysAskedKey)
        modal = nil
    }

    /// A member (joining is the consent) but iOS location is refused or restricted (e.g. turned
    /// off in Settings after joining): the calm fix on the trip tab.
    var locationDenied: Bool {
        session.hasConsent && (location.authorization == .denied || location.authorization == .restricted)
    }

    /// Right after «انضم» nothing more is asked (the one-step join asked for the location).
    /// «دائمًا» comes in context: the first time the person is back after sending paused off screen.
    func followUpJoin() {
        if session.joinedJustNow { session.joinedJustNow = false }
        guard session.askAlwaysOnReturn, session.isVisible, UIApplication.shared.applicationState == .active else { return }
        session.askAlwaysOnReturn = false
        if location.canLocate { offerShareAlwaysIfNeeded() }
    }

    /// One line under «موقعك مُشارَك»: what happens when the screen locks, and what to do.
    var shareBackgroundHint: ShareBackgroundHint? {
        guard session.wantsToShare, session.closedReason == nil, session.view?.status == .active else { return nil }
        if !session.hasAlwaysPermission { return location.canLocate ? .needsAlways : nil }
        return ProcessInfo.processInfo.isLowPowerModeEnabled ? .lowPower : .dontForceQuit
    }

    /// «ابدأ الطلعة»: never without a destination («لا يوجد رحلة من غير نهاية»).
    func startOuting() {
        guard tripDestination != nil else {
            toast("حدّد الوجهة أولًا")
            chooseTripDestination()
            return
        }
        Task {
            await session.setStatus("start")
            /* Guidance is the leader's choice: for everyone, or only for him. */
            if session.view?.status == .active { offerGuidanceChoice() }
        }
    }

    // MARK: participants

    func openParticipant(_ id: String) {
        if id == session.view?.myId {
            /* «أنت»: «رسالة فوق سيارتي» (only while the outing runs: after the end nobody would see it)
             * and «انسخ أو شارك موقعي» (moved here from «+», «تخفيف الزحمة» ١٣). */
            meMenuOpen = true
        } else {
            modal = .participant(id)
        }
    }

    func participantCard(_ id: String) -> ParticipantCardUIState? {
        guard let p = LiveOutingPresenter.participants(input).first(where: { $0.id == id }), let v = session.view else { return nil }
        return ParticipantCardUIState(participant: p, now: Date(), canManage: v.iOwn && !p.isMe && p.role != .leader,
                                      isBusy: session.busy.contains("member:\(id)"), errorMessage: cardMessage[id])
    }

    func participantActions(_ id: String) -> ParticipantCardActions {
        ParticipantCardActions(
            call: { [weak self] in self?.dial(id, whatsApp: false) },
            whatsApp: { [weak self] in self?.dial(id, whatsApp: true) },
            showOnMap: { [weak self] in
                self?.modal = nil
                self?.show(member: id)
            },
            navigate: { [weak self] in self?.navigateToMember(id) },
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

    // MARK: «قناة الطلعة» (live walkie-talkie)

    /// The button's one state, from the session's walkie-talkie.
    var pttUI: PTTStateUI {
        let w = session.walkie
        if w.muted { return .muted }
        switch w.floor.state {
        case .idle:
            return w.mode == .unavailable && session.view?.status != .ended ? .unavailable : .idle
        case .requesting:
            return .arming
        case .talking:
            let s = w.floor.talkingSeconds(nowMs: w.nowMs)
            return .talking(seconds: s, remaining: max(0, Int(w.floor.maxTalkMs / 1000) - s))
        case .listening(let t):
            let v = session.displayView
            return .listening(name: v?.members[t.userId]?.display_name ?? (t.name.isEmpty ? "عضو" : t.name), color: v?.colors[t.userId] ?? 0xFFFFFF)
        }
    }

    var pttLevel: Float { session.walkie.level }

    #if DEBUG
    /// `-SaryPTTDemo talking|listening` (screenshots): the walkie-talkie on air without a server.
    private func pttDebugLaunch() {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-SaryPTTDemo"), i + 1 < a.count else { return }
        let what = a[i + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSince1970 * 1000
            if what == "talking" {
                self.session.walkie.debugForce(.talking(burst: 1, sinceMs: now - 7_000))
            } else if let friend = self.session.displayView?.orderedMembers.first(where: { $0.user_id != self.session.myUserId }) {
                self.session.walkie.debugForce(.listening(PTTTalker(userId: friend.user_id, name: friend.display_name, burst: 1)))
            }
            self.objectWillChange.send()
        }
    }
    #endif

    /// On air right now (me or a friend): the speaking badge over that car.
    var speakingUserId: String? {
        switch session.walkie.floor.state {
        case .talking: return session.myUserId
        case .listening(let t): return t.userId
        default: return nil
        }
    }

    private func pttBegan() {
        guard session.view?.status != .ended else { return }
        if MicPermission.granted || PTTAudioEngine.testToneRequested {
            session.walkie.pressBegan()
            return
        }
        /* First time: iOS asks; they hold again once it is allowed. */
        Task {
            if await MicPermission.request() {
                toast("جاهز — اضغط مطولًا وتكلم")
            } else {
                toast("اسمح بالميكروفون من الإعدادات لتتكلم في «قناة الطلعة»")
            }
        }
    }

    private func pttEnded() {
        session.walkie.pressEnded()
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
    /// «غادر الطلعة» from the trip tab's sharing row.
    case leave
    var id: Int { self == .leave ? 1 : 0 }
}

/// Directions in Apple Maps (no third party sees the request from us).
enum Directions {
    static func open(lat: Double, lng: Double, name: String) {
        var c = URLComponents(string: "https://maps.apple.com/")!
        c.queryItems = [.init(name: "daddr", value: "\(lat),\(lng)"), .init(name: "q", value: name)]
        if let u = c.url { UIApplication.shared.open(u) }
    }
}
