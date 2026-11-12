import Foundation

// «توجيه البر» — the wording of the guidance when the trip is off-road (the desert), in the same
// «صوت سرى» voice but in desert words: progress and direction in plain Najdi, «مسارك» (never «الأثر»),
// no names in the voice, and only what the data can back (docs: memory «offroad-voice-wording»).
//
// Deferred on purpose (no data yet): fuel level, mobile-network coverage, sand / sabkha / wadi told
// apart, «exit the sand» (the route only knows one «rough ground» class), wadi flood warnings.
//
// Text first: every line has its text, so the device voice says it until the owner's clip exists
// (`NavVoice.speak`: «صوت سرى» with no clip → device voice, never silence). The clips are generated in
// the owner's ElevenLabs account and imported later with `scripts/sary-voice-import.py`
// (files `offr_NN.m4a`, rows move from `offroad-pending.json` into `manifest.json`).

/// Every off-road line. `key` is the clip («offr_NN»), nil for the number-less fallbacks that have no recording.
enum OffRoadLine: String, CaseIterable {
    case start, km50, km20, km10, km5, km2, km1, near800, near500, near200, arrived
    case right300, left300, slightRight, slightLeft, wrongWay
    case backN, backNE, backE, backSE, backS, backSW, backW, backNW
    case farOff, backOn, noRouteNear
    case rough
    case friendFar3, friendLost, station40, noStation, offline, sunset40
    /// Number-less fallbacks (no clip yet): said by the device voice only.
    case friendFarGeneric, stationGeneric, sunsetGeneric

    struct Entry: Equatable {
        var key: String?
        var text: String
        /// What the device voice reads when it differs from the written wording (the owner's spelling of 800
        /// is «ثمنمية»: the phone's voice reads the standard «ثمانمية»).
        var deviceText: String?
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    var entry: Entry {
        switch self {
        case .start: return .init(key: "offr_01", text: "توكلنا على الله، اتبع مسارك", deviceText: nil)
        case .km50: return .init(key: "offr_02", text: "باقي خمسين كيلو على مسارك", deviceText: nil)
        case .km20: return .init(key: "offr_03", text: "باقي عشرين كيلو على مسارك", deviceText: nil)
        case .km10: return .init(key: "offr_04", text: "باقي عشرة كيلو على مسارك", deviceText: nil)
        case .km5: return .init(key: "offr_05", text: "باقي خمسة كيلو على مسارك", deviceText: nil)
        case .km2: return .init(key: "offr_06", text: "باقي كيلوين على مسارك", deviceText: nil)
        case .km1: return .init(key: "offr_07", text: "باقي كيلو واحد على مسارك", deviceText: nil)
        case .near800: return .init(key: "offr_08", text: "قربنا، ثمنمية متر", deviceText: "قربنا، ثمانمية متر")
        case .near500: return .init(key: "offr_09", text: "قربنا، خمسمية متر", deviceText: nil)
        case .near200: return .init(key: "offr_10", text: "وصلنا تقريبًا، ميتين متر", deviceText: "وصلنا تقريبًا، مئتين متر")
        case .arrived: return .init(key: "offr_11", text: "وصلنا، الحمد لله على السلامة", deviceText: nil)
        case .right300: return .init(key: "offr_12", text: "خذ يمينك بعد ثلاثمية متر", deviceText: nil)
        case .left300: return .init(key: "offr_13", text: "خذ يسارك بعد ثلاثمية متر", deviceText: nil)
        case .slightRight: return .init(key: "offr_14", text: "ميّل شوي لليمين", deviceText: nil)
        case .slightLeft: return .init(key: "offr_15", text: "ميّل شوي لليسار", deviceText: nil)
        case .wrongWay: return .init(key: "offr_16", text: "لف وارجع، الاتجاه غلط", deviceText: nil)
        case .backN: return .init(key: "offr_17", text: "ابتعدت عن مسارك، ارجع شمالًا", deviceText: nil)
        case .backNE: return .init(key: "offr_18", text: "ابتعدت عن مسارك، ارجع شمال شرق", deviceText: nil)
        case .backE: return .init(key: "offr_19", text: "ابتعدت عن مسارك، ارجع شرقًا", deviceText: nil)
        case .backSE: return .init(key: "offr_20", text: "ابتعدت عن مسارك، ارجع جنوب شرق", deviceText: nil)
        case .backS: return .init(key: "offr_21", text: "ابتعدت عن مسارك، ارجع جنوبًا", deviceText: nil)
        case .backSW: return .init(key: "offr_22", text: "ابتعدت عن مسارك، ارجع جنوب غرب", deviceText: nil)
        case .backW: return .init(key: "offr_23", text: "ابتعدت عن مسارك، ارجع غربًا", deviceText: nil)
        case .backNW: return .init(key: "offr_24", text: "ابتعدت عن مسارك، ارجع شمال غرب", deviceText: nil)
        case .farOff: return .init(key: "offr_25", text: "بعدت كثير عن مسارك", deviceText: nil)
        case .backOn: return .init(key: "offr_26", text: "رجعت على مسارك", deviceText: nil)
        case .noRouteNear: return .init(key: "offr_27", text: "ما لقينا مسار قريب، امش للوجهة بخط مستقيم", deviceText: nil)
        case .rough: return .init(key: "offr_28", text: "أرض وعرة قدامك، خفّف", deviceText: nil)
        case .friendFar3: return .init(key: "offr_29", text: "أحد أصدقائك بعيد عنك ثلاثة كيلو", deviceText: nil)
        case .friendLost: return .init(key: "offr_30", text: "أحد أصدقائك ما ظهر من فترة", deviceText: nil)
        case .station40: return .init(key: "offr_31", text: "أقرب محطة بنزين قدامك أربعين كيلو", deviceText: nil)
        case .noStation: return .init(key: "offr_32", text: "ما فيه محطة قريبة، تأكد من وقودك", deviceText: nil)
        case .offline: return .init(key: "offr_33", text: "ما عندك إنترنت الآن، الخرائط محفوظة عندك", deviceText: nil)
        case .sunset40: return .init(key: "offr_34", text: "الشمس تغيب بعد أربعين دقيقة", deviceText: nil)
        case .friendFarGeneric: return .init(key: nil, text: "أحد أصدقائك بعيد عنك", deviceText: nil)
        case .stationGeneric: return .init(key: nil, text: "أقرب محطة بنزين قدامك", deviceText: nil)
        case .sunsetGeneric: return .init(key: nil, text: "قرب الغروب", deviceText: nil)
        }
    }

