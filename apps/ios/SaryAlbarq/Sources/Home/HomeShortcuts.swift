import Foundation

/// «البيت» and «الشغل» on the home sheet: two places kept on this phone only (never sent).
enum HomeShortcut: String, CaseIterable, Identifiable, Codable {
    case home, work

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "البيت"
        case .work: return "الشغل"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .work: return "briefcase.fill"
        }
    }
}

enum HomeShortcutStore {
    static let key = "sary.home.shortcuts.v1"

    static func load(defaults: UserDefaults = .standard) -> [HomeShortcut: OutingDestination] {
        guard let d = defaults.data(forKey: key),
              let raw = try? JSONDecoder().decode([String: OutingDestination].self, from: d) else { return [:] }
        var out: [HomeShortcut: OutingDestination] = [:]
        for (k, v) in raw {
            if let s = HomeShortcut(rawValue: k), PlanGeo.valid(lat: v.lat, lng: v.lng) { out[s] = v }
        }
        return out
    }

    static func set(_ s: HomeShortcut, _ d: OutingDestination?, defaults: UserDefaults = .standard) {
        var all = load(defaults: defaults)
        all[s] = d
        let raw = Dictionary(uniqueKeysWithValues: all.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) { defaults.set(data, forKey: key) }
    }

    static func forget(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}

/// The category chips over the home map and in the raised sheet. Everyday places first,
/// then the desert (our difference): نفود، روضة، فيضة، مخيمات، أمطار وربيع.
struct HomeCategory: Identifiable, Equatable {
    var id: String
    var label: String
    var systemImage: String
    /// What the place search is asked.
    var query: String
    /// A desert category (drawn with the sand tint).
    var desert = false
    /// Where a desert chip's places come from («دليل البر» or the rain/green search); nil for
    /// the everyday ones, which ask the place search with `query`.
    var desertSource: DesertCategorySource? = nil

    static let city: [HomeCategory] = [
        .init(id: "restaurants", label: "مطاعم", systemImage: "fork.knife", query: "مطعم"),
        .init(id: "cafes", label: "مقاهي", systemImage: "cup.and.saucer.fill", query: "مقهى"),
        .init(id: "mosques", label: "مساجد", systemImage: "building.columns.fill", query: "مسجد"),
        .init(id: "fuel", label: "محطات وقود", systemImage: "fuelpump.fill", query: "محطة وقود"),
        .init(id: "airports", label: "المطارات", systemImage: "airplane", query: "مطار"),
    ]

    static let desertOnes: [HomeCategory] = [
        .init(id: "nufud", label: "نفود", systemImage: "mountain.2.fill", query: "نفود", desert: true, desertSource: .gazetteer(.nafud)),
        .init(id: "rawda", label: "روضة", systemImage: "leaf.fill", query: "روضة", desert: true, desertSource: .gazetteer(.rawda)),
        .init(id: "faydah", label: "فيضة", systemImage: "drop.fill", query: "فيضة", desert: true, desertSource: .gazetteer(.fayda)),
        .init(id: "camps", label: "مخيمات", systemImage: "tent.fill", query: "مخيمات", desert: true, desertSource: .gazetteer(.camp)),
        .init(id: "rain", label: "أمطار وربيع", systemImage: "cloud.rain.fill", query: "أمطار وربيع", desert: true, desertSource: .rainGreen("مطر|ربيع")),
    ]

    /// The order on the map: two everyday, then the desert, then the rest (one row that scrolls).
    static let all: [HomeCategory] = city + desertOnes
}

/// Pure rules for the home sheet (unit-tested in HomeFlowTests).
enum HomeSheetRules {
    /// Collapsed: the search bar, the shortcuts and one line of what is happening.
    static let collapsedHeight: Double = 200
    /// Raised: most of the screen, the map still peeks above.
    static func expandedHeight(screen: Double) -> Double { max(collapsedHeight, screen * 0.82) }

    /// Collapsed with its one state card: a one-line card, or the first-time card with two actions.
    static func collapsedHeight(card: HomeStateCard) -> Double {
        switch card {
        case .none: return collapsedHeight
        case .active, .upcoming, .failed: return collapsedHeight + 78
        case .start: return collapsedHeight + 128
        case .invite: return collapsedHeight + 150
        }
    }

