import AVFoundation
import Combine
import SwiftUI
import UIKit

/// «إذاعة الطلعة» for one open outing: what the whole trip listens to, in sync, while
/// driving — background, screen locked, car speakers. The leader (or anyone with
/// «الكل يقدر يشغّل») picks; every phone plays the source itself with AVPlayer.
///
/// With a server that does not have it yet (404), it falls back to local-only:
/// the person still gets the radio, for themselves, with a calm note.
@MainActor
final class GroupAudioCenter: ObservableObject {
    enum Availability: Equatable {
        case unknown
        /// In sync with the trip through the server.
        case shared
        /// No server support yet / the demo: only this phone.
        case localOnly
    }

    enum PlayerStatus: Equatable {
        case idle
        case loading
        case playing
        case paused
        case failed(String)
    }

    let outingId: String
    let myUserId: String
    private var backend: GroupAudioBackend
    private let iLead: () -> Bool
    private let names: () -> [String: String]
    private let sessionClockOffset: () -> Double

    @Published var presented = false
    @Published var pickerSource: GroupAudioSource = .radio
    @Published private(set) var state: GroupAudioState = .idle()
    @Published private(set) var availability: Availability = .unknown
    @Published private(set) var ducking = GroupAudioDucking()
    @Published private(set) var status: PlayerStatus = .idle
    /// From the server's catalog; empty while it loads (the app's copy only if it cannot be reached).
    @Published private(set) var stations: [GroupAudioStation] = []
    /// The server's catalog could not be fetched: the app's own copy is shown.
    @Published private(set) var catalogOffline = false
    @Published private(set) var audiusResults: [AudiusAPI.Track] = []
    @Published private(set) var audiusSearching = false
    @Published var errorText: String?
    @Published private(set) var busy = false
    /// «اطلع»: hide «يشغّل الآن» until something new starts.
    @Published private(set) var left = false
    /// Seconds into a file, for the sheet.
    @Published private(set) var elapsed: Double?
    @Published private(set) var lastDrift: Double?

    private(set) lazy var engine: GroupAudioEngine = makeEngine()
    private let nowPlaying = GroupAudioNowPlaying()
    private var bag = Set<AnyCancellable>()
    private var timer: Timer?
    private var measuredOffsetMs: Double?
    private var lastFetchAt = Date.distantPast
    private var lastSeekAt = Date.distantPast
    /// We activated `.playback` (and so may deactivate it).
    private var activated = false

