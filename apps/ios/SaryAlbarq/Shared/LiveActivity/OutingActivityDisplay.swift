import Foundation

/// Arabic-Indic formatting for the activity. The widget extension cannot link
/// the app's UI layer, so this mirrors `SaryFormat` (a test keeps them equal).
enum ActivityFormat {
    private static let arabicDigits: [Character] = ["٠", "١", "٢", "٣", "٤", "٥", "٦", "٧", "٨", "٩"]

    static func digits(_ s: String) -> String {
        var out = ""
        for ch in s {
            if let v = ch.wholeNumberValue, ch.isASCII { out.append(arabicDigits[v]) } else if ch == "." { out.append("٫") } else { out.append(ch) }
        }
        return out
    }

    static func number(_ n: Int) -> String { digits(String(n)) }

    /// "٩٠٠ م", "٦٫١ كم", "١٢٣ كم" — the same rules as `SaryFormat.distance`.
    static func distance(meters: Double) -> String {
        let m = max(0, meters)
        let rounded10 = (m / 10).rounded() * 10
        if rounded10 < 1000 {
            if m < 10 { return "\(number(Int(m.rounded()))) م" }
            return "\(number(Int(rounded10))) م"
        }
        let km = m / 1000
        if km < 100 {
            let one = (km * 10).rounded() / 10
            if one == one.rounded() { return "\(number(Int(one))) كم" }
            return "\(digits(String(format: "%.1f", one))) كم"
        }
        return "\(number(Int(km.rounded()))) كم"
    }

    /// "٤:٣٠ م" in Riyadh time — as `NavText.clock`.
    static func clock(_ date: Date, timeZone: TimeZone = TimeZone(identifier: "Asia/Riyadh")!) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute], from: date)
        let h24 = c.hour ?? 0, m = c.minute ?? 0
        let h = h24 % 12 == 0 ? 12 : h24 % 12
        return digits(String(format: "%d:%02d", h, m)) + (h24 < 12 ? " ص" : " م")
    }

    /// "٦٢٪".
    static func percent(_ p: Int) -> String { "\(number(min(100, max(0, p))))٪" }

    /// "الآن", "قبل ٤ د", "قبل ٢ س", "قبل ٣ ي" — as `SaryFormat.elapsed`.
    static func elapsed(since: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(since))
        if s < 60 { return "الآن" }
        let minutes = Int(s / 60)
        if minutes < 60 { return "قبل \(number(minutes)) د" }
        let hours = minutes / 60
        if hours < 24 { return "قبل \(number(hours)) س" }
        return "قبل \(number(hours / 24)) ي"
    }
}

/// The activity's layout decisions, as plain values: what the banner says and
/// in which tone, which numbers are shown, and whether the whole picture is old.
/// Pure, so every rule is unit-tested; the widget views only draw this.
struct OutingActivityDisplay: Equatable {
    enum Tone: Equatable { case emergency, warning, stale }

    struct Banner: Equatable {
        var text: String
        var tone: Tone
    }

    /// Red SOS / stuck first; otherwise the connection or GPS problem; otherwise none.
    var banner: Banner?
    /// The picture is older than `OutingActivityState.staleAfter` (or iOS says so).
    var isStale: Bool
    /// When the picture was taken (the widget ages it live from here).
    var updatedAt: Date
    /// "٣ من ٤ مباشر".
    var liveLine: String
    /// "سلطان — ٢٫٤ كم" (a middle dot would read as Arabic zero), nil when nobody else is live.
    var farthestLine: String?
    /// "٦٫١ كم" back along my trail, nil without back-track data or a fix.
    var backText: String?
    /// Compact Dynamic Island: the distance back, or "—".
    var backShort: String
    /// A red dot in the compact / minimal island.
    var showAlertDot: Bool
    /// The minimal island: the SOS mark wins, then the distance back.
    var minimalText: String
    /// "٤٢ كم/س", or "—" without a fresh speed or once the picture is old.
    var speedText: String = "—"
    /// «الرحلة»: 0...1 for the bar, nil hides the trip row.
    var tripFraction: Double?
    /// "قطعنا ٦٢٪ · باقي ١٢ كم · نوصل ٤:٣٠ م", or "وصلنا 🎉".
    var tripLine: String?
    /// Compact island: "١٢ كم" left to the destination.
    var tripShort: String?

    static func make(_ s: OutingActivityState, now: Date, systemStale: Bool = false) -> OutingActivityDisplay {
        let stale = systemStale || now.timeIntervalSince(s.updatedAt) > OutingActivityState.staleAfter
        let back = s.backMeters.map { ActivityFormat.distance(meters: $0) }
        var farthest: String?
        if let n = s.farthestName, let m = s.farthestMeters { farthest = "\(n) — \(ActivityFormat.distance(meters: m))" }
        return OutingActivityDisplay(
            banner: banner(s),
            isStale: stale,
            updatedAt: s.updatedAt,
            liveLine: "\(ActivityFormat.number(s.liveCount)) من \(ActivityFormat.number(s.memberCount)) مباشر",
            farthestLine: farthest,
            backText: back,
            backShort: back ?? "—",
            showAlertDot: s.alert != nil,
            minimalText: s.alert != nil ? "!" : (back ?? "—"),
            speedText: stale ? "—" : (s.speedKmh.map { "\(ActivityFormat.number(max(0, $0))) كم/س" } ?? "—"),
            tripFraction: trip(s, stale: stale).fraction,
            tripLine: trip(s, stale: stale).line,
            tripShort: trip(s, stale: stale).short
        )
    }

    /// The trip row. A stale picture keeps the percent (it only grows) but not the
    /// remaining distance or the ETA, which an old picture can't vouch for.
    static func trip(_ s: OutingActivityState, stale: Bool = false) -> (fraction: Double?, line: String?, short: String?) {
        if s.tripArrived { return (1, "وصلنا 🎉", "وصلنا") }
        guard let p = s.tripPercent else { return (nil, nil, nil) }
        var parts = ["قطعنا \(ActivityFormat.percent(p))"]
        var short: String?
        if let m = s.tripRemainingM, !stale {
            let d = ActivityFormat.distance(meters: m)
            parts.append("باقي \(d)" + (s.tripApprox ? " تقريبًا" : ""))
            short = d
        }
        if let e = s.tripETA, !stale { parts.append("نوصل \(ActivityFormat.clock(e))") }
        return (Double(min(100, max(0, p))) / 100, parts.joined(separator: " · "), short)
    }

    static func banner(_ s: OutingActivityState) -> Banner? {
        if let a = s.alert {
            let more = a.more > 0 ? " +\(ActivityFormat.number(a.more))" : ""
            let text: String
            switch (a.kind, a.isMe) {
            case (.sos, true): text = "طوارئك مفعّلة"
            case (.sos, false): text = "طوارئ: \(a.name) يطلب المساعدة"
            case (.stuck, true): text = "أبلغت المجموعة أنك غرّزت"
            case (.stuck, false): text = "\(a.name) غرّز"
            }
            return Banner(text: text + more, tone: .emergency)
        }
        switch (s.online, s.gpsOK) {
        case (false, false): return Banner(text: "بلا اتصال ولا GPS", tone: .warning)
        case (false, true): return Banner(text: "بلا اتصال بالشبكة", tone: .warning)
        case (true, false): return Banner(text: "انقطع GPS", tone: .warning)
        case (true, true): return nil
        }
    }
}
