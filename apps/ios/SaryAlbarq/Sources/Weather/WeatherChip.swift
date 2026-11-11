import CoreLocation
import SwiftUI

/// Which place the always-visible weather chip is for: the destination if the
/// outing has one, else the group's area (the members' centre, sent only as its
/// 0.1° cell), else my own area. `none` = nothing known yet; the chip still shows.
enum WeatherChipSource: Equatable {
    case destination(OutingDestination)
    case group(Geo.LatLng)
    case me(Geo.LatLng)
    case none

    static func select(destination: OutingDestination?, others: [Geo.LatLng], me: Geo.LatLng?) -> WeatherChipSource {
        if let d = destination, PlanGeo.valid(lat: d.lat, lng: d.lng) { return .destination(d) }
        if let c = areaCenter(others: others, me: me) { return others.isEmpty ? .me(c) : .group(c) }
        return .none
    }

    /// The outing area's centre: everyone known (members, rally, me); just me when alone.
    static func areaCenter(others: [Geo.LatLng], me: Geo.LatLng?) -> Geo.LatLng? {
        let valid = others.filter { PlanGeo.valid(lat: $0.lat, lng: $0.lng) }
        if valid.isEmpty { return me }
        return OutingWeather.centroid(valid + (me.map { [$0] } ?? []))
    }

    /// What goes on the chip: «روضة الثمامة», «منطقة الطلعة», «منطقتك».
    var placeLabel: String {
        switch self {
        case let .destination(d): return d.name.trimmingCharacters(in: .whitespaces).isEmpty ? "الوجهة" : d.name
        case .group: return "منطقة الطلعة"
        case .me: return "منطقتك"
        case .none: return "الطقس"
        }
    }

    var area: WeatherArea? {
        switch self {
        case let .destination(d): return WeatherArea(point: d.lat, lng: d.lng)
        case let .group(c), let .me(c): return WeatherArea(around: c.lat, lng: c.lng)
        case .none: return nil
        }
    }
}

/// Plain values for the chip (tested in `WeatherChipTests`).
struct WeatherChipUI: Equatable {
    enum Phase: Equatable { case loading, ready, unavailable }
    var phase: Phase
    var symbol: String
    var temp: String
    var place: String
    /// «آخر تحديث قبل ٣ س» when the data is old or the refresh failed; nil when fresh.
    var staleText: String?
    var offline = false
    /// 0 calm, 1 worth a look (strong wind, dust, rain), 2 serious.
    var alertLevel = 0
    var accessibility: String
}

enum WeatherChipPresenter {
    static let noSourceText = "نحتاج موقعك أو وجهة الطلعة لنعرض الطقس"

    static func chip(source: WeatherChipSource, report r: WeatherReport?, refreshing: Bool, failed: Bool, now: Date) -> WeatherChipUI {
        let place = source.placeLabel
        if source == .none {
            return WeatherChipUI(phase: .unavailable, symbol: "location.slash", temp: "—", place: "الطقس", staleText: nil,
                                 accessibility: "الطقس: \(noSourceText)")
        }
        guard let r else {
            if failed {
                return WeatherChipUI(phase: .unavailable, symbol: "cloud", temp: "—", place: place, staleText: "تعذّر جلب الطقس", offline: true,
                                     accessibility: "الطقس في \(place): تعذّر جلب الطقس، اضغط للتفاصيل")
            }
            return WeatherChipUI(phase: .loading, symbol: "cloud", temp: "…", place: place, staleText: nil, accessibility: "الطقس في \(place): نجيب الطقس")
        }
        let age = SaryFormat.lastUpdate(since: r.fetchedAt, now: now)
        guard let (h, _) = WeatherRules.nowValue(r, now: now) else {
            /* Expired forecast: never shown as current, but the chip stays with its age. */
            return WeatherChipUI(phase: .unavailable, symbol: "clock.badge.exclamationmark", temp: "—", place: place, staleText: age, offline: failed,
                                 accessibility: "الطقس في \(place): التوقعات المحفوظة انتهت، \(age)")
        }
        var stale = false
        if case .stale = WeatherFreshness.of(r, now: now) { stale = true }
        let c = WeatherRules.displayCondition(h)
        let alerts = WeatherAlerts.evaluate(r, now: now, wadi: nil)
        let level = alerts.map { $0.kind == .flood ? 2 : $0.level }.max() ?? 0
        let temp = WeatherFormat.temp(h.temperatureC)
        let staleText = stale || failed ? age : nil
        var a11y = "الطقس في \(place): \(temp) \(c.text)"
        if let w = h.windKmh { a11y += "، رياح \(WeatherFormat.speed(w))" }
        if let t = alerts.first?.title { a11y += "، \(t)" }
        if let staleText { a11y += "، \(staleText)" }
        return WeatherChipUI(phase: .ready, symbol: c.symbol, temp: temp, place: place, staleText: staleText, offline: failed,
                             alertLevel: level, accessibility: a11y)
    }
}

