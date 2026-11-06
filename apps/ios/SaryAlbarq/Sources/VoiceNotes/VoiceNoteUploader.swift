import Foundation

/// The server side of «رسالة صوتية» (apps/api/lib/outings/voice-notes.js).
protocol VoiceNoteBackend: AnyObject {
    /// POST the recording. Same `clientId` again = the same note (a retry), never a second one.
    func uploadVoiceNote(_ outingId: String, audio: Data, durationMs: Int, channel: String, clientId: String, ageMs: Int) async throws -> VoiceNote
    /// The channel's notes of the last 24 h (no audio), newest first.
    func listVoiceNotes(_ outingId: String, channel: String) async throws -> [VoiceNote]
    /// One note's audio bytes.
    func fetchVoiceNote(_ note: VoiceNote) async throws -> Data
}

extension OutingsAPI: VoiceNoteBackend {
    struct VoiceNoteBox: Decodable { var note: VoiceNote }
    struct VoiceNoteListBox: Decodable { var notes: [VoiceNote] }

    func uploadVoiceNote(_ outingId: String, audio: Data, durationMs: Int, channel: String, clientId: String, ageMs: Int) async throws -> VoiceNote {
        var req = URLRequest(url: base.appendingPathComponent("api/outings/\(outingId)/voice-notes"), timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(String(durationMs), forHTTPHeaderField: "X-Clip-Duration-Ms")
        req.setValue(channel, forHTTPHeaderField: "X-Ptt-Channel")
        req.setValue(clientId, forHTTPHeaderField: "X-Client-Id")
        req.setValue(String(max(0, ageMs)), forHTTPHeaderField: "X-Clip-Age-Ms")
        let sent = tokenProvider()
        if let t = sent { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        req.httpBody = audio
        let (data, resp) = try await raw(req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401, let sent { onUnauthorized(sent) }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw OutingAPIError(code: obj?["error"] as? String ?? "http_\(status)", status: status)
        }
        guard let box = try? JSONDecoder().decode(VoiceNoteBox.self, from: data) else { throw OutingAPIError(code: "bad_response", status: status) }
        return box.note
    }

    func listVoiceNotes(_ outingId: String, channel: String) async throws -> [VoiceNote] {
        let c = channel.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(["-"])) ?? "1"
        let r: VoiceNoteListBox = try await call("GET", "/\(outingId)/voice-notes", query: "channel=\(c)")
        return r.notes
    }

    func fetchVoiceNote(_ note: VoiceNote) async throws -> Data {
        let path = note.url.hasPrefix("/") ? String(note.url.dropFirst()) : note.url
        var req = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 20)
        if let t = tokenProvider() { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await raw(req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw OutingAPIError(code: status == 404 ? "clip_gone" : "http_\(status)", status: status) }
        return data
    }
}

/// A recording waiting to go out. Kept on disk until the server has it, so a tunnel, a dead
/// network or the app being killed only delays it.
struct VoiceNoteOutboxItem: Codable, Equatable {
    var clientId: String
    var outingId: String
    var channel: String
    var durationMs: Int
    /// Wall clock when recording stopped (for the age the server stores; survives a relaunch).
    var recordedAt: Date
    var file: String
    var attempts = 0
}

/// Uploads voice notes in order, retrying with backoff until each one is stored. One per outing.
@MainActor
final class VoiceNoteUploader {
    enum Outcome: Equatable { case sent(VoiceNote), retrying(attempt: Int), dropped(String) }

    private let outingId: String
    private let backend: VoiceNoteBackend?
    private let dir: URL
    private let defaults: UserDefaults
    private var items: [VoiceNoteOutboxItem]
    private var running = false
    private var retry: Task<Void, Never>?
    var onOutcome: (VoiceNoteOutboxItem, Outcome) -> Void = { _, _ in }
    var now: () -> Date = { Date() }

    /// Retry waits (s): quick at first (a tunnel), then patient.
    nonisolated static let backoff: [Double] = [1, 2, 4, 8, 15, 30]
    /// Older than this it would only be a stale message in the list: give up on it.
    nonisolated static let giveUpAfter: TimeInterval = 6 * 3600

    nonisolated static let keyPrefix = "sary.voiceNotes.outbox."

    init(outingId: String, backend: VoiceNoteBackend?, defaults: UserDefaults = .standard, dir: URL = VoiceNoteUploader.defaultDir) {
        self.outingId = outingId
        self.backend = backend
        self.defaults = defaults
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let saved = defaults.data(forKey: Self.keyPrefix + outingId).flatMap { try? JSONDecoder().decode([VoiceNoteOutboxItem].self, from: $0) } ?? []
        items = saved.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.file).path) }
    }

    nonisolated static var defaultDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VoiceNotesOutbox", isDirectory: true)
    }

    var pending: Int { items.count }

    /// A finished recording: move it into the outbox and start sending.
    func enqueue(file: URL, channel: String, durationMs: Int, recordedAt: Date) -> VoiceNoteOutboxItem? {
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let name = "\(id).m4a"
        let dest = dir.appendingPathComponent(name)
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: file, to: dest)
        } catch {
            return nil
        }
        let item = VoiceNoteOutboxItem(clientId: id, outingId: outingId, channel: channel, durationMs: durationMs, recordedAt: recordedAt, file: name)
        items.append(item)
        save()
        kick()
        return item
    }

    /// The link is back / the app came forward: try now instead of waiting out the backoff.
    func kick() {
        retry?.cancel()
        retry = nil
        guard !running else { return }
        Task { await drain() }
    }

    func stop() {
        retry?.cancel()
        retry = nil
    }

    private func drain() async {
        guard !running, let backend else { return }
        running = true
        defer { running = false }
        while let item = items.first {
            let url = dir.appendingPathComponent(item.file)
            if now().timeIntervalSince(item.recordedAt) > Self.giveUpAfter {
                finish(item, .dropped("too_old"))
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                finish(item, .dropped("missing"))
                continue
            }
            do {
                let age = Int(max(0, now().timeIntervalSince(item.recordedAt)) * 1000)
                let note = try await backend.uploadVoiceNote(outingId, audio: data, durationMs: item.durationMs, channel: item.channel, clientId: item.clientId, ageMs: age)
                finish(item, .sent(note))
            } catch let e as OutingAPIError where Self.isFinal(e) {
                finish(item, .dropped(e.code))
            } catch {
                var it = item
                it.attempts += 1
                items[0] = it
                save()
                onOutcome(it, .retrying(attempt: it.attempts))
                let wait = Self.backoff[min(it.attempts - 1, Self.backoff.count - 1)]
                retry = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    await self?.drain()
                }
                return
            }
        }
    }

    /// Errors no retry will fix (not a member any more, trip over, a bad file, a private channel closed).
    nonisolated static func isFinal(_ e: OutingAPIError) -> Bool {
        if e.status == 429 || e.status == 0 || e.status >= 500 { return false }
        return (400..<500).contains(e.status)
    }

    private func finish(_ item: VoiceNoteOutboxItem, _ o: Outcome) {
        items.removeAll { $0.clientId == item.clientId }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(item.file))
        save()
        onOutcome(item, o)
    }

    /// Left the trip / it ended: nothing of it stays on the phone.
    func discardAll() {
        stop()
        for it in items { try? FileManager.default.removeItem(at: dir.appendingPathComponent(it.file)) }
        items = []
        save()
    }

    private func save() {
        if items.isEmpty { defaults.removeObject(forKey: Self.keyPrefix + outingId) }
        else if let d = try? JSONEncoder().encode(items) { defaults.set(d, forKey: Self.keyPrefix + outingId) }
    }
}
