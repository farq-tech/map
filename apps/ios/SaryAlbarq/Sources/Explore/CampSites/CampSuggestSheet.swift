import SwiftUI

/// «اقترح لي مكان كشتة»: the five best sites within a radius, ranked with tonight's wind,
/// rain and sunset (Open-Meteo) — each with its reasons and «اتجه».
@MainActor
final class CampSuggestModel: ObservableObject {
    static let radii: [Double] = [25, 50, 100, 200]

    enum Phase: Equatable { case noFix, loading, ready }

    @Published var radiusKm: Double = 100
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var ranked: [CampRanker.Ranked] = []
    /// Tonight per region (one Open-Meteo request per region, at its rounded centre).
    @Published private(set) var nights: [String: CampNight] = [:]
    @Published private(set) var weatherFailed = false

    private let sites: [CampSite]
    private let provider: FallbackWeatherProvider
    /// Number tonight's five on the map (the suggestion sheet; not a single tapped site's card).
    private let highlights: Bool
    private var me: LngLat?

    init(sites: [CampSite] = CampSiteCatalog.all, provider: FallbackWeatherProvider = .placeBrief, highlights: Bool = true) {
        self.sites = sites
        self.provider = provider
        self.highlights = highlights
    }

    /// The night that applies to tonight's list (the nearest region's).
    var night: CampNight? { ranked.first.flatMap { nights[$0.site.region] } ?? nights.values.first }

    func start(me: LngLat?) async {
        var me = me
        #if DEBUG
        /* UI tests / screenshots: `-SaryCampFrom 24.7113,46.6744` stands in for the GPS fix. */
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-SaryCampFrom"), i + 1 < a.count {
            let v = a[i + 1].split(separator: ",").compactMap { Double($0) }
            if v.count == 2 { me = LngLat(lng: v[1], lat: v[0]) }
        }
        #endif
        self.me = me
        guard let me else { phase = .noFix; return }
        phase = .loading
        #if DEBUG
        if let n = Self.debugNight() {
            for r in CampSiteCatalog.regions { nights[r] = n }
            rank(me)
            return
        }
        #endif
        rank(me)
        let regions = Set(sites.filter { Vehicle.distanceMeters(me, $0.position) <= Self.radii.last! * 1000 }.map(\.region))
        var failed = false
        for r in regions {
            let rs = sites.filter { $0.region == r }
            guard !rs.isEmpty else { continue }
            let lat = rs.map(\.lat).reduce(0, +) / Double(rs.count), lng = rs.map(\.lng).reduce(0, +) / Double(rs.count)
            /* The region's centre on the 0.1° grid: nothing about where the person is. */
            let area = WeatherArea(around: lat, lng: lng)
            do {
                let w = try await provider.fetch(area, now: Date())
                nights[r] = CampNight.from(w.report, now: Date(), lat: lat, lng: lng)
            } catch { failed = true }
        }
        weatherFailed = failed && nights.isEmpty
        rank(me)
    }

    func setRadius(_ km: Double) {
        radiusKm = km
        if let me { rank(me) }
    }

    private func rank(_ me: LngLat) {
        /* Each region's own night; the list is merged by score. */
        var all: [CampRanker.Ranked] = []
        for r in Set(sites.map(\.region)) {
            all += CampRanker.top(sites.filter { $0.region == r }, near: me, radiusKm: radiusKm, night: nights[r], count: 5)
        }
        ranked = Array(all.sorted { $0.score > $1.score }.prefix(5))
        phase = .ready
        guard highlights else { return }
        CampSitesHub.shared.highlighted = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($0.element.site.id, $0.offset + 1) })
    }

    #if DEBUG
    /// UI tests: `-SaryCampNight "fromDeg,gustKmh[,rainProb]"` instead of the network.
    static func debugNight() -> CampNight? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-SaryCampNight"), i + 1 < a.count else { return nil }
        let v = a[i + 1].split(separator: ",").compactMap { Double($0) }
        guard v.count >= 2 else { return nil }
        return CampNight(windKmh: v[1] * 0.7, gustKmh: v[1], fromDeg: v[0], rainProbability: v.count > 2 ? v[2] : 0, rainMm: 0,
                         dust: nil, pm10: nil, sunset: SunTimes.sunset(near: Date(), lat: 25, lng: 46.7))
    }
    #endif
}

