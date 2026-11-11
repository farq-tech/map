import SwiftUI

/// The plan's modals on the live screen (one `LiveModal.plan` case).
enum LivePlanModal: Equatable {
    /// The single long-press card for a point.
    case point(LngLat)
    /// «بريف المكان»: a single tap on an empty map spot (or a map label, with its name).
    case brief(LngLat, name: String?)
    /// «انسخ موقعي» (control cluster or long-press on «أنت»).
    case me
    case search
    case editor

    var id: String {
        switch self {
        case let .point(p): return "plan.point.\(p.lat),\(p.lng)"
        case let .brief(p, _): return "plan.brief.\(p.lat),\(p.lng)"
        case .me: return "plan.me"
        case .search: return "plan.search"
        case .editor: return "plan.editor"
        }
    }
}

/// Gives the live map the plan as plain data, observing the outing's `PlanModel`.
struct PlanObserving<Content: View>: View {
    @ObservedObject var plan: PlanModel
    var picked: LngLat?
    @ViewBuilder var content: (MapPlan) -> Content

    var body: some View {
        content(MapPlan(route: plan.plan.points, destination: plan.plan.destination, picked: picked, emphasised: plan.following))
            .task {
                if plan.planPhase != .loaded { await plan.load() }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-SaryPlanFollow"), plan.plan.hasRoute { plan.following = true }
                #endif
            }
    }
}

extension LiveOutingController {
    /// Long-press on the map: «أنت» (within reach of my car) opens my card, anywhere else the point card.
    func planLongPress(_ p: LngLat, at screen: CGPoint) {
        if let me = session.view?.myId, let mine = overlay.projection.points[me], hypot(mine.x - screen.x, mine.y - screen.y) <= 40, location.lastFix != nil {
            modal = .plan(.me)
        } else {
            modal = .plan(.point(p))
        }
    }

    var planPicked: LngLat? {
        if case let .plan(.point(p))? = modal { return p }
        if case let .plan(.brief(p, _))? = modal { return p }
        return nil
    }
}

/// The modal content for `LiveModal.plan`.
struct LivePlanModalView: View {
    let controller: LiveOutingController
    let modal: LivePlanModal
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var location: LocationSharer
    @Environment(\.sary) private var theme

    var body: some View {
        let plan = model.plans.model(controller.session.id)
        let close = { controller.modal = nil }
        Group {
            switch modal {
            case let .point(p):
                briefCard(p, name: nil, plan: plan, close: close)
            case let .brief(p, name):
                briefCard(p, name: name, plan: plan, close: close)
            case .me:
                if let f = CoordinateShare.Fix(location.lastFix) {
                    /* Scrolls when the card is taller than the detent (an SE, large text, every action). */
                    ScrollView {
                        PointCard(subject: .me(f), actions: actions(plan), close: close)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .presentationDetents([.height(460), .large])
                } else {
                    SaryStateView(kind: .empty(title: "ما عندنا موقعك بعد", message: "فعّل الموقع وانتظر قليلًا.", systemImage: SaryIcon.gpsOff))
                        .presentationDetents([.medium])
                }
            case .search:
                /* UI-AUDIT م3: a dedicated search sheet, not the whole home screen in a sheet (its
                 * profile, «المفضلة» and «طلعة جديدة» did nothing here, or closed the outing). */
                LiveSearchSheet(near: location.lastFix.map { LngLat(lng: $0.lng, lat: $0.lat) },
                                pick: { controller.pickLegDestination($0) }, close: close)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            case .editor:
                PlanEditorView(plan: plan, outingName: controller.ui.outingName, canEdit: controller.session.view?.iLead == true, myFix: location.lastFix, close: close)
                    .presentationDetents([.large])
                    .interactiveDismissDisabled()
            }
        }
        .rtl()
    }

    /// The point card with «بريف المكان»; compact (one weather line) in the driving layout.
    @ViewBuilder
    private func briefCard(_ p: LngLat, name: String?, plan: PlanModel, close: @escaping () -> Void) -> some View {
        let compact = controller.briefCompact(drive: theme.drive)
        let opts = PlaceBriefOptions(me: controller.briefMe(location.lastFix), compact: compact, saved: SavedPlacesStore.shared.places)
        ScrollView {
            PointCard(subject: .point(p, name: name), actions: actions(plan), close: close, brief: opts)
        }
        .accessibilityIdentifier("point.sheet.scroll")
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents(compact ? [.height(330), .large] : [.fraction(0.62), .large])
    }

    private func actions(_ plan: PlanModel) -> PointActions {
        let lead = controller.session.view?.iLead == true
        var a = PointActions(setDestination: nil, addPoint: nil, rally: nil)
        a.navigateHere = { p, name in
            controller.modal = nil
            /* Let the point sheet dismiss before starting/replacing personal guidance. */
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { controller.navLongPressed(p, name: name) }
        }
        a.savePlace = { p, name in
            controller.modal = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                controller.modal = .placeEdit(SavedPlaceDraft(id: nil, point: p, name: name ?? "", icon: .pin))
            }
        }
        if lead {
            a.setDestination = { p, name in
                controller.modal = nil
                Task {
                    if await plan.setDestination(OutingDestination(name: name ?? "الوجهة", lat: p.lat, lng: p.lng)) { controller.toast("صارت الوجهة") }
                }
            }
            a.rally = { p in
                controller.modal = nil
                controller.saveRally(p, label: "")
            }
        }
        a.droneFlight = { p in
            controller.modal = nil
            controller.sheetDetent = .peek
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { MapVisualsHub.shared.fly(to: p) }
        }
        if let hook = PointActions.addWaypointHook {
            let id = controller.session.id
            a.addPoint = { p in controller.modal = nil; hook(id, p) }
        } else if lead {
            a.addPoint = { p in
                controller.modal = nil
                Task {
                    var tp = plan.plan
                    tp.route = PlanLineString(tp.points + [p])
                    if await plan.save(tp) { controller.toast("أُضيفت للمسار") }
                }
            }
        }
        return a
    }
}

