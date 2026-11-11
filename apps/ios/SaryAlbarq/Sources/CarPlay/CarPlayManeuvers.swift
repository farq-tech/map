import CarPlay
import UIKit

// The road route → CarPlay's own navigation types (CPManeuver, CPLaneGuidance, CPRouteChoice).
// Values come from the phone's navigation (`NavSnapshot` via `CarPlayNavAdapter`); this file only
// shapes them. Tested in Tests/CarPlayManeuverTests.swift.

enum CarPlayManeuverMapper {
    /// Saudi Arabia drives on the right.
    static let trafficSide = "right"

    /// Instruction variants, longest first (CarPlay picks the one that fits). Always Arabic,
    /// never empty: an empty router text becomes the action («انعطف يمين»).
    static func instructionVariants(_ m: CarPlayRoadManeuver) -> [String] {
        var out: [String] = []
        for t in [m.instruction, m.shortInstruction ?? ""] {
            let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty, !out.contains(s) { out.append(s) }
        }
        return out.isEmpty ? ["تابع"] : out
    }

    /// The step's own time when the router gave one (Mapbox: traffic-aware); else from the
    /// car's real speed; else none (never an invented ETA).
    static func estimates(distanceM: Double, durationS: Double?, speed: Double?) -> CPTravelEstimates {
        let t: TimeInterval
        if let d = durationS, d > 0 { t = d } else if let v = speed, v > 2 { t = distanceM / v } else { t = 0 }
        return CPTravelEstimates(distanceRemaining: Measurement(value: max(0, distanceM), unit: UnitLength.meters), timeRemaining: max(0, t))
    }

    /// The whole route's estimate: the router's remaining time (traffic) wins.
    static func tripEstimates(remainingM: Double, remainingS: Double?, speed: Double?) -> CPTravelEstimates {
        estimates(distanceM: remainingM, durationS: remainingS, speed: speed)
    }

    /// `NavGlyph.carPlayType` names → `CPManeuverType` raw values (iOS 17.4+). Unknown → nil.
    static func maneuverTypeRaw(_ name: String?) -> UInt? {
        guard let name else { return nil }
        if name.hasPrefix("roundaboutExit"), let n = Int(name.dropFirst("roundaboutExit".count)), (1...19).contains(n) {
            return 27 + UInt(n)   // CPManeuverTypeRoundaboutExit1 = 28
        }
        let table: [String: UInt] = [
            "noTurn": 0, "leftTurn": 1, "rightTurn": 2, "straightAhead": 3, "uTurn": 4, "followRoad": 5,
            "enterRoundabout": 6, "exitRoundabout": 7, "offRamp": 8, "onRamp": 9, "arriveEndOfNavigation": 10,
            "startRoute": 11, "arriveAtDestination": 12, "keepLeft": 13, "keepRight": 14,
            "highwayOffRampLeft": 22, "offRampLeft": 22, "highwayOffRampRight": 23, "offRampRight": 23,
            "sharpLeftTurn": 47, "sharpRightTurn": 48, "slightLeftTurn": 49, "slightRightTurn": 50,
            "changeHighway": 51, "highwayMerge": 51,
        ]
        return table[name]
    }

    /// Lane angle in degrees (0 = straight, + = right) for one painted arrow.
    static func angle(_ d: NavTurnDirection) -> Double {
        switch d {
        case .straight: return 0
        case .slightRight: return 45
        case .right: return 90
        case .sharpRight: return 135
        case .slightLeft: return -45
        case .left: return -90
        case .sharpLeft: return -135
        /* Right-hand traffic: a U-turn is drawn on the left. */
        case .uTurn: return -180
        }
    }

    /// The angle a lane is highlighted with: the arrow that matches the maneuver, else its first.
    static func highlighted(_ lane: NavLane, turn: NavTurnDirection?) -> Double? {
        guard lane.valid, let first = lane.directions.first else { return nil }
        if let turn, lane.directions.contains(turn) { return angle(turn) }
        return angle(first)
    }

