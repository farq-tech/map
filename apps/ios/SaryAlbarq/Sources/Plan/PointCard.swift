import SwiftUI
import UIKit

/// What a point on the map can become. A nil action hides its button.
struct PointActions {
    var setDestination: ((LngLat, String?) -> Void)?
    var addPoint: ((LngLat) -> Void)?
    var rally: ((LngLat) -> Void)?
    var weatherHere: ((LngLat) -> Void)? = PointActions.weatherHook
    /// «ملاحة إلى هنا» (turn-by-turn, live outing only): the map's single long press is the
    /// point card, so navigation to a pressed point starts from here.
    var navigateHere: ((LngLat) -> Void)? = nil
    /// «احفظ في أماكني» (on-device saved places, live outing only).
    var savePlace: ((LngLat, String?) -> Void)? = nil

    /// «الطقس هنا»: the weather branch sets this; until then the button is hidden.
    static var weatherHook: ((LngLat) -> Void)?
    /// «أضف نقطة»: the waypoints branch sets this (outing id, point) to add a shared
    /// waypoint; when nil, «أضف نقطة» adds the point to the end of the planned route.
    static var addWaypointHook: ((String, LngLat) -> Void)?

    static let none = PointActions(setDestination: nil, addPoint: nil, rally: nil, weatherHere: nil)
}

