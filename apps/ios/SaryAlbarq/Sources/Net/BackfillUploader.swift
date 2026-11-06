import Foundation

/// Uploads the offline queue (`OfflineFixQueue`) in one `POST /api/outings/:id/positions/batch`
/// on a BACKGROUND `URLSession`: iOS finishes the upload even if it suspends or kills the app a
/// second later (the network came back in a tunnel, the screen is locked). The answer, when the
/// app is alive to hear it, removes the batch from the queue (`onDone`); if it never comes, the
/// next flush sends it again (the server keeps the newest position and ignores older ones).
///
/// No coordinates in the URL; the body is written to a temporary file (background sessions
/// upload from files only) and deleted when the task ends.
final class BackfillUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = BackfillUploader()
    static let sessionId = "sary.backfill"

    /// (outingId, upToMs, ok). Main queue.
    var onDone: (String, Double, Bool) -> Void = { _, _, _ in }
    /// From `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    var backgroundCompletion: (() -> Void)?

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.sessionId)
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        c.allowsCellularAccess = true
        c.allowsExpensiveNetworkAccess = true
        c.allowsConstrainedNetworkAccess = true
        c.timeoutIntervalForResource = 6 * 3600
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()
    private let lock = NSLock()
    private var status: [Int: Int] = [:]
    private var inFlight: Set<String> = []

    /// Wake the session after a relaunch so pending answers are delivered.
    func resume() { _ = session }

    /// One batch for one outing; at most one in flight per outing. False when not started.
    @discardableResult
    func upload(outingId: String, fixes: [WireFix], upToMs: Double, token: String, base: URL = Endpoints.apiBase) -> Bool {
        guard !fixes.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard !inFlight.contains(outingId) else { return false }
        struct Body: Encodable { var fixes: [WireFix] }
        guard let data = try? JSONEncoder().encode(Body(fixes: fixes)) else { return false }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sary-backfill-\(UUID().uuidString).json")
        guard (try? data.write(to: file, options: .completeFileProtectionUntilFirstUserAuthentication)) != nil else { return false }
        var req = URLRequest(url: base.appendingPathComponent("api/outings/\(outingId)/positions/batch"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.uploadTask(with: req, fromFile: file)
        task.taskDescription = Self.describe(outingId: outingId, upToMs: upToMs, file: file)
        inFlight.insert(outingId)
        task.resume()
        return true
    }

    static func describe(outingId: String, upToMs: Double, file: URL) -> String {
        "\(outingId)|\(Int64(upToMs))|\(file.lastPathComponent)"
    }

    static func parse(_ d: String?) -> (outingId: String, upToMs: Double, file: String)? {
        guard let p = d?.split(separator: "|").map(String.init), p.count == 3, let ms = Double(p[1]) else { return nil }
        return (p[0], ms, p[2])
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        status[dataTask.taskIdentifier] = (response as? HTTPURLResponse)?.statusCode ?? 0
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let code = status.removeValue(forKey: task.taskIdentifier) ?? (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let info = Self.parse(task.taskDescription)
        if let info { inFlight.remove(info.outingId) }
        lock.unlock()
        guard let info else { return }
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(info.file))
        /* 2xx: taken. 4xx other than 429: never acceptable (left, ended) — drop it too. */
        let ok = error == nil && ((200..<300).contains(code) || ((400..<500).contains(code) && code != 429 && code != 401))
        DispatchQueue.main.async { self.onDone(info.outingId, info.upToMs, ok) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}
