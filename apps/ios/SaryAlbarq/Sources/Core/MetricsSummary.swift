import Foundation

/// «أداء التطبيق» (docs/METRICS.md): the compact, on-device summary of one MetricKit payload.
/// Pure Foundation on purpose — it is built from the payload's `jsonRepresentation()` dictionary,
/// never from `MX*` objects, so tests can feed it plain JSON. Nothing personal goes in: no
/// location, no account or device ids, no region; only timings, counts and truncated stacks.
struct MetricsSummary: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case daily, diagnostic }

    var id: String
    var kind: Kind
    var receivedAt: Date
    var periodStart: String?
    var periodEnd: String?
    var appVersion: String?
    var appBuild: String?
    var osVersion: String?

    // MARK: daily (MXMetricPayload)

    /// Time to first draw (cold launch), median and 90th percentile, ms.
    var firstDrawMedianMs: Double?
    var firstDrawP90Ms: Double?
    var launchSamples: Int?
    /// Resume (warm, from the background), median, ms.
    var resumeMedianMs: Double?
    /// Hang time over the period, seconds, and per foreground hour (Organizer's «hang rate»).
    var hangSeconds: Double?
    var hangSecondsPerHour: Double?
    var hangCount: Int?
    var cpuSeconds: Double?
    var gpuSeconds: Double?
    var peakMemoryMB: Double?
    var foregroundSeconds: Double?
    var backgroundSeconds: Double?
    var backgroundLocationSeconds: Double?
    /// Battery proxies: MetricKit exposes no joules, only what drains them.
    var locationSeconds: [String: Double]?
    var displayAverageLuminance: Double?
    /// Time on cellular per signal bars ("1 bars" → samples): weak signal burns the radio.
    var cellularBars: [String: Int]?
    var cellularDownloadMB: Double?
    var cellularUploadMB: Double?
    var diskWritesMB: Double?
    /// "foreground.abnormal" → count, from MXAppExitMetric.
    var exits: [String: Int]?
    /// MXAnimationMetric.scrollHitchTimeRatio, ms of hitch per s of scrolling.
    var scrollHitchMsPerS: Double?
    var signposts: [Signpost]?

    // MARK: diagnostic (MXDiagnosticPayload)

    var diagnostics: [Diagnostic]?

    struct Signpost: Codable, Equatable {
        var name: String
        var category: String
        var count: Int
        var medianMs: Double?
        var p90Ms: Double?
    }

    struct Diagnostic: Codable, Equatable {
        /// hang | crash | cpu | diskWrite | launch
        var type: String
        /// One line: hang duration, crash signal/reason, CPU or bytes written.
        var detail: String?
        /// Heaviest call path, "binary +offset (samples)", root first, truncated.
        var stack: [String]
    }
}

// MARK: - extraction

enum MetricsExtract {
    /// Frames kept per diagnostic stack, and diagnostics kept per type, so a payload stays small.
    static let maxFrames = 12
    static let maxPerType = 3

