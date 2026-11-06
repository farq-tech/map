import AVFoundation
import Combine
import Foundation
import UIKit

/// `voice_note` frames from the outing socket (LiveChannel posts, the session's center listens).
enum VoiceNoteEvents {
    static let name = Notification.Name("sary.voiceNotes.note")

    static func post(outingId: String, raw: Any?) {
        guard let raw, !(raw is NSNull) else { return }
        NotificationCenter.default.post(name: name, object: nil, userInfo: ["outing": outingId, "note": raw])
    }

    static func decode(_ raw: Any?) -> VoiceNote? {
        guard let raw, JSONSerialization.isValidJSONObject(raw), let d = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(VoiceNote.self, from: d)
    }
}

/// The open outing's voice-note center, for views that only know the outing (the channel sheet).
@MainActor
enum VoiceNoteCenters {
    private static var all: [String: WeakBox] = [:]
    private final class WeakBox { weak var center: VoiceNoteCenter?; init(_ c: VoiceNoteCenter) { center = c } }

    static func register(_ c: VoiceNoteCenter) { all[c.outingId] = WeakBox(c) }
    static func of(_ outingId: String) -> VoiceNoteCenter? { all[outingId]?.center }
}

/// The recording's live level, apart from the center so only the record bar redraws 20×/s.
@MainActor
final class VoiceNoteMeter: ObservableObject {
    @Published var levels: [Float] = []
    @Published var elapsed: TimeInterval = 0
    static let bars = 36

    func reset() {
        levels = []
        elapsed = 0
    }

    func push(_ l: Float, elapsed e: TimeInterval) {
        elapsed = e
        levels.append(l)
        if levels.count > Self.bars { levels.removeFirst(levels.count - Self.bars) }
    }
}