/// The compact chip itself: icon, temperature, place, and its age when old.
struct WeatherChipView: View {
    var ui: WeatherChipUI
    var tap: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let tint: Color = ui.alertLevel >= 2 ? p.emergencyText : (ui.alertLevel == 1 ? p.warningText : p.textPrimary)
        Button(action: tap) {
            HStack(spacing: 6) {
                if ui.phase == .loading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: ui.symbol).symbolRenderingMode(.multicolor).font(.system(size: theme.drive ? 18 : 15, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
                /* A new reading rolls its digits instead of snapping. */
                Text(ui.temp).saryNumber(theme.drive ? .headline : .subhead, weight: .heavy).foregroundStyle(tint)
                    .contentTransition(theme.reduceMotion ? .opacity : .numericText())
                Text(ui.place).saryText(.caption, weight: .bold).foregroundStyle(p.textSecondary).lineLimit(1)
                    .frame(maxWidth: 110, alignment: .leading)
                if let s = ui.staleText {
                    HStack(spacing: 2) {
                        Image(systemName: ui.offline ? SaryIcon.offline : "clock").saryGlyph(10, weight: .bold)
                        Text(s.replacingOccurrences(of: "آخر تحديث ", with: "")).saryNumber(.micro, weight: .bold).lineLimit(1)
                    }
                    .foregroundStyle(p.warningText)
                }
                if ui.alertLevel > 0 {
                    Image(systemName: SaryIcon.warning).saryGlyph(11, weight: .bold).foregroundStyle(tint)
                }
            }
            .padding(.horizontal, theme.space(.m))
            .frame(minHeight: theme.drive ? 52 : 40)
            .saryGlass(Capsule(), role: .control, interactive: true)
            .overlay {
                if ui.alertLevel > 0 { Capsule().stroke(ui.alertLevel >= 2 ? p.emergency : p.warning, lineWidth: 1.5) }
            }
        }
        .buttonStyle(SaryPressStyle())
        .saryAnimation(.smooth, value: ui.temp)
        .saryAnimation(.smooth, value: ui.symbol)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(ui.accessibility))
        .accessibilityHint(Text("يفتح تفاصيل الطقس"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("weather.chip")
    }
}

/// The live screen's chip: observes the outing's weather (refreshes every minute for the age text).
struct LiveWeatherChip: View {
    let controller: LiveOutingController
    @ObservedObject var weather: OutingWeather

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            WeatherChipView(ui: weather.chip(now: ctx.date)) { controller.modal = .weather }
        }
        .task { controller.feedWeather(force: true) }
    }
}

/// «طلعاتي»: a small icon + temperature for an outing's destination.
struct DestinationWeatherBadge: View {
    let destination: OutingDestination
    @StateObject private var store = WeatherStore()
    @Environment(\.sary) private var theme

    var body: some View {
        let now = Date()
        let ui = WeatherChipPresenter.chip(source: .destination(destination), report: store.report, refreshing: store.refreshing, failed: store.lastFailed, now: now)
        HStack(spacing: 3) {
            Image(systemName: ui.phase == .loading ? "cloud" : ui.symbol).symbolRenderingMode(.multicolor).font(.system(size: 12))
                .contentTransition(.symbolEffect(.replace))
            Text(ui.temp).saryNumber(.caption, weight: .bold)
                .foregroundStyle(ui.alertLevel > 0 ? theme.palette.warningText : theme.palette.textSecondary)
                .contentTransition(theme.reduceMotion ? .opacity : .numericText())
            if ui.staleText != nil { Image(systemName: "clock").saryGlyph(9, weight: .bold).foregroundStyle(theme.palette.warningText) }
        }
        /* The reading arrives after the card: its digits roll in rather than pop. */
        .saryAnimation(.smooth, value: ui.temp)
        .saryAnimation(.smooth, value: ui.symbol)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(ui.accessibility))
        .accessibilityIdentifier("outing-row.weather")
        .task(id: "\(destination.lat),\(destination.lng)") { await store.update(WeatherArea(point: destination.lat, lng: destination.lng)) }
    }
}

/// One rough fix (≈1 km is plenty for an 11 km weather cell) for screens that do
/// not run the GPS: outing details, «وين رايحين؟». Only if location was already allowed.
@MainActor
final class OneShotLocator: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var fix: Geo.LatLng?
    private let manager = CLLocationManager()
    private var asked = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        if let l = manager.location, -l.timestamp.timeIntervalSinceNow < 6 * 3600 {
            fix = Geo.LatLng(lat: l.coordinate.latitude, lng: l.coordinate.longitude)
        }
    }

    func request() {
        let st = manager.authorizationStatus
        guard !asked, st == .authorizedWhenInUse || st == .authorizedAlways else { return }
        asked = true
        manager.requestLocation()
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last else { return }
        let c = Geo.LatLng(lat: l.coordinate.latitude, lng: l.coordinate.longitude)
        Task { @MainActor in self.fix = c }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}
