import CoreLocation
import Foundation

/// «البوصلة» while driving (owner's request, 2026-11-12): a round dial bottom-left whose rose turns
/// with the car (course-up) and whose orange needle leads to the chosen target — «الوجهة»، «الرجعة»،
/// «القبلة»، «أقرب مطر»، «أقرب ربيع». Pure rules here (unit-tested in `DestinationCompassTests`); the
/// view is `DestinationCompassView`. The needle points at the target itself, relative to the car. Everything is computed on this phone: nothing leaves it except the
/// bbox the rain / spring lookups send (the same as the weather layers, no user id).
enum DestinationCompass {
    enum Target: String, CaseIterable, Equatable, Identifiable {
        case destination, back, qibla, rain, spring
        var id: String { rawValue }
    }

    // MARK: Path lookahead («على المسار»)

    /// The needle aims this far ahead of my snapped place on the path …
    static let lookaheadM = 300.0
    /// … and this far when slow (below `slowBelowMps`) or when the speed is unknown.
    static let slowLookaheadM = 150.0
    static let slowBelowMps = 30.0 / 3.6
    /// Further than this from the path: the needle leads back to its nearest point («ارجع للمسار»).
    static let offPathM = 150.0

    /// Where the needle aims along a path, and what is left along it.
    struct PathGuide: Equatable {
        /// The lookahead point (on the path), or the nearest point on it when I am off the path.
        var aim: LngLat
        /// Along the path from my snapped place to its end (plus the way back onto it when off it).
        var remainingM: Double
        var offPath: Bool
        /// My distance from the path.
        var offsetM: Double
    }

    static func lookahead(speedMps: Double?) -> Double {
        guard let s = speedMps, s.isFinite, s >= slowBelowMps else { return slowLookaheadM }
        return lookaheadM
    }

    /// Snaps `me` to the nearest point of `path` (in travel order) and aims `lookahead(speedMps:)` metres
    /// further along it; off the path, at the nearest point. Nil without a path (fewer than two points).
    /// `cum`: the running metres at each vertex when the caller has them cached (`NavRouteMetrics`).
    static func guide(path: [LngLat], me: LngLat, speedMps: Double?, cum: [Double]? = nil) -> PathGuide? {
        guard path.count >= 2 else { return nil }
        let c: [Double]
        if let cum, cum.count == path.count { c = cum } else { c = NavRouteMetrics.cumulative(path) }
        var bestSeg = 0
        var bestPoint = path[0]
        var bestU = 0.0
        var bestD = Double.infinity
        for i in 0..<(path.count - 1) {
            let pr = TrailGeo.project(me, path[i], path[i + 1])
            if pr.distM < bestD {
                bestSeg = i
                bestPoint = pr.point
                bestU = pr.u
                bestD = pr.distM
            }
        }
        let along = c[bestSeg] + (c[bestSeg + 1] - c[bestSeg]) * bestU
        let total = c[c.count - 1]
        let off = bestD > offPathM
        let aim = off ? bestPoint : point(path, cum: c, atAlong: along + lookahead(speedMps: speedMps))
        return PathGuide(aim: aim, remainingM: max(0, total - along) + (off ? bestD : 0), offPath: off, offsetM: bestD)
    }

    /// The point `m` metres along `path` (clamped to its ends).
    static func point(_ path: [LngLat], cum c: [Double], atAlong m: Double) -> LngLat {
        guard path.count >= 2, c.count == path.count else { return path.first ?? LngLat(lng: 0, lat: 0) }
        let m = max(0, min(c[c.count - 1], m))
        var i = 1
        while i < c.count - 1, c[i] < m { i += 1 }
        let a = path[i - 1], b = path[i]
        let seg = c[i] - c[i - 1]
        let u = seg > 0 ? (m - c[i - 1]) / seg : 0
        return LngLat(lng: a.lng + (b.lng - a.lng) * u, lat: a.lat + (b.lat - a.lat) * u)
    }

    /// A route that stops short of the target (the router's last road): the straight rest is added to
    /// what is left, as the off-road card counts it (`NavOffRoad.thresholdM`).
    static func addingTail(_ g: PathGuide, pathEnd: LngLat?, target: LngLat) -> PathGuide {
        guard let end = pathEnd else { return g }
        let tail = PlanGeo.meters(end, target)
        guard tail >= NavOffRoad.thresholdM else { return g }
        var out = g
        out.remainingM += tail
        return out
    }

    // MARK: The reading