    /// One `MXMetricPayload.jsonRepresentation()`, already decoded with JSONSerialization.
    static func daily(_ d: [String: Any], receivedAt: Date = Date()) -> MetricsSummary {
        var s = base(.daily, d, receivedAt: receivedAt)

        if let launch = d["applicationLaunchMetrics"] as? [String: Any] {
            /* "histogrammedTimeToFirstDrawKey" (and an "Optimized…" twin on newer iOS): the plain one. */
            let firstDraw = histogram(in: launch, where: { $0.contains("firstdraw") && !$0.contains("optimized") })
                ?? histogram(in: launch, where: { $0.contains("firstdraw") })
            s.firstDrawMedianMs = firstDraw.flatMap { quantile($0, 0.5) }.map(toMs)
            s.firstDrawP90Ms = firstDraw.flatMap { quantile($0, 0.9) }.map(toMs)
            s.launchSamples = firstDraw.map { buckets in buckets.reduce(0) { $0 + $1.count } }
            s.resumeMedianMs = histogram(in: launch, where: { $0.contains("resume") }).flatMap { quantile($0, 0.5) }.map(toMs)
        }

        if let time = d["applicationTimeMetrics"] as? [String: Any] {
            s.foregroundSeconds = seconds(time["cumulativeForegroundTime"])
            s.backgroundSeconds = seconds(time["cumulativeBackgroundTime"])
            s.backgroundLocationSeconds = seconds(time["cumulativeBackgroundLocationTime"])
        }

        if let resp = d["applicationResponsivenessMetrics"] as? [String: Any],
           let h = histogram(in: resp, where: { $0.contains("hang") }) {
            let total = h.reduce(0.0) { $0 + $1.mid * Double($1.count) }
            s.hangSeconds = total
            s.hangCount = h.reduce(0) { $0 + $1.count }
            if let fg = s.foregroundSeconds, fg > 0 { s.hangSecondsPerHour = total / (fg / 3600) }
        }

        if let cpu = d["cpuMetrics"] as? [String: Any] { s.cpuSeconds = seconds(cpu["cumulativeCPUTime"]) }
        if let gpu = d["gpuMetrics"] as? [String: Any] { s.gpuSeconds = seconds(gpu["cumulativeGPUTime"]) }
        if let mem = d["memoryMetrics"] as? [String: Any] { s.peakMemoryMB = megabytes(mem["peakMemoryUsage"]) }

        if let loc = d["locationActivityMetrics"] as? [String: Any] {
            var out: [String: Double] = [:]
            for (k, v) in loc { if let sec = seconds(v) { out[k.replacingOccurrences(of: "cumulative", with: "")] = sec } }
            if !out.isEmpty { s.locationSeconds = out }
        }
        if let disp = d["displayMetrics"] as? [String: Any],
           let apl = disp["averagePixelLuminance"] as? [String: Any] {
            s.displayAverageLuminance = Quantity(apl["averageValue"])?.value
        }
        if let cell = d["cellularConditionMetrics"] as? [String: Any],
           let h = cell.values.compactMap({ $0 as? [String: Any] }).first,
           let buckets = h["histogramValue"] as? [String: Any] {
            var out: [String: Int] = [:]
            for b in buckets.values.compactMap({ $0 as? [String: Any] }) {
                guard let label = b["bucketStart"] as? String, let n = int(b["bucketCount"]) else { continue }
                out[label, default: 0] += n
            }
            if !out.isEmpty { s.cellularBars = out }
        }
        if let net = d["networkTransferMetrics"] as? [String: Any] {
            s.cellularDownloadMB = megabytes(net["cumulativeCellularDownload"])
            s.cellularUploadMB = megabytes(net["cumulativeCellularUpload"])
        }
        if let disk = d["diskIOMetrics"] as? [String: Any] { s.diskWritesMB = megabytes(disk["cumulativeLogicalWrites"]) }

        if let ex = d["applicationExitMetrics"] as? [String: Any] {
            var out: [String: Int] = [:]
            for (side, key) in [("foreground", "foregroundExitData"), ("background", "backgroundExitData")] {
                guard let data = ex[key] as? [String: Any] else { continue }
                for (k, v) in data {
                    guard let n = int(v), n > 0 else { continue }
                    out["\(side).\(exitReason(k))"] = n
                }
            }
            if !out.isEmpty { s.exits = out }
        }

        if let anim = d["animationMetrics"] as? [String: Any] {
            s.scrollHitchMsPerS = Quantity(anim["scrollHitchTimeRatio"])?.value
        }

        if let posts = d["signpostMetrics"] as? [[String: Any]] {
            let out: [MetricsSummary.Signpost] = posts.compactMap { (p: [String: Any]) -> MetricsSummary.Signpost? in
                guard let name = p["signpostName"] as? String else { return nil }
                let interval = p["signpostIntervalData"] as? [String: Any]
                let h = interval.flatMap { data in histogram(in: data, where: { $0.contains("duration") }) }
                return .init(name: name, category: p["signpostCategory"] as? String ?? "",
                             count: int(p["totalSignpostCount"]) ?? 0,
                             medianMs: h.flatMap { quantile($0, 0.5) }.map(toMs),
                             p90Ms: h.flatMap { quantile($0, 0.9) }.map(toMs))
            }
            if !out.isEmpty { s.signposts = out.sorted { $0.name < $1.name } }
        }
        return s
    }

