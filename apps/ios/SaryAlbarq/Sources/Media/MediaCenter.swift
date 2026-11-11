import AVFoundation
import Combine
import SwiftUI
import UIKit

/// «يوتيوب» for one open outing: «قناتي» (only me) and «قناة الطلعة» (shared,
/// in sync). One embedded player for both — only one channel plays at a time.
///
/// Policy (YouTube Terms / API Services): official embedded IFrame player only;
/// no stream extraction, no downloads, no audio-only or background playback
/// (we pause on background, and when the phone is on CarPlay); the player is
/// never hidden or covered and is at least 200 × 200 pt. Each phone plays its
/// own player; the server only carries the video id, position, rate and
/// play/pause (see apps/api/lib/outings/media.js).
@MainActor
final class MediaCenter: ObservableObject {
    enum Availability: Equatable {
        case unknown
        case ready
        /// The server has no «قناة الطلعة» yet (404). «قناتي» still works.
        case notDeployed
        case failed(String)
    }

    struct PrivateItem: Equatable {
        var videoId: String
        var title: String
        var start: Double
    }

    /// «سعد شغّل: … في قناة الطلعة» (alert lane).
    struct Notice: Equatable, Identifiable {
        var id: String
        var videoId: String
        var who: String
        var title: String
    }

    let outingId: String
    let myUserId: String
    private let backend: MediaBackend
    private let iLead: () -> Bool
    private let names: () -> [String: String]
    private let clockOffset: () -> Double
    let driveMode: () -> Bool
    let speedMps: () -> Double?

    @Published var presented = false
    @Published var tab: MediaChannel = .mine
    @Published private(set) var availability: Availability = .unknown
    @Published private(set) var shared: SharedMediaState?
    @Published private(set) var privateItem: PrivateItem?
    @Published private(set) var coordinator = MediaCoordinator()
    @Published private(set) var notice: Notice?
    @Published private(set) var titles: [String: String] = [:]
    @Published private(set) var reading: MediaSync.PlayerReading?
    @Published private(set) var playerError: String?
    @Published var errorText: String?
    @Published private(set) var busy = false
    /// «أنا راكب»: the full-size player while the car is moving (this outing, until I leave the sheet).
    @Published var passengerConfirmed = false
    /// I paused / moved my own copy while following: stop correcting until «رجّع للمزامنة».
    @Published private(set) var localHold = false
    @Published private(set) var onCarPlay = false
    @Published private(set) var tick = 0

    private(set) lazy var engine: MediaPlayerEngine = makeEngine()
    private var engineLoaded: String?
    private var bag = Set<AnyCancellable>()
    private var timer: Timer?
    private var lastCommandAt = Date.distantPast
    private var lastFetchAt = Date.distantPast
    private var noticeTimer: Timer?
    private var fetchedOffsetMs: Double?

