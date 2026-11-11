import Combine
import Foundation

/// The weather for one outing: the area forecast (rounded), the destination
/// forecast (as chosen), the wadi estimate from the map, and the rate-limited
/// alerts for the live screen's alert lane.
@MainActor
final class OutingWeather: ObservableObject {
    let area: WeatherStore
    let destination: WeatherStore
    let outingId: String
    /// Real centre of the group (never sent: only its 0.1° cell is).
    @Published private(set) var center: Geo.LatLng?
    @Published private(set) var destinationPoint: OutingDestination?
    @Published private(set) var wadi: WadiContext?
    @Published private(set) var wadiDestination: WadiContext?
    /// The map has reported its watercourses at least once (live screen only).
    @Published private(set) var mapChecked = false
    /// Where the chip's weather is for: destination > the group's area > my area.
    @Published private(set) var source: WeatherChipSource = .none
    /// User-chosen departure for the arrival estimate; nil = now.
    @Published var departure: Date?
    /// The live screen has a map: show the wadi section.
    var showsWadi: Bool { tracksMap }

    /// New alerts that passed the rate limit.
    var onAlert: (WeatherAlertUI) -> Void = { _ in }

    private var tracksMap: Bool
    private var points: [Geo.LatLng] = []
    private var others: [Geo.LatLng] = []
    private var mine: Geo.LatLng?
    private var lines: [WaterwayLine] = []
    private var fixes: [DeviceFix] = []
    private var gate: WeatherAlertGate
    private var bag = Set<AnyCancellable>()
    private var loop: Task<Void, Never>?
    private var lastEvaluated: Date?
    private var lastFed: Date?
    private let clock: () -> Date

    init(outingId: String, tracksMap: Bool, area: WeatherStore? = nil, destination: WeatherStore? = nil, clock: @escaping () -> Date = Date.init) {
        self.outingId = outingId
        self.tracksMap = tracksMap
        self.area = area ?? WeatherStore()
        self.destination = destination ?? WeatherStore()
        self.clock = clock
        gate = WeatherAlertGate.load(outing: outingId)
        for s in [self.area, self.destination] {
            s.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        }
        /* «واقعية القيادة»: the map's dust drifts with this area's real wind, and stops in rain. */
        if tracksMap { self.area.$report.sink { DrivingWeather.update($0?.current ?? $0?.hours.first) }.store(in: &bag) }
    }

    deinit { loop?.cancel() }

    /// Refresh every 10 minutes while the screen is open (the store itself skips
    /// the network while data is younger than 30 min).
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(force: false)
                try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Where the group is: my fix first, else every real position (members, rally),
    /// plus the planned route (sampled) for the wadi check.
    func setPositions(_ pts: [Geo.LatLng], me: DeviceFix?, route: [Geo.LatLng] = []) {
        if let me {
            if fixes.last.map({ me.atMs - $0.atMs >= 5_000 }) ?? true { fixes.append(me) }
            fixes.removeAll { me.atMs - $0.atMs > 10 * 60_000 }
        }
        others = pts
        mine = me?.coordinate
        /* The outing's area: the group's centre when anyone else is known, else mine. */
        let c = WeatherChipSource.areaCenter(others: pts, me: mine)
        let oldCell = center.map { WeatherArea(around: $0.lat, lng: $0.lng) }
        if center != c { center = c }
        updateSource()
        points = pts + (me.map { [$0.coordinate] } ?? []) + WadiProximity.densify(route)
        if let c, WeatherArea(around: c.lat, lng: c.lng) != oldCell {
            Task { await refresh(force: false) }
        } else {
            evaluateIfDue()
        }
    }

    /// The live screen feeds positions at most every 15 s.
    func feedDue(_ now: Date) -> Bool {
        if let t = lastFed, now.timeIntervalSince(t) < 15 { return false }
        lastFed = now
        return true
    }

    func setDestination(_ d: OutingDestination?) {
        guard d != destinationPoint else { return }
        destinationPoint = d
        updateSource()
        Task { await refresh(force: false) }
    }

