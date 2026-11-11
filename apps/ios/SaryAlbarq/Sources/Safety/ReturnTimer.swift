import Foundation

// «مؤقت الرجوع»: before heading out, tell someone at home when you will be back.
// They get a link that shows the outing, its members' names and the due time —
// and the last known positions ONLY once the timer is overdue (the server's rule).
// Pure value logic here; the controller talks to the server and the scheduler.

/// What the timer card shows.
enum ReturnTimerPhase: Equatable {
    /// We have not asked the server yet.
    case loading
    /// The server has no return-timer endpoints yet: «غير متاح بعد».
    case unavailable
    /// No timer.
    case none
    case armed(due: Date, contact: String)
    /// The due time passed (locally, or the server's sweeper said so) and nobody pressed «وصلت».
    case overdue(due: Date, contact: String)
    case arrived(contact: String)

    var isRunning: Bool {
        switch self {
        case .armed, .overdue: return true
        default: return false
        }
    }
}

enum ReturnTimerLogic {
    /// Reminders before the due time, minutes.
    static let reminderMinutes = [30, 10]
    /// The earliest and latest due time the picker allows, from now (inside the server's 1 min … 7 days).
    static let minLead: TimeInterval = 10 * 60
    static let maxLead: TimeInterval = 24 * 3600
    static let contactMax = 40
    /// «مدّد» choices, minutes.
    static let extendChoices = [30, 60]

    static func due(_ t: ReturnTimerWire) -> Date? { ISODate.parse(t.due_at) }

    /// The card's phase from the server's timer and the clock. An armed timer whose
    /// time passed reads as overdue at once — the server's sweeper may lag a minute,
    /// the person's own clock does not.
    static func phase(_ t: ReturnTimerWire?, availability: SafetyAvailability, now: Date) -> ReturnTimerPhase {
        if availability == .notDeployed { return .unavailable }
        guard let t else { return availability == .unknown ? .loading : .none }
        guard let due = due(t) else { return .none }
        switch t.state {
        case .armed: return now > due ? .overdue(due: due, contact: t.contact_name) : .armed(due: due, contact: t.contact_name)
        case .overdue: return .overdue(due: due, contact: t.contact_name)
        case .arrived: return .arrived(contact: t.contact_name)
        case .cancelled: return .none
        }
    }

    /// The picker's first suggestion: three hours from now, on a quarter hour.
    static func suggestedDue(now: Date) -> Date {
        let t = now.addingTimeInterval(3 * 3600).timeIntervalSince1970
        return Date(timeIntervalSince1970: (t / 900).rounded(.up) * 900)
    }

    static func clampDue(_ d: Date, now: Date) -> Date {
        min(max(d, now.addingTimeInterval(minLead)), now.addingTimeInterval(maxLead))
    }

    /// Trimmed, ≤ 40 characters, never empty (nil = ask again).
    static func cleanContact(_ s: String) -> String? {
        ServerRules.cleanText(s, max: contactMax).flatMap { $0.isEmpty ? nil : $0 }
    }

    enum Problem: Equatable { case noContact, tooSoon, tooLate }

    static func validate(due: Date, contact: String, now: Date) -> Problem? {
        if cleanContact(contact) == nil { return .noContact }
        if due < now.addingTimeInterval(minLead - 30) { return .tooSoon }
        if due > now.addingTimeInterval(maxLead + 30) { return .tooLate }
        return nil
    }

    /// «مدّد»: from the due time if it is still ahead, otherwise from now.
    static func extended(due: Date, byMinutes m: Int, now: Date) -> Date {
        max(due, now).addingTimeInterval(TimeInterval(m * 60))
    }

    // MARK: reminders

    struct Reminder: Equatable {
        var id: String
        var fireAt: Date
        var title: String
        var body: String
    }

    static func reminderId(_ outingId: String, minutes: Int) -> String { "rt-\(outingId)-\(minutes)" }
    static func reminderIds(_ outingId: String) -> [String] { reminderMinutes.map { reminderId(outingId, minutes: $0) } + [reminderId(outingId, minutes: 0)] }