struct CampSuggestSheet: View {
    @ObservedObject var controller: LiveOutingController
    @StateObject private var model = CampSuggestModel()
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        SaryPage(title: "اقترح لي مكان كشتة", subtitle: "أحلى ٥ جلسات حولك الليلة", close: close) {
            radiusPicker
            if let n = model.night { nightCard(n) } else if model.weatherFailed {
                Text("ما قدرنا نجيب طقس الليلة، الترتيب بدون الريح").saryText(.footnote).foregroundStyle(p.warningText)
                    .accessibilityIdentifier("camp.noWeather")
            }
            switch model.phase {
            case .noFix:
                SaryStateView(kind: .empty(title: "ننتظر موقعك", message: "نحتاج موقعك عشان نقترح أماكن قريبة منك.", systemImage: "location"))
                    .sarySurface(radius: SaryRadius.l)
            case .loading where model.ranked.isEmpty:
                SaryStateView(kind: .loading("ندوّر لك أحلى جلسة…")).sarySurface(radius: SaryRadius.l)
            default:
                if model.ranked.isEmpty {
                    SaryStateView(kind: .empty(title: "ما لقينا أماكن مقترحة قريبة",
                                               message: "الاقتراحات الحين حول الثمامة والدهناء والنفود. وسّع المسافة أو جرّب منطقة ثانية.",
                                               systemImage: "tent"))
                        .sarySurface(radius: SaryRadius.l)
                        .accessibilityIdentifier("camp.empty")
                } else {
                    ForEach(Array(model.ranked.enumerated()), id: \.element.id) { i, r in
                        CampSiteCard(rank: i + 1, ranked: r, night: model.nights[r.site.region], go: { go(r.site, rank: i + 1) },
                                     routes: DesertGrid.bboxes[r.site.region] == nil ? nil : { routes(r.site, rank: i + 1) })
                    }
                }
            }
            Text("\(CampReason.estimateNote). \(CampReason.legalNote).")
                .saryText(.footnote, weight: .bold).foregroundStyle(p.warningText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("camp.estimateNote")
        }
        .task {
            let f = controller.location.lastFix
            await model.start(me: f.map { LngLat(lng: $0.lng, lat: $0.lat) })
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("camp.sheet")
    }

    private var radiusPicker: some View {
        HStack(spacing: theme.space(.s)) {
            Text("ضمن").saryText(.subhead, weight: .bold).foregroundStyle(theme.palette.textSecondary)
            ForEach(CampSuggestModel.radii, id: \.self) { km in
                let on = model.radiusKm == km
                Button { model.setRadius(km) } label: {
                    Text("\(SaryFormat.number(Int(km))) كم").saryText(.subhead, weight: .bold)
                        .foregroundStyle(on ? theme.palette.onAccent : theme.palette.textPrimary)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(on ? theme.palette.accent : theme.palette.sunken))
                }
                .buttonStyle(SaryPressStyle())
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("camp.radius.\(Int(km))")
            }
            Spacer(minLength: 0)
        }
    }

    private func nightCard(_ n: CampNight) -> some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 4) {
            Label("الليلة: ريح \(CampReason.windAdjective(n.fromDeg)) \(SaryFormat.number(Int(n.windKmh.rounded()))) كم/س · هبّات \(SaryFormat.number(Int(n.gustKmh.rounded())))",
                  systemImage: "wind")
                .saryText(.subhead, weight: .bold).foregroundStyle(p.textPrimary)
            if let s = n.sunset {
                Label("المغرب \(s.formatted(.dateTime.hour().minute().locale(Locale(identifier: "ar_SA"))))", systemImage: "sunset.fill")
                    .saryText(.footnote).foregroundStyle(p.textSecondary)
            }
            if let v = CampReason.verdictLine(n) {
                Text(v).saryText(.footnote, weight: .bold).foregroundStyle(n.verdict == .notTonight ? p.emergencyText : p.warningText)
                    .accessibilityIdentifier("camp.windWarning")
            }
            if let r = CampReason.rainLine(n) {
                Text(r).saryText(.footnote, weight: .bold).foregroundStyle(p.warningText).accessibilityIdentifier("camp.rainWarning")
            }
            Text(OpenMeteo.attribution).saryText(.caption).foregroundStyle(p.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.space(.m))
        .sarySurface(radius: SaryRadius.l)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("camp.night")
    }

    private func close() {
        CampSitesHub.shared.highlighted = [:]
        controller.modal = nil
    }

    private func routes(_ s: CampSite, rank: Int) {
        let rain = model.nights[s.region]?.rainy ?? false
        controller.modal = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            controller.modal = .desertRoute(s.position, "جلسة \(SaryFormat.number(rank))" + (s.nearName.map { " قرب \($0)" } ?? ""), rain)
        }
    }

    private func go(_ s: CampSite, rank: Int) {
        /* Our own guidance (NavSession); the off-road remainder never routes along a channel:
         * the target itself is outside every flood buffer (scripts/camp-sites). */
        controller.directions(NavTargets.point(s.position, name: "جلسة \(SaryFormat.number(rank))" + (s.nearName.map { " قرب \($0)" } ?? "")))
    }
}

