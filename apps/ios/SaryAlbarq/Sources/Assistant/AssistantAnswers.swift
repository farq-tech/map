import Foundation

/// Everything «مساعد سرى» may say, frozen from the app's state at the moment of the question.
/// Built by `LiveOutingController+Assistant`; pure data so the templates are testable.
struct AssistantFacts: Equatable {
    struct Member: Equatable {
        var id: String
        var name: String
        var position: LngLat
        var presence: Policy.Freshness
        /// The fix's time, ms since 1970 (device clock).
        var atMs: Double
    }

    struct Radio: Equatable {
        var available = true
        var playing = false
        var muted = false
        var title: String?
        /// Only the leader (or everyone, if the leader allowed it) starts / stops it for the trip.
        var canControl = false
    }

    var now: Date
    /// My position, only when it is fresh enough to measure from.
    var me: LngLat?
    var others: [Member] = []
    var destinationName: String?
    var remaining: RemainingDistance?
    /// Seconds to the destination: the guidance's own ETA, else distance ÷ my recent moving speed.
    var etaSeconds: TimeInterval?
    var arrived = false
    var stations: LoadPhaseUI<[StationUI]>?
    var weather: WeatherReport?
    var weatherPlace: String?
    var sunset: Date?
    var wayBackS: TimeInterval?
    var rally: MapRallyPoint?
    var radio = Radio()
    var channelsAvailable = false
    var currentChannel: String?
    var chatAvailable = true
    var tripRunning = true
    var hasBackTrail = false

    var memberNames: [String] { others.map(\.name) }
}

/// What to do after answering. There is deliberately no case that sends SOS: the assistant can
/// only show the SOS button (`AssistantAnswer.showsSOSButton`); a person presses it themselves.
enum AssistantAction: Equatable {
    case navigate(AssistantIntent.NavGoal)
    case radioPlay
    case radioMute
    case openRadio
    case setChannel(String)
    case openChat
    case openStations
    case openWeather
    case showRally

    /// For the tests that pin «never triggers SOS».
    var triggersSOS: Bool { false }
}

/// How the answer is spoken: all in «صوت سرى» (his clips say the whole sentence), or all in the
/// phone's Arabic voice. Never a mix inside one sentence.
enum AssistantSpoken: Equatable {
    case clips([String], text: String)
    case system(String)

    var text: String {
        switch self {
        case let .clips(_, t), let .system(t): return t
        }
    }
}

struct AssistantAnswer: Equatable {
    enum Kind: Equatable { case answer, clarify, done }
    var kind: Kind = .answer
    /// The card's text (all facts from `AssistantFacts`).
    var text: String
    /// A second, smaller line («موقعه قديم»، «تقريبي»…).
    var detail: String?
    var spoken: AssistantSpoken
    var action: AssistantAction?
    /// Shown as tappable chips (and said by voice when unclear).
    var suggestions: [String] = []
    var showsSOSButton = false
    /// A member's position is older than live: the card says so plainly.
    var stale = false
}

/// The deterministic Najdi templates: intent + facts → answer. Numbers and places are always the
/// app's; when a fact is missing the answer says what is missing instead of guessing.
enum AssistantAnswers {
    static let suggestions = ["وين الربع", "كم باقي", "أقرب محطة", "متى المغرب", "كيف الجو"]

    static func answer(_ intent: AssistantIntent, _ f: AssistantFacts) -> AssistantAnswer {
        switch intent {
        case let .membersWhere(who): return members(who, f)
        case .tripRemaining: return remaining(f)
        case .nearestFuel: return fuel(f)
        case let .weather(a): return weather(a, f)
        case let .sunset(a): return sunset(a, f)
        case .rallyPoint: return rally(f)
        case let .navigate(g): return navigate(g, f)
        case let .radio(play): return radio(play, f)
        case let .setChannel(n): return channel(n, f)
        case .openChat: return chat(f)
        case .sosHelp: return sos()
        case .unknown: return unclear()
        }
    }

    static func unclear() -> AssistantAnswer {
        let t = "ما فهمت عليك. تقدر تسألني مثلًا:"
        return AssistantAnswer(kind: .clarify, text: t, spoken: .system("ما فهمت عليك. جرّب: وين الربع، أو كم باقي"), suggestions: suggestions)
    }

