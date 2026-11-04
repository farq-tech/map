import Foundation

/// Pure formatting helpers for the UI. Everything a person reads uses
/// Arabic-Indic digits (٠١٢٣٤٥٦٧٨٩) and the Arabic decimal separator (٫).
enum SaryFormat {
    private static let arabicDigits: [Character] = ["٠", "١", "٢", "٣", "٤", "٥", "٦", "٧", "٨", "٩"]

    /// Replaces Western digits with Arabic-Indic ones and "." with "٫".
    /// Other characters (letters, spaces, ":") are kept.
    static func digits(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            if let v = ch.wholeNumberValue, ch.isASCII {
                out.append(arabicDigits[v])
            } else if ch == "." {
                out.append("٫")
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// 3 → "٣"
    static func number(_ n: Int) -> String { digits(String(n)) }

    /// «سيارة واحدة»، «سيارتان»، «٣ سيارات»، «١١ سيارة» (Arabic number agreement).
    static func cars(_ n: Int) -> String {
        switch n {
        case 1: return "سيارة واحدة"
        case 2: return "سيارتان"
        case 3...10: return "\(number(n)) سيارات"
        default: return "\(number(n)) سيارة"
        }
    }

    /// Distance for people: under 1 km in metres rounded to 10 ("٩٠٠ م"),
    /// under 100 km with one decimal ("٦٫١ كم", "١ كم" when the decimal is 0),
    /// otherwise whole kilometres ("١٢٣ كم").
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

    /// Time since `since` as a short label: "الآن" under a minute,
    /// then "قبل ٤ د", "قبل ٢ س", "قبل ٣ ي".
    static func elapsed(since: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(since))
        if s < 60 { return "الآن" }
        let minutes = Int(s / 60)
        if minutes < 60 { return "قبل \(number(minutes)) د" }
        let hours = minutes / 60
        if hours < 24 { return "قبل \(number(hours)) س" }
        return "قبل \(number(hours / 24)) ي"
    }

    /// "آخر تحديث قبل ٤ د" — used wherever a stale position is shown.
    static func lastUpdate(since: Date, now: Date) -> String {
        "آخر تحديث \(elapsed(since: since, now: now))"
    }

    /// Clip length "٠:١٢", "١:٠٥".
    static func clock(seconds: Int) -> String {
        let s = max(0, seconds)
        return digits(String(format: "%d:%02d", s / 60, s % 60))
    }

    /// Trip durations: "٤٥ د", "٢ س ١٥ د", "٣ س".
    static func duration(seconds: Int) -> String {
        let totalMin = max(0, seconds) / 60
        let h = totalMin / 60, m = totalMin % 60
        if h == 0 { return "\(number(m)) د" }
        if m == 0 { return "\(number(h)) س" }
        return "\(number(h)) س \(number(m)) د"
    }

    /// Bytes for offline areas: "٨٥ م.ب", "١٫٢ ج.ب".
    static func bytes(_ b: Int64) -> String {
        let mb = Double(max(0, b)) / 1_048_576
        if mb < 1000 { return "\(number(Int(mb.rounded()))) م.ب" }
        return "\(digits(String(format: "%.1f", mb / 1024))) ج.ب"
    }

    /// Battery "٨٢٪".
    static func percent(_ p: Int) -> String { "\(number(min(100, max(0, p))))٪" }

    /// Arabic compass word for a bearing (0 = north, clockwise).
    static func compass(_ degrees: Double) -> String {
        let names = ["شمال", "شمال شرق", "شرق", "جنوب شرق", "جنوب", "جنوب غرب", "غرب", "شمال غرب"]
        let d = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return names[Int((d + 22.5) / 45) % 8]
    }

    /// Peek summary line of the live sheet: "٣ مشارك · ٢ مباشر · الأقرب ٩٠٠ م".
    static func peekSummary(_ participants: [ParticipantUI]) -> String {
        let others = participants.filter { !$0.isMe }
        let live = participants.filter { $0.presence == .live }.count
        var parts = ["\(number(participants.count)) مشارك", "\(number(live)) مباشر"]
        if let nearest = others.compactMap(\.distanceMeters).min() {
            parts.append("الأقرب \(distance(meters: nearest))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Saudi phone

    /// Normalises a Saudi mobile to "05XXXXXXXX". Accepts Arabic-Indic or Western
    /// digits, spaces/dashes, and the +966 / 00966 / 966 / 5XXXXXXXX forms.
    /// Returns nil when it is not a Saudi mobile number.
    static func normalizeSaudiMobile(_ input: String) -> String? {
        var d = ""
        for ch in input {
            if let v = ch.wholeNumberValue { d.append(String(v)) }
            else if ch == "+" || ch == " " || ch == "-" || ch == "(" || ch == ")" { continue }
            else { return nil }
        }
        if d.hasPrefix("00966") { d = String(d.dropFirst(5)) }
        else if d.hasPrefix("966") { d = String(d.dropFirst(3)) }
        if d.hasPrefix("0") { d = String(d.dropFirst()) }
        guard d.count == 9, d.hasPrefix("5") else { return nil }
        return "0" + d
    }

    /// "05XXXXXXXX" shown as "٠٥٥ ١٢٣ ٤٥٦٧".
    static func displayPhone(_ normalized: String) -> String {
        guard normalized.count == 10 else { return digits(normalized) }
        let a = normalized.prefix(3), b = normalized.dropFirst(3).prefix(3), c = normalized.suffix(4)
        return digits("\(a) \(b) \(c)")
    }
}

extension SaryFormat {
    /// Screen-relative direction for VoiceOver: 0° = ahead (top of screen).
    static func relativeDirection(_ degrees: Double) -> String {
        let d = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        switch d {
        case ..<22.5, 337.5...: return "أمامك"
        case ..<67.5: return "أمامك يمينًا"
        case ..<112.5: return "على يمينك"
        case ..<157.5: return "خلفك يمينًا"
        case ..<202.5: return "خلفك"
        case ..<247.5: return "خلفك يسارًا"
        case ..<292.5: return "على يسارك"
        default: return "أمامك يسارًا"
        }
    }
}
