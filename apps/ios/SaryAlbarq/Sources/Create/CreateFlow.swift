import Foundation

// «طلعة جديدة»: ١ وين رايحين؟ → ٢ الجو هناك → ٣ ادعُ أصدقاءك.
// Pure state and text, no UI (tested in CreateFlowTests).

/// Which way a step change slides. Going on, the next step enters from the reading end and
/// the old one leaves toward the start: in Arabic (RTL) the new step comes in from the LEFT,
/// in LTR from the right. Edges are semantic (`trailing` = left in RTL), so SwiftUI mirrors.
enum CreateStepMotion {
    enum Side: Equatable { case left, right }
    /// Semantic, like SwiftUI's `HorizontalEdge` (this file stays free of UI imports).
    enum Edge: Equatable { case leading, trailing }

    static func isForward(from old: CreateStep, to new: CreateStep) -> Bool { new.rawValue >= old.rawValue }

    /// The semantic edge the incoming step enters from (the outgoing one leaves by the other).
    static func insertionEdge(forward: Bool) -> Edge { forward ? .trailing : .leading }

    /// «ابدأ الطلعة» is ready (its emphasis plays): the outing exists and nothing is pending.
    static func startReady(outingId: String?, creating: Bool) -> Bool { outingId != nil && !creating }

    /// Where that is on screen.
    static func enterSide(forward: Bool, rightToLeft: Bool) -> Side {
        let trailing = insertionEdge(forward: forward) == .trailing
        return trailing == rightToLeft ? .left : .right
    }
}

enum CreateCopy {
    /// The server creates the outing and nothing is queued on the phone, so offline we say it
    /// plainly (the buttons wait) — never «ننشئها أول ما يرجع الاتصال» (UI-AUDIT ١-هـ).
    static let offline = "تحتاج إنترنت لإنشاء الطلعة."
}

enum CreateStep: Int, CaseIterable, Equatable {
    case destination = 1
    case weather = 2
    case invite = 3

    var title: String {
        switch self {
        case .destination: return "وين رايحين؟"
        case .weather: return "الجو هناك"
        case .invite: return "ادعُ أصدقاءك"
        }
    }
}

/// What «يناسبنا الجو، كمّل» / «ادعُ أصدقاءك» is waiting on, said on screen while it runs
/// (Build 36 report, item 8: «نجهّز الطلعة…» with no progress looked stuck).
enum CreateStage: Equatable {
    /// `POST /api/outings` (12 s timeout in `OutingsAPI.call`).
    case outing
    /// A create call failed: we ask the list whether the server made it anyway (a timeout can
    /// land after the server already created it), so a retry never makes a second outing.
    case verifying
    /// The destination goes into the new outing's plan (load + save, 12 s each at most).
    case destination

    var text: String {
        switch self {
        case .outing: return "ننشئ الطلعة على الخادم…"
        case .verifying: return "الاتصال تعثّر. نتأكد هل انحفظت الطلعة…"
        case .destination: return "انحفظت الطلعة. نحفظ الوجهة فيها…"
        }
    }
}

struct CreateFlowState: Equatable {
    /// The last attempt failed: its message; the primary button then reads «أعد المحاولة».
    struct Failure: Equatable {
        var message: String
    }

    enum Issue: Equatable {
        case nameEmpty
        case departurePast
        case departureTooFar
        /// «لا يوجد رحلة من غير نهاية»: every outing has a destination.
        case destinationMissing

        var arabic: String {
            switch self {
            case .destinationMissing: return "اختر الوجهة أولًا: كل طلعة لها بداية ونهاية."
            case .nameEmpty: return "اكتب اسم الطلعة."
            case .departurePast: return "وقت الانطلاق فات. اختر وقتًا من الآن وطالع."
            case .departureTooFar: return "اختر وقت انطلاق خلال ١٤ يومًا."
            }
        }
    }