    // MARK: members

    static func members(_ who: String?, _ f: AssistantFacts) -> AssistantAnswer {
        let list = who.map { n in f.others.filter { $0.name == n } } ?? f.others
        if let who, list.isEmpty {
            return AssistantAnswer(kind: .clarify, text: "ما لقيت \(who) في الطلعة.", spoken: .system("ما لقيت \(who) في الطلعة"),
                                   suggestions: f.others.prefix(4).map { "وين \($0.name)" })
        }
        if list.isEmpty {
            return AssistantAnswer(text: "ما فيه أحد غيرك في الطلعة الحين.", spoken: .system("ما فيه أحد غيرك في الطلعة الحين"))
        }
        let lines = list.sorted { distance($0, f) ?? .infinity < distance($1, f) ?? .infinity }.map { line($0, f) }
        let stale = list.contains { $0.presence != .live }
        if list.count == 1 {
            return AssistantAnswer(text: lines[0], detail: stale ? staleNote : nil, spoken: .system(lines[0]), stale: stale)
        }
        let text = lines.prefix(6).joined(separator: "\n")
        let liveCount = list.filter { $0.presence == .live }.count
        let summary: String
        if let nearest = list.filter({ $0.presence == .live }).min(by: { distance($0, f) ?? .infinity < distance($1, f) ?? .infinity }),
           let d = distance(nearest, f) {
            summary = "أقربهم \(nearest.name) على بعد \(SaryFormat.distance(meters: d))." + (liveCount < list.count ? " وبعضهم موقعه قديم." : "")
        } else {
            summary = "مواقعهم كلها قديمة، شوف البطاقة."
        }
        return AssistantAnswer(text: text, detail: stale ? staleNote : nil, spoken: .system(summary), stale: stale)
    }

    static let staleNote = "الموقع القديم آخر مكان وصلنا منه، مو مكانه الحين."

    static func distance(_ m: AssistantFacts.Member, _ f: AssistantFacts) -> Double? {
        f.me.map { Vehicle.distanceMeters($0, m.position) }
    }

    /// «سعود على بعد ٣٫٢ كم شمال شرق منك (مباشر)» / «آخر موقع لسعود قبل ١٢ دقيقة: …».
    static func line(_ m: AssistantFacts.Member, _ f: AssistantFacts) -> String {
        var place = ""
        if let me = f.me {
            let d = Vehicle.distanceMeters(me, m.position)
            if d < 50 {
                place = "جنبك"
            } else {
                let dir = SaryFormat.compass(Geo.bearingDeg(Geo.LatLng(lat: me.lat, lng: me.lng), Geo.LatLng(lat: m.position.lat, lng: m.position.lng)))
                place = "على بعد \(SaryFormat.distance(meters: d)) \(dir) منك"
            }
        }
        switch m.presence {
        case .live:
            return place.isEmpty ? "\(m.name) موقعه مباشر، بس ما عندي موقعك عشان أحسب المسافة." : "\(m.name) \(place)، موقعه مباشر."
        case .recent, .lost:
            let mins = max(1, Int((f.now.timeIntervalSince1970 * 1000 - m.atMs) / 60_000))
            let age = SafetyFormat.span(minutes: mins)
            return place.isEmpty ? "آخر موقع وصلنا من \(m.name) قبل \(age)." : "آخر موقع لـ\(m.name) قبل \(age): كان \(place). موقعه قديم."
        }
    }

    // MARK: the destination