    struct Reading: Equatable {
        var target: Target
        /// Absolute bearing (0..<360) of the path's lookahead point (the target itself when there is no path).
        var aimBearing: Double
        /// Absolute bearing straight to the target itself.
        var targetBearing: Double
        /// What the centre shows: along the path when `onPath`, else the straight line.
        var distanceM: Double
        var straightM: Double
        /// A path leads the needle («على المسار»).
        var onPath: Bool
        var offPath: Bool
        /// The rose turns with the car (a trusted GPS course, else the phone's magnetometer); with neither, north stays up.
        var headingUp: Bool
        /// Where the car's heading came from.
        var headingSource: HeadingSource
        /// Rotation of the rose (−heading, −180…180), 0 north-up.
        var roseDegrees: Double
        /// Rotation of the needle from the top of the dial (−180…180): the straight line to the target itself,
        /// relative to the car, always (owner's definition of «بوصلة الوجهة»).
        var needleDegrees: Double
        /// The small ring marker: where the path leads (the lookahead point), only when a path exists.
        var markerDegrees: Double?
    }

    enum HeadingSource: String, Equatable { case course, magnetometer, none }

    static var kaaba: LngLat { LngLat(lng: Qibla.kaaba.longitude, lat: Qibla.kaaba.latitude) }

    /// The car's heading: the GPS course while moving (`Policy.trustedHeading`), else the phone's magnetometer
    /// (`compass`, already accuracy-filtered by `DeviceHeading`), else nil (north stays up).
    static func heading(course: Double?, speed: Double?, compass: Double?) -> (degrees: Double, source: HeadingSource)? {
        if let c = Policy.trustedHeading(course, speed: speed) { return (c, .course) }
        if let m = compass, m.isFinite { return ((m.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360), .magnetometer) }
        return nil
    }

    /// `course` / `speed`: my GPS course and speed; `compass`: the magnetometer heading, used only when the course is
    /// not trusted (parked or crawling). The needle is always the straight-line bearing to the target minus the car's
    /// heading; the path lookahead is the small marker.
    static func reading(me: LngLat, course: Double?, speed: Double?, compass: Double? = nil, target: LngLat, kind: Target, guide: PathGuide? = nil) -> Reading {
        let from = CLLocationCoordinate2D(latitude: me.lat, longitude: me.lng)
        let straight = kind == .qibla ? Qibla.distanceKm(from: from) * 1000 : PlanGeo.meters(me, target)
        let targetBearing = kind == .qibla ? Qibla.bearing(from: from) : PlanGeo.bearing(me, target)
        let aimBearing = guide.map { PlanGeo.bearing(me, $0.aim) } ?? targetBearing
        let h = heading(course: course, speed: speed, compass: compass)
        let ref = h?.degrees ?? 0
        return Reading(target: kind, aimBearing: aimBearing, targetBearing: targetBearing,
                       distanceM: guide?.remainingM ?? straight, straightM: straight,
                       onPath: guide != nil, offPath: guide?.offPath ?? false, headingUp: h != nil,
                       headingSource: h?.source ?? .none,
                       roseDegrees: h.map { NavOffRoad.arrowDegrees(bearing: 0, reference: $0.degrees) } ?? 0,
                       needleDegrees: NavOffRoad.arrowDegrees(bearing: targetBearing, reference: ref),
                       markerDegrees: guide == nil ? nil : NavOffRoad.arrowDegrees(bearing: aimBearing, reference: ref))
    }

    /// The angle to animate to from `previous` (an accumulated angle): the short way round, so
    /// 359° → 1° turns 2°, not 358° back.
    static func unwrap(previous: Double, next: Double) -> Double {
        previous + NavOffRoad.arrowDegrees(bearing: next, reference: previous)
    }

    // MARK: Which target

    /// The chosen target while it is available; otherwise «الوجهة» when there is one, else «الرجعة»
    /// when returning, else «القبلة» (always available).
    static func resolve(chosen: Target?, available: Set<Target>, returning: Bool) -> Target {
        if let chosen, available.contains(chosen) { return chosen }
        if available.contains(.destination) { return .destination }
        if returning, available.contains(.back) { return .back }
        return .qibla
    }

    /// Driving or guiding, at the sheet's peek, nothing else holding the corner: not exploring, not after
    /// the end, off the route too (when it is most needed; `offRoad` is kept for call sites), not with my SOS on or the alerts' list
    /// open, and not on a short screen (iPhone SE: the dial would meet SOS and the dock, `LiveFit`).
    static func shows(driving: Bool, guiding: Bool, offRoad: Bool, exploring: Bool, ended: Bool, peek: Bool,
                      sosFocused: Bool, bellOpen: Bool, screenHeight: CGFloat) -> Bool {
        (driving || guiding) && !exploring && !ended && peek && !sosFocused && !bellOpen
            && !LiveFit.compactHeight(screenHeight)
    }