    /// Watercourses the map has loaded (see `WadiProximity`).
    func setWaterways(_ l: [WaterwayLine]) {
        lines = l
        mapChecked = true
        evaluate()
    }

    func refresh(force: Bool) async {
        if let c = center { await area.update(WeatherArea(around: c.lat, lng: c.lng), force: force) }
        if let d = destinationPoint { await destination.update(WeatherArea(point: d.lat, lng: d.lng), force: force) }
        evaluate()
    }

    private func evaluateIfDue() {
        if let t = lastEvaluated, clock().timeIntervalSince(t) < 60 { return }
        evaluate()
    }

    /// Recompute the wadi estimate and raise the alerts that pass the gate.
    func evaluate() {
        let now = clock()
        lastEvaluated = now
        guard tracksMap else { return }
        wadi = WadiProximity.nearest(to: points, lines: lines)
        wadiDestination = destinationPoint.flatMap { WadiProximity.nearest(to: [Geo.LatLng(lat: $0.lat, lng: $0.lng)], lines: lines) }
        var all: [WeatherAlertUI] = []
        if let r = area.report { all += WeatherAlerts.evaluate(r, now: now, wadi: wadi) }
        if let r = destination.report { all += WeatherAlerts.evaluate(r, now: now, wadi: wadiDestination, forDestination: true) }
        var changed = false
        for a in all where gate.admit(a, now: now) {
            changed = true
            onAlert(a)
        }
        if changed { gate.save(outing: outingId) }
    }

    private func updateSource() {
        let s = WeatherChipSource.select(destination: destinationPoint, others: others, me: mine)
        if s != source { source = s }
    }

    /// The store that holds the chip's forecast.
    var chipStore: WeatherStore? {
        switch source {
        case .destination: return destination
        case .group, .me: return area
        case .none: return nil
        }
    }

    /// The live screen's always-visible chip.
    func chip(now: Date) -> WeatherChipUI {
        let st = chipStore
        return WeatherChipPresenter.chip(source: source, report: st?.report, refreshing: st?.refreshing ?? false, failed: st?.lastFailed ?? false, now: now)
    }

    // MARK: UI

    func areaCard(now: Date, hours: Int = 8) -> WeatherCardUI {
        let title = others.isEmpty && mine != nil ? "الطقس في منطقتك" : "الطقس في منطقة الطلعة"
        guard center != nil else {
            /* No position at all yet: say what is missing instead of spinning forever. */
            return WeatherCardUI(title: title, phase: .unavailable(WeatherChipPresenter.noSourceText))
        }
        /* «نقطة التوقع على بعد … منك» (Build 36 item 12); from the group's centre when my fix is unknown. */
        let ref = mine.map { WeatherReference(point: $0, label: "منك") } ?? center.map { WeatherReference(point: $0, label: "من وسط الطلعة") }
        return WeatherPresenter.card(title: title, report: area.report, refreshing: area.refreshing, failed: area.lastFailed, now: now, hours: hours,
                                     reference: ref)
    }

    func destinationCard(now: Date, hours: Int = 8) -> WeatherCardUI {
        let name = destinationPoint?.name ?? ""
        return WeatherPresenter.card(title: name.isEmpty ? "الطقس في الوجهة" : "الطقس في الوجهة: \(name)", report: destination.report,
                                     refreshing: destination.refreshing, failed: destination.lastFailed, now: now, hours: hours,
                                     reference: destinationPoint.map { WeatherReference(point: Geo.LatLng(lat: $0.lat, lng: $0.lng), label: "من الوجهة") })
    }

    func arrival(now: Date) -> WeatherArrivalUI? {
        guard let d = destinationPoint, let from = fixes.last?.coordinate ?? center else { return nil }
        let est = ArrivalEstimate.estimate(from: from, to: Geo.LatLng(lat: d.lat, lng: d.lng),
                                           recentKmh: ArrivalEstimate.recentSpeedKmh(fixes), departure: max(now, departure ?? now))
        return WeatherPresenter.arrival(est, report: destination.report, now: now)
    }