    init(outingId: String, myUserId: String, backend: GroupAudioBackend, iLead: @escaping () -> Bool,
         names: @escaping () -> [String: String], clockOffset: @escaping () -> Double, engine: GroupAudioEngine? = nil) {
        self.outingId = outingId
        self.myUserId = myUserId
        self.backend = backend
        self.iLead = iLead
        self.names = names
        sessionClockOffset = clockOffset
        if let engine {
            self.engine = engine
            engine.onEvent = { [weak self] ev in self?.playerEvent(ev) }
        }
        if !backend.isShared { availability = .localOnly }
        let nc = NotificationCenter.default
        nc.publisher(for: GroupAudioEvents.name).receive(on: RunLoop.main).sink { [weak self] n in
            guard let self, n.userInfo?["outing"] as? String == self.outingId, self.backend.isShared else { return }
            guard let s = GroupAudioEvents.decodeState(n.userInfo?["state"]) else { return }
            if self.measuredOffsetMs == nil, let now = ISODate.parse(n.userInfo?["server_now"] as? String) {
                self.measuredOffsetMs = now.timeIntervalSinceNow * 1000
            }
            self.availability = .shared
            self.apply(s)
        }.store(in: &bag)
        nc.publisher(for: GroupAudioDuck.name).receive(on: RunLoop.main).sink { [weak self] n in
            let on = n.userInfo?["on"] as? Bool == true
            let nav = n.userInfo?["kind"] as? String == "nav"
            self?.duck(nav ? (on ? .navBegan : .navEnded) : (on ? .pttBegan : .pttEnded))
        }.store(in: &bag)
        nc.publisher(for: AVAudioSession.interruptionNotification).receive(on: RunLoop.main).sink { [weak self] n in
            self?.interruption(n)
        }.store(in: &bag)
        nc.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main).sink { [weak self] n in
            /* Headphones / car Bluetooth gone: iOS convention is to stop, not to switch to the phone's speaker. */
            guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            self?.mute()
        }.store(in: &bag)
        nc.publisher(for: AVAudioSession.mediaServicesWereResetNotification).receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            self.engine.unload()
            self.reconcile()
        }.store(in: &bag)
        nc.publisher(for: UIApplication.didBecomeActiveNotification).sink { [weak self] _ in
            Task { await self?.refresh() }
        }.store(in: &bag)
        Task { await refresh() }
        Task { await loadCatalog() }
    }

    private func makeEngine() -> GroupAudioEngine {
        let e: GroupAudioEngine = ProcessInfo.processInfo.arguments.contains("-SaryStubAudio") ? StubGroupAudioEngine() : AVGroupAudioEngine()
        e.onEvent = { [weak self] ev in self?.playerEvent(ev) }
        return e
    }

    // MARK: derived

    var canControl: Bool { availability == .localOnly || GroupAudioPermissions.canControl(state, iLead: iLead()) }
    var canSetAllowAll: Bool { availability == .shared && GroupAudioPermissions.canSetAllowAll(iLead: iLead()) }
    var canQueue: Bool { availability == .shared && GroupAudioPermissions.canQueue(state) }
    var muted: Bool { ducking.muted }
    var nowItem: GroupAudioItem? { state.item }
    /// «يشغّل الآن: …» on the map.
    var showsNowPlaying: Bool { state.item != nil && !left }
    var clockOffsetMs: Double { measuredOffsetMs ?? sessionClockOffset() }

    func name(of userId: String?) -> String {
        guard let userId else { return "" }
        return userId == myUserId ? "أنت" : (names()[userId] ?? "عضو")
    }

    var expectedPosition: Double { state.position(deviceNow: Date(), clockOffsetMs: clockOffsetMs) }

    // MARK: presentation

    func open(_ source: GroupAudioSource? = nil) {
        if let source { pickerSource = source }
        presented = true
        Task { await refresh() }
    }

    // MARK: server

    func refresh() async {
        lastFetchAt = Date()
        do {
            let r = try await backend.fetch()
            take(r)
        } catch GroupAudioBackendError.notDeployed {
            fallBackToLocal()
        } catch {}
    }

    private func take(_ r: GroupAudioReply) {
        if let o = r.clockOffsetMs { measuredOffsetMs = o }
        if backend.isShared { availability = .shared }
        apply(r.state)
    }

    /// An older server: radio for this phone only, with the same screens.
    private func fallBackToLocal() {
        guard backend.isShared else { return }
        backend = GroupAudioLocalBackend(me: myUserId, iLead: true)
        availability = .localOnly
        if stations.isEmpty { stations = GroupAudioCatalog.bundled }
    }

    private func loadCatalog() async {
        var list: [GroupAudioStation]?
        if backend.isShared {
            let url = Endpoints.apiBase.appendingPathComponent("api/outings/group-audio/catalog")
            for attempt in 0..<2 where list == nil {
                if attempt > 0 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
                if let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8)),
                   (resp as? HTTPURLResponse)?.statusCode == 200 { list = GroupAudioCatalog.decode(data) }
            }
        }
        let r = GroupAudioCatalog.resolve(server: list, shared: backend.isShared)
        stations = r.stations
        catalogOffline = r.offline
    }

    private func send(_ c: GroupAudioCommand) async {
        busy = true
        defer { busy = false }
        do {
            take(try await backend.send(c))
        } catch GroupAudioBackendError.notDeployed {
            fallBackToLocal()
            if let r = try? await backend.send(c) { take(r) }
        } catch let e as GroupAudioBackendError {
            errorText = e.arabic
        } catch {}
    }

    // MARK: controls

    func play(_ item: GroupAudioItem) async {
        if muted { duck(.unmute) }
        left = false
        await send(.play(item))
    }

    func playStation(_ s: GroupAudioStation) async { await play(s.item) }

    func togglePlay() async {
        guard state.item != nil else { return }
        if state.playing { await send(.pause(at: currentFilePosition)) } else { await send(.resume(at: currentFilePosition)) }
    }

    func next() async { await send(.next) }
    func stop() async { await send(.stop) }
    func queue(_ item: GroupAudioItem) async { await send(.queue(item)) }
    func setAllowAll(_ on: Bool) async { await send(.allowAll(on)) }

    /// «اسكت عندي»: only this phone goes quiet; the trip keeps listening.
    func mute() { duck(.mute) }
    func unmute() {
        left = false
        duck(.unmute)
    }

    /// «اطلع»: quiet, and «يشغّل الآن» hides until something new starts.
    func leave() {
        duck(.mute)
        left = true
    }

    func searchAudius(_ q: String) async {
        audiusSearching = true
        defer { audiusSearching = false }
        audiusResults = await AudiusAPI.search(q)
        if audiusResults.isEmpty { errorText = "ما لقينا شي في Audius. جرّب كلمة ثانية." }
    }

    private var currentFilePosition: Double? {
        guard let item = state.item, !item.live else { return nil }
        return engine.position ?? expectedPosition
    }

    // MARK: state in

    func apply(_ next: GroupAudioState) {
        let prev = state
        /* An older frame arriving late (HTTP reply after a newer socket frame): ignore it. */
        guard next.seq >= prev.seq || prev.seq == 0 || availability == .localOnly else { return }
        state = next
        if left, next.item?.id != prev.item?.id, next.item != nil {
            /* Something new started: show it again (still quiet until they unmute). */
            left = false
        }
        if next.item == nil { left = false }
        reconcile()
    }

    // MARK: player

    private func duck(_ e: GroupAudioDucking.Event) {
        var d = ducking
        let fx = d.handle(e)
        ducking = d
        for f in fx {
            switch f {
            case let .volume(v): engine.setVolume(v)
            case .pause: if engine.loadedURL != nil { engine.pause() }
            case .resume: reconcile(forceResync: true)
            }
        }
        if e == .navEnded || e == .pttEnded, state.item != nil, ducking.shouldPlay {
            /* NavVoice / PTT may have changed the category: take `.playback` back. */
            GroupAudioSession.activate()
            activated = true
        }
        updateNowPlaying()
    }

    private func interruption(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            guard engine.loadedURL != nil else { return }
            duck(.interruptionBegan)
        case .ended:
            guard ducking.shouldPlay == false else { return }
            let opts = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            duck(.interruptionEnded(shouldResume: opts.contains(.shouldResume)))
        @unknown default: break
        }
    }

    /// Bring this phone's player in line with the trip's state.
    func reconcile(forceResync: Bool = false) {
        guard let item = state.item, let url = item.streamURL else {
            if engine.loadedURL != nil { engine.unload() }
            status = .idle
            elapsed = nil
            stopTimer()
            GroupAudioDuck.musicOwnsSession = false
            /* Only give the session back if we took it: never cut a nav prompt or a PTT call short. */
            if activated {
                activated = false
                nowPlaying.clear()
                GroupAudioSession.deactivate()
            }
            return
        }
        guard state.playing, ducking.shouldPlay else {
            if engine.loadedURL != nil { engine.pause() }
            status = .paused
            GroupAudioDuck.musicOwnsSession = false
            updateNowPlaying()
            return
        }
        GroupAudioSession.activate()
        activated = true
        GroupAudioDuck.musicOwnsSession = true
        attachRemote()
        if engine.loadedURL != url {
            status = .loading
            engine.load(url, live: item.live, start: item.live ? 0 : expectedPosition, play: true)
        } else {
            if !item.live, forceResync || !engine.isPlaying { engine.seek(to: expectedPosition) }
            if item.live, forceResync {
                /* Back from a pause on a live stream: rejoin at the live edge, like everyone else. */
                engine.load(url, live: true, start: 0, play: true)
            } else if !engine.isPlaying {
                engine.play()
            }
        }
        engine.setVolume(ducking.volume)
        item.live ? stopTimer() : startTimer()
        updateNowPlaying()
    }

    private func playerEvent(_ e: GroupAudioPlayerEvent) {
        switch e {
        case .playing: status = .playing
        case .paused: status = state.playing && ducking.shouldPlay ? .loading : .paused
        case .buffering: status = .loading
        case let .failed(msg): status = .failed(msg)
        case .ended:
            /* The controller moves the trip on; everyone else just waits for the next state. */
            if canControl, state.by == myUserId || iLead() { Task { await next() } }
        }
        updateNowPlaying()
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: GroupAudioSync.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Drift correction for files: ±0.3 s nothing, ≤3 s rate nudge, beyond that seek.
    private func tick() {
        elapsed = engine.position
        if backend.isShared, Date().timeIntervalSince(lastFetchAt) > 30 { Task { await refresh() } }
        guard let item = state.item, !item.live, state.playing, ducking.shouldPlay, engine.isPlaying, let actual = engine.position else { return }
        let expected = expectedPosition
        lastDrift = GroupAudioSync.drift(expected: expected, actual: actual)
        switch GroupAudioSync.plan(expected: expected, actual: actual, rate: engine.rate) {
        case .none: break
        case let .rate(r): engine.setRate(r)
        case let .seek(p):
            guard Date().timeIntervalSince(lastSeekAt) > 4 else { return }
            lastSeekAt = Date()
            engine.setRate(1)
            engine.seek(to: p)
        }
    }

    // MARK: lock screen / CarPlay / steering wheel

    private func attachRemote() {
        nowPlaying.attach(.init(
            toggle: { [weak self] in self?.remoteToggle() },
            play: { [weak self] in self?.remotePlay() },
            pause: { [weak self] in self?.remotePause() },
            next: { [weak self] in
                guard let self, self.canControl, !self.state.queue.isEmpty else { return }
                Task { await self.next() }
            }
        ))
    }

    /// The controller's buttons drive the trip; a member's only mute / unmute their phone.
    private func remoteToggle() {
        if canControl { Task { await togglePlay() } } else { muted ? unmute() : mute() }
    }

    private func remotePlay() {
        if muted { unmute(); return }
        if canControl, !state.playing { Task { await togglePlay() } }
    }

    private func remotePause() {
        if canControl, state.playing { Task { await togglePlay() } } else { mute() }
    }

    private func updateNowPlaying() {
        guard let item = state.item else { return }
        let who = state.by.map { name(of: $0) } ?? ""
        let artist = [item.subtitle, who.isEmpty ? "" : "شغّلها \(who)"].filter { !$0.isEmpty }.joined(separator: " • ")
        nowPlaying.update(title: item.title, artist: artist, live: item.live, position: engine.position, duration: item.duration_s ?? engine.duration,
                          playing: state.playing && ducking.shouldPlay)
    }

    /// The outing is gone from this phone.
    func shutDown() {
        stopTimer()
        engine.unload()
        nowPlaying.clear()
        GroupAudioDuck.musicOwnsSession = false
        if activated { GroupAudioSession.deactivate() }
        activated = false
    }
}

