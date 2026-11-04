import Foundation

/// Arabic guidance text, built by us (not the router's English-ordered strings):
/// «بعد ٥٠٠ م انعطف يمينًا إلى طريق الملك فهد». Arabic-Indic digits everywhere a
/// person reads; spoken variants say «متر» / «كيلومتر» in full for the voice.
enum NavText {
    // MARK: distances

    /// Rounded for guidance: under 100 m to 10, under 1 km to 50, then 0.1 km.
    static func roundedMeters(_ m: Double) -> Double {
        let m = max(0, m)
        if m < 100 { return (m / 10).rounded() * 10 }
        if m < 1000 { return (m / 50).rounded() * 50 }
        return (m / 100).rounded() * 100
    }

    /// «٥٠٠ م»، «١٫٢ كم»، «٣ كم».
    static func distance(_ m: Double) -> String {
        let r = roundedMeters(m)
        if r < 1000 { return "\(SaryFormat.number(Int(r))) م" }
        return SaryFormat.distance(meters: r)
    }

    /// «بعد ٥٠٠ م» — nil when the maneuver is right here (under 30 m: just do it).
    static func inDistance(_ m: Double) -> String? {
        m < 30 ? nil : "بعد \(distance(m))"
    }

    /// For the voice: «بعد خمسمية» is not needed, the synthesizer reads digits; we only spell the unit.
    static func spokenInDistance(_ m: Double) -> String? {
        guard m >= 30 else { return nil }
        let r = roundedMeters(m)
        if r < 1000 { return "بعد \(SaryFormat.number(Int(r))) متر" }
        let km = (r / 100).rounded() / 10
        let s = km == km.rounded() ? SaryFormat.number(Int(km)) : SaryFormat.digits(String(format: "%.1f", km))
        return "بعد \(s) كيلومتر"
    }

    // MARK: maneuvers

    static func turn(_ d: NavTurnDirection?) -> String {
        switch d {
        case .right: return "انعطف يمينًا"
        case .left: return "انعطف يسارًا"
        case .slightRight: return "انعطف قليلًا لليمين"
        case .slightLeft: return "انعطف قليلًا لليسار"
        case .sharpRight: return "انعطف بحدّة لليمين"
        case .sharpLeft: return "انعطف بحدّة لليسار"
        case .uTurn: return "استدر للخلف"
        case .straight, .none: return "استمر للأمام"
        }
    }

    private static func side(_ d: NavTurnDirection?) -> String? {
        switch d {
        case .right, .slightRight, .sharpRight: return "اليمين"
        case .left, .slightLeft, .sharpLeft: return "اليسار"
        default: return nil
        }
    }

    static func ordinal(_ n: Int) -> String {
        let names = ["الأول", "الثاني", "الثالث", "الرابع", "الخامس", "السادس", "السابع", "الثامن", "التاسع", "العاشر"]
        return (1...10).contains(n) ? names[n - 1] : "رقم \(SaryFormat.number(n))"
    }

    /// The verb part: «انعطف يمينًا»، «في الدوّار خذ المخرج الثاني»، «وصلت».
    static func action(_ m: NavManeuver) -> String {
        switch m.kind {
        case .turn: return turn(m.direction)
        case .continue, .newName, .notification:
            if let d = m.direction, d != .straight { return turn(d) }
            return "استمر"
        case .merge: return side(m.direction).map { "اندمج من \($0)" } ?? "اندمج"
        case .onRamp: return side(m.direction).map { "اسلك المنحدر على \($0)" } ?? "اسلك المنحدر"
        case .offRamp: return side(m.direction).map { "اخرج من \($0)" } ?? "اخرج"
        case .fork:
            if let s = side(m.direction) { return "التزم ب\(s) عند التفرّع" }
            return "استمر للأمام عند التفرّع"
        case .endOfRoad: return "في نهاية الطريق \(turn(m.direction))"
        case .useLane: return side(m.direction).map { "التزم بمسار \($0)" } ?? "التزم بمسارك"
        case .roundabout:
            if let e = m.exit { return "في الدوّار خذ المخرج \(ordinal(e))" }
            return "ادخل الدوّار"
        case .exitRoundabout: return "اخرج من الدوّار"
        case .depart: return "انطلق"
        case .arrive: return "وجهتك"
        }
    }