    // MARK: Words

    static func title(_ t: Target) -> String {
        switch t {
        case .destination: return "الوجهة"
        case .back: return "الرجعة"
        case .qibla: return "القبلة"
        case .rain: return "أقرب مطر"
        case .spring: return "أقرب ربيع"
        }
    }

    static func icon(_ t: Target) -> String {
        switch t {
        case .destination: return "flag.checkered"
        case .back: return "arrow.uturn.backward"
        case .qibla: return "location.north.circle"
        case .rain: return "cloud.rain"
        case .spring: return "leaf"
        }
    }

    /// The small line under the distance.
    static func caption(_ r: Reading) -> String {
        guard r.onPath else { return "خط مستقيم" }
        return r.offPath ? "ارجع للمسار" : "على المسار"
    }

    /// What the target itself is called in «… نفسها باتجاه …».
    private static func endName(_ t: Target) -> String {
        t == .back ? "نقطة البداية" : "الوجهة نفسها"
    }

    /// VoiceOver: «الوجهة: باقي ١٢ كم على المسار، الوجهة نفسها باتجاه الشمال»، «أقرب مطر: ٢٣ كم، باتجاه الغرب».
    static func accessibility(_ r: Reading, detail: String? = nil) -> String {
        let name = title(r.target)
        let dist = SaryFormat.distance(meters: r.distanceM)
        let dir = NavText.compassDefinite(r.targetBearing)
        var s: String
        if r.onPath {
            s = r.offPath
                ? "\(name): ارجع للمسار، باقي \(dist)، \(endName(r.target)) باتجاه \(dir)"
                : "\(name): باقي \(dist) على المسار، \(endName(r.target)) باتجاه \(dir)"
        } else {
            s = "\(name): \(dist)، باتجاه \(dir)"
        }
        if let detail, !detail.isEmpty { s += "، \(detail)" }
        return s
    }

    static let noDestination = "ما فيه وجهة"
    static let noTrail = "ما فيه مسار مسجّل"
    static let needsInternet = "يحتاج إنترنت"
    static let loading = "نجيب البيانات…"

    // MARK: Lookups (rain, spring)

    /// The bbox sent for «أقرب مطر» / «أقرب ربيع»: about ±1.5° around me (`w,s,e,n`).
    static let bboxHalfDeg = 1.5
    static let cacheS: TimeInterval = 15 * 60
    /// Moved this far from where the last lookup was made: look again.
    static let refetchMovedM = 30_000.0

    static func bbox(around me: LngLat, half: Double = bboxHalfDeg) -> String {
        [me.lng - half, me.lat - half, me.lng + half, me.lat + half].map { String(format: "%.2f", $0) }.joined(separator: ",")
    }

    static func needsFetch(fetchedAt: Date?, origin: LngLat?, me: LngLat, now: Date) -> Bool {
        guard let fetchedAt, let origin else { return true }
        if now.timeIntervalSince(fetchedAt) >= cacheS { return true }
        return PlanGeo.meters(origin, me) >= refetchMovedM
    }
}

// MARK: - «أقرب مطر»

/// One cell of `GET /api/weather/rain/recent` (`grid.cells`: `[lng, lat, mm, hours_since_rain]`).
struct CompassRainCell: Equatable {
    var position: LngLat
    var mm: Double
    var hoursAgo: Double?
}

/// The part of `GET /api/weather/rain/recent` the compass reads.
struct RecentRainResponse: Decodable {
    struct Grid: Decodable {
        var cells: [[Double?]]
    }

    var ok: Bool?
    var grid: Grid?
    var message_ar: String?
}

enum CompassRain {
    /// Real rain first: the nearest cell with at least this much …
    static let strongMm = 5.0
    /// … else the nearest with any measurable rain.
    static let minMm = 1.0
    static let credit = "NASA GPM IMERG"
    static let none = "ما فيه مطر قريب آخر ٢٤ ساعة"
    static let failed = "ما قدرنا نجيب بيانات المطر الحين"

    static func cells(_ rows: [[Double?]]) -> [CompassRainCell] {
        rows.compactMap { r in
            guard r.count >= 3, let lng = r[0], let lat = r[1], let mm = r[2], PlanGeo.valid(lat: lat, lng: lng), mm.isFinite else { return nil }
            let hours: Double? = r.count > 3 ? r[3] : nil
            return CompassRainCell(position: LngLat(lng: lng, lat: lat), mm: mm, hoursAgo: hours)
        }
    }

