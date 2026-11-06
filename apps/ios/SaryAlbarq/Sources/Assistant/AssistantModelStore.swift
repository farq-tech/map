import CryptoKit
import Foundation
import Network

/// The model «مساعد سرى» downloads on demand. Never bundled: the app works without it (keyword rules).
struct AssistantModelSpec: Equatable {
    var id: String
    var title: String
    /// Official source only (the publisher's own Hugging Face repo).
    var url: URL
    var sha256: String
    var bytes: Int64
    var license: String

    /// Qwen2.5-1.5B-Instruct, Q4_K_M, from Qwen's own repo (Apache-2.0). Picked on the 88 + 33
    /// utterance test sets (Tests/Fixtures/assistant-*.json): the smallest model at ≥ 90 %.
    static let qwen25_15b = AssistantModelSpec(
        id: "qwen2.5-1.5b-instruct-q4_k_m",
        title: "Qwen2.5 1.5B",
        url: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!,
        sha256: "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e",
        bytes: 1_117_320_736,
        license: "Apache-2.0")

    static let current = qwen25_15b
    var fileName: String { "\(id).gguf" }
}

/// Moves the bytes and checks them. Injected so the tests run without a network.
protocol AssistantDownloader: AnyObject {
    /// Starts the download to a temporary file; `progress` 0…1; `done` with the file or an error.
    func start(_ url: URL, allowCellular: Bool, progress: @escaping (Double) -> Void, done: @escaping (Result<URL, Error>) -> Void)
    func cancel()
}

/// Settings → «متقدم» → «مساعد سرى»: download (size shown, Wi-Fi preferred, cancellable),
/// sha256-verified, kept in Application Support and excluded from iCloud backup.
@MainActor
final class AssistantModelStore: ObservableObject {
    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case verifying
        case ready
        case failed(String)
    }

    static let shared = AssistantModelStore()
    static let enabledKey = "sary.assistant.model.enabled.v1"

    let spec: AssistantModelSpec
    let directory: URL
    private let downloader: AssistantDownloader
    private let defaults: UserDefaults
    @Published private(set) var state: State = .notDownloaded
    /// Using the model (it may be downloaded but switched off).
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Self.enabledKey) }
    }

    init(spec: AssistantModelSpec = .current, directory: URL? = nil, downloader: AssistantDownloader? = nil, defaults: UserDefaults = .standard) {
        self.spec = spec
        self.directory = directory ?? Self.defaultDirectory
        self.downloader = downloader ?? URLSessionAssistantDownloader()
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
        if FileManager.default.fileExists(atPath: fileURL.path) { state = .ready }
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Assistant", isDirectory: true)
    }

    var fileURL: URL { directory.appendingPathComponent(spec.fileName) }
    /// The model file, when downloaded, verified and switched on.
    var modelURL: URL? { enabled && state == .ready ? fileURL : nil }
    var sizeText: String { SaryFormat.bytes(spec.bytes) }

    func download(allowCellular: Bool) {
        switch state {
        case .downloading, .verifying, .ready: return
        default: break
        }
        state = .downloading(0)
        downloader.start(spec.url, allowCellular: allowCellular, progress: { [weak self] p in
            Task { @MainActor in
                guard let self, case .downloading = self.state else { return }
                self.state = .downloading(min(1, max(0, p)))
            }
        }, done: { [weak self] r in
            Task { @MainActor in self?.finished(r) }
        })
    }

    func cancel() {
        guard case .downloading = state else { return }
        downloader.cancel()
        state = .notDownloaded
    }

    func delete() {
        downloader.cancel()
        try? FileManager.default.removeItem(at: fileURL)
        state = .notDownloaded
        enabled = false
    }

    private func finished(_ r: Result<URL, Error>) {
        guard case .downloading = state else {
            /* Cancelled meanwhile: drop whatever arrived. */
            if case let .success(tmp) = r { try? FileManager.default.removeItem(at: tmp) }
            return
        }
        switch r {
        case let .failure(e):
            state = (e as? URLError)?.code == .cancelled ? .notDownloaded : .failed(Self.message(e))
        case let .success(tmp):
            state = .verifying
            let spec = spec, dest = fileURL, dir = directory
            Task.detached(priority: .utility) {
                let outcome = Self.install(tmp, spec: spec, into: dir, as: dest)
                await MainActor.run {
                    if let e = outcome { self.state = .failed(e.text) } else {
                        self.state = .ready
                        self.enabled = true
                    }
                }
            }
        }
    }

    enum InstallError: Error, Equatable {
        case size(Int64), checksum, move(String)
        var text: String {
            switch self {
            case .size: return "الملف ناقص، جرّب التحميل مرة ثانية."
            case .checksum: return "الملف ما طابق البصمة (sha256)، حذفناه. جرّب مرة ثانية."
            case .move: return "ما قدرنا نحفظ الملف على الجوال."
            }
        }
    }

    /// Size, then sha256, then into place (backup excluded). A file that fails is deleted. nil = installed.
    nonisolated static func install(_ tmp: URL, spec: AssistantModelSpec, into dir: URL, as dest: URL) -> InstallError? {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: tmp) }
        let size = (try? fm.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size == spec.bytes else { return .size(size) }
        guard sha256(of: tmp) == spec.sha256.lowercased() else { return .checksum }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var d = dir
            var v = URLResourceValues()
            v.isExcludedFromBackup = true
            try d.setResourceValues(v)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: tmp, to: dest)
            var f = dest
            try f.setResourceValues(v)
            return nil
        } catch {
            return .move(error.localizedDescription)
        }
    }

    /// Streaming sha256 (the file is over a gigabyte: never read whole).
    nonisolated static func sha256(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk = autoreleasepool { h.readData(ofLength: 4 << 20) }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func message(_ e: Error) -> String {
        switch (e as? URLError)?.code {
        case .notConnectedToInternet?, .networkConnectionLost?: return "ما فيه إنترنت. كمّل التحميل لما يرجع الاتصال."
        case .dataNotAllowed?, .internationalRoamingOff?: return "التحميل على بيانات الجوال مقفل. اتصل بشبكة Wi-Fi."
        default: return "تعذّر التحميل، جرّب مرة ثانية."
        }
    }
}

