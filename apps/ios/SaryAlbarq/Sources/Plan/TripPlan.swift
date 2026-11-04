import Foundation

// «تخطيط الطلعة»: the planned route, notes and destination (`GET/PUT /:id/plan`)
// and the shared checklist (`/:id/checklist`). Pure types and geometry, no UI.

/// GeoJSON LineString as the server stores it: `[[lng, lat], …]`.
struct PlanLineString: Codable, Equatable {
    var type = "LineString"
    var coordinates: [[Double]]

    init(_ points: [LngLat]) {
        coordinates = points.map { [Self.round6($0.lng), Self.round6($0.lat)] }
    }

    /// Valid points only (finite, in range); anything else in the payload is dropped.
    var points: [LngLat] {
        coordinates.compactMap { c in
            guard c.count >= 2, PlanGeo.valid(lat: c[1], lng: c[0]) else { return nil }
            return LngLat(lng: c[0], lat: c[1])
        }
    }

    /// ~11 cm: enough for a desert track, and keeps the body small.
    static func round6(_ v: Double) -> Double { (v * 1_000_000).rounded() / 1_000_000 }
}

struct TripPlan: Codable, Equatable {
    var route: PlanLineString?
    var notes: String
    var destination: OutingDestination?
    var updated_at: String?

    static let maxPoints = 5000
    static let notesMax = 1000
    static let destinationNameMax = 40
    static let empty = TripPlan(route: nil, notes: "", destination: nil, updated_at: nil)

    var points: [LngLat] { route?.points ?? [] }
    var hasRoute: Bool { points.count >= 2 }
    var isEmpty: Bool { !hasRoute && notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && destination == nil }

    init(route: PlanLineString?, notes: String, destination: OutingDestination?, updated_at: String?) {
        self.route = route
        self.notes = notes
        self.destination = destination
        self.updated_at = updated_at
    }

    /* Tolerant: a server without `destination` yet, or `notes: null`, still decodes. */
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        route = try? c.decodeIfPresent(PlanLineString.self, forKey: .route)
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
        destination = try? c.decodeIfPresent(OutingDestination.self, forKey: .destination)
        updated_at = try? c.decodeIfPresent(String.self, forKey: .updated_at)
    }

    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(route, forKey: .route) // explicit null clears the route
        try c.encode(notes, forKey: .notes)
        try c.encode(destination, forKey: .destination)
    }

    private enum CodingKeys: String, CodingKey { case route, notes, destination, updated_at }

    /// What a PUT sends: route capped/simplified to ≤ 5000 points, notes and name trimmed to the limits.
    func cleanedForUpload() -> TripPlan {
        var p = self
        let pts = PlanSimplify.capped(points, max: Self.maxPoints)
        p.route = pts.count >= 2 ? PlanLineString(pts) : nil
        p.notes = String(notes.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.notesMax))
        if var d = destination {
            d.name = String(d.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.destinationNameMax))
            if d.name.isEmpty { d.name = "الوجهة" }
            p.destination = PlanGeo.valid(lat: d.lat, lng: d.lng) ? d : nil
        }
        return p
    }
}

// MARK: - geometry

enum PlanGeo {
    static func valid(lat: Double, lng: Double) -> Bool {
        lat.isFinite && lng.isFinite && (-90...90).contains(lat) && (-180...180).contains(lng)
    }

    static func meters(_ a: LngLat, _ b: LngLat) -> Double {
        Geo.haversineMeters(.init(lat: a.lat, lng: a.lng), .init(lat: b.lat, lng: b.lng))
    }

    static func bearing(_ a: LngLat, _ b: LngLat) -> Double {
        Geo.bearingDeg(.init(lat: a.lat, lng: a.lng), .init(lat: b.lat, lng: b.lng))
    }

    /// Total length along the points.
    static func length(_ pts: [LngLat]) -> Double {
        guard pts.count >= 2 else { return 0 }
        var s = 0.0
        for i in 1..<pts.count { s += meters(pts[i - 1], pts[i]) }
        return s
    }

    /// Local metres around `ref` (equirectangular; fine at route scale).
    static func xy(_ p: LngLat, ref: LngLat) -> (x: Double, y: Double) {
        let r = Geo.earthRadiusM, k = Double.pi / 180
        return ((p.lng - ref.lng) * k * r * cos(ref.lat * k), (p.lat - ref.lat) * k * r)
    }

    static func lngLat(x: Double, y: Double, ref: LngLat) -> LngLat {
        let r = Geo.earthRadiusM, k = Double.pi / 180
        return LngLat(lng: ref.lng + x / (r * cos(ref.lat * k)) / k, lat: ref.lat + y / r / k)
    }