    /// One `MXDiagnosticPayload.jsonRepresentation()`.
    static func diagnostic(_ d: [String: Any], receivedAt: Date = Date()) -> MetricsSummary {
        var s = base(.diagnostic, d, receivedAt: receivedAt)
        var out: [MetricsSummary.Diagnostic] = []
        let kinds: [(String, String)] = [("hangDiagnostics", "hang"), ("crashDiagnostics", "crash"),
                                         ("cpuExceptionDiagnostics", "cpu"), ("diskWriteExceptionDiagnostics", "diskWrite"),
                                         ("appLaunchDiagnostics", "launch")]
        for (key, type) in kinds {
            guard let list = d[key] as? [[String: Any]] else { continue }
            for item in list.prefix(maxPerType) {
                let meta = item["diagnosticMetaData"] as? [String: Any] ?? [:]
                if s.appVersion == nil { s.appVersion = meta["appVersion"] as? String }
                if s.appBuild == nil { s.appBuild = meta["appBuildVersion"] as? String }
                if s.osVersion == nil { s.osVersion = meta["osVersion"] as? String }
                out.append(.init(type: type, detail: detail(type, meta),
                                 stack: heaviestPath(item["callStackTree"] as? [String: Any])))
            }
        }
        s.diagnostics = out
        return s
    }

    // MARK: pieces

    private static func base(_ kind: MetricsSummary.Kind, _ d: [String: Any], receivedAt: Date) -> MetricsSummary {
        let meta = d["metaData"] as? [String: Any]
        let start = d["timeStampBegin"] as? String
        let end = d["timeStampEnd"] as? String
        return MetricsSummary(id: "\(kind.rawValue)|\(start ?? "")|\(end ?? "")|\(Int(receivedAt.timeIntervalSince1970))",
                              kind: kind, receivedAt: receivedAt, periodStart: start, periodEnd: end,
                              appVersion: d["appVersion"] as? String ?? meta?["appVersion"] as? String,
                              appBuild: meta?["appBuildVersion"] as? String,
                              osVersion: meta?["osVersion"] as? String)
    }