/// One suggestion: the score, tonight's wind line, the top three reasons, notes and «اتجه».
struct CampSiteCard: View {
    var rank: Int
    var ranked: CampRanker.Ranked
    var night: CampNight?
    var go: () -> Void
    /// «دروب البر» (nil: the site is outside the bundled route grids).
    var routes: (() -> Void)? = nil
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let s = ranked.site
        VStack(alignment: .leading, spacing: theme.space(.s)) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space(.s)) {
                Text(SaryFormat.number(rank)).saryText(.headline, weight: .bold).foregroundStyle(p.onAccent)
                    .frame(width: 30, height: 30).background(Circle().fill(p.accent))
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.nearName.map { "قرب \($0)" } ?? "جلسة \(SaryFormat.number(rank))")
                        .saryText(.body, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(1)
                    Text("\(SaryFormat.distance(meters: ranked.distanceM)) خط مستقيم · درجة \(SaryFormat.number(Int((ranked.score * 100).rounded())))")
                        .saryNumber(.footnote).foregroundStyle(p.textSecondary)
                }
                Spacer(minLength: 0)
                Button(action: go) { SaryButtonLabel(title: "اتجه", systemImage: SaryIcon.directions) }
                    .buttonStyle(.sary(.primary, width: .hug, compact: true))
                    .accessibilityIdentifier("camp.go.\(rank)")
            }
            if let night {
                Text(CampReason.windLine(s, night: night)).saryText(.footnote, weight: .bold).foregroundStyle(p.accentText)
                    .accessibilityIdentifier("camp.wind.\(rank)")
            }
            Text(CampReason.top3(s, night: night).joined(separator: " · "))
                .saryText(.subhead).foregroundStyle(p.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("camp.reasons.\(rank)")
            HStack(spacing: theme.space(.s)) {
                axis("سلامة", s.safety)
                axis("راحة", s.comfort)
                axis("جمال", s.beauty)
                axis("وصول", s.access)
            }
            if let routes {
                Button(action: routes) {
                    Label("دروب البر: الأسهل والأقصر", systemImage: "point.topleft.down.to.point.bottomright.filled.curvepath")
                        .saryText(.subhead, weight: .bold)
                }
                .buttonStyle(.sary(.secondary, width: .hug, compact: true))
                .accessibilityIdentifier("camp.routes.\(rank)")
            }
            if let pr = s.protected {
                Label(CampReason.protectedNote(pr), systemImage: "exclamationmark.shield.fill")
                    .saryText(.caption, weight: .bold).foregroundStyle(p.warningText)
            }
        }
        .padding(theme.space(.m))
        .sarySurface(radius: SaryRadius.l)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("camp.card.\(rank)")
    }

    private func axis(_ t: String, _ v: Double) -> some View {
        VStack(spacing: 2) {
            Text(t).saryText(.caption).foregroundStyle(theme.palette.textSecondary)
            Capsule().fill(theme.palette.sunken).frame(height: 5)
                .overlay(alignment: .leading) {
                    GeometryReader { g in Capsule().fill(theme.palette.accent).frame(width: g.size.width * max(0.05, min(1, v))) }
                }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(t) \(SaryFormat.percent(Int((v * 100).rounded())))"))
    }
}

/// A site tapped on the map: its card alone, ranked with tonight's wind when it arrives.
struct CampSiteTappedSheet: View {
    @ObservedObject var controller: LiveOutingController
    var siteId: String
    @StateObject private var model = CampSuggestModel(highlights: false)
    @Environment(\.sary) private var theme

    var body: some View {
        let site = CampSiteCatalog.all.first { $0.id == siteId }
        SaryPage(title: "مكان مقترح للكشتة", close: { controller.modal = nil }) {
            if let site {
                let me = controller.location.lastFix.map { LngLat(lng: $0.lng, lat: $0.lat) }
                let night = model.nights[site.region]
                CampSiteCard(rank: 1, ranked: .init(site: site, score: CampRanker.score(site, night: night),
                                                    distanceM: me.map { Vehicle.distanceMeters($0, site.position) } ?? 0),
                             night: night, go: {
                    controller.directions(NavTargets.point(site.position, name: site.nearName.map { "جلسة قرب \($0)" } ?? "جلسة كشتة"))
                }, routes: {
                    let rain = night?.rainy ?? false
                    controller.modal = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        controller.modal = .desertRoute(site.position, site.nearName.map { "جلسة قرب \($0)" } ?? "جلسة كشتة", rain)
                    }
                })
            }
            Text("\(CampReason.estimateNote). \(CampReason.legalNote).")
                .saryText(.footnote, weight: .bold).foregroundStyle(theme.palette.warningText)
        }
        .task {
            let f = controller.location.lastFix
            await model.start(me: f.map { LngLat(lng: $0.lng, lat: $0.lat) })
        }
        .accessibilityIdentifier("camp.site.sheet")
    }
}