/// «رسالة صوتية» for one outing: record → send (outbox) → everyone on the channel hears it.
/// Lives with the `OutingSession` (like the live walkie-talkie), so a note plays with the
/// screen locked when iOS wakes the app through the PushToTalk channel.
@MainActor
final class VoiceNoteCenter: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Recording: whole seconds so far (the meter has the fine detail).
        case recording(seconds: Int)
    }

    /// The «فهد يتكلم…» card.
    struct Playing: Equatable {
        var id: String
        var userId: String
        var name: String
        var color: UInt32
        var progress: Double
        var loading: Bool
        var waveform: [Float]
        var seconds: Int
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var playing: Playing?
    /// Recordings still on their way to the server.
    @Published private(set) var sending = 0
    /// «الرسائل الصوتية» for the current channel, newest first.
    @Published private(set) var list: [VoiceNote] = []
    /// Others' notes on this channel not heard yet.
    @Published private(set) var unheard = 0
    /// «تشغيل تلقائي» off: the newest fresh note waits here, on a card with a play button.
    @Published private(set) var offer: Playing?
    /// A short sentence for a toast.
    @Published private(set) var notice: String?
    let meter = VoiceNoteMeter()

    let outingId: String
    let me: String
    private let backend: VoiceNoteBackend?
    private let defaults: UserDefaults
    private weak var walkie: OutingWalkieTalkie?
    private let recorder: VoiceNoteRecorder
    private let uploader: VoiceNoteUploader
    private let player = VoiceNotePlayer()
    private var inbox: VoiceNoteInbox
    private var audioCache: [String: Data] = [:]
    private var cacheOrder: [String] = []
    /// How the current note got the speaker (to give it back the same way).
    private enum Speaker { case app, system }
    private var speaker: Speaker?
    private var bag = Set<AnyCancellable>()
    private var observer: NSObjectProtocol?
    private var pumpTimer: Timer?
    private var closed = false
    var nameOf: (String) -> String? = { _ in nil }
    var colorOf: (String) -> UInt32 = { _ in 0xFFFFFF }
    var isForeground: () -> Bool = { UIApplication.shared.applicationState == .active }

    static func monoMs() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }

    init(outingId: String, me: String, backend: VoiceNoteBackend?, walkie: OutingWalkieTalkie?, defaults: UserDefaults = .standard,
         recorder: VoiceNoteRecorder? = nil, outboxDir: URL = VoiceNoteUploader.defaultDir) {
        self.outingId = outingId
        self.me = me
        self.backend = backend
        self.walkie = walkie
        self.defaults = defaults
        self.recorder = recorder ?? VoiceNoteRecorder()
        uploader = VoiceNoteUploader(outingId: outingId, backend: backend, defaults: defaults, dir: outboxDir)
        inbox = VoiceNoteInbox(heard: VoiceNoteHeardStore.load(outingId, defaults: defaults))
        sending = uploader.pending
        self.recorder.onTick = { [weak self] t, l in
            guard let self else { return }
            self.meter.push(l, elapsed: t)
            let s = Int(t)
            if case let .recording(cur) = self.phase, cur != s { self.phase = .recording(seconds: s) }
        }
        self.recorder.onLimit = { [weak self] in
            self?.say("وصلت الدقيقة — انرسلت")
            self?.send()
        }
        uploader.onOutcome = { [weak self] item, o in self?.uploaded(item, o) }
        player.onProgress = { [weak self] id, p in
            guard let self, self.playing?.id == id else { return }
            self.playing?.progress = p
        }
        player.onFinish = { [weak self] id, done in self?.playbackEnded(id, completed: done) }
    }

    var channel: String { walkie?.channelId ?? PTTChannels.defaultId }
    private var muted: Bool { walkie?.muted ?? false }
    var isRecording: Bool { if case .recording = phase { return true }; return false }

    // MARK: lifecycle

    func attach() {
        VoiceNoteCenters.register(self)
        observer = NotificationCenter.default.addObserver(forName: VoiceNoteEvents.name, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, (n.userInfo?["outing"] as? String) == self.outingId, let note = VoiceNoteEvents.decode(n.userInfo?["note"]) else { return }
                self.receive(note)
            }
        }
        /* Tuned to another channel or muted: what was queued for the old one never plays by itself. */
        walkie?.$channelId.removeDuplicates().dropFirst().sink { [weak self] ch in
            guard let self else { return }
            self.inbox.dropQueue(except: ch)
            self.refreshList()
            Task { await self.sync() }
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).sink { [weak self] _ in
            self?.uploader.kick()
            Task { await self?.sync() }
        }.store(in: &bag)
        /* A live talker or my own transmission holds the air: a note waits for it. */
        pumpTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pump() }
        }
        uploader.kick()
        Task { await sync() }
    }

    /// The socket is back: send what waited, fetch what we missed.
    func linkLive() {
        uploader.kick()
        Task { await sync() }
    }

    func close(leftOuting: Bool) {
        closed = true
        if isRecording { recorder.cancel(); releaseSpeaker(.app) }
        phase = .idle
        player.stop()
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
        pumpTimer?.invalidate()
        pumpTimer = nil
        bag.removeAll()
        if leftOuting {
            uploader.discardAll()
            defaults.removeObject(forKey: VoiceNoteHeardStore.prefix + outingId)
        } else {
            uploader.stop()
        }
    }

    // MARK: talking

    /// The talk button, in «رسالة صوتية» mode: idle → record; recording → send.
    func talkTapped() {
        if isRecording { return send() }
        guard !closed else { return }
        if muted { return say("القناة مكتومة — شغّلها من الإعدادات") }
        if !(MicPermission.granted || recorder.useTestTone) {
            Task {
                if await MicPermission.request() { self.say("جاهز — اضغط وسجّل رسالتك") }
                else { self.say("اسمح بالميكروفون من الإعدادات عشان تسجّل رسالة") }
            }
            return
        }
        /* My message cuts whatever note is playing (it stays in the list). */
        if playing != nil { player.stop() }
        guard VoiceNoteAudio.acquire(why: "record") else { return say("تعذّر فتح الميكروفون") }
        do {
            meter.reset()
            try recorder.start()
            phase = .recording(seconds: 0)
            if PTTRadioSounds.enabled(defaults) { PTTDiagnosticsLog.shared.add("voice", "record start") }
        } catch {
            VoiceNoteAudio.release()
            say("تعذّر بدء التسجيل")
        }
    }

    /// «أرسل».
    func send() {
        guard isRecording else { return }
        let take = recorder.stop()
        phase = .idle
        VoiceNoteAudio.release()
        guard let take else { return say("التسجيل قصير — اضغط وتكلم ثم أرسل") }
        let ch = channel
        sending += 1
        Task {
            /* Denoised (DeepFilterNet3, on the phone) and ≈24 kbps AAC before it goes (a minute ≈ 200 KB).
               The DEBUG test tone is not speech: it skips the denoise so the receive tests stay exact. */
            let raw = take.file
            let denoise = !recorder.useTestTone
            let file = await Task.detached(priority: .userInitiated) { VoiceNoteRecorder.transcode(raw, denoise: denoise) }.value
            guard uploader.enqueue(file: file, channel: ch, durationMs: take.durationMs, recordedAt: take.stoppedAt) != nil else {
                sending = uploader.pending
                return say("ما قدرنا نحفظ التسجيل")
            }
            sending = uploader.pending
            PTTDiagnosticsLog.shared.add("voice", "queued \(take.durationMs) ms on \(PTTChannels.isPublic(ch) ? ch : "private")")
        }
    }

    /// «احذف»: nothing is sent, nothing kept.
    func cancel() {
        guard isRecording else { return }
        recorder.cancel()
        phase = .idle
        VoiceNoteAudio.release()
        say("انحذف التسجيل")
    }

    private func uploaded(_ item: VoiceNoteOutboxItem, _ o: VoiceNoteUploader.Outcome) {
        sending = uploader.pending
        switch o {
        case let .sent(note):
            PTTDiagnosticsLog.shared.add("voice", "sent (\(note.duration_ms) ms)")
            inbox.receive(note, nowMs: Self.monoMs(), me: me, channel: channel, muted: true)
            inbox.markHeard(note.id)
            refreshList()
        case let .retrying(n):
            if n == 1 { say("الشبكة ضعيفة — بنرسلها أول ما يرجع الاتصال") }
        case let .dropped(why):
            PTTDiagnosticsLog.shared.add("voice", "dropped: \(why)")
            say(why == "outing_ended" ? "انتهت الطلعة — ما انرسلت الرسالة" : "ما انرسلت الرسالة")
        }
    }

    // MARK: hearing

    /// A note from the socket (or a sync, or a push).
    func receive(_ n: VoiceNote) {
        guard !closed else { return }
        let auto = autoplay
        let known = list.contains { $0.id == n.id } || inbox.heard.contains(n.id)
        let queued = inbox.receive(n, nowMs: Self.monoMs(), me: me, channel: channel, muted: muted || !auto)
        refreshList()
        if queued { return pump() }
        /* «تشغيل تلقائي» off: what would have played waits on a card with ▶︎. */
        if !auto, !known, VoiceNotePolicy.shouldAutoPlay(note: n, ageMs: inbox.ageMs(n.id, nowMs: Self.monoMs()), me: me, channel: channel, muted: muted, heard: false) {
            offer = Playing(id: n.id, userId: n.user_id, name: nameOf(n.user_id) ?? "عضو", color: colorOf(n.user_id), progress: 0, loading: false, waveform: [], seconds: n.seconds)
        }
    }

    /// «تشغيل تلقائي للرسائل الصوتية» (الإعدادات › الصوت واللاسلكي), on by default.
    var autoplay: Bool { VoiceAutoplay.isOn(defaults) }

    /// The card's ▶︎.
    func playOffer() {
        guard let o = offer else { return }
        offer = nil
        play(o.id)
    }

    func dismissOffer() { offer = nil }

    /// iOS woke us with a voice-note push: the system already shows the speaker and opens its
    /// session; fetch the note and play it there.
    func pushed(_ p: VoiceNotePush) {
        guard p.outingId == outingId else { return }
        if !autoplay, !isForeground() {
            /* Woken for it, but it must not play by itself: give the system its session back and say it waits. */
            walkie?.returnSystemSpeaker()
            Notifier.post(title: "\(p.speaker) · قناة الطلعة", body: "🎙️ رسالة صوتية — افتح الطلعة وتسمعها", outingId: outingId, kind: "voice_note")
        }
        receive(p.note)
    }

    /// The channel's notes from the server (after a reconnect, on screen, on a channel change).
    func sync() async {
        guard let backend, !closed else { return }
        let ch = channel
        guard let notes = try? await backend.listVoiceNotes(outingId, channel: ch), ch == channel else { return }
        inbox.prune(channel: ch, keep: Set(notes.map(\.id)))
        for n in notes.sorted(by: { $0.recorded_at < $1.recorded_at }) { _ = inbox.receive(n, nowMs: Self.monoMs(), me: me, channel: ch, muted: muted) }
        refreshList()
        pump()
    }

    /// «الرسائل الصوتية» ▶︎ (any note, any age).
    func play(_ id: String) {
        guard let n = list.first(where: { $0.id == id }) else { return }
        if playing?.id == id { return player.stop() }
        if isRecording { return }
        start(n)
    }

    func stopPlaying() { player.stop() }

    /// Next queued note, if the air is free.
    private func pump() {
        guard !closed, playing == nil, !isRecording, walkie?.isQuiet ?? true else { return }
        guard let n = inbox.nextToPlay(nowMs: Self.monoMs()) else { return }
        start(n)
    }

    private func start(_ n: VoiceNote) {
        if offer?.id == n.id { offer = nil }
        let name = nameOf(n.user_id) ?? "عضو"
        playing = Playing(id: n.id, userId: n.user_id, name: name, color: colorOf(n.user_id), progress: 0, loading: true, waveform: [], seconds: n.seconds)
        Task {
            guard let data = await audio(n) else {
                if playing?.id == n.id { playing = nil }
                inbox.markHeard(n.id)
                refreshList()
                return say("انتهت صلاحية هذي الرسالة")
            }
            let pcm = await Task.detached(priority: .userInitiated) { VoiceNotePlayer.decode(data) }.value
            guard playing?.id == n.id else { return }
            guard let pcm else {
                playing = nil
                inbox.markHeard(n.id)
                return say("ما قدرنا نشغّل الرسالة")
            }
            playing?.waveform = VoiceNotePlayer.waveform(pcm)
            acquireSpeaker(name: name) { [weak self] how in
                guard let self, self.playing?.id == n.id else {
                    if let how { self?.releaseSpeaker(how) }
                    return
                }
                guard let how else {
                    /* Locked, and no PushToTalk channel to borrow: a time-sensitive note says it is waiting. */
                    self.playing = nil
                    Notifier.post(title: "\(name) · قناة الطلعة", body: "🎙️ رسالة صوتية (\(n.seconds) ث) — افتح الطلعة وتسمعها", outingId: self.outingId, kind: "voice_note")
                    return
                }
                self.speaker = how
                self.playing?.loading = false
                if !self.player.play(pcm, id: n.id) {
                    self.releaseSpeaker(how)
                    self.speaker = nil
                    self.playing = nil
                    self.say("ما قدرنا نشغّل الرسالة")
                }
            }
        }
    }

    /// On screen: our own session. Locked / in the background: the PushToTalk system session.
    private func acquireSpeaker(name: String, _ done: @escaping (Speaker?) -> Void) {
        if isForeground() {
            return done(VoiceNoteAudio.acquire(why: "play") ? .app : nil)
        }
        var answered = false
        let ok = walkie?.borrowSystemSpeaker(name: name) {
            guard !answered else { return }
            answered = true
            done(.system)
        } ?? false
        if !ok {
            /* No system channel: in the background our own session may still be allowed (audio mode). */
            return done(VoiceNoteAudio.acquire(why: "play bg") ? .app : nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard !answered else { return }
            answered = true
            PTTDiagnosticsLog.shared.add("voice", "system session never came: notification")
            self?.walkie?.returnSystemSpeaker()
            done(nil)
        }
    }

    private func releaseSpeaker(_ how: Speaker) {
        switch how {
        case .app: VoiceNoteAudio.release()
        case .system: walkie?.returnSystemSpeaker()
        }
    }

    private func playbackEnded(_ id: String, completed: Bool) {
        if let how = speaker { releaseSpeaker(how) }
        speaker = nil
        inbox.markHeard(id)
        VoiceNoteHeardStore.save(inbox.heard, outingId: outingId, defaults: defaults)
        if playing?.id == id { playing = nil }
        refreshList()
        /* The next one (a queue after a tunnel) a breath later, like a radio. */
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.pump() }
    }

    private func audio(_ n: VoiceNote) async -> Data? {
        if let d = audioCache[n.id] { return d }
        guard let backend, let d = try? await backend.fetchVoiceNote(n) else { return nil }
        audioCache[n.id] = d
        cacheOrder.append(n.id)
        while cacheOrder.count > 12 { audioCache[cacheOrder.removeFirst()] = nil }
        return d
    }

    private func refreshList() {
        let wall = Date().timeIntervalSince1970 * 1000
        let l = inbox.list(channel: channel, nowMs: wall)
        if l != list { list = l }
        let u = inbox.unheard(channel: channel, me: me, nowMs: wall)
        if u != unheard { unheard = u }
    }

    func isHeard(_ id: String) -> Bool { inbox.heard.contains(id) }

    private var noticeTimer: Timer?

    private func say(_ t: String) {
        notice = t
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.notice = nil }
        }
    }

    // MARK: the talk button's look

    /// What the talk button shows in «رسالة صوتية» mode (nil: the live walkie-talkie decides).
    func buttonState() -> PTTStateUI? {
        if case let .recording(s) = phase {
            return .talking(seconds: s, remaining: max(0, Int(VoiceNotePolicy.maxRecordMs / 1000) - s))
        }
        if let p = playing { return .listening(name: p.name, color: p.color) }
        return nil
    }

    #if DEBUG
    /// Tests: what the inbox holds.
    var debugInbox: VoiceNoteInbox { inbox }
    #endif
}