    /// Nearest point on segment a–b to p: the point, how far along (0…1) and the distance in metres.
    static func project(_ p: LngLat, _ a: LngLat, _ b: LngLat) -> (point: LngLat, u: Double, distM: Double) {
        let pa = xy(a, ref: p), pb = xy(b, ref: p)
        let dx = pb.x - pa.x, dy = pb.y - pa.y
        let len2 = dx * dx + dy * dy
        var u = len2 > 0 ? (-pa.x * dx - pa.y * dy) / len2 : 0
        u = min(1, max(0, u))
        let x = pa.x + u * dx, y = pa.y + u * dy
        return (lngLat(x: x, y: y, ref: p), u, (x * x + y * y).squareRoot())
    }

    /// Where p sits relative to a polyline: distance off it, the nearest point and the metres still ahead.
    struct Nearest: Equatable {
        var distanceM: Double
        var point: LngLat
        var alongM: Double
        var remainingM: Double
    }

    static func nearest(_ p: LngLat, on pts: [LngLat]) -> Nearest? {
        guard let first = pts.first else { return nil }
        guard pts.count >= 2 else {
            let d = meters(p, first)
            return Nearest(distanceM: d, point: first, alongM: 0, remainingM: 0)
        }
        var best: Nearest?
        var run = 0.0
        let total = length(pts)
        for i in 1..<pts.count {
            let seg = meters(pts[i - 1], pts[i])
            let pr = project(p, pts[i - 1], pts[i])
            if best == nil || pr.distM < best!.distanceM {
                let along = run + seg * pr.u
                best = Nearest(distanceM: pr.distM, point: pr.point, alongM: along, remainingM: max(0, total - along))
            }
            run += seg
        }
        return best
    }
}

/// «الوقت التقديري»: an honest rough guess, said as such in the UI.
enum PlanETA {
    /// Average for sand / gravel tracks with stops; the UI says «تقديري».
    static let offroadKmh = 35.0

    static func seconds(meters: Double, kmh: Double = offroadKmh) -> Int {
        guard meters > 0, kmh > 0 else { return 0 }
        return Int((meters / 1000 / kmh * 3600).rounded())
    }
}

// MARK: - simplification

enum PlanSimplify {
    /// Douglas–Peucker with an explicit stack (no recursion: imported tracks can have 100 000s of points).
    static func douglasPeucker(_ pts: [LngLat], toleranceM: Double) -> [LngLat] {
        guard pts.count > 2 else { return pts }
        let ref = pts[pts.count / 2]
        let xy = pts.map { PlanGeo.xy($0, ref: ref) }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            let ax = xy[a].x, ay = xy[a].y, dx = xy[b].x - ax, dy = xy[b].y - ay
            let len2 = dx * dx + dy * dy
            var worst = -1.0, idx = a
            for i in (a + 1)..<b {
                let px = xy[i].x - ax, py = xy[i].y - ay
                let d: Double
                if len2 == 0 {
                    d = (px * px + py * py).squareRoot()
                } else {
                    let u = min(1, max(0, (px * dx + py * dy) / len2))
                    let ex = px - u * dx, ey = py - u * dy
                    d = (ex * ex + ey * ey).squareRoot()
                }
                if d > worst { worst = d; idx = i }
            }
            if worst > toleranceM {
                keep[idx] = true
                stack.append((a, idx))
                stack.append((idx, b))
            }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
    }

    /// Drop invalid points and exact repeats; simplify (5 m, widening) only when asked or when over `max`.
    /// A hand-drawn route under the cap is kept exactly as drawn.
    static func capped(_ pts: [LngLat], max: Int = TripPlan.maxPoints, startToleranceM: Double = 5, simplify: Bool = false) -> [LngLat] {
        var clean: [LngLat] = []
        clean.reserveCapacity(pts.count)
        for p in pts where PlanGeo.valid(lat: p.lat, lng: p.lng) {
            if let l = clean.last, l == p { continue }
            clean.append(p)
        }
        guard clean.count > 2, simplify || clean.count > max else { return clean }
        var tol = startToleranceM
        var out = douglasPeucker(clean, toleranceM: tol)
        var guardRounds = 0
        while out.count > max && guardRounds < 40 {
            tol *= 1.6
            out = douglasPeucker(clean, toleranceM: tol)
            guardRounds += 1
        }
        if out.count > max {
            /* Pathological input: keep every n-th point and the end. */
            let step = Int((Double(out.count) / Double(max - 1)).rounded(.up))
            var thin = stride(from: 0, to: out.count, by: step).map { out[$0] }
            if thin.last != out.last, let last = out.last { thin.append(last) }
            out = Array(thin.prefix(max))
        }
        return out
    }
}

// MARK: - «اتبع الخطة»

struct FollowPlanStatus: Equatable {
    enum Kind: Equatable {
        /// No fresh fix of mine: say so, never guess.
        case waitingForFix
        case onRoute
        case offRoute
        case arrived
    }