    static func symbol(_ name: String, size: CGFloat = 64, tint: UIColor = .white) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .bold))?
            .withTintColor(tint, renderingMode: .alwaysOriginal)
    }

    /// One CPManeuver, fully filled: Arabic variants, symbol (also for the dashboard / cluster),
    /// estimates, the maneuver type and traffic side (iOS 17.4+).
    static func maneuver(_ m: CarPlayRoadManeuver, speed: Double?) -> CPManeuver {
        let c = CPManeuver()
        let v = instructionVariants(m)
        c.instructionVariants = v
        c.dashboardInstructionVariants = [v.last ?? v[0]]
        c.symbolImage = symbol(m.symbol)
        c.dashboardSymbolImage = symbol(m.symbol, size: 32)
        c.initialTravelEstimates = estimates(distanceM: m.distanceM, durationS: m.durationS, speed: speed)
        c.userInfo = m.cpManeuverType
        if #available(iOS 17.4, *) {
            c.trafficSide = .right
            if let raw = maneuverTypeRaw(m.cpManeuverType), let t = CPManeuverType(rawValue: raw) { c.maneuverType = t }
        }
        return c
    }

    /// CarPlay lane guidance for a maneuver (iOS 18+ initialisers). Nil without lane data.
    @available(iOS 18.0, *)
    static func laneGuidance(_ m: CarPlayRoadManeuver, turn: NavTurnDirection?) -> CPLaneGuidance? {
        guard !m.lanes.isEmpty, m.lanes.contains(where: \.valid) else { return nil }
        let g = CPLaneGuidance()
        g.lanes = m.lanes.map { lane in
            let angles = (lane.directions.isEmpty ? [.straight] : lane.directions).map { Measurement(value: angle($0), unit: UnitAngle.degrees) }
            if let h = highlighted(lane, turn: turn) {
                return CPLane(angles: angles, highlightedAngle: Measurement(value: h, unit: UnitAngle.degrees), isPreferred: lane.preferred)
            }
            return CPLane(angles: angles)
        }
        g.instructionVariants = [laneLine(m.lanes)]
        return g
    }

    /// «خذ المسار الأيمن» / «المسارات الوسطى» — a short Arabic line for the lane card.
    static func laneLine(_ lanes: [NavLane]) -> String {
        let ok = lanes.indices.filter { lanes[$0].valid }
        guard !ok.isEmpty, ok.count < lanes.count else { return "أي مسار" }
        if ok.count == 1 {
            if ok[0] == lanes.count - 1 { return "خذ المسار الأيمن" }
            if ok[0] == 0 { return "خذ المسار الأيسر" }
            return "خذ المسار اللي في النص"
        }
        if ok.last == lanes.count - 1 { return "خلك يمين" }
        if ok.first == 0 { return "خلك يسار" }
        return "خلك في النص"
    }

    // MARK: trip preview («الأسرع / الأقصر»)

    struct ChoiceText: Equatable {
        var id: String
        var summary: [String]
        var info: [String]
        var selection: [String]
    }

    /// The preview's route choices: the fastest first, labelled «الأسرع»; the shortest «الأقصر»
    /// when it is another route; the rest «طريق ثاني». Times are the router's (traffic).
    static func choices(_ options: [CarPlayRouteOption]) -> [ChoiceText] {
        guard !options.isEmpty else { return [] }
        let fastest = options.min { $0.durationS < $1.durationS }!.id
        let shortest = options.min { $0.distanceM < $1.distanceM }!.id
        let ordered = options.sorted { a, b in
            func rank(_ o: CarPlayRouteOption) -> Int { o.id == fastest ? 0 : (o.id == shortest ? 1 : 2) }
            return rank(a) != rank(b) ? rank(a) < rank(b) : a.durationS < b.durationS
        }
        return ordered.map { o in
            let label = o.id == fastest ? (o.id == shortest ? "الأسرع والأقصر" : "الأسرع") : (o.id == shortest ? "الأقصر" : "طريق ثاني")
            let time = NavText.remaining(seconds: o.durationS)
            let dist = ArabicFormat.distance(o.distanceM)
            var info = "\(time) · \(dist)"
            if o.hasUnpaved { info += " · فيه ترابي" }
            let via = (o.via ?? "").trimmingCharacters(in: .whitespaces)
            return ChoiceText(id: o.id, summary: via.isEmpty ? [label] : ["\(label) · \(via)", label],
                              info: [info], selection: [label + " · " + time])
        }
    }

    static func routeChoices(_ options: [CarPlayRouteOption]) -> [CPRouteChoice] {
        choices(options).map { t in
            let c = CPRouteChoice(summaryVariants: t.summary, additionalInformationVariants: t.info, selectionSummaryVariants: t.selection)
            c.userInfo = t.id
            return c
        }
    }

    static let previewText = (start: "يلّا", more: "طرق ثانية", overview: "نظرة عامة")
}

