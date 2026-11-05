import Foundation

/// «رسالة صوتية» — the walkie-talkie as voice notes (server: apps/api/lib/outings/voice-notes.js).
///
/// Tap the talk button: recording starts (≤ 60 s, timer + waveform). «أرسل» uploads it over
/// HTTP (retried from an outbox until it gets through); «احذف» throws it away. Everyone on the
/// same «تردد» hears it play by itself with the radio cues and the «صوت اللاسلكي» level, if it
/// is still recent (≤ 2 min); older ones wait in «الرسائل الصوتية» with a play button.
///
/// The live mode («مباشر (تجريبي)», `OutingWalkieTalkie`) stays as an option in the settings.

/// «طريقة اللاسلكي»: how the talk button works.
enum PTTTalkMode: String, CaseIterable, Hashable {
    /// Record, then send (the default).
    case notes
    /// Hold to talk live (the old way; experimental).
    case live

    static let key = "sary.ptt.talkMode"
    static let `default` = PTTTalkMode.notes

    static func current(_ defaults: UserDefaults = .standard) -> PTTTalkMode {
        defaults.string(forKey: key).flatMap(PTTTalkMode.init(rawValue:)) ?? .default
    }

    var label: String {
        switch self {
        case .notes: "رسالة صوتية"
        case .live: "مباشر (تجريبي)"
        }
    }
}

/// One voice note as the server describes it (never the audio itself).
struct VoiceNote: Codable, Equatable, Identifiable {
    var id: String
    var channel: String
    var user_id: String
    var mime: String
    var duration_ms: Int
    var bytes: Int?
    var recorded_at: String
    var created_at: String?
    var expires_at: String
    /// Server-measured age when it was sent to us (the phone's clock may be wrong).
    var age_ms: Double?
    /// `/api/outings/:id/voice-notes/:noteId`, needs the Bearer token.
    var url: String

    var seconds: Int { max(1, Int((Double(duration_ms) / 1000).rounded())) }
}

/// Pure rules: what plays by itself, what waits in the list. Unit-tested.
enum VoiceNotePolicy {
    /// A note plays by itself only this long after it was recorded (server: NOTE_AUTOPLAY_MS).
    static let autoPlayMs = 120_000.0
    static let maxRecordMs = 60_000.0
    /// Shorter than this is a slip of the finger: not sent.
    static let minRecordMs = 600.0

    /// Age now, from the server's age when it reached us plus our own monotonic time since.
    static func ageMs(serverAgeMs: Double?, receivedAtMs: Double, nowMs: Double, recordedAt: String) -> Double {
        if let a = serverAgeMs { return a + max(0, nowMs - receivedAtMs) }
        /* No server age (a push without one): our clock against recorded_at. */
        guard let d = ISODate.parse(recordedAt) else { return .infinity }
        return max(0, nowMs - d.timeIntervalSince1970 * 1000)
    }

    static func shouldAutoPlay(note: VoiceNote, ageMs: Double, me: String, channel: String, muted: Bool, heard: Bool) -> Bool {
        note.user_id != me && note.channel == channel && !muted && !heard && ageMs < autoPlayMs
    }
}

/// What this phone knows of the voice notes of one outing: received, heard, waiting to play.
/// Pure (no audio, no network), so the auto-play rules are tested on their own.
struct VoiceNoteInbox: Equatable {
    struct Entry: Equatable {
        var note: VoiceNote
        /// Our monotonic ms when the server's `age_ms` was measured for us.
        var receivedAtMs: Double
    }

    private(set) var entries: [String: Entry] = [:]
    private(set) var heard: Set<String> = []
    /// Fresh notes not yet played, oldest first.
    private(set) var queue: [String] = []

    init(heard: Set<String> = []) { self.heard = heard }

    /// A note from the socket, a push or a sync. True when it was queued to play by itself now.
    @discardableResult
    mutating func receive(_ n: VoiceNote, nowMs: Double, me: String, channel: String, muted: Bool) -> Bool {
        let known = entries[n.id] != nil
        if !known { entries[n.id] = Entry(note: n, receivedAtMs: nowMs) }
        guard !known, !queue.contains(n.id) else { return false }
        let age = ageMs(n.id, nowMs: nowMs)
        guard VoiceNotePolicy.shouldAutoPlay(note: n, ageMs: age, me: me, channel: channel, muted: muted, heard: heard.contains(n.id)) else { return false }
        queue.append(n.id)
        queue.sort { (entries[$0]?.note.recorded_at ?? "") < (entries[$1]?.note.recorded_at ?? "") }
        return true
    }