    var kind: Kind
    /// Metres from me to the nearest point of the plan.
    var offM: Double = 0
    /// Bearing from me to that nearest point (to get back on it).
    var backBearing: Double = 0
    /// Metres still ahead along the plan from the nearest point.
    var remainingM: Double = 0
}

/// Same idea and thresholds as «طريق العودة»: off at 60 m, back on under 45 m (no flicker), arrived within 30 m of the end.
struct FollowPlan: Equatable {
    static let offRouteM = 60.0
    static let backOnM = 45.0
    static let arrivedM = 30.0
    /// A fix older than this is not "where I am now".
    static let maxFixAgeS = 30.0
    static let maxAccuracyM = 60.0

    var points: [LngLat]
    private(set) var off = false

    init(points: [LngLat]) { self.points = points }

    mutating func update(me: LngLat?, fixAgeS: Double, accuracyM: Double?) -> FollowPlanStatus {
        guard let me, fixAgeS <= Self.maxFixAgeS, (accuracyM ?? 0) <= Self.maxAccuracyM,
              let n = PlanGeo.nearest(me, on: points), let end = points.last else {
            return FollowPlanStatus(kind: .waitingForFix)
        }
        if PlanGeo.meters(me, end) <= Self.arrivedM {
            off = false
            return FollowPlanStatus(kind: .arrived, offM: n.distanceM, remainingM: 0)
        }
        off = off ? n.distanceM > Self.backOnM : n.distanceM > Self.offRouteM
        return FollowPlanStatus(kind: off ? .offRoute : .onRoute, offM: n.distanceM,
                                backBearing: PlanGeo.bearing(me, n.point), remainingM: n.remainingM)
    }
}

// MARK: - checklist

struct ChecklistItem: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var assignee_user_id: String?
    var done: Bool
    var created_by: String?
    var created_at: String?

    static let titleMax = 40

    init(id: String, title: String, assignee_user_id: String? = nil, done: Bool = false, created_by: String? = nil, created_at: String? = nil) {
        self.id = id
        self.title = title
        self.assignee_user_id = assignee_user_id
        self.done = done
        self.created_by = created_by
        self.created_at = created_at
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .id) { id = s } else { id = String(try c.decode(Int.self, forKey: .id)) }
        title = try c.decode(String.self, forKey: .title)
        assignee_user_id = try? c.decodeIfPresent(String.self, forKey: .assignee_user_id)
        done = (try? c.decodeIfPresent(Bool.self, forKey: .done)) ?? false
        created_by = try? c.decodeIfPresent(String.self, forKey: .created_by)
        created_at = try? c.decodeIfPresent(String.self, forKey: .created_at)
    }
}

/// The checklist as a pure value: ordering, progress and the quick-add suggestions.
struct ChecklistState: Equatable {
    var items: [ChecklistItem] = []

    /// Quick-add chips; the ones already on the list are hidden.
    static let suggestions = ["ماء", "حطب", "شاحن", "حبل سحب", "كفرات احتياط", "عدة إسعاف", "كشاف", "بنزين احتياط", "أكل", "خيمة", "فحم", "مضخة هواء"]

    var doneCount: Int { items.filter(\.done).count }
    var total: Int { items.count }
    var fraction: Double { total == 0 ? 0 : Double(doneCount) / Double(total) }
    /// «٧ من ١٠».
    var progressLabel: String { "\(SaryFormat.number(doneCount)) من \(SaryFormat.number(total))" }

    /// Open items first (in the order they were added), then the done ones.
    var ordered: [ChecklistItem] {
        let idx = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        return items.sorted { a, b in
            if a.done != b.done { return !a.done }
            return (idx[a.id] ?? 0) < (idx[b.id] ?? 0)
        }
    }

    var openSuggestions: [String] {
        let have = Set(items.map { Self.key($0.title) })
        return Self.suggestions.filter { !have.contains(Self.key($0)) }
    }

    static func key(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "ـ", with: "").lowercased()
    }

    /// A title the server accepts (trimmed, 1…40), or nil.
    static func cleanTitle(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).joined(separator: " ")
        guard !t.isEmpty else { return nil }
        return String(t.prefix(ChecklistItem.titleMax))
    }

    func contains(title: String) -> Bool {
        items.contains { Self.key($0.title) == Self.key(title) }
    }

    mutating func upsert(_ item: ChecklistItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
    }

    mutating func remove(_ id: String) { items.removeAll { $0.id == id } }

    mutating func setDone(_ id: String, _ done: Bool) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].done = done }
    }

    mutating func assign(_ id: String, to user: String?) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].assignee_user_id = user }
    }

    /// Creator or leader may delete (the server checks too).
    static func canDelete(_ item: ChecklistItem, me: String, iLead: Bool) -> Bool {
        iLead || item.created_by == me
    }
}