    static func remaining(_ f: AssistantFacts) -> AssistantAnswer {
        let name = f.destinationName.map { $0.isEmpty ? "الوجهة" : $0 } ?? "الوجهة"
        if f.arrived {
            return AssistantAnswer(text: "وصلت \(name)، الله يحيّيك.", spoken: .clips(["arr_02"], text: "وصلت وجهتك."))
        }
        guard f.destinationName != nil else {
            return AssistantAnswer(text: "ما فيه وجهة محددة للطلعة.", detail: "يحددها أمير الرحلة من «الرحلة».", spoken: .system("ما فيه وجهة محددة للطلعة"))
        }
        guard let r = f.remaining else {
            return AssistantAnswer(text: "ما عندي موقعك الحين عشان أحسب الباقي.", spoken: .system("ما عندي موقعك الحين عشان أحسب الباقي"))
        }
        let dist = SaryFormat.distance(meters: r.meters)
        var text = "باقي \(dist) على \(name)"
        var spoken: AssistantSpoken = .system(text)
        if let eta = f.etaSeconds, eta.isFinite, eta > 0 {
            let mins = Int((eta / 60).rounded())
            text += "، توصل تقريبًا بعد \(SafetyFormat.span(minutes: max(1, mins))) (\(SafetyFormat.clock(f.now.addingTimeInterval(eta))))"
            if let clip = etaClip(seconds: eta) { spoken = .clips([clip.key], text: clip.text) } else { spoken = .system(text) }
        }
        text += "."
        return AssistantAnswer(text: text, detail: r.source.approximate ? "المسافة بخط مستقيم، تقريبية." : nil, spoken: spoken)
    }

    /// «باقي ربع ساعة وتوصل»: only when one of his recorded times is this ETA (within 10 %, ±1 min).
    static func etaClip(seconds: TimeInterval) -> (key: String, text: String)? {
        let table: [(Double, String, String)] = [(1, "eta_02", "باقي دقيقة وتوصل."), (2, "eta_03", "باقي دقيقتين وتوصل."),
                                                 (3, "eta_04", "باقي ثلاث دقايق وتوصل."), (5, "eta_05", "باقي خمس دقايق وتوصل."),
                                                 (10, "eta_06", "باقي عشر دقايق وتوصل."), (15, "eta_07", "باقي ربع ساعة وتوصل."),
                                                 (20, "eta_08", "باقي عشرين دقيقة وتوصل."), (30, "eta_09", "باقي نص ساعة وتوصل."),
                                                 (45, "eta_10", "باقي خمس وأربعين دقيقة وتوصل."), (60, "eta_11", "باقي ساعة وتوصل."),
                                                 (90, "eta_12", "باقي ساعة ونص وتوصل."), (120, "eta_13", "باقي ساعتين وتوصل."),
                                                 (180, "eta_14", "باقي ثلاث ساعات وتوصل."), (240, "eta_15", "باقي أربع ساعات وتوصل.")]
        let m = seconds / 60
        if m < 1 { return ("eta_01", "باقي أقل من دقيقة وتوصل.") }
        return table.first { abs(m - $0.0) <= max(0.5, $0.0 * 0.1) }.map { ($0.1, $0.2) }
    }

    // MARK: petrol

    static func fuel(_ f: AssistantFacts) -> AssistantAnswer {
        var phase = f.stations
        if case let .loaded(rows)? = phase, rows.isEmpty { phase = .empty }
        switch phase {
        case let .loaded(rows)?:
            let s = rows.min(by: { $0.distanceMeters < $1.distanceMeters })!
            let dir = s.bearingDegrees.map { " " + SaryFormat.compass($0) } ?? ""
            let text = "أقرب محطة: \(s.name)، على بعد \(SaryFormat.distance(meters: s.distanceMeters))\(dir)."
            return AssistantAnswer(text: text, detail: s.detail, spoken: .system(text), action: .openStations, suggestions: ["ودني للمحطة"])
        case .empty?:
            return AssistantAnswer(text: "ما لقيت محطة قريبة منك.", spoken: .system("ما لقيت محطة قريبة منك"), action: .openStations)
        case let .error(e)?:
            return AssistantAnswer(text: e, spoken: .system(e), action: .openStations)
        case .loading?, nil:
            return AssistantAnswer(text: "أدوّر لك على أقرب محطة…", spoken: .system("أدوّر لك على أقرب محطة"), action: .openStations)
        }
    }

    // MARK: weather