/// The demo outing (no server): notes stay on this phone, and «أبو فهد» answers each one a
/// moment later with the same recording — a second member to hear, for the UI test.
@MainActor
final class DemoVoiceNoteBackend: VoiceNoteBackend {
    private var store: [String: (VoiceNote, Data)] = [:]
    let friendId: String
    let me: String
    var deliver: (VoiceNote) -> Void = { _ in }
    var replyDelay: TimeInterval = 1.2

    init(friendId: String, me: String) {
        self.friendId = friendId
        self.me = me
    }

    func uploadVoiceNote(_ outingId: String, audio: Data, durationMs: Int, channel: String, clientId: String, ageMs: Int) async throws -> VoiceNote {
        let mine = make(outingId, user: me, channel: channel, ms: durationMs, data: audio)
        let reply = make(outingId, user: friendId, channel: channel, ms: durationMs, data: audio)
        DispatchQueue.main.asyncAfter(deadline: .now() + replyDelay) { [weak self] in self?.deliver(reply) }
        return mine
    }

    func listVoiceNotes(_ outingId: String, channel: String) async throws -> [VoiceNote] {
        store.values.map(\.0).filter { $0.channel == channel && $0.user_id == friendId }
    }

    func fetchVoiceNote(_ note: VoiceNote) async throws -> Data {
        guard let d = store[note.id]?.1 else { throw OutingAPIError(code: "clip_gone", status: 404) }
        return d
    }

    private func make(_ outingId: String, user: String, channel: String, ms: Int, data: Data) -> VoiceNote {
        let id = UUID().uuidString.lowercased()
        let n = VoiceNote(id: id, channel: channel, user_id: user, mime: "audio/mp4", duration_ms: ms, bytes: data.count,
                          recorded_at: ISODate.string(Date()), created_at: ISODate.string(Date()),
                          expires_at: ISODate.string(Date().addingTimeInterval(24 * 3600)), age_ms: 0, url: "/api/outings/\(outingId)/voice-notes/\(id)")
        store[id] = (n, data)
        return n
    }
}
