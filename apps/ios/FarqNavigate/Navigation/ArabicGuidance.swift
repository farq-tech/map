import FerrostarCoreFFI
import Foundation

/// Turn-by-turn, said in Arabic that a Saudi driver would actually say.
///
/// This exists because the routing server's Arabic is unusable. Valhalla accepts
/// `language: ar-SA` and answers with English sentence frames holding Arabic
/// words — measured on the live endpoint, 22 Aug 2026:
///
///     Make a اليسار U-turn at شارع العليا, Al Olaya Street
///     Keep اليسار to stay on طريق العروبة, Al Uaroba Road
///     تحملاليسار للبقاء على الدائري الشرقي
///
/// An English frame, a missing space in «تحملاليسار», and every street named
/// twice in two scripts. Read aloud, that is noise in two languages at the one
/// moment a driver cannot look away from the road to work out what was meant.
///
/// So the sentence is built here from the structured manoeuvre — the type, the
/// modifier, the road, the distance — and the server's prose is never spoken.
/// Nothing in this file touches audio: it returns a string, so the phrasing can
/// be read and checked without a car, a route or a speaker.
enum ArabicGuidance {
    /// How far ahead the manoeuvre is when it is announced.
    enum Phase {
        /// Far enough to change lane and think.
        case prepare
        /// Committed: the turn is here.
        case now
    }

    /// The two announcement points, in metres.
    ///
    /// A single announcement is either too early to act on or too late to obey.
    /// These are conventional and deliberately not tuned by taste — 350 m is
    /// roughly one city block's warning at 60 km/h, and 60 m is the last moment
    /// a lane change is still legal rather than heroic.
    static let prepareMeters: Double = 350
    static let nowMeters: Double = 60

    /// The whole sentence, or nil when there is nothing worth saying.
    static func sentence(
        type: ManeuverType?,
        modifier: ManeuverModifier?,
        roadName: String?,
        exitNumber: String?,
        roundaboutExit: UInt16?,
        distanceMeters: Double,
        phase: Phase
    ) -> String? {
        guard let action = action(
            type: type,
            modifier: modifier,
            roadName: road(roadName),
            exitNumber: exitNumber,
            roundaboutExit: roundaboutExit
        ) else { return nil }

        switch phase {
        case .now:
            return action
        case .prepare:
            guard let lead = distance(distanceMeters) else { return action }
            return "\(lead)، \(action)"
        }
    }

    // MARK: The manoeuvre

    private static func action(
        type: ManeuverType?,
        modifier: ManeuverModifier?,
        roadName: String?,
        exitNumber: String?,
        roundaboutExit: UInt16?
    ) -> String? {
        let onto = roadName.map { " إلى \($0)" } ?? ""
        let along = roadName.map { " على \($0)" } ?? ""

        switch type {
        case .arrive:
            return "وصلت وجهتك"
        case .depart:
            return roadName.map { "انطلق على \($0)" } ?? "انطلق"
        case .roundabout, .rotary, .roundaboutTurn:
            /* The exit number is the only part of a roundabout anyone needs; a
             * roundabout announced without it is a roundabout you circle twice. */
            if let exit = roundaboutExit, let ordinal = ordinal(Int(exit)) {
                return "ادخل الدوار واخرج من المخرج \(ordinal)"
            }
            return "ادخل الدوار"
        case .exitRoundabout, .exitRotary:
            return "اخرج من الدوار\(onto)"
        case .merge:
            return "اندمج\(onto)"
        case .onRamp:
            return "اسلك المدخل\(onto)"
        case .offRamp:
            if let exit = exitNumber, !exit.isEmpty {
                return "اسلك المخرج \(exit)"
            }
            return "اسلك المخرج\(onto)"
        case .fork:
            guard let side = side(modifier) else { return "خذ التفرع\(onto)" }
            return "خذ التفرع \(side)\(onto)"
        case .endOfRoad:
            guard let side = side(modifier) else { return "عند نهاية الطريق، واصل\(onto)" }
            return "عند نهاية الطريق، انعطف \(side)\(onto)"
        case .continue, .newName, .notification, .none:
            /* "Continue" is not always continuing. Valhalla pairs it with a
             * modifier to mean "keep left to stay on X" and — measured on a
             * live Riyadh route — with `uTurn` to mean an actual U-turn. Read
             * as plain "carry on", that instruction drives past the turn. */
            switch modifier {
            case .uTurn:
                return roadName.map { "استدر عكس الاتجاه للبقاء على \($0)" }
                    ?? "استدر عكس الاتجاه"
            case .left, .slightLeft, .sharpLeft:
                return roadName.map { "خذ يسارك للبقاء على \($0)" } ?? "خذ يسارك"
            case .right, .slightRight, .sharpRight:
                return roadName.map { "خذ يمينك للبقاء على \($0)" } ?? "خذ يمينك"
            case .straight, .none:
                /* A rename with no manoeuvre is not an instruction: a driver
                 * doing nothing does not need to be told to keep doing it. */
                guard let name = roadName else { return nil }
                return "واصل على \(name)"
            }
        case .turn:
            return turn(modifier: modifier, onto: onto, along: along)
        }
    }

