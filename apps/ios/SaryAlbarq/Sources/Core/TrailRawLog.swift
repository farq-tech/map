import Foundation

/// Every raw GPS fix of an outing's «مساري», on this device only (next to the trail
/// file, same folder, same protection, never backed up). One compact CSV line per
/// fix — `t,lat,lng,acc,spd,crs,spdAcc` — appended in small batches, so the drawn
/// trail can always be re-derived (better filters later, GPX export for diagnosis).
///
/// Capped: past `cap` lines the older half is thinned to every other fix (a 10-hour
/// drive at 1 Hz stays under ~2 MB).
enum TrailRawLog {
    static let cap = 40_000

    static func fileName(_ outingId: String) -> String {
        TrailStore.fileName(outingId).replacingOccurrences(of: ".json", with: ".raw.csv")
    }

    static func url(_ outingId: String, in dir: URL? = TrailStore.directory) -> URL? {
        dir?.appendingPathComponent(fileName(outingId))
    }

    static func line(_ f: RawFix) -> String {
        func n(_ v: Double?, _ digits: Int) -> String {
            guard let v, v.isFinite else { return "" }
            return String(format: "%.\(digits)f", v)
        }
        return "\(Int64(f.t.rounded())),\(n(f.lat, 7)),\(n(f.lng, 7)),\(n(f.acc, 1)),\(n(f.spd, 2)),\(n(f.crs, 1)),\(n(f.spdAcc, 2))\n"
    }

    static func parse(_ text: String) -> [RawFix] {
        var out: [RawFix] = []
        for l in text.split(separator: "\n") {
            let c = l.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 4, let t = Double(c[0]), let lat = Double(c[1]), let lng = Double(c[2]) else { continue }
            func v(_ i: Int) -> Double? { i < c.count ? Double(c[i]) : nil }
            out.append(RawFix(t: t, lat: lat, lng: lng, acc: v(3), spd: v(4), crs: v(5), spdAcc: v(6)))
        }
        return out
    }

    static func append(_ fixes: [RawFix], outingId: String, in dir: URL? = TrailStore.directory) {
        guard !fixes.isEmpty, let dir, let u = url(outingId, in: dir) else { return }
        /* Off the main thread, in order with the trail's own saves (`TrailIO`). */
        TrailIO.async { appendNow(fixes, outingId: outingId, dir: dir, u: u) }
    }

    private static func appendNow(_ fixes: [RawFix], outingId: String, dir: URL, u: URL) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = Data(fixes.map(line).joined().utf8)
            if FileManager.default.fileExists(atPath: u.path) {
                let h = try FileHandle(forWritingTo: u)
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: data)
            } else {
                try data.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var f = u
                try? f.setResourceValues(values)
            }
            /* ~45 bytes a line: only count lines when the file could be over the cap. */
            let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
            if size > cap * 40 { compact(outingId, in: dir) }
        } catch {}
    }

    /// Waits for queued appends (`TrailIO`).
    static func load(_ outingId: String, in dir: URL? = TrailStore.directory) -> [RawFix] {
        guard let u = url(outingId, in: dir), let d = TrailIO.sync({ try? Data(contentsOf: u) }) else { return [] }
        return parse(String(decoding: d, as: UTF8.self))
    }

    /// Thin the older half to every other fix when over the cap.
    static func compact(_ outingId: String, in dir: URL? = TrailStore.directory) {
        TrailIO.sync {
            let all = load(outingId, in: dir)
            guard all.count > cap, let u = url(outingId, in: dir) else { return }
            let thinned = thin(all)
            try? Data(thinned.map(line).joined().utf8).write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func thin(_ all: [RawFix]) -> [RawFix] {
        guard all.count > cap else { return all }
        let half = all.count / 2
        return all[..<half].enumerated().filter { $0.offset % 2 == 0 }.map(\.element) + all[half...]
    }

    static func delete(_ outingId: String, in dir: URL? = TrailStore.directory) {
        guard let u = url(outingId, in: dir) else { return }
        TrailIO.sync { _ = try? FileManager.default.removeItem(at: u) }
    }
}

/// The honest numbers under «مساري» while recording: «الدقة ±٨ م • ١٢ نقطة/دقيقة».
struct TrailHealth: Equatable {
    /// Last fix's accuracy, m.
    var accuracyM: Double?
    /// Raw fixes in the last minute.
    var fixesPerMinute: Int
    var preciseOff: Bool
    var whenInUseOnly: Bool
    var lowPower: Bool

    static func compute(raw recent: [RawFix], nowMs: Double, preciseOff: Bool, whenInUseOnly: Bool, lowPower: Bool) -> TrailHealth {
        let lastMinute = recent.filter { nowMs - $0.t <= 60_000 && $0.t <= nowMs + 1000 }
        let acc = recent.last.flatMap { nowMs - $0.t <= 30_000 ? $0.acc : nil }
        return TrailHealth(accuracyM: acc, fixesPerMinute: lastMinute.count, preciseOff: preciseOff, whenInUseOnly: whenInUseOnly, lowPower: lowPower)
    }

    /// «الدقة ±٨ م • ١٢ نقطة/دقيقة».
    var line: String {
        var parts: [String] = []
        if let a = accuracyM { parts.append("الدقة ±\(SaryFormat.number(Int(a.rounded()))) م") } else { parts.append("بانتظار الموقع") }
        parts.append("\(SaryFormat.number(fixesPerMinute)) نقطة/دقيقة")
        return parts.joined(separator: " • ")
    }

    /// What to fix, most important first.
    var warnings: [String] {
        var w: [String] = []
        if preciseOff { w.append("فعّل الموقع الدقيق: الإعدادات ← سَرى البارق ← الموقع ← «الموقع الدقيق». بدونه يصير المسار تقريبيًا بالكيلومترات.") }
        if whenInUseOnly { w.append("الإذن «أثناء الاستخدام»: نكمل التسجيل والشاشة مقفلة، لكن لو أغلق iOS التطبيق يتوقف. «دائمًا» أضمن.") }
        if lowPower { w.append("وضع توفير الطاقة شغّال: قد يقلّل iOS عدد النقاط.") }
        return w
    }
}
