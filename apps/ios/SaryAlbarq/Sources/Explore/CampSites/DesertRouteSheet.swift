import SwiftUI

/// What «مخطط دروب البر» is showing (drawn by `CampSitesMapLayer`).
@MainActor
final class DesertRoutesHub: ObservableObject {
    static let shared = DesertRoutesHub()
    @Published var options: [DesertRouter.Option] = []
    @Published var selected: DesertRouter.Mode = .easy
    private init() {}

    func clear() {
        options = []
        selected = .easy
    }
}

/// Who hosts the desert tools («اقترح لي مكان كشتة»، «دروب البر»): the live outing, or the home
/// map without an outing (UI-AUDIT م6). The sheets only ask through these, never the controller.
struct DesertToolsHost {
    /// My position now (nil: no fix yet).
    var myPoint: @MainActor () -> LngLat?
    /// The sheet is done.
    var close: @MainActor () -> Void
    /// «اتجه» to a point: our own guidance (the trip's, or `StandaloneNavScreen`).
    var directions: @MainActor (Result<NavTarget, NavRefusal>) -> Void
    /// «دروب البر» to a point: target, name, rain tonight, weather known.
    var openRoutes: @MainActor (LngLat, String, Bool, Bool) -> Void
    /// «اتجه» (was «امشِ عليه»): follow the picked desert route («اسلك هذا المسار»).
    var follow: @MainActor (FollowSubject) -> Void
    /// Frame the routes on the host's map (the live map, or the home map that draws them too).
    var fitTrack: @MainActor ([LngLat]) -> Void = { _ in }

    /// Inside a live outing: the same modals and guidance as before (`LiveSheet`).
    static func live(_ c: LiveOutingController) -> DesertToolsHost {
        DesertToolsHost(
            myPoint: { [weak c] in c?.location.lastFix.map { LngLat(lng: $0.lng, lat: $0.lat) } },
            close: { [weak c] in c?.modal = nil },
            directions: { [weak c] r in c?.directions(r) },
            openRoutes: { [weak c] target, name, rain, weatherAvailable in
                c?.modal = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { c?.modal = .desertRoute(target, name, rain, weatherAvailable) }
            },
            follow: { [weak c] s in
                c?.modal = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { c?.startFollow(s) }
            },
            fitTrack: { [weak c] pts in c?.lowerSheetThenAsk(.fitTrack(pts)) })
    }
}

/// «مخطط دروب البر»: three ways there — «الأسهل»، «المتوازن»، «الأقصر» — each with distance,
/// time, the share on a known track, the hard stretches and how to avoid them. Picking one
/// follows it with the app's own guidance («اسلك هذا المسار»).
struct DesertRouteSheet: View {
    var host: DesertToolsHost
    var target: LngLat
    var name: String
    /// Forecast indicates rain tonight.
    var rain: Bool
    /// When false, route conservatively treats rainfall as possible and refuses major wadis.
    var weatherAvailable: Bool
    @ObservedObject private var hub = DesertRoutesHub.shared
    @State private var phase: Phase = .working
    /// Bumped by a tap that picks another route (the selection tick).
    @State private var pickTick = 0
    @Environment(\.sary) private var theme

    enum Phase: Equatable { case working, ready, outside, noFix, none }

    static let note = "مسار مقترح من صور الأقمار، تأكد بعينك. ما يغني عن خبرة الدليل"
    static let attribution = "الدروب من بيانات مفتوحة • © OpenStreetMap contributors"

    init(host: DesertToolsHost, target: LngLat, name: String, rain: Bool, weatherAvailable: Bool) {
        self.host = host
        self.target = target
        self.name = name
        self.rain = rain
        self.weatherAvailable = weatherAvailable
    }

    init(controller: LiveOutingController, target: LngLat, name: String, rain: Bool, weatherAvailable: Bool) {
        self.init(host: .live(controller), target: target, name: name, rain: rain, weatherAvailable: weatherAvailable)
    }