    /// The collapsed height for the current text size: `textScale` is the body text's scale
    /// (1 at the default size). Text in the collapsed sheet grows with Dynamic Type while the
    /// sheet stayed fixed, so its card was cut off (collapsed, nothing scrolls); the sheet now
    /// grows with it, up to 1.4×, and `frameHeight` still keeps the map visible above it.
    static func collapsedHeight(card: HomeStateCard, textScale: Double) -> Double {
        let k = textScale.isFinite ? min(1.4, max(1, textScale)) : 1
        return (collapsedHeight(card: card) * k).rounded()
    }

    /// Clamp a GeometryReader's first (sometimes zero) measurement before it reaches `.frame`.
    /// SwiftUI may lay out the home screen once before safe-area insets are available.
    static func frameHeight(screen: Double, preferred: Double, drag: Double) -> Double {
        let measured = screen.isFinite ? max(0, screen) : 0
        let desired = preferred.isFinite ? preferred : collapsedHeight
        let offset = drag.isFinite ? drag : 0
        let available = max(160, min(760, measured - 60))
        return min(available, max(160, desired - offset))
    }

    /// The finger's offset since the drag was recognized: `DragGesture` reports its first change only
    /// after `minimumDistance`, and applying that whole translation made the sheet jump that far at once.
    static func dragOffset(translation: Double, origin: Double) -> Double {
        guard translation.isFinite else { return 0 }
        return translation - (origin.isFinite ? origin : 0)
    }

    /// Where the sheet settles after a drag (true = expanded): the rest height nearest to where the
    /// release would carry it — the start height moved by the gesture's predicted end translation
    /// (> 0 is downwards; includes the release velocity). A slow drag stopped short goes back; a
    /// drag past the middle, or a flick, goes on.
    static func settle(expanded: Bool, collapsedHeight: Double, expandedHeight: Double, predictedTranslation: Double) -> Bool {
        /* One rest height (the picked-place card, a tiny screen): nothing to choose, keep the state. */
        guard abs(expandedHeight - collapsedHeight) > 0.5 else { return expanded }
        let start = expanded ? expandedHeight : collapsedHeight
        let projected = start - (predictedTranslation.isFinite ? predictedTranslation : 0)
        return abs(projected - expandedHeight) < abs(projected - collapsedHeight)
    }
}

/// The ONE state card on the collapsed home sheet (UI-AUDIT §٢ «الرئيسية»), decided here and
/// unit-tested in HomeFlowTests: a running outing, else the planned / paused one, else (first
/// time, or nothing current) «أنشئ طلعة وادعُ أصدقاءك» with «انضم برابط».
enum HomeStateCard: Equatable {
    /// «طلعتك جارية».
    case active(String)
    /// Installed from an invite page and the link was never pasted: «جاي من دعوة؟» stays on the
    /// home after onboarding (the system «لصق» button reads it).
    case invite
    /// «طلعتك القادمة»: planned (not started) or paused.
    case upcoming(String)
    /// «أنشئ طلعة وادعُ أصدقاءك» + «انضم برابط».
    case start
    /// The list could not load and nothing is on screen: say so (never an empty home).
    case failed(String)
    /// Still loading the first list: nothing yet (no flash of «أنشئ طلعة»).
    case none

    static func pick(current: [OutingSummary], phase: ListPhase, inviteHint: Bool = false) -> HomeStateCard {
        if let a = current.first(where: { $0.status == .active }) { return .active(a.id) }
        if inviteHint { return .invite }
        if let u = upcoming(current) { return .upcoming(u.id) }
        switch phase {
        case .loaded: return .start
        case let .failed(m): return current.isEmpty ? .failed(m) : .start
        case .loading: return current.isEmpty ? .none : .start
        }
    }