    private(set) var step: CreateStep = .destination {
        didSet { if step != oldValue { movedForward = CreateStepMotion.isForward(from: oldValue, to: step) } }
    }
    /// The last step change went on (true) or back: set in the same mutation as `step`, so the
    /// step transition that animates that change already reads the right direction.
    private(set) var movedForward = true
    /// Required: there is no «بدون وجهة» — an outing is a trip with a start and an end.
    private(set) var destination: OutingDestination?
    var name = ""
    var departure: Date
    private(set) var outingId: String?
    private(set) var creating = false
    var error: String?
    /// While `creating`: which call we are waiting on, and since when (for the seconds counter).
    private(set) var stage: CreateStage?
    private(set) var startedAt: Date?
    /// The last create attempt failed (cleared by the next attempt or a success).
    private(set) var failure: Failure?
    /// Past this, the wait is called slow and the person is told we are still trying.
    static let slowAfterS: TimeInterval = 8
    /// The primary button's title after a failure.
    static let retryTitle = "أعد المحاولة"

    /// A departure slightly in the past (the person took a minute on this screen) still counts as now.
    static let pastGraceS: TimeInterval = 10 * 60
    static let maxAheadS: TimeInterval = 14 * 86_400

    init(now: Date = Date()) {
        departure = Self.defaultDeparture(now)
    }

    /// Now + 1 h, rounded up to the next 5 minutes.
    static func defaultDeparture(_ now: Date) -> Date {
        let t = now.addingTimeInterval(3600).timeIntervalSince1970
        return Date(timeIntervalSince1970: (t / 300).rounded(.up) * 300)
    }

    /// «١ من ٣».
    var progressText: String { "\(SaryFormat.number(step.rawValue)) من \(SaryFormat.number(CreateStep.allCases.count))" }
    var progress: Double { Double(step.rawValue) / Double(CreateStep.allCases.count) }

    /// Once the outing exists on the server there is no going back to change step 1–2 here
    /// (the destination can still be changed from the live screen).
    var canGoBack: Bool { step == .weather && !creating }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: step 1

    /// A place from search, the map or a typed coordinate. Invalid coordinates are refused.
    @discardableResult
    mutating func choose(_ d: OutingDestination) -> Bool {
        guard step == .destination, PlanGeo.valid(lat: d.lat, lng: d.lng) else { return false }
        var clean = d
        clean.name = String(d.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(TripPlan.destinationNameMax))
        if clean.name.isEmpty { clean.name = "الوجهة" }
        destination = clean
        if trimmedName.isEmpty {
            name = Self.suggestedName(for: clean)
        }
        error = nil
        step = .weather
        return true
    }

    // MARK: step 2

    func issue(now: Date) -> Issue? {
        if destination == nil { return .destinationMissing }
        if trimmedName.isEmpty { return .nameEmpty }
        if departure < now.addingTimeInterval(-Self.pastGraceS) { return .departurePast }
        if departure > now.addingTimeInterval(Self.maxAheadS) { return .departureTooFar }
        return nil
    }

    /// «غيّر المكان» / back: to step 1, keeping the name and the time.
    mutating func back() {
        guard canGoBack else { return }
        step = .destination
        error = nil
    }

    /// «يناسبنا الجو، كمّل»: validated; true = go ahead and create the outing.
    mutating func approve(now: Date) -> Bool {
        guard step == .weather, !creating else { return false }
        /* The name is optional: use the selected place, or a neutral title for a map pin. */
        if trimmedName.isEmpty, let destination { name = Self.suggestedName(for: destination) }
        if let i = issue(now: now) {
            error = i.arabic
            return false
        }
        if departure < now { departure = now }
        error = nil
        failure = nil
        creating = true
        stage = .outing
        startedAt = now
        return true
    }

    /// The running attempt moved on to its next call.
    mutating func advance(_ s: CreateStage) {
        guard creating else { return }
        stage = s
    }

    mutating func created(_ id: String) {
        guard creating else { return }
        creating = false
        stage = nil
        startedAt = nil
        failure = nil
        outingId = id
        step = .invite
    }

    mutating func createFailed(_ message: String) {
        creating = false
        stage = nil
        startedAt = nil
        error = message
        failure = Failure(message: message)
    }

    /// «ننشئ الطلعة على الخادم… ٥ ث»; past `slowAfterS` a second line «الشبكة بطيئة، ما زلنا نحاول • ١٢ ث».
    /// Nil when nothing runs.
    func waitingText(now: Date) -> String? {
        guard creating, let stage else { return nil }
        let s = max(0, Int(now.timeIntervalSince(startedAt ?? now)))
        let seconds = "\(SaryFormat.number(s)) ث"
        if Double(s) >= Self.slowAfterS {
            return "\(stage.text)\nالشبكة بطيئة، ما زلنا نحاول • \(seconds)"
        }
        return "\(stage.text) \(seconds)"
    }