    func ageMs(_ id: String, nowMs: Double) -> Double {
        guard let e = entries[id] else { return .infinity }
        return VoiceNotePolicy.ageMs(serverAgeMs: e.note.age_ms, receivedAtMs: e.receivedAtMs, nowMs: nowMs, recordedAt: e.note.recorded_at)
    }

    /// The next note to play by itself; stale ones are dropped from the queue (they stay in the list).
    mutating func nextToPlay(nowMs: Double) -> VoiceNote? {
        while let id = queue.first {
            queue.removeFirst()
            guard let e = entries[id], !heard.contains(id) else { continue }
            if ageMs(id, nowMs: nowMs) < VoiceNotePolicy.autoPlayMs { return e.note }
        }
        return nil
    }

    var hasQueued: Bool { !queue.isEmpty }

    mutating func markHeard(_ id: String) {
        heard.insert(id)
        queue.removeAll { $0 == id }
    }

    /// Tuned away or muted: nothing queued for the old channel plays by itself any more.
    mutating func dropQueue(except channel: String) {
        queue.removeAll { entries[$0]?.note.channel != channel }
    }

    mutating func clearQueue() { queue = [] }

    /// «الرسائل الصوتية» for one channel, newest first, not expired.
    func list(channel: String, nowMs: Double) -> [VoiceNote] {
        entries.values.map(\.note)
            .filter { $0.channel == channel && (ISODate.parse($0.expires_at).map { $0.timeIntervalSince1970 * 1000 > nowMs } ?? true) }
            .sorted { $0.recorded_at > $1.recorded_at }
    }

    /// Others' notes on `channel` not heard yet (the badge).
    func unheard(channel: String, me: String, nowMs: Double) -> Int {
        list(channel: channel, nowMs: nowMs).filter { $0.user_id != me && !heard.contains($0.id) }.count
    }

    /// Forget what the server no longer has (a sync of one channel).
    mutating func prune(channel: String, keep ids: Set<String>) {
        for (id, e) in entries where e.note.channel == channel && !ids.contains(id) {
            entries[id] = nil
            queue.removeAll { $0 == id }
        }
    }
}

/// Saved per outing: which notes were heard (so a relaunch never replays them).
enum VoiceNoteHeardStore {
    static let prefix = "sary.voiceNotes.heard."
    static let cap = 300

    static func load(_ outingId: String, defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: prefix + outingId) ?? [])
    }

    static func save(_ ids: Set<String>, outingId: String, defaults: UserDefaults) {
        defaults.set(Array(ids.sorted().suffix(cap)), forKey: prefix + outingId)
    }

    static func forgetAll(defaults: UserDefaults = .standard) {
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(prefix) { defaults.removeObject(forKey: k) }
    }
}

/// The few fields of a `voice_note` Push to Talk push (built on the PushToTalk delegate's thread).
struct VoiceNotePush: Equatable, Sendable {
    var outingId: String
    var speaker: String
    var noteId: String
    var channel: String
    var userId: String
    var durationMs: Int
    var recordedAt: String
    var url: String

    nonisolated static func parse(_ p: [String: Any], fallbackOuting: String) -> VoiceNotePush? {
        guard p["type"] as? String == "voice_note", let n = p["note"] as? [String: Any],
              let id = n["id"] as? String, let url = n["url"] as? String else { return nil }
        return VoiceNotePush(
            outingId: (p["outing_id"] as? String) ?? fallbackOuting,
            speaker: (p["activeSpeaker"] as? String) ?? "",
            noteId: id,
            channel: (n["channel"] as? String) ?? (p["channel"] as? String) ?? PTTChannels.defaultId,
            userId: (n["user_id"] as? String) ?? (p["user_id"] as? String) ?? "",
            durationMs: (n["duration_ms"] as? NSNumber)?.intValue ?? 1000,
            recordedAt: (n["recorded_at"] as? String) ?? ISODate.string(Date()),
            url: url
        )
    }

    var note: VoiceNote {
        VoiceNote(id: noteId, channel: channel, user_id: userId, mime: "audio/mp4", duration_ms: durationMs, bytes: nil,
                  recorded_at: recordedAt, created_at: nil, expires_at: ISODate.string(Date().addingTimeInterval(24 * 3600)), age_ms: nil, url: url)
    }
}
