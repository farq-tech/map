import Foundation
import os

/// «سجل القناة»: what the live link and the walkie-talkie did, line by line, so a field
/// test comes back with exact failure reasons (Settings of the outing → «سجل القناة» → share).
///
/// PRIVACY: only events, close codes, states and counts. Never a token, a position, a
/// name, an outing id or audio. Kept on this phone (Caches), the newest `maxLines` only,
/// and leaves it only when the person taps share.
final class PTTDiagnosticsLog: @unchecked Sendable {
    static let shared = PTTDiagnosticsLog()
    static let maxLines = 600
    private static let os = Logger(subsystem: "sa.sary.albarq", category: "link")

    private let lock = NSLock()
    private var lines: [String] = []
    private let fileURL: URL?
    private let io = DispatchQueue(label: "sa.sary.ptt.log", qos: .utility)
    private var flushPending = false
    private let clock: () -> Date
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS'Z'"
        return f
    }()

    init(fileURL: URL? = PTTDiagnosticsLog.defaultURL, clock: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.clock = clock
        if let fileURL, let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            lines = Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(Self.maxLines).map(String.init))
        }
    }

    static var defaultURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("sary-channel-log.txt")
    }

    /// One line: `area` is a short tag (link, ptt, sys, floor, audio, push).
    func add(_ area: String, _ message: String) {
        let line = "\(formatter.string(from: clock())) [\(area)] \(message)"
        Self.os.notice("\(line, privacy: .public)")
        lock.lock()
        lines.append(line)
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
        let schedule = !flushPending && fileURL != nil
        if schedule { flushPending = true }
        lock.unlock()
        if schedule { io.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.flush() } }
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    /// The text that is shared: a header with the app build, then the lines.
    func exportText() -> String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        let sys = ProcessInfo.processInfo.operatingSystemVersionString
        return (["سجل قناة الطلعة — سرى البارق \(v) (\(b)) • iOS \(sys)"] + snapshot).joined(separator: "\n") + "\n"
    }

    /// The file handed to the share sheet (written now, so it is complete).
    func exportFile() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sary-channel-log.txt")
        do {
            try exportText().write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    func clear() {
        lock.lock()
        lines = []
        lock.unlock()
        flush()
    }

    private func flush() {
        lock.lock()
        flushPending = false
        let text = lines.joined(separator: "\n")
        lock.unlock()
        guard let fileURL else { return }
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