    /// Lines about the group (counted against the personal budget).
    var isPersonal: Bool { self == .friendFar3 || self == .friendLost || self == .friendFarGeneric }
    /// A warning (spoken even close to a manoeuvre, but never twice in a row).
    var isHazard: Bool { self == .rough || self == .wrongWay }
    /// Said the moment it is true, outside the minimum gap between lines.
    var isImmediate: Bool {
        switch self {
        case .arrived, .backOn, .wrongWay, .rough, .farOff, .noRouteNear: return true
        default: return false
        }
    }
}

/// One line ready to be said.
struct OffRoadSpeech: Equatable {
    var line: OffRoadLine
    var text: String
    var clips: [String]

    /// As the navigation voice takes it: the clips only when every one is in the bundle, else the text
    /// (the device voice reads it, with the phone-friendly spelling).
    func navLine(maneuverID: String? = nil, routeRevision: Int? = nil) -> NavLine {
        NavLine(text, clips: clips, maneuverID: maneuverID, routeRevision: routeRevision, expiresAt: Date().addingTimeInterval(20), safety: line.isHazard)
    }
}

/// What the provider needs to know at this moment, besides the event.
struct OffRoadContext: Equatable {
    /// Metres to the next manoeuvre (nil: unknown / none).
    var distanceToManeuverM: Double?
    /// A safety warning (SOS, hazard, friend alert) is on the screen or being said.
    var warningActive = false
    var now = Date()
}

/// The off-road wording: which line, when. A value type with all its memory in it, so it can be tested
/// without a route, a voice or a clock.
struct OffRoadVoice {
    // MARK: policy