// MARK: - recent destinations («الأخيرة»)

/// The last places driven to from the car (search, members excluded: they move). Kept on the
/// phone only, at most `max`, newest first, no duplicates within ~50 m.
struct CarPlayRecents: Equatable {
    struct Place: Equatable, Codable {
        var name: String
        var lat: Double
        var lng: Double
        var position: LngLat { LngLat(lng: lng, lat: lat) }
    }

    static let key = "sary.carplay.recents.v1"
    static let max = 6
    private(set) var places: [Place] = []

    init(places: [Place] = []) { self.places = Array(places.prefix(Self.max)) }

    mutating func add(name: String, at p: LngLat) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        places.removeAll { Vehicle.distanceMeters($0.position, p) < 50 || $0.name == n }
        places.insert(Place(name: n, lat: p.lat, lng: p.lng), at: 0)
        if places.count > Self.max { places = Array(places.prefix(Self.max)) }
    }

    static func load(_ d: UserDefaults = .standard) -> CarPlayRecents {
        guard let data = d.data(forKey: key), let p = try? JSONDecoder().decode([Place].self, from: data) else { return .init() }
        return .init(places: p)
    }

    func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(places) { d.set(data, forKey: Self.key) }
    }
}

// MARK: - «وين نروح؟» (the destinations list, as plain rows)

struct CarPlayDestinationRow: Equatable {
    enum Action: Equatable {
        case trip(CarPlayTripKind)
        /// «روح لفلان»: their LIVE position only.
        case member(id: String, name: String, position: LngLat)
        case place(name: String, position: LngLat)
        /// Not usable now; says why (a stale member).
        case disabled
    }

    var title: String
    var detail: String
    var symbol: String
    var action: Action
}

enum CarPlayDestinations {
    /// Sections in order: «الطلعة», «العيال», «الأخيرة». Empty sections are left out.
    static func sections(_ i: CarPlayInput, trail: Trail, recents: CarPlayRecents) -> [(header: String, rows: [CarPlayDestinationRow])] {
        var out: [(String, [CarPlayDestinationRow])] = []
        var outing: [CarPlayDestinationRow] = []
        for kind in CarPlayPresenter.availableTrips(i, trail: trail) {
            switch kind {
            case .destination:
                let d = CarPlayPresenter.destination(i)!
                outing.append(.init(title: "الوجهة: \(i.destination?.label.isEmpty == false ? i.destination!.label : "الوجهة")",
                                    detail: CarPlayPresenter.tripLine(i) ?? CarPlayPresenter.distanceAndDirection(from: i.myPosition, to: d.position)?.text ?? "",
                                    symbol: "mappin.and.ellipse", action: .trip(.destination)))
            case .rally:
                let r = CarPlayPresenter.rally(i)!
                outing.append(.init(title: "نقطة التجمع: \(r.label)",
                                    detail: CarPlayPresenter.distanceAndDirection(from: i.myPosition, to: r.position)?.text ?? "",
                                    symbol: "flag.fill", action: .trip(.rally)))
            case .wayBack:
                let d = trail.start.flatMap { st in i.myPosition.map { Vehicle.distanceMeters($0, st.position) } }
                outing.append(.init(title: SaryCopy.backTrack, detail: "على مسارك المسجّل" + (d.map { " · البداية على بعد \(ArabicFormat.distance($0))" } ?? ""),
                                    symbol: "arrow.uturn.backward", action: .trip(.wayBack)))
            case .place: break
            }
        }
        if !outing.isEmpty { out.append(("الطلعة", outing)) }
        let members = CarPlayPresenter.memberRows(i).map { r -> CarPlayDestinationRow in
            if r.isLive, let p = r.position {
                return .init(title: "روح لـ\(r.shortName)", detail: r.detail, symbol: "car.fill", action: .member(id: r.id, name: r.name, position: p))
            }
            /* Never drive anyone to where somebody WAS. */
            return .init(title: r.shortName, detail: r.detail, symbol: "car", action: .disabled)
        }
        if !members.isEmpty { out.append(("الأصدقاء", members)) }
        let recent = recents.places.map { p in
            CarPlayDestinationRow(title: p.name, detail: CarPlayPresenter.distanceAndDirection(from: i.myPosition, to: p.position)?.text ?? "",
                                  symbol: "clock.arrow.circlepath", action: .place(name: p.name, position: p.position))
        }
        if !recent.isEmpty { out.append(("الأخيرة", recent)) }
        return out
    }
}