    /// The nearest cell with ≥ 5 mm; with none, the nearest with ≥ 1 mm; nil when there is no rain.
    static func nearest(_ cells: [CompassRainCell], me: LngLat) -> CompassRainCell? {
        let strong = cells.filter { $0.mm >= strongMm }
        let pool = strong.isEmpty ? cells.filter { $0.mm >= minMm } : strong
        return pool.min { PlanGeo.meters(me, $0.position) < PlanGeo.meters(me, $1.position) }
    }

    /// «مطر ١٢ ملم · قبل ٣ ساعات».
    static func line(_ c: CompassRainCell) -> String {
        let mm = "مطر \(SaryFormat.number(max(1, Int(c.mm.rounded())))) ملم"
        guard let h = c.hoursAgo, h.isFinite, h >= 0 else { return mm }
        let ago = h < 1 ? "قبل أقل من ساعة" : "قبل \(CloudOutlookPresenter.ageText(Int(h.rounded()) * 60))"
        return "\(mm) · \(ago)"
    }
}

// MARK: - «أقرب ربيع»

/// `GET /api/weather/green/regions` (the fields the compass reads; every field optional so one odd
/// region never fails the whole answer).
struct GreenRegionsResponse: Decodable {
    var ok: Bool?
    var composite_date: String?
    var attribution: String?
    var regions: [GreenRegion]?
    var message_ar: String?
}

struct GreenRegion: Decodable, Equatable {
    struct Place: Decodable, Equatable {
        var name: String?
        var kind: String?
        var distance_km: Double?
    }

    var id: String?
    /// `[lng, lat]`.
    var centroid: [Double]?
    var area_km2: Double?
    var level: String?
    var label_ar: String?
    /// The region's cells, `[[lng, lat], …]`.
    var points: [[Double]]?
    var place: Place?
}

struct CompassSpringPick: Equatable {
    var regionID: String?
    /// The region's point nearest to me: the needle aims at the green's edge, not its middle.
    var point: LngLat
    var distanceM: Double
    var areaKm2: Double
    var label: String?
    var placeName: String?
}

enum CompassSpring {
    /// Specks are filtered by the API; still, never smaller than this.
    static let minAreaKm2 = 3.0
    /// A region with a named place (a rawdah) wins when within this factor of the nearest one's distance.
    static let placePreference = 1.5
    static let credit = "NASA VIIRS"
    static let none = "ما فيه ربيع قريب"
    static let warming = "نجهّز صور الخضرة، جرّب بعد دقيقة"

    static func nearest(_ regions: [GreenRegion], me: LngLat) -> CompassSpringPick? {
        let picks: [CompassSpringPick] = regions.compactMap { r in
            guard let area = r.area_km2, area.isFinite, area >= minAreaKm2 else { return nil }
            var pts: [LngLat] = (r.points ?? []).compactMap { p in
                guard p.count >= 2, PlanGeo.valid(lat: p[1], lng: p[0]) else { return nil }
                return LngLat(lng: p[0], lat: p[1])
            }
            if pts.isEmpty, let c = r.centroid, c.count >= 2, PlanGeo.valid(lat: c[1], lng: c[0]) {
                pts = [LngLat(lng: c[0], lat: c[1])]
            }
            guard let best = pts.min(by: { PlanGeo.meters(me, $0) < PlanGeo.meters(me, $1) }) else { return nil }
            let rawName = r.place?.name ?? ""
            let name: String? = rawName.isEmpty ? nil : rawName
            return CompassSpringPick(regionID: r.id, point: best, distanceM: PlanGeo.meters(me, best), areaKm2: area,
                                     label: r.label_ar, placeName: name)
        }
        guard let nearest = picks.min(by: { $0.distanceM < $1.distanceM }) else { return nil }
        if nearest.placeName != nil { return nearest }
        let placed = picks.filter { $0.placeName != nil && $0.distanceM <= nearest.distanceM * placePreference }
        return placed.min(by: { $0.distanceM < $1.distanceM }) ?? nearest
    }

    /// «روضة خريم · ربيع واضح · ٦ كم²» (without a place: «ربيع واضح · ٦ كم²»).
    static func line(_ p: CompassSpringPick) -> String {
        let area = "\(SaryFormat.number(max(1, Int(p.areaKm2.rounded())))) كم²"
        return [p.placeName, p.label.flatMap { $0.isEmpty ? nil : $0 }, area].compactMap { $0 }.joined(separator: " · ")
    }
}