    /// Between two non-urgent lines.
    static let minGapS = 25.0
    /// A manoeuvre this close: nothing but warnings is said.
    static let maneuverQuietM = 120.0
    /// At most this many lines about friends in one trip.
    static let personalMax = 3
    /// Between lines about friends.
    static let personalGapS = 300.0
    /// A deviation line again, at the earliest.
    static let deviationGapS = 45.0
    /// A rough-ground warning again, at the earliest.
    static let roughGapS = 90.0
    /// A trip is «off-road» when at least this share of its covered length is not asphalt.
    static let offRoadShare = 0.5
    /// «باقي X» is said only when the real distance is within this share of the number said (150 m left is not «ثمنمية»).
    static let bandShare = 0.75
    /// Metres of cross-track error under which nothing is said.
    static let deviationMinM = 40.0
    /// Over this far from the route it is «بعدت كثير».
    static let deviationFarM = 400.0

    /// Whether a clip exists for this key (injected in tests; in the app: the bundle).
    var hasClips: ([String]) -> Bool = { SaryVoiceCatalog.has($0) }

    // MARK: memory (one trip)

    private(set) var said: Set<OffRoadLine> = []
    private(set) var lastSpokenAt: Date?
    private(set) var personalCount = 0
    private var lastPersonalAt: Date?
    private var lastDeviationAt: Date?
    private var lastRoughAt: Date?
    private var lastOfflineAt: Date?
    private var lastLine: OffRoadLine?
    private(set) var deviationOpen = false
    private var turnsSaid: Set<String> = []

    init() {}

    mutating func reset() { self = OffRoadVoice(hasClips: hasClips) }
    private init(hasClips: @escaping ([String]) -> Bool) { self.hasClips = hasClips }

    // MARK: choosing the lines

    /// Whether this trip is off-road: more than half of the route is dirt, track or open ground (or there
    /// is no road at all, the last straight leg), judged on the surface split the route already carries.
    static func isOffRoadTrip(_ km: NavSurfaceKm, straightLeg: Bool = false) -> Bool {
        if straightLeg { return true }
        let covered = km.covered
        guard covered > 0 else { return false }
        return (km.unpaved + km.offRoad) / covered >= offRoadShare
    }

    /// The first line of the trip.
    mutating func begin(_ ctx: OffRoadContext) -> OffRoadSpeech? {
        speak(.start, ctx, onceKey: .start)
    }

    /// Remaining distance to the destination: the milestones, said once each, only when the number is true.
    mutating func progress(remainingM: Double, _ ctx: OffRoadContext) -> OffRoadSpeech? {
        guard remainingM.isFinite, remainingM >= 0 else { return nil }
        /// (threshold metres, line)
        let ladder: [(Double, OffRoadLine)] = [
            (50_000, .km50), (20_000, .km20), (10_000, .km10), (5_000, .km5), (2_000, .km2), (1_000, .km1),
            (800, .near800), (500, .near500), (200, .near200),
        ]
        var due: OffRoadLine?
        for (t, line) in ladder where remainingM <= t {
            guard !said.contains(line) else { continue }
            // The nearest threshold above `remainingM` is the one to say; the farther ones are passed.
            if due == nil, remainingM >= t * Self.bandShare { due = line } else { said.insert(line) }
        }
        guard let line = due else { return nil }
        // Quiet now (a manoeuvre, a warning): keep it for the next progress, unless the window is passing.
        if let s = speak(line, ctx, onceKey: line) { return s }
        return nil
    }

    /// The destination is reached.
    mutating func arrival(_ ctx: OffRoadContext) -> OffRoadSpeech? {
        speak(.arrived, ctx, onceKey: .arrived)
    }

    /// A manoeuvre ahead: «خذ يمينك بعد ثلاثمية متر» only when it is 225–300 m away; a slight turn says no number.
    mutating func turn(_ direction: NavTurnDirection?, distanceM: Double, maneuverID: String, _ ctx: OffRoadContext) -> OffRoadSpeech? {
        guard !turnsSaid.contains(maneuverID) else { return nil }
        switch direction {
        case .right, .sharpRight:
            guard distanceM <= 300, distanceM >= 300 * Self.bandShare else { return nil }
            return speakTurn(.right300, maneuverID, ctx)
        case .left, .sharpLeft:
            guard distanceM <= 300, distanceM >= 300 * Self.bandShare else { return nil }
            return speakTurn(.left300, maneuverID, ctx)
        case .slightRight:
            guard distanceM <= 150 else { return nil }
            return speakTurn(.slightRight, maneuverID, ctx)
        case .slightLeft:
            guard distanceM <= 150 else { return nil }
            return speakTurn(.slightLeft, maneuverID, ctx)
        default:
            return nil
        }
    }