/// One place-search result, the same in the home search, the in-trip search and «طلعة جديدة» step ١
/// (Build 36 item 11: rows were tight, Arabic and English mixed on one line, the distance faint):
/// the Arabic name big; the other-language name alone on a small line; the kind and the area under it;
/// the distance bold at the end, easy to compare down the list.
struct PlaceResultRow: View {
    var icon: String
    var name: String
    var secondaryName: String?
    var detail: String?
    var meters: Double?
    var id: String
    var run: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        Button(action: run) {
            HStack(alignment: .center, spacing: theme.space(.m)) {
                SaryRowIcon(systemImage: icon)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).saryText(.body, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(2)
                    if let secondaryName {
                        /* Latin reads left to right inside the RTL row, small and quiet. */
                        Text(secondaryName).saryText(.caption).foregroundStyle(p.textTertiary).lineLimit(1)
                    }
                    if let detail { Text(detail).saryNumber(.footnote).foregroundStyle(p.textSecondary).lineLimit(1) }
                }
                Spacer(minLength: theme.space(.s))
                if let m = meters {
                    Text(m == 0 ? "هنا" : SaryFormat.distance(meters: m))
                        .saryNumber(.subhead, weight: .bold).foregroundStyle(p.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.vertical, theme.space(.s))
            .frame(minHeight: theme.minTarget + 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }
}

/// «الأنسب · الأقرب · حسب النوع» above a result list (shown when there is something to reorder).
struct PlaceOrderPicker: View {
    @Binding var order: PlaceSearch.ListOrder
    /// Without a position «الأقرب» means nothing: only relevance and kind are offered.
    var hasPosition: Bool

    var body: some View {
        Picker("ترتيب النتائج", selection: $order) {
            ForEach(PlaceSearch.ListOrder.allCases.filter { hasPosition || $0 != .nearest }, id: \.self) { o in
                Text(o.title).tag(o)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("places.order")
    }
}

/// In-trip search («ابحث أو إحداثية», «ابحث عن مكان» in «وين رايحين؟», «حدّد الوجهة»): the home
/// search's sources — «دليل البر» first (offline), then Apple and Mapbox, or a typed coordinate —
/// in a lean sheet with a close button. Picking a place sets the next leg's destination.
struct LiveSearchSheet: View {
    var near: LngLat?
    var pick: (OutingDestination) -> Void
    var close: () -> Void
    @Environment(\.sary) private var theme
    @State private var query = ""
    @State private var results: [PlaceSearch.Place] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var order: PlaceSearch.ListOrder = .relevance
    @State private var job: Task<Void, Never>?
    /* Loaded on appear (a @State initialiser runs on every re-init of this struct). */
    @State private var recent: [OutingDestination] = []
    @FocusState private var focused: Bool

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.space(.m)) {
            HStack {
                Text("ابحث عن مكان").saryText(.title2, weight: .heavy).foregroundStyle(p.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                SaryIconButton(systemImage: SaryIcon.close, label: "إغلاق", id: "live.search.close", action: close)
            }
            HStack(spacing: theme.space(.s)) {
                Image(systemName: "magnifyingglass").foregroundStyle(p.textTertiary).accessibilityHidden(true)
                TextField("مكان، أو إحداثية", text: $query)
                    .focused($focused)
                    .submitLabel(.search)
                    .onSubmit { schedule(query, now: true) }
                    .onChange(of: query) { _, q in schedule(q) }
                    .accessibilityIdentifier("live.search.field")
                if !query.isEmpty {
                    /* The 44 pt frame and its content shape go INSIDE the label: a frame on the
                     * Button itself grows the layout but not the area a finger can hit. */
                    Button { clear() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(p.textTertiary)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("امسح"))
                        .accessibilityIdentifier("live.search.clear")
                }
            }
            .padding(.horizontal, theme.space(.m))
            .frame(minHeight: 48)
            .background(Capsule().fill(p.sunken))
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space(.m)) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .padding(theme.space(.l))
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            recent = RecentPlaces.load()
            focused = true
        }
        .onDisappear { job?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live.search")
    }

    @ViewBuilder
    private var content: some View {
        let p = theme.palette
        let t = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = CoordinateParser.parse(t) {
            list([Row(id: "coordinate", icon: "scope", title: CoordinateShare.displayDecimal(parsed.point), detail: CoordinateShare.displayDMS(parsed.point),
                      destination: OutingDestination(name: "نقطة على الخريطة", lat: parsed.point.lat, lng: parsed.point.lng), meters: nil)],
                 id: "live.search.coordinate")
        } else if t.count < 2 {
            if !recent.isEmpty {
                Text("أماكن سابقة").saryText(.footnote, weight: .bold).foregroundStyle(p.textSecondary)
                list(recent.enumerated().map { i, d in
                    Row(id: "recent.\(i)", icon: "clock.arrow.circlepath", title: d.name, detail: nil, destination: d, meters: nil)
                }, id: "live.search.recent")
            }
        } else {
            if searching { SaryStateView(kind: .loading("نبحث…")) }
            if let searchError { SaryBanner(text: searchError, tone: .warning) }
            if !results.isEmpty {
                if results.count >= 3 { PlaceOrderPicker(order: $order, hasPosition: near != nil) }
                list(PlaceSearch.ordered(results, by: order, near: near).map { r in
                    let target = r.areaApproach ?? r.point
                    return Row(id: r.id, icon: r.icon, title: r.name, secondaryName: r.secondaryName, detail: r.rowDetail,
                               destination: OutingDestination(name: String(r.name.prefix(TripPlan.destinationNameMax)), lat: target.lat, lng: target.lng),
                               meters: r.areaDistanceM)
                }, id: "live.search.result")
            } else if !searching && searchError == nil {
                Text("ما لقينا مكان بهالاسم. جرّب اسم ثاني، أو اكتب إحداثية.").saryText(.subhead).foregroundStyle(p.textSecondary)
            }
        }
    }

    private struct Row: Identifiable {
        var id: String
        var icon: String
        var title: String
        var secondaryName: String? = nil
        var detail: String?
        var destination: OutingDestination
        var meters: Double?
    }

    private func list(_ rows: [Row], id: String) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                if i > 0 { SaryDivider() }
                let point = LngLat(lng: r.destination.lng, lat: r.destination.lat)
                PlaceResultRow(icon: r.icon, name: r.title, secondaryName: r.secondaryName, detail: r.detail,
                               meters: r.meters ?? near.map { PlanGeo.meters($0, point) }, id: id) { pick(r.destination) }
            }
        }
        .padding(.horizontal, theme.space(.m))
        .sarySurface(radius: SaryRadius.m)
    }

