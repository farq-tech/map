import CoreLocation
import SwiftUI

/// «البر» outside an outing (UI-AUDIT م6): the weather at a point, the Qibla, «اقترح لي مكان
/// كشتة» and «دروب البر», from the home map — the person standing in the desert without a trip.
enum HomeTool: Identifiable {
    /// The «البر» chip: the four tools in one short sheet.
    case menu
    case weather(OutingDestination)
    case qibla
    case camp
    case routes(target: LngLat, name: String, rain: Bool, weatherAvailable: Bool)

    var id: String {
        switch self {
        case .menu: return "menu"
        case let .weather(d): return "weather:\(d.lat),\(d.lng)"
        case .qibla: return "qibla"
        case .camp: return "camp"
        case let .routes(t, _, _, _): return "routes:\(t.lat),\(t.lng)"
        }
    }
}

/// Full-screen pages the home map opens without an outing.
enum HomeCover: Identifiable {
    /// «اتجه»: turn-by-turn on this phone (`StandaloneNavScreen`).
    case nav(NavTarget)
    /// «امشِ عليه» on a desert route: «اسلك هذا المسار» (`TrackFollowScreen`).
    case follow(TrackFollowModel)

    var id: String {
        switch self {
        case let .nav(t): return "nav:\(t.position.lat),\(t.position.lng)"
        case let .follow(m): return "follow:\(m.id)"
        }
    }
}

/// Pure rules of the desert tools on the home map (unit-tested in HomeFlowTests).
enum HomeDesertTools {
    /// «دروب البر» on a place card: only for a desert place (a desert chip / «دليل البر» result, a
    /// point pressed on the map) that the desert router can reach from here — a bundled region
    /// or a national-tiles corridor (`DesertRouteSheet` decides the same). Unknown position: offered,
    /// the sheet then says «ننتظر موقعك».
    static func offersRoutes(desertPlace: Bool, me: LngLat?, target: LngLat) -> Bool {
        guard desertPlace else { return false }
        guard let me else { return true }
        return DesertGrid.covering(me, target) != nil || DesertTiles.corridor(spanning: me, target) != nil
    }

    /// Where «الطقس هنا» is for: my position, else nothing (the row says why).
    static func weatherPoint(me: LngLat?) -> OutingDestination? {
        me.map { OutingDestination(name: "موقعك", lat: $0.lat, lng: $0.lng) }
    }
}

/// The «البر» chip's sheet: four rows, each opens its tool (no outing needed).
struct HomeDesertToolsMenu: View {
    var me: LngLat?
    var open: (HomeTool) -> Void
    var close: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        SaryPage(title: "البر", subtitle: "بدون طلعة: الجو والقبلة والكشتة والدروب", close: close) {
            VStack(spacing: 0) {
                let weatherAt = HomeDesertTools.weatherPoint(me: me)
                row("cloud.sun.fill", "الطقس هنا", weatherAt == nil ? "نحتاج موقعك عشان نجيب جوّك" : "جو مكانك ٢٤ ساعة، والسيول والتحذيرات",
                    id: "home.tools.weather", enabled: weatherAt != nil) { if let w = weatherAt { open(.weather(w)) } }
                SaryDivider().padding(.leading, 56)
                row("location.north.line.fill", "القبلة", "الاتجاه بالبوصلة والمسافة لمكة", id: "home.tools.qibla") { open(.qibla) }
                SaryDivider().padding(.leading, 56)
                row("tent.fill", "اقترح لي مكان كشتة", "أحلى ٥ جلسات حولك الليلة، مع ريح الليلة", id: "home.tools.camp") { open(.camp) }
                SaryDivider().padding(.leading, 56)
                HStack(alignment: .top, spacing: theme.space(.m)) {
                    SaryRowIcon(systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("دروب البر").saryText(.body, weight: .bold).foregroundStyle(p.textPrimary)
                        Text("اختر وجهتك أول (ابحث أو اضغط مطوّلًا على الخريطة)، وتلقى «دروب البر» في بطاقتها.")
                            .saryText(.footnote).foregroundStyle(p.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, theme.space(.s))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("home.tools.routes")
            }
            .padding(.horizontal, theme.space(.m))
            .sarySurface(radius: SaryRadius.m)
            Text("كل هذا على جوالك، وما نرسل موقعك لأحد. الطقس يرسل إحداثية النقطة فقط لـOpen-Meteo.")
                .saryText(.footnote).foregroundStyle(p.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.tools")
    }

    private func row(_ icon: String, _ title: String, _ detail: String, id: String, enabled: Bool = true, run: @escaping () -> Void) -> some View {
        let p = theme.palette
        return Button(action: run) {
            HStack(spacing: theme.space(.m)) {
                SaryRowIcon(systemImage: icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).saryText(.body, weight: .bold).foregroundStyle(p.textPrimary)
                    Text(detail).saryText(.footnote).foregroundStyle(p.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: SaryIcon.back).foregroundStyle(p.textTertiary).rotationEffect(.degrees(180))
            }
            .frame(minHeight: theme.minTarget + 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .accessibilityIdentifier(id)
    }
}

/// One tool's sheet on the home map (the live outing presents the same views from `LiveSheet`).
struct HomeToolSheet: View {
    let tool: HomeTool
    var me: LngLat?
    var host: DesertToolsHost
    var open: (HomeTool) -> Void
    var close: () -> Void

    var body: some View {
        switch tool {
        case .menu:
            HomeDesertToolsMenu(me: me, open: open, close: close)
        case let .weather(point):
            WeatherPointSheet(point: point, close: close)
        case .qibla:
            QiblaView(fallback: me.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }, close: close)
        case .camp:
            CampSuggestSheet(host: host)
        case let .routes(target, name, rain, weatherAvailable):
            /* Half height first, the map live behind it: the routes are drawn on the home map. */
            DesertRouteSheet(host: host, target: target, name: name, rain: rain, weatherAvailable: weatherAvailable)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
        }
    }
}