    static func weather(_ a: AssistantIntent.WeatherAspect, _ f: AssistantFacts) -> AssistantAnswer {
        guard let r = f.weather, let now = WeatherRules.nowValue(r, now: f.now)?.hour else {
            return AssistantAnswer(text: "ما عندي بيانات طقس الحين.", detail: "تحتاج إنترنت أول مرة، بعدها نعرض آخر ما وصلنا.",
                                   spoken: .system("ما عندي بيانات طقس الحين"), action: .openWeather)
        }
        let place = f.weatherPlace.map { " \($0)" } ?? ""
        let age = f.now.timeIntervalSince(r.fetchedAt)
        let ageNote = age > 3600 ? "آخر تحديث للطقس \(SaryFormat.elapsed(since: r.fetchedAt, now: f.now))." : nil
        func n(_ x: Double) -> String { SaryFormat.number(Int(x.rounded())) }
        let windText: String? = now.windKmh.map { w in
            var s = "الريح \(n(w)) كم/س"
            if let g = now.gustKmh, g > w + 10 { s += " وهبات لين \(n(g))" }
            if let d = now.windFromDeg { s += " من \(WeatherRules.windName(from: d))" }
            return s
        }
        let dust = DustLevel.of(now.dust)
        let text: String
        var clips: [String]? = nil
        switch a {
        case .wind:
            text = (windText ?? "ما عندي قراءة للريح") + "."
        case .dust:
            if let dust {
                text = "\(dust.label)\(place) الحين."
                if dust == .heavy { clips = ["haz_06"] }
            } else {
                text = "ما عندي قراءة للغبار الحين."
            }
        case .temp:
            text = now.temperatureC.map { "الحرارة\(place) \(n($0))°" + (now.apparentC.map { " ويُحس كأنها \(n($0))°" } ?? "") + "." } ?? "ما عندي قراءة للحرارة."
        case .rain:
            let chance = WeatherRules.maxRainChance(r, now: f.now)
            if let c = chance, c >= WeatherThresholds.rainProbability {
                text = "فيه احتمال مطر \(SaryFormat.percent(Int(c.rounded()))) في الساعات الجاية."
            } else {
                text = "ما فيه مطر متوقع في الساعات الجاية."
            }
        case .general:
            let cond = WeatherRules.condition(now.weatherCode).text
            var parts = [cond]
            if let t = now.temperatureC { parts.append("\(n(t))°") }
            if let windText { parts.append(windText) }
            if let dust, dust > .clear { parts.append(dust.label) }
            text = "الجو\(place): " + parts.joined(separator: "، ") + "."
        }
        let spoken: AssistantSpoken = clips.map { .clips($0, text: "انتبه، الغبار كثيف والرؤية ضعيفة.") } ?? .system(text)
        return AssistantAnswer(text: text, detail: ageNote, spoken: spoken, action: .openWeather)
    }

    // MARK: sunset

    static func sunset(_ a: AssistantIntent.SunsetAspect, _ f: AssistantFacts) -> AssistantAnswer {
        guard let s = f.sunset else {
            return AssistantAnswer(text: "ما أقدر أحسب المغرب بدون موقعك.", spoken: .system("ما أقدر أحسب المغرب بدون موقعك"))
        }
        let left = s.timeIntervalSince(f.now)
        let clock = SafetyFormat.clock(s)
        let leftText = left <= 0 ? "غابت الشمس" : "باقي \(SafetyFormat.span(minutes: max(1, Int((left / 60).rounded())))) على المغرب"
        switch a {
        case .time:
            let text = left <= 0 ? "غابت الشمس الساعة \(clock)." : "المغرب الساعة \(clock)، \(leftText)."
            return AssistantAnswer(text: text, spoken: .system(text))
        case .remaining:
            let text = left <= 0 ? "غابت الشمس الساعة \(clock)." : "\(leftText) (\(clock))."
            return AssistantAnswer(text: text, spoken: sunClip(left: left).map { .clips([$0.key], text: $0.text) } ?? .system(text))
        case .wayBack:
            guard let way = f.wayBackS else {
                let text = "\(leftText). ما عندي مسار رجعة كافي أحسب منه وقت الرجعة."
                return AssistantAnswer(text: text, spoken: .system(text))
            }
            let wayMin = SunsetWarning.roundUp5(way / 60)
            let wayText = "طريق الرجعة على مسارك تقريبًا \(SafetyFormat.span(minutes: wayMin))"
            let verdict: String
            if left <= 0 { verdict = "ارجعوا على مهلكم وشغّلوا الأنوار." }
            else if way <= left - SunsetWarning.marginS { verdict = "تلحقون ترجعون قبل الظلام إن شاء الله." }
            else if way <= left { verdict = "تلحقون على الحد، الأفضل تبدون الرجعة الحين." }
            else { verdict = "ما تلحقون قبل المغرب، الأفضل تبدون الرجعة الحين وعلى مهلكم." }
            let text = "\(leftText)، و\(wayText). \(verdict)"
            return AssistantAnswer(text: text, spoken: .system(text))
        }
    }