    private func clear() {
        job?.cancel()
        query = ""
        results = []
        searching = false
        searchError = nil
    }

    /// The home search's order (`MapHomeScreen.schedule`): «دليل البر» first (offline), then the
    /// online sources merged in; a desert category («نفود», «روضة»…) is answered by the guide alone.
    private func schedule(_ q: String, now: Bool = false) {
        job?.cancel()
        searchError = nil
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, CoordinateParser.parse(t) == nil else {
            results = []
            searching = false
            return
        }
        searching = true
        let near = self.near
        job = Task {
            if !now { try? await Task.sleep(nanoseconds: 350_000_000) }
            guard !Task.isCancelled else { return }
            let (desert, desertOnly) = await Task.detached(priority: .userInitiated) {
                (HomeDesertRules.searchPlaces(DesertGazetteer.bundled, t, near: near), HomeDesertRules.categoryKind(t) != nil)
            }.value
            guard !Task.isCancelled else { return }
            results = desert
            if desertOnly {
                searching = false
                return
            }
            do {
                let r = try await PlaceSearch.search(t, near: near)
                guard !Task.isCancelled else { return }
                results = HomeDesertRules.merge(desert: desert, places: r)
            } catch let e as PlaceSearch.SearchError {
                results = desert
                if desert.isEmpty { searchError = e.arabic }
            } catch {
                results = desert
                if desert.isEmpty { searchError = PlaceSearch.SearchError.network.arabic }
            }
            searching = false
        }
    }
}