/// Is the phone on Wi-Fi now (the download prefers it, and asks before using mobile data)?
final class AssistantNetworkPath {
    static let shared = AssistantNetworkPath()
    private let monitor = NWPathMonitor()
    private(set) var expensive = false
    private(set) var online = true

    init() {
        monitor.pathUpdateHandler = { [weak self] p in
            self?.expensive = p.isExpensive
            self?.online = p.status == .satisfied
        }
        monitor.start(queue: DispatchQueue(label: "sary.assistant.path"))
    }
}

final class URLSessionAssistantDownloader: NSObject, AssistantDownloader, URLSessionDownloadDelegate {
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var progress: (Double) -> Void = { _ in }
    private var done: (Result<URL, Error>) -> Void = { _ in }

    func start(_ url: URL, allowCellular: Bool, progress: @escaping (Double) -> Void, done: @escaping (Result<URL, Error>) -> Void) {
        self.progress = progress
        self.done = done
        let c = URLSessionConfiguration.default
        c.allowsExpensiveNetworkAccess = allowCellular
        c.allowsCellularAccess = allowCellular
        c.allowsConstrainedNetworkAccess = false
        c.waitsForConnectivity = true
        c.timeoutIntervalForResource = 3 * 3600
        let s = URLSession(configuration: c, delegate: self, delegateQueue: nil)
        session = s
        task = s.downloadTask(with: url)
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite t: Int64) {
        if t > 0 { progress(Double(w) / Double(t)) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        /* The system deletes `location` when this returns: keep it under our own name first. */
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-\(UUID().uuidString).part")
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            try FileManager.default.moveItem(at: location, to: keep)
            done(.success(keep))
        } catch {
            done(.failure(error))
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { done(.failure(error)) }
        s.finishTasksAndInvalidate()
    }
}