    private static func turn(modifier: ManeuverModifier?, onto: String, along: String) -> String? {
        switch modifier {
        case .right: return "انعطف يمين\(onto)"
        case .left: return "انعطف يسار\(onto)"
        case .slightRight: return "مِل يمين\(onto)"
        case .slightLeft: return "مِل يسار\(onto)"
        case .sharpRight: return "انعطف يمين بزاوية حادة\(onto)"
        case .sharpLeft: return "انعطف يسار بزاوية حادة\(onto)"
        case .uTurn: return "استدر عكس الاتجاه\(along)"
        case .straight: return along.isEmpty ? nil : "واصل\(along)"
        case .none: return onto.isEmpty ? nil : "انعطف\(onto)"
        }
    }

    private static func side(_ modifier: ManeuverModifier?) -> String? {
        switch modifier {
        case .right, .slightRight, .sharpRight: return "يمين"
        case .left, .slightLeft, .sharpLeft: return "يسار"
        default: return nil
        }
    }

    // MARK: Distance

    /// Distances as words, not digits.
    ///
    /// The set of things this ever needs to say is small and closed, so it is
    /// written out: «ثلاثمئة متر» cannot be misread, while a numeral leaves the
    /// grammar of the counted noun to a speech engine that does not know it.
    /// Spelling it also fixes تمييز العدد for free — «مئتي متر», not «مئتين متر».
    static func distance(_ meters: Double) -> String? {
        guard meters.isFinite, meters > 0 else { return nil }
        switch meters {
        case ..<75: return nil
        case ..<125: return "بعد مئة متر"
        case ..<175: return "بعد مئة وخمسين مترًا"
        case ..<250: return "بعد مئتي متر"
        case ..<350: return "بعد ثلاثمئة متر"
        case ..<450: return "بعد أربعمئة متر"
        case ..<600: return "بعد خمسمئة متر"
        case ..<850: return "بعد سبعمئة متر"
        case ..<1500: return "بعد كيلومتر"
        case ..<2500: return "بعد كيلومترين"
        default:
            let km = Int((meters / 1000).rounded())
            guard let word = ordinalFreeCount(km) else { return "بعد \(km) كيلومتر" }
            return "بعد \(word) كيلومترات"
        }
    }

    /// Three to ten, as the counted-plural form Arabic wants.
    private static func ordinalFreeCount(_ n: Int) -> String? {
        let words = [3: "ثلاثة", 4: "أربعة", 5: "خمسة", 6: "ستة",
                     7: "سبعة", 8: "ثمانية", 9: "تسعة", 10: "عشرة"]
        return words[n]
    }

    /// Roundabout exits, as ordinals.
    private static func ordinal(_ n: Int) -> String? {
        let words = [1: "الأول", 2: "الثاني", 3: "الثالث", 4: "الرابع",
                     5: "الخامس", 6: "السادس", 7: "السابع", 8: "الثامن"]
        return words[n]
    }

    // MARK: Road names

    /// The Arabic half of a bilingual road name.
    ///
    /// OSM carries both scripts and Valhalla hands them over joined — «طريق
    /// العروبة; Al Uaroba Road», sometimes with a slash. Spoken whole, an
    /// Arabic voice reads the Latin half letter by letter. So the Arabic side is
    /// taken when there is one, and when there is not, the name is left exactly
    /// as it came: a road with only a Latin name is still that road, and saying
    /// nothing about it is worse than saying it plainly.
    static func road(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let parts = raw
            .split(whereSeparator: { $0 == ";" || $0 == "/" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        if let arabic = parts.first(where: isArabic) { return arabic }
        return parts.first
    }

    private static func isArabic(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x0600...0x06FF).contains(scalar.value) ||
                (0x0750...0x077F).contains(scalar.value) ||
                (0xFB50...0xFDFF).contains(scalar.value) ||
                (0xFE70...0xFEFF).contains(scalar.value)
        }
    }
}