    /// «باقي ساعة / نص ساعة / ربع ساعة على الغروب» when one of them is the time left (±5 min).
    static func sunClip(left: TimeInterval) -> (key: String, text: String)? {
        let m = left / 60
        if left <= 0 { return ("sun_05", "غربت الشمس.") }
        if abs(m - 60) <= 5 { return ("sun_02", "باقي ساعة على غروب الشمس.") }
        if abs(m - 30) <= 5 { return ("sun_03", "باقي نص ساعة على غروب الشمس.") }
        if abs(m - 15) <= 3 { return ("sun_04", "باقي ربع ساعة على الغروب.") }
        return nil
    }

    // MARK: rally

    static func rally(_ f: AssistantFacts) -> AssistantAnswer {
        guard let r = f.rally else {
            return AssistantAnswer(text: "ما فيه نقطة تجمع محددة.", detail: "يحددها أمير الرحلة من «الجماعة».", spoken: .system("ما فيه نقطة تجمع محددة"))
        }
        let label = r.label.isEmpty ? "نقطة التجمع" : "نقطة التجمع «\(r.label)»"
        var text = label
        if let me = f.me {
            let d = Vehicle.distanceMeters(me, r.position)
            let dir = SaryFormat.compass(Geo.bearingDeg(Geo.LatLng(lat: me.lat, lng: me.lng), Geo.LatLng(lat: r.position.lat, lng: r.position.lng)))
            text += " على بعد \(SaryFormat.distance(meters: d)) \(dir) منك."
        } else {
            text += " على الخريطة."
        }
        return AssistantAnswer(text: text, spoken: .system(text), action: .showRally, suggestions: ["ودني لنقطة التجمع"])
    }

    // MARK: actions

    static func navigate(_ g: AssistantIntent.NavGoal, _ f: AssistantFacts) -> AssistantAnswer {
        /* The route options open (as from «ملاحة»): the person presses «ابدأ», nothing drives off on its own. */
        let started: (String) -> AssistantAnswer = { t in
            AssistantAnswer(kind: .done, text: "جهّزنا الطريق إلى \(t). اضغط «ابدأ» وينطلق التوجيه.",
                            spoken: .system("جهّزنا الطريق إلى \(t). اضغط ابدأ"), action: .navigate(g))
        }
        switch g {
        case .destination:
            guard let d = f.destinationName else {
                return AssistantAnswer(text: "ما فيه وجهة محددة للطلعة.", spoken: .system("ما فيه وجهة محددة للطلعة"))
            }
            return started(d.isEmpty ? "الوجهة" : d)
        case .rally:
            guard f.rally != nil else { return rally(f) }
            return started("نقطة التجمع")
        case .station:
            if case let .loaded(rows)? = f.stations, let s = rows.min(by: { $0.distanceMeters < $1.distanceMeters }) { return started(s.name) }
            return AssistantAnswer(text: "أفتح لك المحطات القريبة، اختر وحدة.", spoken: .system("أفتح لك المحطات القريبة، اختر وحدة"), action: .openStations)
        case .back:
            guard f.hasBackTrail else {
                return AssistantAnswer(text: "ما عندي مسار مسجّل أرجعك عليه.", spoken: .system("ما عندي مسار مسجّل أرجعك عليه"))
            }
            return AssistantAnswer(kind: .done, text: "بدأنا طريق الرجعة على مسارك.", spoken: .clips(["sun_10"], text: "بدأنا درب الرجعة."), action: .navigate(.back))
        case let .member(n):
            guard let m = f.others.first(where: { $0.name == n }) else {
                return AssistantAnswer(kind: .clarify, text: "ما لقيت \(n) في الطلعة.", spoken: .system("ما لقيت \(n) في الطلعة"))
            }
            var a = started(m.name)
            if m.presence != .live {
                a.detail = "موقع \(m.name) قديم: التوجيه لآخر مكان وصلنا منه."
                a.stale = true
            }
            return a
        }
    }