    /// Driving the wrong way along the route (the course is against it).
    mutating func wrongWay(_ ctx: OffRoadContext) -> OffRoadSpeech? {
        guard lastLine != .wrongWay || gapOK(ctx.now, Self.deviationGapS, since: lastDeviationAt) else { return nil }
        lastDeviationAt = ctx.now
        return speak(.wrongWay, ctx, force: true)
    }

    /// Off the route by `crossM`, and the way back is `bearingToRoute` degrees (0 = north, clockwise).
    mutating func deviation(crossM: Double, bearingToRoute: Double?, _ ctx: OffRoadContext) -> OffRoadSpeech? {
        guard crossM >= Self.deviationMinM else { return nil }
        guard gapOK(ctx.now, Self.deviationGapS, since: lastDeviationAt) else { return nil }
        let line: OffRoadLine
        if crossM >= Self.deviationFarM { line = .farOff }
        else if let b = bearingToRoute { line = Self.backLine(bearing: b) }
        else { return nil }
        guard let s = speak(line, ctx, force: true) else { return nil }
        lastDeviationAt = ctx.now
        deviationOpen = true
        return s
    }

    /// Back on the route after a deviation was spoken.
    mutating func backOnRoute(_ ctx: OffRoadContext) -> OffRoadSpeech? {
        guard deviationOpen else { return nil }
        deviationOpen = false
        return speak(.backOn, ctx, force: true)
    }

    /// No route within reach: the last straight leg.
    mutating func noRouteNear(_ ctx: OffRoadContext) -> OffRoadSpeech? {
        speak(.noRouteNear, ctx, onceKey: .noRouteNear)
    }

    /// A rough-ground run starts `aheadM` metres ahead: said once per run, 100–400 m before it.
    mutating func rough(aheadM: Double, _ ctx: OffRoadContext) -> OffRoadSpeech? {
        guard aheadM >= 100, aheadM <= 400 else { return nil }
        guard gapOK(ctx.now, Self.roughGapS, since: lastRoughAt) else { return nil }
        guard let s = speak(.rough, ctx, force: true) else { return nil }
        lastRoughAt = ctx.now
        return s
    }

    /// A friend is `distanceM` away: the number only for ~3 km (2.7–3.6), a plain line farther than 1.5 km.
    mutating func friendFar(distanceM: Double, _ ctx: OffRoadContext) -> OffRoadSpeech? {
        guard distanceM >= 1_500 else { return nil }
        let line: OffRoadLine = (2_700 ... 3_600).contains(distanceM) ? .friendFar3 : .friendFarGeneric
        return speakPersonal(line, ctx)
    }

    /// A friend has not reported for a while.
    mutating func friendLost(_ ctx: OffRoadContext) -> OffRoadSpeech? {
        speakPersonal(.friendLost, ctx)
    }

    /// The nearest fuel station ahead: «أربعين كيلو» for 36–44 km, a plain line otherwise (up to 80 km), nothing farther.
    mutating func station(distanceM: Double?, _ ctx: OffRoadContext) -> OffRoadSpeech? {
        guard let d = distanceM else { return speak(.noStation, ctx, onceKey: .noStation) }
        if (36_000 ... 44_000).contains(d) { return speak(.station40, ctx, onceKey: .station40) }
        if d > 10_000, d < 80_000 { return speak(.stationGeneric, ctx, onceKey: .stationGeneric) }
        return nil
    }

    /// No internet: said once per outage (not more often than every 10 minutes).
    mutating func offline(_ ctx: OffRoadContext) -> OffRoadSpeech? {
        guard gapOK(ctx.now, 600, since: lastOfflineAt) else { return nil }
        guard let s = speak(.offline, ctx, force: true) else { return nil }
        lastOfflineAt = ctx.now
        return s
    }

    /// Minutes to sunset: «أربعين دقيقة» for 36–44, a plain line under 90.
    mutating func sunset(minutes: Double, _ ctx: OffRoadContext) -> OffRoadSpeech? {
        if (36 ... 44).contains(minutes) { return speak(.sunset40, ctx, onceKey: .sunset40) }
        if minutes > 0, minutes < 90 { return speak(.sunsetGeneric, ctx, onceKey: .sunsetGeneric) }
        return nil
    }