    var body: some View {
        let p = theme.palette
        SaryPage(title: "دروب البر", subtitle: "إلى \(name)", close: close) {
            if !weatherAvailable {
                Label("ما وصلنا طقس الليلة؛ نتجنب مجاري الأودية الرئيسية احتياطًا", systemImage: "cloud.rain.fill")
                    .saryText(.footnote, weight: .bold).foregroundStyle(p.warningText)
            } else if rain {
                Label("فيه تحذير مطر: ما نمشيك في بطون الأودية", systemImage: "cloud.rain.fill")
                    .saryText(.footnote, weight: .bold).foregroundStyle(p.warningText)
            }
            switch phase {
            case .working:
                SaryStateView(kind: .loading("نحسب الدروب…")).sarySurface(radius: SaryRadius.l)
            case .noFix:
                SaryStateView(kind: .empty(title: "ننتظر موقعك", message: nil, systemImage: "location")).sarySurface(radius: SaryRadius.l)
            case .outside:
                /* «اتجه» is right here (it was named without a button): the usual road guidance. */
                SaryStateView(kind: .empty(title: "الوجهة بعيدة على دروب البر",
                                           message: "دروب البر تنحسب داخل المملكة لمسافة نحو ١٠٠ كم بينك وبين الوجهة. «اتجه» يوجّهك بالطريق العادي.",
                                           systemImage: "map"),
                              actionTitle: "اتجه", actionID: "routes.direct", actionIcon: SaryIcon.directions, action: direct)
                    .sarySurface(radius: SaryRadius.l)
                    .accessibilityIdentifier("routes.outside")
            case .none:
                SaryStateView(kind: .empty(title: "ما لقينا درب آمن", message: "«اتجه» يوجّهك بالطريق العادي، أو جرّب نقطة ثانية.", systemImage: "xmark.octagon"),
                              actionTitle: "اتجه", actionID: "routes.direct", actionIcon: SaryIcon.directions, action: direct)
                    .sarySurface(radius: SaryRadius.l)
                    .accessibilityIdentifier("routes.none")
            case .ready:
                ForEach(hub.options) { o in
                    card(o).transition(SaryTransition.appear(theme))
                }
            }
            /* «مسار مقترح من صور الأقمار» only with an actual route, never beside «ما لقينا درب آمن». */
            if phase == .ready {
                Text(Self.note).saryText(.footnote, weight: .bold).foregroundStyle(p.warningText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("routes.note")
            }
            /* The grid's tracks come from OSM (ODbL): the credit shows with the lines. */
            Text(Self.attribution).saryText(.caption).foregroundStyle(p.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await compute() }
        /* The computed routes arrive with a soft entrance; picking one pops it (and a tick). */
        .saryAnimation(.smooth, value: phase)
        .saryAnimation(.snappy, value: hub.selected)
        .saryHaptic(.selection, trigger: pickTick)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routes.sheet")
    }

    private func compute() async {
        /* «أداء التطبيق»: route asked → options (or none) shown. */
        let perf = PerfSignpost.begin(.desertRoute)
        defer { perf.end() }
        var me = host.myPoint()
        #if DEBUG
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-SaryRouteFrom"), i + 1 < a.count {
            let v = a[i + 1].split(separator: ",").compactMap { Double($0) }
            if v.count == 2 { me = LngLat(lng: v[1], lat: v[0]) }
        }
        #endif
        guard let me else { phase = .noFix; return }
        // A bundled pilot region first (offline); elsewhere in the Kingdom a corridor of national tiles.
        let region = DesertGrid.covering(me, target)
        let corridor = region == nil ? DesertTiles.corridor(spanning: me, target) : nil
        guard region != nil || corridor != nil else { phase = .outside; return }
        let target = self.target, rain = self.rain || !weatherAvailable
        var opts = await Task.detached(priority: .userInitiated) { () -> [DesertRouter.Option] in
            let grid: DesertGrid?
            if let region {
                grid = DesertGrid.bundled(region)
            } else if let corridor {
                grid = await DesertTileStore.shared.corridor(corridor)
            } else {
                grid = nil
            }
            guard let g = grid else { return [] }
            return DesertRouter.options(g, from: me, to: target, rain: rain)
        }.value
        #if DEBUG
        /* Screenshots / UI tests: the «ما لقينا درب آمن» state without hunting for a blocked target. */
        if ProcessInfo.processInfo.arguments.contains("-SaryRouteForceNone") { opts = [] }
        #endif
        hub.options = opts
        hub.selected = opts.first?.mode ?? .easy
        phase = opts.isEmpty ? .none : .ready
        if let all = opts.first?.points, !all.isEmpty { host.fitTrack(opts.flatMap(\.points)) }
    }

    private func card(_ o: DesertRouter.Option) -> some View {
        let p = theme.palette
        let on = hub.selected == o.mode
        return VStack(alignment: .leading, spacing: theme.space(.s)) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.mode.label).saryText(.headline, weight: .bold).foregroundStyle(Self.color(o.mode))
                    Text(o.mode.detail).saryText(.caption).foregroundStyle(p.textSecondary)
                }
                Spacer(minLength: 0)
                Button {
                    go(o)
                } label: { SaryButtonLabel(title: SaryCopy.go, systemImage: SaryIcon.directions) }
                    .buttonStyle(.sary(on ? .primary : .secondary, width: .hug, compact: true))
                    .accessibilityIdentifier("routes.go.\(o.mode.rawValue)")
            }
            Text("\(SaryFormat.distance(meters: o.distanceM)) • نحو \(SaryFormat.duration(seconds: Int(o.minutes * 60))) • \(SaryFormat.percent(Int(o.trackPercent.rounded()))) على درب معروف")
                .saryNumber(.subhead).foregroundStyle(p.textPrimary)
                .accessibilityIdentifier("routes.stats.\(o.mode.rawValue)")
            if o.hard.isEmpty {
                Text("ما فيه مقاطع صعبة تُذكر").saryText(.footnote).foregroundStyle(p.liveText)
            } else {
                Text("مقاطع صعبة: " + o.hardTotals.prefix(3).map { "\($0.0.text) \(SaryFormat.distance(meters: $0.1))" }.joined(separator: " • "))
                    .saryText(.footnote, weight: .bold).foregroundStyle(p.emergencyText)
                    .accessibilityIdentifier("routes.hard.\(o.mode.rawValue)")
                if let tip = o.tip {
                    Text("كيف تتجنبها: \(tip)").saryText(.footnote).foregroundStyle(p.textSecondary)
                }
            }
        }
        .padding(theme.space(.m))
        .contentShape(Rectangle())
        .onTapGesture {
            guard hub.selected != o.mode else { return }
            hub.selected = o.mode
            pickTick &+= 1
        }
        .sarySurface(radius: SaryRadius.l)
        .overlay(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous).stroke(on ? Self.color(o.mode) : .clear, lineWidth: 2))
        /* Visual only (no layout change): the picked card sits a hair forward. */
        .scaleEffect(on ? 1 : 0.985)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routes.card.\(o.mode.rawValue)")
    }

    static func color(_ m: DesertRouter.Mode) -> Color {
        switch m {
        case .easy: return Color(red: 0.18, green: 0.8, blue: 0.44)
        case .balanced: return Color(red: 0.2, green: 0.6, blue: 0.86)
        case .short: return Color(red: 0.9, green: 0.3, blue: 0.24)
        }
    }

    static func hex(_ m: DesertRouter.Mode) -> String { DesertRouteLayers.hex(m) }

    private func go(_ o: DesertRouter.Option) {
        guard let s = FollowSubject.desertRoute(points: o.points, name: "دروب البر: \(o.mode.label) إلى \(name)") else { return }
        DesertRoutesHub.shared.clear()
        host.follow(s)
    }

    /// «اتجه»: the usual road guidance to the same point (no desert route here).
    private func direct() {
        DesertRoutesHub.shared.clear()
        host.directions(NavTargets.point(target, name: name))
    }

    private func close() {
        DesertRoutesHub.shared.clear()
        host.close()
    }
}