    /// After a failed (or timed-out) create: the outing the server made anyway, if the list shows one —
    /// mine (owner), the same name, not started, not on the list before the first attempt, made in the
    /// last 15 minutes. A retry then continues with it instead of creating a second one.
    static func recovered(name: String, current: [OutingSummary], knownBefore: Set<String>, now: Date) -> String? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        let candidates = current.filter { o in
            guard !knownBefore.contains(o.id), o.role == "owner", o.status == .created,
                  o.name.trimmingCharacters(in: .whitespacesAndNewlines) == wanted,
                  let at = ISODate.parse(o.created_at) else { return false }
            return abs(now.timeIntervalSince(at)) <= 15 * 60
        }
        return candidates.max { (ISODate.parse($0.created_at) ?? .distantPast) < (ISODate.parse($1.created_at) ?? .distantPast) }?.id
    }

    private static func suggestedName(for destination: OutingDestination) -> String {
        let place = destination.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !PlaceLabel.isGeneric(place), !PlaceLabel.isRelative(place) else { return "طلعة جديدة" }
        return String("طلعة \(place)".prefix(ServerRules.outingNameMax))
    }
}

/// «الجو هناك وقت وصولنا: ٢٤° رياح خفيفة» — one short line for the invite.
enum WeatherSummary {
    static func windWord(_ h: WeatherHour) -> String? {
        guard let w = h.windKmh else { return nil }
        switch WeatherRules.windLevel(h) {
        case 2: return "رياح شديدة"
        case 1: return "رياح قوية"
        default: break
        }
        if w >= WeatherThresholds.windActive { return "رياح نشطة" }
        if w >= 20 { return "رياح معتدلة" }
        return w < 5 ? "هدوء" : "رياح خفيفة"
    }

    /// `withTemp: false` where the temperature is already shown big beside it.
    static func line(_ h: WeatherHour, withTemp: Bool = true) -> String {
        var bits: [String] = []
        let t = withTemp && h.temperatureC != nil ? WeatherFormat.temp(h.temperatureC) : nil
        if let w = windWord(h) { bits.append([t, w].compactMap { $0 }.joined(separator: " ")) } else if let t { bits.append(t) }
        if let p = h.precipitationProbability, p >= 30 { bits.append("مطر \(SaryFormat.percent(Int(p.rounded())))") }
        if let d = DustLevel.of(h.dust), d >= .light { bits.append(d.label) }
        return bits.joined(separator: "، ")
    }

    /// The forecast hour at `eta`, if the report covers it.
    static func atArrival(_ r: WeatherReport?, eta: Date) -> String? {
        guard let r, let h = WeatherRules.hour(containing: eta, in: r) else { return nil }
        return line(h)
    }
}

/// The invite text (WhatsApp first). Arabic-Indic digits for what people read,
/// Western digits in every link so it opens everywhere.
enum InviteMessage {
    static func text(outingName: String, destination: OutingDestination?, arrivalWeather: String?, departure: Date?, link: URL) -> String {
        var lines = ["تعال معنا في طلعة «\(outingName)» على سَرى البارق."]
        if let d = destination {
            lines.append("الوجهة: \(d.name)")
            lines.append("على الخريطة: \(CoordinateShare.link(LngLat(lng: d.lng, lat: d.lat), .google).absoluteString)")
        }
        if let departure { lines.append("الانطلاق: \(day(departure)) \(WeatherFormat.clock(departure))") }
        if let w = arrivalWeather { lines.append("الجو هناك وقت وصولنا: \(w)") }
        lines.append("انضم من الرابط:")
        lines.append(link.absoluteString)
        return lines.joined(separator: "\n")
    }

    /// «اليوم» / «بكرة» / «الخميس».
    static func day(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(d, inSameDayAs: now) { return "اليوم" }
        if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(d, inSameDayAs: t) { return "بكرة" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ar")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "EEEE"
        return f.string(from: d)
    }

    /// WhatsApp's own share link (opens the app when installed, the web otherwise).
    static func whatsAppURL(_ text: String) -> URL? {
        var c = URLComponents(string: "https://wa.me/")!
        c.queryItems = [.init(name: "text", value: text)]
        return c.url
    }
}