    static func radio(_ play: Bool, _ f: AssistantFacts) -> AssistantAnswer {
        guard f.radio.available else {
            return AssistantAnswer(text: "إذاعة الطلعة مو متاحة الحين.", spoken: .system("إذاعة الطلعة مو متاحة الحين"))
        }
        if play {
            if f.radio.muted, f.radio.title != nil {
                return AssistantAnswer(kind: .done, text: "رجّعنا صوت الإذاعة عندك: \(f.radio.title ?? "").", spoken: .clips(["x_16"], text: "تمام."), action: .radioPlay)
            }
            if f.radio.playing { return AssistantAnswer(text: "الإذاعة شغّالة: \(f.radio.title ?? "").", spoken: .system("الإذاعة شغّالة")) }
            if f.radio.canControl, f.radio.title != nil {
                return AssistantAnswer(kind: .done, text: "شغّلنا الإذاعة للطلعة.", spoken: .clips(["x_16"], text: "تمام."), action: .radioPlay)
            }
            return AssistantAnswer(text: "أفتح لك إذاعة الطلعة، اختر وش تسمع.", spoken: .system("أفتح لك إذاعة الطلعة"), action: .openRadio)
        }
        guard f.radio.playing, !f.radio.muted else {
            return AssistantAnswer(text: "الإذاعة مو شغّالة عندك.", spoken: .system("الإذاعة مو شغّالة عندك"))
        }
        /* Only this phone goes quiet; stopping it for everyone stays the leader's button. */
        return AssistantAnswer(kind: .done, text: "سكّتنا الإذاعة عندك، والطلعة تكمّل تسمع.", spoken: .clips(["x_16"], text: "تمام."), action: .radioMute)
    }

    static func channel(_ n: Int, _ f: AssistantFacts) -> AssistantAnswer {
        let id = String(n)
        let name = PTTChannels.publicName(id)
        guard f.channelsAvailable else {
            return AssistantAnswer(text: "الترددات مو متاحة في هذي الطلعة.", spoken: .system("الترددات مو متاحة في هذي الطلعة"))
        }
        if f.currentChannel == id { return AssistantAnswer(text: "أنت على \(name) أصلًا.", spoken: .system("أنت على \(name) أصلًا")) }
        return AssistantAnswer(kind: .done, text: "حوّلناك على \(name).", spoken: .system("حوّلناك على \(name)"), action: .setChannel(id))
    }

    static func chat(_ f: AssistantFacts) -> AssistantAnswer {
        guard f.chatAvailable else {
            return AssistantAnswer(text: "المحادثات مو متاحة الحين.", spoken: .system("المحادثات مو متاحة الحين"))
        }
        return AssistantAnswer(kind: .done, text: "فتحنا المحادثات.", spoken: .clips(["x_16"], text: "تمام."), action: .openChat)
    }

    /// Never sends anything: says where the button is and what it does.
    static func sos() -> AssistantAnswer {
        let text = "زر الطوارئ (SOS) الأحمر تحت، وعلى يسار الشاشة: اضغط عليه ثانية كاملة، يوصل نداءك وموقعك لكل الربع. وإذا غرّزتوا، «غرّزت» في «أدوات ← السلامة». أنا ما أرسل نداء الفزعة بنفسي."
        return AssistantAnswer(text: text, spoken: .system("زر الطوارئ الأحمر على يسار الشاشة. اضغط عليه ثانية كاملة، يوصل نداءك وموقعك لكل الربع. أنا ما أرسل نداء الفزعة بنفسي"),
                               showsSOSButton: true)
    }
}