    /// The outing «طلعتك القادمة» is about: a paused one first (it already ran), then a planned one.
    static func upcoming(_ current: [OutingSummary]) -> OutingSummary? {
        current.first { $0.status == .paused } ?? current.first { $0.status == .created }
    }
}

/// The main action of the picked-place card (unit-tested in HomeFlowTests). Never a second
/// outing while one I lead is running or planned.
enum HomePlaceAction: Equatable {
    /// No outing of mine to add it to: «أنشئ طلعة».
    case create
    /// I lead the running outing: «وجّه القافلة إلى هنا».
    case guideConvoy(String)
    /// A member of the running outing: «ابدأ مشوارًا لنفسي».
    case personalLeg(String)
    /// I lead a planned / paused outing: «أضفها لطلعتك» (its destination, or the next stop).
    case addToOuting(String)

    var title: String {
        switch self {
        case .create: return "أنشئ طلعة"
        case .guideConvoy: return "وجّه القافلة إلى هنا"
        case .personalLeg: return "ابدأ مشوارًا لنفسي"
        case .addToOuting: return "أضفها لطلعتك"
        }
    }

    var systemImage: String {
        switch self {
        case .create: return "plus"
        case .guideConvoy, .personalLeg: return "car.2.fill"
        case .addToOuting: return "text.badge.plus"
        }
    }

    /// Members cannot edit a plan (it is the leader's), so only an outing I own takes the place.
    static func pick(current: [OutingSummary]) -> HomePlaceAction {
        if let a = current.first(where: { $0.status == .active }) {
            return a.role == "owner" ? .guideConvoy(a.id) : .personalLeg(a.id)
        }
        if let u = HomeStateCard.upcoming(current), u.role == "owner" { return .addToOuting(u.id) }
        return .create
    }
}

/// «أضفها لطلعتك»: the place becomes the planned outing's destination when it has none,
/// else its next stop; the same place twice changes nothing (unit-tested in HomeFlowTests).
enum HomePlanEdit {
    enum Outcome: Equatable { case destination, stop, already, full }

    /// Within this distance it is the same place.
    static let sameM = 50.0
    /// The most stops a plan takes from here (more is a route to draw, not a list).
    static let maxStops = 10

    static func adding(_ d: OutingDestination, to plan: TripPlan) -> (plan: TripPlan, outcome: Outcome) {
        let p = LngLat(lng: d.lng, lat: d.lat)
        func same(_ o: OutingDestination) -> Bool { PlanGeo.meters(LngLat(lng: o.lng, lat: o.lat), p) < sameM }
        guard let dest = plan.destination else {
            var next = plan
            next.destination = d
            return (next, .destination)
        }
        if same(dest) || plan.stops.contains(where: same) { return (plan, .already) }
        if plan.stops.count >= maxStops { return (plan, .full) }
        var next = plan
        next.stops.append(d)
        return (next, .stop)
    }

    static func confirmation(_ o: Outcome, name: String) -> String {
        switch o {
        case .destination: return "صارت «\(name)» وجهة طلعتك"
        case .stop: return "أضفنا «\(name)» محطة في طلعتك"
        case .already: return "«\(name)» موجودة في طلعتك"
        case .full: return "خطة طلعتك فيها \(SaryFormat.number(maxStops)) محطات. عدّلها من تفاصيل الطلعة"
        }
    }
}

/// «طلعاتي» could not load (unit-tested in HomeFlowTests): said in Najdi, never an empty list.
enum HomeListCopy {
    static let failedTitle = "ما قدرنا نجيب طلعاتك"

    /// The server's own reason when it has one; the catch-all becomes plain words.
    static func failedDetail(_ message: String, online: Bool) -> String {
        guard online else { return "ما فيه إنترنت. نجيبها أول ما يرجع الاتصال." }
        let generic = [SaryCopy.genericError, "لا يوجد اتصال بالإنترنت.", ""]
        return generic.contains(message.trimmingCharacters(in: .whitespaces)) ? "صار خلل من طرفنا. جرّب مرة ثانية بعد شوي." : message
    }
}

// MARK: - Home V2 (the owner-approved redesign: one bar on top, one card at the bottom, two map buttons)

/// The home layout: V2 by default; the old layout (chips over the map, three side buttons, search
/// inside the sheet) stays reachable behind DEBUG `-SaryHomeV1`, like `StandaloneNavSwitch`.
enum HomeLayoutSwitch {
    static let argument = "-SaryHomeV1"

    /// True when the old layout was asked for (DEBUG builds only; Release is always V2).
    static func v1(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        #if DEBUG
        return arguments.contains(argument)
        #else
        return false
        #endif
    }

