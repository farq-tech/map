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
    /// Weather, wind, dust, rain and wadi floods (Sources/Weather).
    let weather: OutingWeather
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

    private var bag = Set<AnyCancellable>()
    private var lastView: OutingView?
    private var stationList: [OutdoorAPI.Station] = []
    private let recorder = VoiceRecorder()
    private let player = VoicePlayer()
    private var pttTimer: Timer?
    private var alertTimers: [String: Timer] = [:]

    init(session: OutingSession, location: LocationSharer, appearance: AppearanceSettings) {
        self.session = session
        self.location = location
        self.appearance = appearance
        notificationsOn = UserDefaults.standard.object(forKey: "sary.outings.notify.v1") as? Bool ?? true
        inviteLink = session.storedInviteURL()?.absoluteString
        weather = OutingWeather(outingId: session.id, tracksMap: true)
        weather.onAlert = { [weak self] a in self?.pushAlert(LiveAlertUI(id: a.id, kind: .weather(a)), ttl: 45) }
        #if DEBUG
        /* Screenshots: `-SaryLiveSheet half|full`, `-SaryLiveModal weather`. */
        let args = ProcessInfo.processInfo.arguments
        func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
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
        lastView = session.view
    }

    // MARK: state

    var input: LivePresenterInput {
        LivePresenterInput(
            view: session.view,
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
            now: Date()
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
            if showNames || m.isMe {
                m.chip = NameChipUI(name: m.name, color: m.color, isMe: m.isMe, presence: presence, hasVoice: p?.hasVoice ?? false, now: chipNow)
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
        guard let v = session.view else { return }
        defer { lastView = v }
        guard let prev = lastView else { return }
        /* New notes from friends and new clips become cards in the alert lane. */
        for (uid, m) in v.members where uid != v.myId {
            if let n = m.note, prev.members[uid]?.note != n, LiveOutingPresenter.activeNote(n, view: v, now: Date()) != nil {
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
        feedWeather()
        if session.closedReason != nil, modal != nil { modal = nil }
        objectWillChange.send()
    }

    private func locationChanged() {
        updateAuto()
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
            let parts = id.split(separator: ":").map(String.init)
            if parts.first == "note", parts.count > 1 { self.show(member: parts[1]) }
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
            Task { await session.beginSharing() }
        } else {
            modal = .consent
        }
    }

    func acceptConsent() {
        modal = nil
        Task { await session.beginSharing() }
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
        guard let uid = alertId.split(separator: "|").first.map(String.init), let v = session.view else { return }
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