    /// Local reminders 30 and 10 minutes before the due time, plus one at the time
    /// itself — only those still in the future (a timer set 20 minutes ahead gets the 10-minute one).
    static func reminders(outingId: String, due: Date, contact: String, now: Date) -> [Reminder] {
        var out: [Reminder] = []
        for m in reminderMinutes {
            let at = due.addingTimeInterval(TimeInterval(-m * 60))
            guard at > now.addingTimeInterval(30) else { continue }
            out.append(Reminder(id: reminderId(outingId, minutes: m), fireAt: at, title: "مؤقت الرجوع",
                                body: contact.isEmpty
                                    ? "باقي \(SafetyFormat.span(minutes: m)) على وقت رجوعك. مدّد من المشوار إذا تحتاج."
                                    : "باقي \(SafetyFormat.span(minutes: m)) على وقت رجوعك. إذا تأخرت يوصل تنبيه لـ\(contact). مدّد من الطلعة إذا تحتاج."))
        }
        if due > now.addingTimeInterval(30) {
            out.append(Reminder(id: reminderId(outingId, minutes: 0), fireAt: due, title: "حان وقت رجوعك",
                                body: contact.isEmpty
                                    ? "اضغط «وصلت» إذا رجعت، أو مدّد الوقت. ما يوصل تنبيه لأحد: إذا تحتاج مساعدة اتصل بـ٩١١."
                                    : "اضغط «وصلت» إذا رجعت، أو مدّد الوقت. بعد دقيقة يوصل تنبيه التأخير لـ\(contact)."))
        }
        return out
    }

    // MARK: the message to the contact

    /// What the person sends with the link (WhatsApp, Messages…): what the contact
    /// will see, and when. Honest about positions: only after the time passes.
    static func shareMessage(contact: String, outingName: String, due: Date, url: URL?, now: Date) -> String {
        var lines = [
            "هلا \(contact)،",
            "أنا طالع «\(outingName)»، وضبطت مؤقت رجوع على \(SafetyFormat.dueLabel(due, now: now)).",
            "من الرابط تشوف اسم الطلعة ومين معي ووقت رجوعنا، وإذا وصلنا بالسلامة يوصلك «وصلوا بالسلامة».",
            "ما تشوف مواقعنا. إذا تأخرنا عن الوقت ولا ضغطنا «وصلت»، يوصلك تنبيه ويظهر لك آخر موقع معروف لنا وقت التأخير.",
        ]
        if let url { lines.append(url.absoluteString) } else { lines.append("(عرض تجريبي، بلا رابط)") }
        return lines.joined(separator: "\n")
    }
}

/// Arabic times and spans for the safety pack (Arabic-Indic digits).
enum SafetyFormat {
    /// «٧:٣٠ م» in the phone's time zone.
    static func clock(_ d: Date, calendar: Calendar = .current) -> String {
        SaryFormat.timeOfDay(d, timeZone: calendar.timeZone)
    }

    /// «اليوم ٧:٣٠ م» / «بكرة ١:١٥ ص».
    static func dueLabel(_ d: Date, now: Date, calendar: Calendar = .current) -> String {
        let day = calendar.isDate(d, inSameDayAs: now) ? "اليوم" : (calendar.isDate(d, inSameDayAs: now.addingTimeInterval(86400)) ? "بكرة" : "")
        return day.isEmpty ? clock(d, calendar: calendar) : "\(day) \(clock(d, calendar: calendar))"
    }

    /// «دقيقة»، «دقيقتين»، «٤٥ دقيقة»، «ساعة»، «ساعتين»، «ساعة و١٥ دقيقة»، «٣ ساعات».
    static func span(minutes raw: Int) -> String {
        let total = max(0, raw)
        let h = total / 60, m = total % 60
        func mins(_ n: Int) -> String {
            switch n {
            case 1: return "دقيقة"
            case 2: return "دقيقتين"
            case 3...10: return "\(SaryFormat.number(n)) دقائق"
            default: return "\(SaryFormat.number(n)) دقيقة"
            }
        }
        func hours(_ n: Int) -> String {
            switch n {
            case 1: return "ساعة"
            case 2: return "ساعتين"
            case 3...10: return "\(SaryFormat.number(n)) ساعات"
            default: return "\(SaryFormat.number(n)) ساعة"
            }
        }
        if h == 0 { return mins(m) }
        if m == 0 { return hours(h) }
        return "\(hours(h)) و\(mins(m))"
    }

    /// Time left until `due`, rounded up to the minute: «باقي ساعة و٢٠ دقيقة».
    static func remaining(until due: Date, now: Date) -> String {
        var m = Int((due.timeIntervalSince(now) / 60).rounded(.up))
        /* Past an hour, minutes are noise: «باقي ٣ ساعات», not «٣ ساعات ودقيقة». */
        if m > 60 { m = Int((Double(m) / 5).rounded()) * 5 }
        return m <= 0 ? "حان الوقت" : "باقي \(span(minutes: m))"
    }

    /// «متأخر ١٢ دقيقة».
    static func late(since due: Date, now: Date) -> String {
        let m = max(1, Int((now.timeIntervalSince(due) / 60).rounded(.down)))
        return "متأخر \(span(minutes: m))"
    }
}