    var wadiStatus: String {
        guard mapChecked else { return "ننتظر بيانات الخريطة حولكم…" }
        guard let w = wadi else { return "لم نجد مجرى وادٍ مرسومًا قرب الطلعة على الخريطة. هذا لا يعني أنه غير موجود." }
        if w.distanceM <= WeatherThresholds.wadiInsideM { return "أنتم في مجرى وادٍ أو بجانبه\(w.name.map { " (\($0))" } ?? "")" }
        return "أقرب مجرى وادٍ مرسوم على بعد \(SaryFormat.distance(meters: w.distanceM))\(w.name.map { " (\($0))" } ?? "")"
    }

    nonisolated static func centroid(_ pts: [Geo.LatLng]) -> Geo.LatLng? {
        guard !pts.isEmpty else { return nil }
        return Geo.LatLng(lat: pts.map(\.lat).reduce(0, +) / Double(pts.count), lng: pts.map(\.lng).reduce(0, +) / Double(pts.count))
    }
}

#if DEBUG
/// Screenshot scenarios (`-SaryWeatherDemo rain|dust|calm`, DEBUG only): a
/// synthetic forecast so the alerts can be captured without waiting for weather.
/// Never compiled into Release.
enum WeatherDemo {
    static var scenario: String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-SaryWeatherDemo"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    /// `-SaryWeatherDemoAge <minutes>`: pretend the data arrived that long ago (stale / offline shots).
    static var ageS: TimeInterval {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-SaryWeatherDemoAge"), i + 1 < a.count, let m = Double(a[i + 1]) else { return 6 * 60 }
        return m * 60
    }

    /// `-SaryDemoDestination "lat,lng,name"`: a destination before the plan branch is merged.
    static var destination: OutingDestination? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-SaryDemoDestination"), i + 1 < a.count else { return nil }
        let parts = a[i + 1].split(separator: ",", maxSplits: 2).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, let lat = Double(parts[0]), let lng = Double(parts[1]) else { return nil }
        return OutingDestination(name: parts.count > 2 ? parts[2] : "", lat: lat, lng: lng)
    }

    static func report(for area: WeatherArea, now: Date) -> WeatherReport? {
        guard let s = scenario else { return nil }
        let fetched = now.addingTimeInterval(-ageS)
        let start = (fetched.timeIntervalSince1970 / 3600).rounded(.down) * 3600
        var hours: [WeatherHour] = []
        let dest = area.precision == .point
        for i in 0..<48 {
            let t = Double(i)
            var h = WeatherHour(time: Date(timeIntervalSince1970: start + t * 3600), temperatureC: 31 - t * 0.4 + (dest ? -2 : 0), precipitationMm: 0,
                                precipitationProbability: 0, weatherCode: 1, windKmh: 14, gustKmh: 24, windFromDeg: 315, visibilityM: 24_000, dust: 40, pm10: 60)
            switch s {
            case "rain":
                h.weatherCode = i < 2 ? 3 : (i < 9 ? 63 : 80)
                h.precipitationProbability = i < 2 ? 40 : (i < 9 ? 85 : 30)
                h.precipitationMm = i < 2 ? 0 : (i < 9 ? 1.6 : 0.2)
                h.windKmh = 34 + (i < 4 ? 8 : 0)
                h.gustKmh = 58 + (i < 4 ? 9 : 0)
                h.windFromDeg = 200
            case "dust":
                h.dust = i < 6 ? 1_450 : 420
                h.pm10 = i < 6 ? 1_900 : 600
                h.visibilityM = i < 6 ? 1_800 : 6_000
                h.windKmh = 38
                h.gustKmh = 64
                h.windFromDeg = 330
            default: break
            }
            hours.append(h)
        }
        var cur = hours[0]
        cur.time = fetched
        cur.precipitationProbability = nil
        return WeatherReport(area: area, fetchedAt: fetched, current: cur, hours: hours, airAvailable: true)
    }
}
#endif