enum PlanClipboard {
    /// Western digits only (see CoordinateShare). Haptic + the caller's «نُسخ» toast.
    static func copy(_ s: String) {
        UIPasteboard.general.string = s
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

struct ShareItem: Identifiable {
    let text: String
    var id: String { text }
}

/// The single long-press card (and «انسخ موقعي»): the point's coordinates in decimal
/// and DMS, copy (either format, Western digits), share (Google / Apple Maps link)
/// and what the point can become.
struct PointCard: View {
    enum Subject: Equatable {
        case point(LngLat, name: String?)
        case me(CoordinateShare.Fix)
    }

    var subject: Subject
    var actions: PointActions = .none
    var close: (() -> Void)?
    /// «بريف المكان» (the live map's tap / long-press): weather, sun and terrain at the point.
    var brief: PlaceBriefOptions? = nil
    @Environment(\.sary) private var theme
    @StateObject private var briefModel = PlaceBriefModel()
    @State private var toast: String?
    @State private var copied = ""
    @State private var share: ShareItem?

    private var point: LngLat {
        switch subject {
        case let .point(p, _): return p
        case let .me(f): return f.point
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            content(now: ctx.date)
        }
        .overlay(alignment: .bottom) {
            if let toast {
                SaryToast(text: toast)
                    .accessibilityIdentifier("point.toast")
                    .accessibilityValue(copied)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, theme.space(.s))
            }
        }
        .animation(theme.animation(.snappy), value: toast)
        .sheet(item: $share) { s in ShareSheet(items: [s.text]).presentationDetents([.medium, .large]) }
        .task(id: "\(point.lat),\(point.lng)") {
            guard let brief, case let .point(p, name) = subject else { return }
            briefModel.load(p, knownName: name, saved: brief.saved)
        }
    }

    private var briefOn: Bool {
        if brief != nil, case .point = subject { return true }
        return false
    }

    /// The name to save / share with: one the person or the map gave, or a saved place (never «قرب …»).
    private var resolvedName: String? {
        if case let .point(_, n) = subject, let n { return n }
        if briefOn, let n = briefModel.name, !n.approximate { return n.text }
        return nil
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.space(.m)) {
            HStack(alignment: .top, spacing: theme.space(.s)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(now: now)).saryText(.headline).foregroundStyle(p.textPrimary)
                        .accessibilityIdentifier("point.title")
                    if briefOn, let d = PlaceBriefRules.distanceText(from: brief?.me, to: point) {
                        Text(d).saryNumber(.footnote).foregroundStyle(p.textSecondary).accessibilityIdentifier("point.distance")
                    }
                    if case let .me(f) = subject {
                        let parts = [CoordinateShare.accuracyLabel(f.accuracyM), CoordinateShare.clock(f.at)].compactMap { $0 }
                        Text(parts.joined(separator: " · ")).saryText(.footnote).foregroundStyle(p.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                if let close { SaryIconButton(systemImage: SaryIcon.close, label: "إغلاق", id: "point.close", action: close) }
            }
            if case let .me(f) = subject, !CoordinateShare.isFresh(f, now: now) {
                SaryBanner(text: "هذا ليس موقعك الحالي: \(CoordinateShare.headline(f, now: now)). يُرسل كذلك في النص.", tone: .warning)
            }
            if briefOn {
                /* The brief's header already carries the coordinates when there is no name. */
                if briefModel.name != nil || resolvedName != nil {
                    Text(CoordinateShare.displayDecimal(point)).saryNumber(.subhead, weight: .bold).foregroundStyle(p.textSecondary)
                        .textSelection(.enabled).accessibilityIdentifier("point.decimal")
                }
                if brief?.compact != true {
                    Text(CoordinateShare.displayDMS(point)).saryNumber(.footnote).foregroundStyle(p.textTertiary)
                }
                PlaceBriefSection(ui: PlaceBriefPresenter.build(briefModel.weather, loading: briefModel.loading, failed: briefModel.failure, point: point, now: now),
                                  terrain: briefModel.terrain, compact: brief?.compact == true)
            } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(CoordinateShare.displayDecimal(point))
                    .saryNumber(.title2, weight: .bold).foregroundStyle(p.textPrimary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("point.decimal")
                Text(CoordinateShare.displayDMS(point))
                    .saryNumber(.subhead).foregroundStyle(p.textSecondary)
            }
            }
            HStack(spacing: theme.space(.s)) {
                Menu {
                    Button("عشري (٢٤٫٧١٣٦٠، ٤٦٫٦٧٥٣٠)") { copy(.decimal, now: now) }
                    Button("درجات ودقائق وثوانٍ") { copy(.dms, now: now) }
                } label: { SaryButtonLabel(title: "انسخ الإحداثية", systemImage: SaryIcon.copy) }
                    .buttonStyle(.sary(.primary))
                    .accessibilityIdentifier("point.copy")
                    .accessibilityValue(copied.isEmpty ? "" : "نُسخ: \(copied)")
                Menu {
                    Button("رابط Google Maps") { share = ShareItem(text: message(.google, now: now)) }
                    Button("رابط Apple Maps") { share = ShareItem(text: message(.apple, now: now)) }
                } label: { SaryButtonLabel(title: "شارك", systemImage: SaryIcon.share) }
                    .buttonStyle(.sary(.secondary))
                    .accessibilityIdentifier("point.share")
            }
            if case .me = subject {
                Text("«شارك» يرسل موقعك الحالي مرة وحدة، عن طريق التطبيق اللي تختاره. التطبيق نفسه لا يرسل شيئًا.")
                    .saryText(.footnote).foregroundStyle(p.textTertiary)
            }
            let extra = extraActions
            if !extra.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: theme.space(.s)), GridItem(.flexible(), spacing: theme.space(.s))], spacing: theme.space(.s)) {
                    ForEach(extra, id: \.id) { a in
                        Button(action: a.run) { SaryButtonLabel(title: a.title, systemImage: a.icon) }
                            .buttonStyle(.sary(.secondary, compact: true))
                            .accessibilityIdentifier(a.id)
                    }
                }
            }
        }
        .padding(theme.space(.l))
    }

    private struct Extra { var id: String; var title: String; var icon: String; var run: () -> Void }

    private var extraActions: [Extra] {
        let pt = point
        var out: [Extra] = []
        let name = resolvedName
        if let f = actions.navigateHere { out.append(Extra(id: "point.navigate", title: "ملاحة إلى هنا", icon: SaryIcon.directions) { f(pt) }) }
        if let f = actions.weatherHere { out.append(Extra(id: "point.weather", title: "الطقس هنا", icon: "cloud.sun.fill") { f(pt) }) }
        if let f = actions.setDestination { out.append(Extra(id: "point.destination", title: "اجعلها الوجهة", icon: "flag.checkered") { f(pt, name) }) }
        if let f = actions.addPoint { out.append(Extra(id: "point.add", title: "أضف نقطة", icon: "mappin.and.ellipse") { f(pt) }) }
        if let f = actions.rally { out.append(Extra(id: "point.rally", title: "نقطة تجمع", icon: SaryIcon.rally) { f(pt) }) }
        if let f = actions.savePlace { out.append(Extra(id: "point.save", title: "احفظ في أماكني", icon: "star.fill") { f(pt, name) }) }
        return out
    }

    private func title(now: Date) -> String {
        switch subject {
        case let .point(_, name):
            if briefOn { return name ?? briefModel.name?.display ?? CoordinateShare.displayDecimal(point) }
            return name ?? "نقطة على الخريطة"
        case let .me(f): return CoordinateShare.headline(f, now: now)
        }
    }

    private func copy(_ f: CoordinateShare.Format, now: Date) {
        let text: String
        switch subject {
        case .point: text = CoordinateShare.copy(point, f)
        case let .me(fix): text = CoordinateShare.myLocationCopy(fix, format: f, now: now)
        }
        PlanClipboard.copy(text)
        copied = text
        toast = "نُسخ"
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            toast = nil
        }
    }

    private func message(_ kind: CoordinateShare.MapLink, now: Date) -> String {
        switch subject {
        case let .point(p, _): return CoordinateShare.pointMessage(p, name: resolvedName, link: kind)
        case let .me(f): return CoordinateShare.myLocationMessage(f, link: kind, now: now)
        }
    }
}

