import Foundation

/// The server's input rules (`apps/api/lib/outings/validate.js`), mirrored so
/// the app never sends what the server would refuse — and so a test fails here
/// the day the two disagree.
enum ServerRules {
    /// A fix older than this when it reaches the server is history, not a live position.
    static let maxFixAgeMs = 60_000.0
    /// Beyond this the fix cannot place a person usefully on a map of the desert.
    static let maxAccuracyM = 1_000.0
    /// ~200 km/h: faster than any car on these roads; above it is a GPS glitch.
    static let maxSpeedMps = 55.0
    /// `OUTING_MIN_FIX_INTERVAL_MS` default on the server.
    static let minFixIntervalMs = 1_000.0

    static let nameMax = 40
    static let outingNameMax = 60
    static let noteMax = 80

    enum FixVerdict: Equatable {
        case ok
        case rejected(String)
    }

    /// Same order of checks and same reason codes as `validate.fix`.
    static func check(_ f: WireFix) -> FixVerdict {
        let lat = f.lat, lng = f.lng
        if !lat.isFinite || !lng.isFinite || lat < -90 || lat > 90 || lng < -180 || lng > 180 {
            return .rejected("invalid_coordinates")
        }
        if lat == 0 && lng == 0 { return .rejected("invalid_coordinates") }
        if let a = f.accuracy {
            if !a.isFinite || a < 0 { return .rejected("invalid_accuracy") }
            if a > maxAccuracyM { return .rejected("inaccurate") }
        }
        if !f.age_ms.isFinite || f.age_ms < 0 { return .rejected("invalid_age") }
        if f.age_ms > maxFixAgeMs { return .rejected("stale") }
        if let s = f.speed, s.isFinite, s >= 0, s > maxSpeedMps { return .rejected("implausible_speed") }
        return .ok
    }

    /// Collapse whitespace and drop control and bidi-override characters, as `cleanText` does.
    static func cleanText(_ raw: String, max: Int) -> String? {
        let banned: (Unicode.Scalar) -> Bool = { s in
            let v = s.value
            return v <= 0x1F || v == 0x7F || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
        }
        let filtered = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !banned($0) }))
        let collapsed = filtered.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(max))
    }

    /// E.164 from Saudi local forms and Arabic-Indic digits, as `validate.phone`.
    /// Returns nil when the input cannot be a phone number.
    static func normalizePhone(_ raw: String) -> String? {
        var t = ""
        for s in raw.unicodeScalars {
            switch s.value {
            case 0x0660...0x0669: t.append(String(s.value - 0x0660))
            case 0x06F0...0x06F9: t.append(String(s.value - 0x06F0))
            case 0x20, 0x09, 0x0A, 0x0D, 0x2D, 0x28, 0x29, 0x2E, 0xA0: continue
            default: t.unicodeScalars.append(s)
            }
        }
        if t.hasPrefix("00") { t = "+" + t.dropFirst(2) }
        let digits = { (s: Substring) in s.allSatisfy { $0.isASCII && $0.isNumber } }
        if t.count == 10, t.hasPrefix("05"), digits(Substring(t)) {
            t = "+966" + t.dropFirst()
        } else if t.count == 9, t.hasPrefix("5"), digits(Substring(t)) {
            t = "+966" + t
        } else if t.count == 12, t.hasPrefix("9665"), digits(Substring(t)) {
            t = "+" + t
        }
        guard t.hasPrefix("+") else { return nil }
        let rest = t.dropFirst()
        guard (8...15).contains(rest.count), digits(rest) else { return nil }
        return t
    }
}