    private static func detail(_ type: String, _ m: [String: Any]) -> String? {
        switch type {
        case "hang": return (m["hangDuration"] as? String).map { "مدة التعليق \($0)" }
        case "crash":
            var parts: [String] = []
            if let sig = int(m["signal"]) { parts.append("signal \(sig)") }
            if let t = int(m["exceptionType"]) { parts.append("exception \(t)") }
            if let r = m["terminationReason"] as? String { parts.append(String(r.prefix(120))) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case "cpu": return (m["totalCPUTime"] as? String).map { "CPU \($0)" }
        case "diskWrite": return (m["writesCaused"] as? String).map { "كتابة \($0)" }
        case "launch": return (m["launchDuration"] as? String).map { "الفتح \($0)" }
        default: return nil
        }
    }

    /// The call path with the most samples, root first: thread-attributed stacks win (the hung
    /// main thread), then at each level the frame with the highest `sampleCount`.
    static func heaviestPath(_ tree: [String: Any]?, limit: Int = maxFrames) -> [String] {
        guard let stacks = tree?["callStacks"] as? [[String: Any]], !stacks.isEmpty else { return [] }
        let stack = stacks.first(where: { ($0["threadAttributed"] as? Bool) == true }) ?? stacks[0]
        var level = stack["callStackRootFrames"] as? [[String: Any]] ?? []
        var out: [String] = []
        while out.count < limit, let f = level.max(by: { (int($0["sampleCount"]) ?? 0) < (int($1["sampleCount"]) ?? 0) }) {
            let bin = f["binaryName"] as? String ?? "?"
            let off = int(f["offsetIntoBinaryTextSegment"]).map { " +\($0)" } ?? ""
            let n = int(f["sampleCount"]).map { " (\($0))" } ?? ""
            out.append(bin + off + n)
            level = f["subFrames"] as? [[String: Any]] ?? []
        }
        return out
    }

    /// "cumulativeAbnormalExitCount" → "abnormal", "cumulativeAppWatchdogExitCount" → "appWatchdog".
    static func exitReason(_ key: String) -> String {
        var k = key
        if k.hasPrefix("cumulative") { k.removeFirst("cumulative".count) }
        if k.hasSuffix("ExitCount") { k.removeLast("ExitCount".count) }
        guard let first = k.first else { return key }
        return first.lowercased() + String(k.dropFirst())
    }

    // MARK: histograms

    struct Bucket: Equatable {
        var start: Double
        var end: Double
        var count: Int
        var unit: String
        var mid: Double { (start + end) / 2 }
    }

    /// The first histogram (a dict with "histogramValue") whose key matches, buckets in seconds-or-raw.
    static func histogram(in d: [String: Any], where match: (String) -> Bool) -> [Bucket]? {
        for key in d.keys.sorted() where match(key.lowercased()) {
            guard let h = d[key] as? [String: Any], let raw = h["histogramValue"] as? [String: Any] else { continue }
            let buckets: [Bucket] = raw.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.compactMap { k in
                guard let b = raw[k] as? [String: Any], let lo = Quantity(b["bucketStart"]), let hi = Quantity(b["bucketEnd"]),
                      let n = int(b["bucketCount"]) else { return nil }
                return Bucket(start: lo.seconds ?? lo.value, end: hi.seconds ?? hi.value, count: n, unit: lo.seconds == nil ? lo.unit : "s")
            }
            if !buckets.isEmpty { return buckets }
        }
        return nil
    }

    /// Approximate quantile from bucket midpoints, weighted by count.
    static func quantile(_ b: [Bucket], _ q: Double) -> Double? {
        let total = b.reduce(0) { $0 + $1.count }
        guard total > 0 else { return nil }
        let sorted = b.sorted { $0.start < $1.start }
        let target = Double(total) * q
        var seen = 0
        for x in sorted {
            seen += x.count
            if Double(seen) >= target { return x.mid }
        }
        return sorted.last?.mid
    }

    // MARK: units

    /// A MetricKit value string like "200 ms", "100 sec", "200000 kB", "1000 ms per s", or a number.
    struct Quantity {
        var value: Double
        var unit: String

        init?(_ any: Any?) {
            if let n = any as? NSNumber { value = n.doubleValue; unit = ""; return }
            guard let raw = any as? String else { return nil }
            let s = Self.normalized(raw)
            guard !s.isEmpty else { return nil }
            let num = s.prefix { "0123456789.-eE+".contains($0) }
            guard let v = Double(num) else { return nil }
            value = v
            unit = s.dropFirst(num.count).trimmingCharacters(in: .whitespaces)
        }

        /// The value as plain ASCII "1234.5 ms" whatever the phone's number format: Arabic-Indic and
        /// Persian digits, the Arabic decimal and group signs, spaces/NBSP as group separators, and a
        /// lone comma read as a decimal comma unless it groups exactly three digits ("1,234" vs "1,5").
        static func normalized(_ raw: String) -> String {
            var out = ""
            for ch in raw.trimmingCharacters(in: .whitespacesAndNewlines) {
                switch ch {
                case "\u{0660}"..."\u{0669}":
                    out.append(Character(String(ch.unicodeScalars.first!.value - 0x0660)))
                case "\u{06F0}"..."\u{06F9}":
                    out.append(Character(String(ch.unicodeScalars.first!.value - 0x06F0)))
                case "\u{066B}": out.append(".")          // Arabic decimal separator
                case "\u{066C}", "\u{00A0}", "\u{202F}", "'": break   // group separators
                default: out.append(ch)
                }
            }
            /* Split the numeric head from the unit, then settle the comma/period roles in the head. */
            let headEnd = out.firstIndex { !"0123456789.,-eE+ ".contains($0) } ?? out.endIndex
            var head = String(out[..<headEnd]).replacingOccurrences(of: " ", with: "")
            let tail = String(out[headEnd...])
            if head.contains(",") && head.contains(".") {
                /* Both: the later one is the decimal mark. */
                if let c = head.lastIndex(of: ","), let d = head.lastIndex(of: "."), c > d {
                    head = head.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
                } else {
                    head = head.replacingOccurrences(of: ",", with: "")
                }
            } else if head.contains(",") {
                let groups = head.split(separator: ",", omittingEmptySubsequences: false)
                let grouping = groups.count > 1 && groups.dropFirst().allSatisfy { $0.count == 3 }
                head = grouping ? head.replacingOccurrences(of: ",", with: "") : head.replacingOccurrences(of: ",", with: ".")
            }
            return (head + " " + tail.trimmingCharacters(in: .whitespaces)).trimmingCharacters(in: .whitespaces)
        }

        var seconds: Double? {
            switch unit.lowercased() {
            case "ms", "msec": return value / 1000
            case "s", "sec", "secs", "second", "seconds": return value
            case "min", "mins", "minute", "minutes": return value * 60
            case "hr", "hrs", "h", "hour", "hours": return value * 3600
            case "µs", "us", "μs": return value / 1_000_000
            default: return nil
            }
        }

        var megabytes: Double? {
            switch unit.lowercased() {
            case "b", "byte", "bytes": return value / 1_048_576
            case "kb", "kib": return value / 1024
            case "mb", "mib": return value
            case "gb", "gib": return value * 1024
            case "tb": return value * 1_048_576
            default: return nil
            }
        }
    }

    static func seconds(_ any: Any?) -> Double? { Quantity(any)?.seconds }
    static func megabytes(_ any: Any?) -> Double? { Quantity(any)?.megabytes }
    private static func toMs(_ s: Double) -> Double { (s * 1000).rounded() }
    static func int(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}

// MARK: - ring buffer + persistence

/// The last `limit` summaries, oldest dropped first.
enum MetricsRing {
    static let limit = 14

    static func appending(_ new: [MetricsSummary], to old: [MetricsSummary], limit: Int = limit) -> [MetricsSummary] {
        let all = old + new
        return all.count > limit ? Array(all.suffix(limit)) : all
    }
}

/// `Application Support/Metrics/summaries.json`: a JSON array, rewritten atomically. Not
/// thread-safe on its own; `MetricsCollector` calls it from one serial queue.
struct MetricsStore {
    var directory: URL
    var limit = MetricsRing.limit

    static var standard: MetricsStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return MetricsStore(directory: base.appendingPathComponent("Metrics", isDirectory: true))
    }

    var file: URL { directory.appendingPathComponent("summaries.json") }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func load() -> [MetricsSummary] {
        guard let data = try? Data(contentsOf: file),
              let list = try? Self.decoder.decode([MetricsSummary].self, from: data) else { return [] }
        return list
    }

    @discardableResult
    func append(_ new: [MetricsSummary]) -> [MetricsSummary] {
        let list = MetricsRing.appending(new, to: load(), limit: limit)
        save(list)
        return list
    }

    func save(_ list: [MetricsSummary]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encoder.encode(list).write(to: file, options: [.atomic])
        } catch {
            /* Diagnostics only: a failed write never surfaces to the person. */
        }
    }
}