    // MARK: mechanics

    /// The way-back line for a bearing: eight 45° sectors, north at the top.
    static func backLine(bearing deg: Double) -> OffRoadLine {
        let d = (deg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let lines: [OffRoadLine] = [.backN, .backNE, .backE, .backSE, .backS, .backSW, .backW, .backNW]
        return lines[Int((d + 22.5) / 45) % 8]
    }

    private func gapOK(_ now: Date, _ s: Double, since: Date?) -> Bool {
        since.map { now.timeIntervalSince($0) >= s } ?? true
    }

    private mutating func speakTurn(_ line: OffRoadLine, _ maneuverID: String, _ ctx: OffRoadContext) -> OffRoadSpeech? {
        // The turn line IS the manoeuvre cue: said once per manoeuvre, not held back by the manoeuvre window.
        var c = ctx
        c.distanceToManeuverM = nil
        guard let s = speak(line, c, force: true) else { return nil }
        turnsSaid.insert(maneuverID)
        return s
    }

    private mutating func speakPersonal(_ line: OffRoadLine, _ ctx: OffRoadContext) -> OffRoadSpeech? {
        guard personalCount < Self.personalMax else { return nil }
        guard gapOK(ctx.now, Self.personalGapS, since: lastPersonalAt) else { return nil }
        guard let s = speak(line, ctx, force: false) else { return nil }
        personalCount += 1
        lastPersonalAt = ctx.now
        return s
    }

    /// The common gate. `onceKey`: said at most once per trip. `force`: skips the minimum gap (not the quiet rules).
    private mutating func speak(_ line: OffRoadLine, _ ctx: OffRoadContext, onceKey: OffRoadLine? = nil, force: Bool = false) -> OffRoadSpeech? {
        if let k = onceKey, said.contains(k) { return nil }
        // Never over a warning; never near a manoeuvre (except the warnings themselves).
        if ctx.warningActive, !line.isHazard { return nil }
        if !line.isHazard, let m = ctx.distanceToManeuverM, m <= Self.maneuverQuietM, line != .arrived { return nil }
        if !force, !line.isImmediate, !gapOK(ctx.now, Self.minGapS, since: lastSpokenAt) { return nil }
        let e = line.entry
        let clips = e.key.map { [$0] } ?? []
        let usable = !clips.isEmpty && hasClips(clips)
        if let k = onceKey { said.insert(k) }
        lastSpokenAt = ctx.now
        lastLine = line
        return OffRoadSpeech(line: line, text: usable ? e.text : (e.deviceText ?? e.text), clips: usable ? clips : [])
    }
}

// MARK: - Where the way back is

enum OffRoadGeometry {
    /// The nearest point of a polyline to `p`: its distance (metres) and the bearing from `p` to it (0 = north, clockwise).
    /// Flat-earth maths per segment: good to a few metres within a few kilometres, which is all a «ارجع شمالًا» needs.
    static func nearest(on line: [LngLat], from p: LngLat) -> (distanceM: Double, bearing: Double)? {
        guard line.count >= 2 else { return nil }
        let mPerDegLat = 111_320.0
        let mPerDegLng = 111_320.0 * cos(p.lat * .pi / 180)
        func xy(_ c: LngLat) -> (Double, Double) { ((c.lng - p.lng) * mPerDegLng, (c.lat - p.lat) * mPerDegLat) }
        var best: (d: Double, x: Double, y: Double)?
        for i in 0 ..< line.count - 1 {
            let a = xy(line[i]), b = xy(line[i + 1])
            let dx = b.0 - a.0, dy = b.1 - a.1
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, -(a.0 * dx + a.1 * dy) / len2)) : 0
            let px = a.0 + t * dx, py = a.1 + t * dy
            let d = (px * px + py * py).squareRoot()
            if best == nil || d < best!.d { best = (d, px, py) }
        }
        guard let b = best else { return nil }
        let deg = atan2(b.x, b.y) * 180 / .pi
        return (b.d, (deg + 360).truncatingRemainder(dividingBy: 360))
    }
}