/// «الرحلة» tab: the destination (open in Maps, copy), the plan & checklist, «اتبع الخطة»
/// and search — what used to be the pills under the status capsule (docs/IA-REDESIGN.md §2.4).
struct TripPlanCard: View {
    let controller: LiveOutingController
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TripPlanCardContent(controller: controller, plan: model.plans.model(controller.session.id))
    }
}

private struct TripPlanCardContent: View {
    let controller: LiveOutingController
    @ObservedObject var plan: PlanModel
    @EnvironmentObject private var location: LocationSharer
    @Environment(\.sary) private var theme

    var body: some View {
        let tp = plan.plan
        let lead = controller.session.view?.iLead == true
        let p = theme.palette
        SarySection(title: "الوجهة والخطة") {
            VStack(spacing: 0) {
                if let d = tp.destination {
                    destinationRow(d)
                    SaryDivider()
                }
                if plan.following, tp.hasRoute {
                    TimelineView(.periodic(from: .now, by: 5)) { ctx in
                        let st = plan.followStatus(fix: location.lastFix, now: ctx.date)
                        HStack(spacing: theme.space(.m)) {
                            SaryRowIcon(systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill", color: st.kind == .offRoute ? p.warning : p.live)
                            Text(TripHeaderPresenter.follow(st)).saryNumber(.subhead, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("plan.followStatus")
                            Button("إيقاف") { plan.following = false }
                                .buttonStyle(.sary(.secondary, width: .hug, compact: true))
                                .accessibilityIdentifier("plan.followStop")
                        }
                        .frame(minHeight: theme.minTarget + 4)
                    }
                    SaryDivider()
                } else if tp.hasRoute {
                    SaryNavRow(title: "اتبع الخطة", detail: "ينبهك إذا خرجت عن المسار", systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill",
                               id: "plan.followRow") { plan.following = true }
                    SaryDivider()
                }
                SaryNavRow(title: tp.isEmpty ? (lead ? "خطّط الطلعة" : "الخطة") : "الخطة وقائمة التجهيز",
                           detail: planDetail(tp), systemImage: "map", id: "plan.openEditor") { controller.modal = .plan(.editor) }
                /* «ابحث أو إحداثية» is once, in «المزيد» (it was here and in the tools). */
            }
            .padding(.horizontal, theme.space(.m))
        }
    }

    private func planDetail(_ tp: TripPlan) -> String? {
        var parts: [String] = []
        if tp.hasRoute { parts.append("مسار من \(SaryFormat.number(tp.points.count)) نقاط") }
        if plan.checklistPhase == .loaded, !plan.checklist.items.isEmpty {
            let done = plan.checklist.items.filter(\.done).count
            parts.append("التجهيز \(SaryFormat.number(done))/\(SaryFormat.number(plan.checklist.items.count))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func destinationRow(_ d: OutingDestination) -> some View {
        let dest = LngLat(lng: d.lng, lat: d.lat)
        let fix = location.lastFix
        let fresh = fix.map { Date().timeIntervalSince1970 - $0.atMs / 1000 <= FollowPlan.maxFixAgeS } ?? false
        let p = theme.palette
        return Menu {
            /* «اتجه» is our own guidance; the other apps only by name. */
            Button("اتجه") { controller.directions(NavTargets.destination(d)) }
            ForEach(ExternalNav.App.allCases) { app in
                Button(app.openTitle) { ExternalNav.open(app, dest) }
            }
            Button("انسخ إحداثية الوجهة") { PlanClipboard.copy(CoordinateShare.copyDecimal(dest)); controller.toast("نُسخ") }
        } label: {
            HStack(spacing: theme.space(.m)) {
                SaryRowIcon(systemImage: "flag.checkered")
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.name).saryText(.body, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(1)
                    if let fix, fresh {
                        let me = LngLat(lng: fix.lng, lat: fix.lat)
                        Text("\(SaryFormat.distance(meters: PlanGeo.meters(me, dest))) خط مستقيم · \(Geo.directionLabel(PlanGeo.bearing(me, dest)))")
                            .saryNumber(.footnote).foregroundStyle(p.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                Text("افتح في الخرائط").saryText(.caption, weight: .bold).foregroundStyle(p.accentText)
            }
            .frame(minHeight: theme.minTarget + 4)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("plan.destination")
    }
}