    static var isV2: Bool { !v1() }
}

/// The weather line on top of the V2 bottom card: «٢٤° صافي» and «المغرب ٥:١٢ م».
struct HomeWeatherLine: Equatable {
    /// Temperature and condition now; nil when no usable reading is kept (offline, expired).
    var weather: String?
    /// «المغرب …» by day, «الشروق …» by night: from the sun's position, no network.
    var sun: String?
}

/// Pure rules of the V2 bottom card (unit-tested in HomeFlowTests): which rows it shows for a
/// screen height, and how tall it is collapsed. Small screens (iPhone SE, 667 pt) drop the last
/// outing row first, then shrink the shortcut grid to icons.
enum HomeLayoutRules {
    enum Grid: Equatable { case tiles, icons }

    struct Plan: Equatable {
        var weatherLine: Bool
        /// The last ended outing as one row (only when no state card takes that slot).
        var recentRow: Bool
        var grid: Grid
    }

    /// Heights at the default text size (pt).
    static let handle = 44.0
    static let top = 12.0
    static let bottom = 40.0
    static let spacing = 12.0
    static let weatherRow = 22.0
    static let primaryRow = 52.0
    static let tilesRow = 82.0
    static let iconsRow = 52.0
    static let recentRowHeight = 64.0
    /// The collapsed card stays under this share of the screen: the map keeps the rest.
    static let maxShare = 0.46

    /// The state card in the outing slot (`HomeStateCard`): a one-line card, the invite card, or nothing.
    static func statusHeight(_ card: HomeStateCard) -> Double {
        switch card {
        case .active, .upcoming, .failed: return 72
        case .invite: return 150
        case .start, .none: return 0
        }
    }

    /// The rows for this screen. `narrow` (Display Zoom, `SaryWidthClass.narrow`) starts with icons.
    static func plan(screen: Double, textScale: Double = 1, narrow: Bool = false, weather: Bool, status: HomeStateCard, hasRecent: Bool) -> Plan {
        let budget = (screen.isFinite ? max(0, screen) : 0) * maxShare
        var p = Plan(weatherLine: weather, recentRow: hasRecent && statusHeight(status) == 0, grid: narrow ? .icons : .tiles)
        if height(p, status: status, textScale: textScale) > budget { p.recentRow = false }
        if height(p, status: status, textScale: textScale) > budget { p.grid = .icons }
        return p
    }

    /// The collapsed card's height for `p` (text grows with Dynamic Type, up to 1.4×).
    static func height(_ p: Plan, status: HomeStateCard, textScale: Double = 1) -> Double {
        let k = textScale.isFinite ? min(1.4, max(1, textScale)) : 1
        var rows = [primaryRow, p.grid == .tiles ? tilesRow : iconsRow]
        if p.weatherLine { rows.append(weatherRow) }
        let s = statusHeight(status)
        if s > 0 { rows.append(s) }
        if p.recentRow { rows.append(recentRowHeight) }
        let content = rows.reduce(0, +) * k + spacing * Double(rows.count - 1)
        return (handle + top + content + bottom).rounded()
    }

    /// The line's two halves; nil (no line) without a position: nothing to say then.
    static func weatherLine(_ r: WeatherReport?, point: LngLat?, now: Date, timeZone: TimeZone = .current) -> HomeWeatherLine? {
        guard let point, PlanGeo.valid(lat: point.lat, lng: point.lng) else { return nil }
        var line = HomeWeatherLine()
        if let r, let now0 = WeatherRules.nowValue(r, now: now) {
            line.weather = "\(WeatherFormat.temp(now0.hour.temperatureC)) \(WeatherRules.displayCondition(now0.hour).text)"
        }
        let sun = PlaceBriefRules.sun(now: now, lat: point.lat, lng: point.lng)
        if sun.isDay, let set = sun.sunset {
            line.sun = "المغرب \(WeatherFormat.clock(set, timeZone: timeZone))"
        } else if let rise = sun.sunrise {
            line.sun = "الشروق \(WeatherFormat.clock(rise, timeZone: timeZone))"
        }
        return line.weather == nil && line.sun == nil ? nil : line
    }
}
