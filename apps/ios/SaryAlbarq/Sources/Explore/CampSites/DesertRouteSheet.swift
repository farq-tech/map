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

/// «مخطط دروب البر»: three ways there — «الأسهل»، «المتوازن»، «الأقصر» — each with distance,
/// time, the share on a known track, the hard stretches and how to avoid them. Picking one
/// follows it with the app's own guidance («اسلك هذا المسار»).
struct DesertRouteSheet: View {
    @ObservedObject var controller: LiveOutingController
    var target: LngLat
    var name: String
    /// Forecast indicates rain tonight.
    var rain: Bool
    /// When false, route conservatively treats rainfall as possible and refuses major wadis.
    var weatherAvailable: Bool
    @ObservedObject private var hub = DesertRoutesHub.shared
    @State private var phase: Phase = .working
    @Environment(\.sary) private var theme

    enum Phase: Equatable { case working, ready, outside, noFix, none }

    static let note = "مسار مقترح من صور الأقمار، تأكد بعينك. ما يغني عن خبرة الدليل"

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
                SaryStateView(kind: .empty(title: "الوجهة بعيدة على دروب البر",
                                           message: "دروب البر تنحسب داخل المملكة لمسافة نحو ١٠٠ كم بينك وبين الوجهة. استخدم «اتجه» للتوجيه العادي.",
                                           systemImage: "map"))
                    .sarySurface(radius: SaryRadius.l)
                    .accessibilityIdentifier("routes.outside")
            case .none:
                SaryStateView(kind: .empty(title: "ما لقينا درب آمن", message: "جرّب «اتجه» أو نقطة ثانية.", systemImage: "xmark.octagon"))
                    .sarySurface(radius: SaryRadius.l)
            case .ready:
                ForEach(hub.options) { o in card(o) }
            }
            Text(Self.note).saryText(.footnote, weight: .bold).foregroundStyle(p.warningText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("routes.note")
        }
        .task { await compute() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routes.sheet")
    }

    private func compute() async {
        var me = controller.location.lastFix.map { LngLat(lng: $0.lng, lat: $0.lat) }
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
        let opts = await Task.detached(priority: .userInitiated) { () -> [DesertRouter.Option] in
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
        hub.options = opts
        hub.selected = opts.first?.mode ?? .easy
        phase = opts.isEmpty ? .none : .ready
        if let all = opts.first?.points, !all.isEmpty { controller.lowerSheetThenAsk(.fitTrack(opts.flatMap(\.points))) }
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
                } label: { SaryButtonLabel(title: "امشِ عليه", systemImage: SaryIcon.directions) }
                    .buttonStyle(.sary(on ? .primary : .secondary, width: .hug, compact: true))
                    .accessibilityIdentifier("routes.go.\(o.mode.rawValue)")
            }
            Text("\(SaryFormat.distance(meters: o.distanceM)) · نحو \(SaryFormat.duration(seconds: Int(o.minutes * 60))) · \(SaryFormat.percent(Int(o.trackPercent.rounded()))) على درب معروف")
                .saryNumber(.subhead).foregroundStyle(p.textPrimary)
                .accessibilityIdentifier("routes.stats.\(o.mode.rawValue)")
            if o.hard.isEmpty {
                Text("ما فيه مقاطع صعبة تُذكر").saryText(.footnote).foregroundStyle(p.liveText)
            } else {
                Text("مقاطع صعبة: " + o.hardTotals.prefix(3).map { "\($0.0.text) \(SaryFormat.distance(meters: $0.1))" }.joined(separator: " · "))
                    .saryText(.footnote, weight: .bold).foregroundStyle(p.emergencyText)
                    .accessibilityIdentifier("routes.hard.\(o.mode.rawValue)")
                if let tip = o.tip {
                    Text("كيف تتجنبها: \(tip)").saryText(.footnote).foregroundStyle(p.textSecondary)
                }
            }
        }
        .padding(theme.space(.m))
        .contentShape(Rectangle())
        .onTapGesture { hub.selected = o.mode }
        .sarySurface(radius: SaryRadius.l)
        .overlay(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous).stroke(on ? Self.color(o.mode) : .clear, lineWidth: 2))
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

    static func hex(_ m: DesertRouter.Mode) -> String {
        switch m {
        case .easy: return "#2ecc71"
        case .balanced: return "#3498db"
        case .short: return "#e74c3c"
        }
    }

    private func go(_ o: DesertRouter.Option) {
        guard let s = FollowSubject.desertRoute(points: o.points, name: "دروب البر: \(o.mode.label) إلى \(name)") else { return }
        DesertRoutesHub.shared.clear()
        controller.modal = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { controller.startFollow(s) }
    }

    private func close() {
        DesertRoutesHub.shared.clear()
        controller.modal = nil
    }
}