extension CoordinateShare.Fix {
    init?(_ f: DeviceFix?) {
        guard let f else { return nil }
        self.init(point: LngLat(lng: f.lng, lat: f.lat), accuracyM: f.accuracy, at: Date(timeIntervalSince1970: f.atMs / 1000))
    }
}

// MARK: - «ابحث أو أدخل إحداثية»

/// Type or paste a coordinate (any common format) or search for a place, preview it, act on it.
struct CoordinateSearchSheet: View {
    var near: LngLat?
    var myFix: DeviceFix?
    var actions: PointActions
    var search: (String, LngLat?) async throws -> [PlaceSearch.Place] = { q, near in try await PlaceSearch.search(q, near: near) }
    var initialText = ""
    var close: () -> Void
    @Environment(\.sary) private var theme
    @State private var text = ""
    @State private var results: [PlaceSearch.Place] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var picked: (point: LngLat, name: String?)?
    @State private var showMe = false
    @State private var job: Task<Void, Never>?

    var body: some View {
        let p = theme.palette
        let parsed = CoordinateParser.parse(text)
        SaryPage(title: "ابحث أو أدخل إحداثية", close: close) {
            if let picked {
                PlanMapView(route: [], picked: picked.point, interactive: false, camera: PlanCamera(kind: .point(picked.point, zoom: 13), id: Int(picked.point.lat * 1e5) ^ Int(picked.point.lng * 1e5)), theme: theme)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous))
                    .accessibilityIdentifier("search.preview")
                PointCard(subject: .point(picked.point, name: picked.name), actions: actions)
                    .sarySurface(radius: SaryRadius.m)
                Button { self.picked = nil } label: { SaryButtonLabel(title: "رجوع للبحث", systemImage: SaryIcon.back) }
                    .buttonStyle(.sary(.plain))
            } else if showMe, let f = CoordinateShare.Fix(myFix) {
                PointCard(subject: .me(f), actions: actions).sarySurface(radius: SaryRadius.m)
                Button { showMe = false } label: { SaryButtonLabel(title: "رجوع للبحث", systemImage: SaryIcon.back) }
                    .buttonStyle(.sary(.plain))
            } else {
                SaryTextField(title: "مكان أو إحداثية", placeholder: "٢٤٫٧١٣٦، ٤٦٫٦٧٥٣ أو اسم مكان", text: $text, id: "search.field",
                              help: "يقبل: عشري، درجات ودقائق وثوانٍ (مثل 24°42'49\"N)، درجات ودقائق، روابط Google أو Apple Maps، و Plus Code.")
                    .onChange(of: text) { _, v in schedule(v) }
                if let parsed {
                    SarySection(title: "إحداثية") {
                        Button { picked = (parsed.point, nil) } label: {
                            HStack(spacing: theme.space(.m)) {
                                SaryRowIcon(systemImage: "scope")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(CoordinateShare.displayDecimal(parsed.point)).saryNumber(.body, weight: .bold).foregroundStyle(p.textPrimary)
                                    Text(CoordinateShare.displayDMS(parsed.point)).saryNumber(.footnote).foregroundStyle(p.textSecondary)
                                }
                                Spacer()
                                Image(systemName: SaryIcon.back).foregroundStyle(p.textTertiary).rotationEffect(.degrees(180))
                            }
                            .frame(minHeight: theme.minTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search.coordinate")
                    }
                    if parsed.outsideRegion {
                        SaryBanner(text: "هذه الإحداثية خارج السعودية وما حولها. تأكد من ترتيب خط العرض والطول.", tone: .warning)
                    }
                    if parsed.swapped {
                        SaryBanner(text: "قرأناها «طول، عرض» لأن الرقم الأول لا يصلح خط عرض.", tone: .info, systemImage: "arrow.left.arrow.right")
                    }
                } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    if searching { SaryStateView(kind: .loading("نبحث…")) }
                    if let searchError { SaryBanner(text: searchError, tone: .warning) }
                    if !results.isEmpty {
                        SarySection(title: "أماكن") {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, r in
                                if i > 0 { SaryDivider() }
                                Button { picked = (r.point, String(r.name.prefix(TripPlan.destinationNameMax))) } label: {
                                    HStack(spacing: theme.space(.m)) {
                                        SaryRowIcon(systemImage: "mappin")
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(r.name).saryText(.body, weight: .bold).foregroundStyle(p.textPrimary)
                                            if let d = r.detail { Text(d).saryText(.footnote).foregroundStyle(p.textSecondary).lineLimit(1) }
                                        }
                                        Spacer()
                                        if let near { Text(SaryFormat.distance(meters: PlanGeo.meters(near, r.point))).saryNumber(.footnote).foregroundStyle(p.textTertiary) }
                                    }
                                    .frame(minHeight: theme.minTarget)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("search.result")
                            }
                        }
                    } else if !searching && searchError == nil && text.count >= 2 {
                        Text("ما وجدنا مكانًا بهذا الاسم.").saryText(.subhead).foregroundStyle(p.textSecondary)
                    }
                }
                if myFix != nil {
                    SarySection(title: "موقعي") {
                        Button { showMe = true } label: {
                            HStack(spacing: theme.space(.m)) {
                                SaryRowIcon(systemImage: SaryIcon.locate)
                                Text("إحداثياتي — انسخ أو شارك").saryText(.body, weight: .medium).foregroundStyle(p.textPrimary)
                                Spacer()
                            }
                            .frame(minHeight: theme.minTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search.me")
                    }
                }
            }
        }
        .onAppear { if text.isEmpty, !initialText.isEmpty { text = initialText } }
    }

    private func schedule(_ q: String) {
        job?.cancel()
        searchError = nil
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, CoordinateParser.parse(t) == nil else {
            results = []
            searching = false
            return
        }
        searching = true
        job = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            do {
                let r = try await search(t, near)
                guard !Task.isCancelled else { return }
                results = r
            } catch let e as PlaceSearch.SearchError {
                results = []
                searchError = e.arabic
            } catch {
                results = []
                searchError = PlaceSearch.SearchError.network.arabic
            }
            searching = false
        }
    }
}