/// One `GroupAudioCenter` per open outing (the map bar, the sheet and the live sheet share it).
@MainActor
enum GroupAudioCenters {
    private static var centers: [String: GroupAudioCenter] = [:]
    private static var closers = Set<AnyCancellable>()

    static func of(_ controller: LiveOutingController) -> GroupAudioCenter {
        let session = controller.session
        if let c = centers[session.id] { return c }
        let args = ProcessInfo.processInfo.arguments
        let member = args.contains("-SaryRadioMember")
        let iLead = { [weak session] in member ? false : session?.view?.iLead == true }
        let backend: GroupAudioBackend
        if session.isLocal {
            backend = GroupAudioLocalBackend(me: session.myUserId, iLead: !member && session.view?.iLead != false, shared: true)
        } else {
            backend = GroupAudioHTTPBackend(outingId: session.id)
        }
        let c = GroupAudioCenter(
            outingId: session.id, myUserId: session.myUserId, backend: backend, iLead: iLead,
            names: { [weak session] in (session?.view?.members ?? [:]).mapValues(\.display_name) },
            clockOffset: { [weak session] in session?.view?.clockOffsetMs ?? 0 }
        )
        centers[session.id] = c
        session.$closedReason.sink { r in
            guard r != nil else { return }
            DispatchQueue.main.async { drop(session.id) }
        }.store(in: &closers)
        #if DEBUG
        /* UI tests: «أبو فهد» (the leader) starts إذاعة القرآن الكريم for the trip. */
        if args.contains("-SaryRadioRemote"), let local = backend as? GroupAudioLocalBackend {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let s = GroupAudioState(item: GroupAudioCatalog.bundled[0].item, playing: true, by: "00000000-0000-4000-8000-000000000002",
                                        started_at: ISODate.string(Date()), seq: 1, at: ISODate.string(Date()))
                local.simulateRemote(s)
                c.apply(s)
            }
        }
        if args.contains("-SaryOpenRadio") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { c.open() }
        }
        #endif
        return c
    }

    /// Any center (the media sheet's «إذاعة الطلعة» card).
    static func existing(_ outingId: String) -> GroupAudioCenter? { centers[outingId] }

    static func drop(_ outingId: String) {
        centers[outingId]?.shutDown()
        centers[outingId] = nil
    }
}