    init(outingId: String, myUserId: String, backend: MediaBackend, iLead: @escaping () -> Bool,
         names: @escaping () -> [String: String], clockOffset: @escaping () -> Double,
         driveMode: @escaping () -> Bool, speedMps: @escaping () -> Double?) {
        self.outingId = outingId
        self.myUserId = myUserId
        self.backend = backend
        self.iLead = iLead
        self.names = names
        self.clockOffset = clockOffset
        self.driveMode = driveMode
        self.speedMps = speedMps
        NotificationCenter.default.publisher(for: MediaEvents.name)
            .receive(on: RunLoop.main)
            .sink { [weak self] n in
                guard let self, n.userInfo?["outing"] as? String == self.outingId else { return }
                self.availability = .ready
                self.apply(MediaEvents.decodeState(n.userInfo?["state"]))
            }
            .store(in: &bag)
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willResignActiveNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in self?.handle(.background) }.store(in: &bag)
        }
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.presented { self.handle(.resume) }
                self.takeShared()
            }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.checkCarPlay() }
            .store(in: &bag)
        checkCarPlay()
        DispatchQueue.main.async { [weak self] in self?.takeShared() }
    }

    /// A link shared into the app from YouTube / Safari (share extension): open «قناتي» with it.
    private func takeShared() {
        guard let link = MediaShareInbox.take() else { return }
        open(.mine)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.playPrivate(link) }
    }

    private func makeEngine() -> MediaPlayerEngine {
        let e: MediaPlayerEngine = ProcessInfo.processInfo.arguments.contains("-SaryStubPlayer") ? StubMediaPlayer() : YouTubeIFramePlayer()
        e.onEvent = { [weak self] ev in self?.playerEvent(ev) }
        return e
    }

    // MARK: derived

    var iLeadNow: Bool { iLead() }
    var canControl: Bool { MediaPermissions.canControl(shared, me: myUserId, iLead: iLead()) }
    var canTakeover: Bool { MediaPermissions.canTakeover(shared, me: myUserId, iLead: iLead()) }
    var canQueue: Bool { MediaPermissions.canQueue(shared) }
    var joined: Bool { coordinator.joinedShared }
    var activeChannel: MediaChannel? { coordinator.active }

    func name(of userId: String) -> String {
        userId == myUserId ? "أنت" : (names()[userId] ?? "عضو")
    }

    func title(for videoId: String, fallback: String = "") -> String {
        if !fallback.isEmpty { return fallback }
        return titles[videoId] ?? "فيديو يوتيوب"
    }

    var presentation: DriveGate.Presentation {
        _ = tick
        return DriveGate.presentation(driveMode: driveMode(), speedMps: speedMps(), passengerConfirmed: passengerConfirmed)
    }

    var expectedSharedPosition: Double? {
        shared?.position(deviceNow: Date(), clockOffsetMs: fetchedOffsetMs ?? clockOffset())
    }

    // MARK: presentation

    func open(_ channel: MediaChannel? = nil) {
        if let channel { tab = channel }
        presented = true
    }

    func sheetAppeared() {
        startTimer()
        Task { await refresh() }
        handle(.resume)
    }

    /// The sheet closed: the player is off screen, so it must stop (no hidden playback).
    func sheetDisappeared() {
        stopTimer()
        handle(.background)
        passengerConfirmed = false
    }

    func select(_ t: MediaChannel) {
        guard t != tab else { return }
        tab = t
        /* The other channel's player would be off screen: pause it. */
        if coordinator.active != nil && coordinator.active != t { engine.pause() }
    }

    // MARK: «قناتي»

    func playPrivate(_ link: YouTubeLink) {
        guard !onCarPlay else { return carPlayRefusal() }
        let wasJoined = joined
        privateItem = PrivateItem(videoId: link.videoId, title: titles[link.videoId] ?? "", start: link.startSeconds ?? 0)
        run(coordinator: .playPrivate)
        if wasJoined { errorText = nil }
        Task { await loadTitle(link.videoId) }
    }

    func stopPrivate() {
        privateItem = nil
        run(coordinator: .stopPrivate)
    }

    func resumePrivate() {
        guard let p = privateItem else { return }
        guard !onCarPlay else { return carPlayRefusal() }
        if coordinator.active != .mine { playPrivate(YouTubeLink(videoId: p.videoId, startSeconds: reading?.videoId == p.videoId ? reading?.position : p.start)) }
        else { engine.play() }
    }

    // MARK: «قناة الطلعة»

    func refresh() async {
        do {
            let r = try await backend.fetch()
            if let s = r.serverNow { fetchedOffsetMs = (s.timeIntervalSince1970 - Date().timeIntervalSince1970) * 1000 }
            lastFetchAt = Date()
            availability = .ready
            apply(r.state)
        } catch MediaBackendError.notDeployed {
            availability = .notDeployed
        } catch let e as MediaBackendError {
            if availability != .ready { availability = .failed(e.arabic) }
        } catch {}
    }

    func join() {
        guard shared != nil else { return }
        guard !onCarPlay else { return carPlayRefusal() }
        localHold = false
        run(coordinator: .joinShared)
    }

    func leaveShared() { run(coordinator: .leaveShared) }

    /// Start something for everyone (idle channel), or load a new video as controller.
    func startShared(_ link: YouTubeLink) async {
        let title = await YouTubeOEmbed.title(for: link.videoId) ?? ""
        if !title.isEmpty { titles[link.videoId] = title }
        await send(.load(link.videoId, title: title, at: link.startSeconds)) { [weak self] in
            guard let self, !self.joined else { return }
            self.join()
        }
    }

    func queue(_ link: YouTubeLink) async {
        await send(.queue(link.videoId))
        await loadTitle(link.videoId)
    }

    func control(_ a: MediaAction) async { await send(a) }

    func togglePlay() async {
        guard let s = shared else { return }
        let at = currentPositionForControl()
        await send(s.playing ? .pause(at: at) : .play(at: at))
    }

    func skip(by seconds: Double) async {
        guard let p = currentPositionForControl() else { return }
        await send(.seek(max(0, p + seconds)))
    }

    func takeover() async {
        busy = true
        defer { busy = false }
        do { apply(try await backend.takeover()) } catch let e as MediaBackendError { errorText = e.arabic } catch {}
    }

    func resync() {
        localHold = false
        Task { await syncNow() }
    }

    private func currentPositionForControl() -> Double? {
        if coordinator.follows, let r = reading, r.videoId == shared?.video_id { return r.position }
        return expectedSharedPosition
    }

    private func send(_ a: MediaAction, then: (() -> Void)? = nil) async {
        busy = true
        defer { busy = false }
        do {
            let s = try await backend.send(a)
            availability = .ready
            apply(s)
            then?()
        } catch MediaBackendError.notDeployed {
            availability = .notDeployed
        } catch let e as MediaBackendError {
            errorText = e.arabic
            if case .server("media_idle", _) = e { apply(nil) }
        } catch {}
    }

    // MARK: state in

    func apply(_ next: SharedMediaState?) {
        let prev = shared
        shared = next
        guard let next else {
            if prev != nil { run(coordinator: .sharedEnded) }
            return
        }
        if !next.title.isEmpty { titles[next.video_id] = next.title }
        Task { await loadTitle(next.video_id) }
        for id in next.queue.prefix(5) { Task { await loadTitle(id) } }
        if prev?.video_id != next.video_id, next.controller_user_id != myUserId, !joined {
            showNotice(Notice(id: "\(next.video_id)|\(next.at)", videoId: next.video_id, who: name(of: next.controller_user_id), title: next.title))
        }
        if prev?.video_id != next.video_id { localHold = false }
        if coordinator.follows { Task { await syncNow() } }
    }

    private func loadTitle(_ id: String) async {
        guard titles[id] == nil, let t = await YouTubeOEmbed.title(for: id) else { return }
        titles[id] = t
        if notice?.videoId == id, notice?.title.isEmpty == true { notice?.title = t }
    }

    private func showNotice(_ n: Notice) {
        notice = n
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.notice = nil }
        }
    }

    func dismissNotice() { notice = nil }

    func joinFromNotice() {
        notice = nil
        open(.outing)
        join()
    }

    // MARK: coordinator & player

    func handle(_ e: MediaCoordinator.Event) { run(coordinator: e) }

    private func run(coordinator e: MediaCoordinator.Event) {
        var c = coordinator
        let effects = c.handle(e)
        coordinator = c
        for fx in effects {
            switch fx {
            case .pausePlayer:
                if engineLoaded != nil { engine.pause() }
            case .unloadPlayer:
                engine.unload()
                engineLoaded = nil
                reading = nil
            case .startPrivate:
                guard let p = privateItem else { break }
                engine.load(videoId: p.videoId, start: p.start, play: true)
                engineLoaded = p.videoId
                markCommand()
            case .followShared:
                Task { await syncNow() }
            }
        }
    }

    private func markCommand() { lastCommandAt = Date() }

    /// Follower: bring my player to the shared clock (seek if off by > 2 s).
    func syncNow() async {
        guard coordinator.follows, !localHold, let s = shared, let expected = expectedSharedPosition else { return }
        let r = await engine.reading()
        let player = r ?? MediaSync.PlayerReading(videoId: engineLoaded, position: 0, playing: false, rate: 1)
        let cmds = MediaSync.plan(target: s, expected: expected, player: engineLoaded == s.video_id ? player : .init(videoId: nil, position: 0, playing: false, rate: 1))
        for c in cmds {
            switch c {
            case let .load(id, start, play):
                engine.load(videoId: id, start: start, play: play)
                engineLoaded = id
            case let .seek(p): engine.seek(to: p)
            case .play: engine.play()
            case .pause: engine.pause()
            case let .rate(r): engine.setRate(r)
            }
        }
        if !cmds.isEmpty { markCommand() }
    }

    private func playerEvent(_ e: MediaPlayerEvent) {
        if let msg = e.arabicError { playerError = msg; return }
        if e == .playing { playerError = nil }
        if onCarPlay, e == .playing { engine.pause(); return }
        guard coordinator.active == .outing, coordinator.follows, let s = shared else { return }
        /* Our own command echoing back. */
        guard Date().timeIntervalSince(lastCommandAt) > 1.5 else { return }
        switch e {
        case .paused where s.playing, .playing where !s.playing:
            if canControl, s.controller_user_id == myUserId {
                /* The controller used YouTube's own controls: everyone follows. */
                Task { await send(e == .playing ? .play(at: reading?.position) : .pause(at: reading?.position)) }
            } else {
                localHold = true
            }
        case .ended:
            if s.controller_user_id == myUserId, !s.queue.isEmpty { Task { await send(.next) } }
        default: break
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: MediaSync.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.timerTick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func timerTick() async {
        tick &+= 1
        if engineLoaded != nil { reading = await engine.reading() }
        checkCarPlay()
        if Date().timeIntervalSince(lastFetchAt) > 15, availability != .notDeployed { await refresh() }
        guard coordinator.follows, let s = shared else { return }
        /* The controller scrubbing with YouTube's own bar: share the new position. */
        if s.controller_user_id == myUserId, let r = reading, r.videoId == s.video_id, let exp = expectedSharedPosition,
           abs(r.position - exp) > MediaSync.driftThreshold + 1, Date().timeIntervalSince(lastCommandAt) > 3 {
            markCommand()
            await send(.seek(r.position))
            return
        }
        await syncNow()
    }

    // MARK: CarPlay — video never plays there

    private func checkCarPlay() {
        let route = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
        let scene = UIApplication.shared.connectedScenes.contains { $0.session.role == .carTemplateApplication }
        let now = route || scene
        guard now != onCarPlay else { return }
        onCarPlay = now
        if now { handle(.carPlay) }
    }

    private func carPlayRefusal() {
        errorText = "يوتيوب ما يشتغل والجوال متصل بـ CarPlay."
    }
}

/// One `MediaCenter` per open outing, so the sheet, the entry card and the
/// alert-lane notice share it without new state on LiveOutingController.
@MainActor
enum MediaCenters {
    private static var centers: [String: MediaCenter] = [:]
    private static var closers = Set<AnyCancellable>()

    static func of(_ controller: LiveOutingController) -> MediaCenter {
        let session = controller.session
        if let c = centers[session.id] { return c }
        let iLead = { [weak session] in session?.view?.iLead == true }
        let backend: MediaBackend
        if session.isLocal {
            let seeded: SharedMediaState? = ProcessInfo.processInfo.arguments.contains("-SaryMediaShared")
                ? SharedMediaState(video_id: "M7lc1UVf-VE", title: "YouTube Developers Live: Embedded Web Player Customization",
                                   controller_user_id: "00000000-0000-4000-8000-000000000002", position_s: 42, playing: true,
                                   queue: ["aqz-KE-bpKQ", "jNQXAC9IVRw"], at: ISODate.string(Date()))
                : nil
            backend = MediaDemoBackend(me: session.myUserId, iLead: session.view?.iLead == true, seeded: seeded)
        } else {
            backend = MediaHTTPBackend(outingId: session.id)
        }
        let appearance = controller.appearance
        let location = controller.location
        let c = MediaCenter(
            outingId: session.id, myUserId: session.myUserId, backend: backend, iLead: iLead,
            names: { [weak session] in (session?.view?.members ?? [:]).mapValues(\.display_name) },
            clockOffset: { [weak session] in session?.view?.clockOffsetMs ?? 0 },
            driveMode: { [weak appearance] in appearance?.isDriving == true || ProcessInfo.processInfo.arguments.contains("-SaryMediaMoving") },
            speedMps: { [weak location] in ProcessInfo.processInfo.arguments.contains("-SaryMediaMoving") ? 25 : location?.lastFix?.speed }
        )
        centers[session.id] = c
        session.$closedReason.sink { r in
            guard r != nil else { return }
            DispatchQueue.main.async { drop(session.id) }
        }.store(in: &closers)
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-SaryOpenMedia"), i + 1 < args.count {
            let ch: MediaChannel = args[i + 1] == "outing" ? .outing : .mine
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                c.open(ch)
                if let j = args.firstIndex(of: "-SaryMediaVideo"), j + 1 < args.count, let link = YouTubeLink.parse("https://youtu.be/\(args[j + 1])") {
                    c.playPrivate(link)
                }
                if args.contains("-SaryMediaJoin") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { c.join() } }
            }
        }
        if args.contains("-SaryMediaShared"), !args.contains("-SaryOpenMedia") {
            /* The alert-lane notice, as if «أبو فهد» just started it. */
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let s = (backend as? MediaDemoBackend)?.state
                c.apply(nil)
                c.apply(s)
            }
        }
        #endif
        return c
    }

    /// The outing is gone from this device (left / ended / signed out).
    static func drop(_ outingId: String) {
        centers[outingId]?.stopPrivate()
        centers[outingId]?.leaveShared()
        centers[outingId] = nil
    }
}
