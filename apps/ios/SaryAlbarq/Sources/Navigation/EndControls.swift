import Foundation

/// «إنهاء الرحلة» vs «إنهاء الطلعة» (owner's Build 44 report: while guiding he could end neither one clearly).
///
///   الرحلة (the trip)  = the guidance on this phone (navigation to a destination);
///   الطلعة (the outing) = the group session: members, live sharing.
///
/// ONE pure rule says which end actions a state offers, so the guidance bar's sheet, «المزيد» and the tests
/// agree. Nothing here ends anything: every action maps to a call that already existed
/// (`stopGuidanceTapped`, `endTrip`, `leaveOuting`).
enum EndControls {
    struct State: Equatable {
        /// «اتجه» without a group: one member, nothing leaves the phone (`OutingSession.isSolo`).
        var solo = false
        /// Guidance is running (or being planned) on this phone.
        var guiding = false
        /// The outing has not ended.
        var outingRunning = true
        /// I own the outing (the server's `requireOwner` for «end»).
        var iOwn = false
        /// Leaving is allowed (the outing is not closed on this phone and the server has leave).
        var canLeave = false
    }

    enum Action: String, Equatable {
        /// Stops the guidance on this phone only; the outing goes on.
        case endTrip
        /// A solo outing: its trip is its outing, so this ends both on this phone (then the summary).
        case endSolo
        /// The owner ends the outing for everyone.
        case endOutingForAll
        /// The owner leaves; the outing continues for the others.
        case leaveOnly
        /// A member leaves.
        case leaveOuting
    }

    /// The actions offered, in the order shown (the trip first: it is the lightest).
    static func offered(_ s: State) -> [Action] {
        if s.solo { return (s.guiding || s.outingRunning) ? [.endSolo] : [] }
        var out: [Action] = []
        if s.guiding { out.append(.endTrip) }
        if s.iOwn && s.outingRunning {
            out.append(.endOutingForAll)
            if s.canLeave { out.append(.leaveOnly) }
        } else if s.canLeave {
            out.append(.leaveOuting)
        }
        return out
    }

    /// A trip action is a harmless one; the rest end or leave the outing.
    static func isDestructive(_ a: Action) -> Bool { a != .endTrip }

    /// The guidance-stop button's word: «إنهاء الرحلة» (previous design) or «أوقف التوجيه» (new design).
    static var stopWord: String { NewUI.enabled ? "أوقف التوجيه" : "إنهاء الرحلة" }

    static func title(_ a: Action) -> String {
        let new = NewUI.enabled
        switch a {
        case .endTrip: return new ? "أوقف التوجيه" : "إنهاء الرحلة"
        case .endSolo: return new ? "أنهِ المشوار" : "إنهاء الرحلة"
        case .endOutingForAll: return new ? "أنهِ الطلعة للجميع" : "إنهاء الطلعة للجميع"
        case .leaveOnly: return "مغادرتي فقط"
        case .leaveOuting: return "مغادرة الطلعة"
        }
    }

    /// One sentence: what happens to the guidance, to my location sharing and to the others.
    static func sentence(_ a: Action, guiding: Bool) -> String {
        let stop = guiding ? "يتوقف التوجيه و" : ""
        switch a {
        case .endTrip:
            return "يتوقف التوجيه على جوالك فقط. تبقى في الطلعة ومشاركة موقعك مع الأصدقاء كما هي."
        case .endSolo:
            return guiding ? "يتوقف التوجيه وينتهي المشوار ويطلع ملخصه. كل شي على جوالك فقط، ما يتأثر أحد."
                           : "ينتهي المشوار ويطلع ملخصه. كل شي على جوالك فقط، ما يتأثر أحد."
        case .endOutingForAll:
            return "\(stop)يتوقف إرسال المواقع عند كل الأصدقاء ويطلع ملخص الطلعة. ما تقدر ترجعها."
        case .leaveOnly:
            return "\(stop)تتوقف مشاركة موقعك وتطلع من الطلعة. الأصدقاء يكملون وتنتقل الإمارة لغيرك."
        case .leaveOuting:
            return "\(stop)تتوقف مشاركة موقعك وتطلع من الطلعة. الأصدقاء يكملون. ترجع لها فقط بدعوة جديدة."
        }
    }

    static func sheetTitle(_ s: State) -> String {
        if NewUI.enabled { return s.solo ? "أنهِ المشوار" : (s.guiding ? "أوقف التوجيه أو أنهِ الطلعة" : "أنهِ الطلعة") }
        return s.solo ? "إنهاء الرحلة" : (s.guiding ? "إنهاء الرحلة أو الطلعة" : "إنهاء الطلعة")
    }

    static func identifier(_ a: Action) -> String { "end.action.\(a.rawValue)" }
}