    /// «إلى» for a road you turn onto, «على» for the one you stay on.
    private static func preposition(_ k: NavManeuverKind) -> String {
        switch k {
        case .continue, .newName, .depart, .useLane, .notification: return "على"
        default: return "إلى"
        }
    }

    /// Only digits become Arabic-Indic in names («طريق 40» → «طريق ٤٠»); dots stay.
    /// The text is mostly Arabic script (router narration we may speak as is).
    static func isArabic(_ s: String) -> Bool {
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let arabic = letters.filter { (0x0600...0x06FF).contains($0.value) || (0x0750...0x077F).contains($0.value) || (0xFB50...0xFEFF).contains($0.value) }
        return Double(arabic.count) / Double(letters.count) >= 0.6
    }

    static func arabicDigitsOnly(_ s: String) -> String {
        String(s.map { ch -> Character in
            if ch.isASCII, let v = ch.wholeNumberValue { return Character(SaryFormat.number(v)) }
            return ch
        })
    }

    /// The main line of the banner, without the distance: «انعطف يمينًا إلى طريق الملك فهد».
    static func instruction(_ step: NavStep, targetName: String? = nil) -> String {
        if step.maneuver.kind == .arrive {
            if let n = targetName, !n.isEmpty { return "وجهتك: \(arabicDigitsOnly(n))" }
            return "وصلت إلى وجهتك"
        }
        let a = action(step.maneuver)
        let name = (step.roadName?.isEmpty == false ? step.roadName : step.signText).map(arabicDigitsOnly)
        guard let name, !name.isEmpty else { return a }
        return "\(a) \(preposition(step.maneuver.kind)) \(name)"
    }

    /// «بعد ٥٠٠ م انعطف يمينًا إلى طريق الملك فهد».
    static func banner(_ step: NavStep, distanceM: Double, targetName: String? = nil) -> String {
        if step.maneuver.kind == .arrive {
            return distanceM < 30 ? "وصلت إلى \(targetName.map(arabicDigitsOnly) ?? "وجهتك")" : "بعد \(distance(distanceM)) تصل إلى \(targetName.map(arabicDigitsOnly) ?? "وجهتك")"
        }
        let i = instruction(step, targetName: targetName)
        return inDistance(distanceM).map { "\($0) \(i)" } ?? i
    }

    /// For the voice when the router gave none (Valhalla without voice, local engine).
    static func spoken(_ step: NavStep, distanceM: Double, targetName: String? = nil) -> String {
        if step.maneuver.kind == .arrive {
            return distanceM < 30 ? "وصلت إلى \(targetName ?? "وجهتك")" : "\(spokenInDistance(distanceM) ?? "") تصل إلى \(targetName ?? "وجهتك")"
        }
        let i = instruction(step, targetName: targetName)
        return spokenInDistance(distanceM).map { "\($0)، \(i)" } ?? i
    }

    // MARK: compass, time

    /// With the article, for «باتجاه …»: «الجنوب الغربي».
    static func compassDefinite(_ deg: Double) -> String {
        let names = ["الشمال", "الشمال الشرقي", "الشرق", "الجنوب الشرقي", "الجنوب", "الجنوب الغربي", "الغرب", "الشمال الغربي"]
        let d = (deg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return names[Int((d + 22.5) / 45) % 8]
    }

    /// «٤:٣٥ م» (Riyadh time unless told otherwise).
    static func clock(_ date: Date, timeZone: TimeZone = TimeZone(identifier: "Asia/Riyadh")!) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute], from: date)
        let h24 = c.hour ?? 0, m = c.minute ?? 0
        let h = h24 % 12 == 0 ? 12 : h24 % 12
        return SaryFormat.digits(String(format: "%d:%02d", h, m)) + (h24 < 12 ? " ص" : " م")
    }

    /// Remaining time: «أقل من دقيقة»، «١٢ د»، «١ س ٥ د».
    static func remaining(seconds: Double) -> String {
        seconds < 60 ? "أقل من دقيقة" : SaryFormat.duration(seconds: Int(seconds.rounded()))
    }
}
