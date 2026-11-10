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
                    PointCard(subject: .me(f), actions: actions(plan), close: close)
                        .presentationDetents([.height(460), .large])
                } else {
                    SaryStateView(kind: .empty(title: "ما عندنا موقعك بعد", message: "فعّل الموقع وانتظر قليلًا.", systemImage: SaryIcon.gpsOff))
                        .presentationDetents([.medium])
                }
            case .search:
                MapHomeScreen(push: { _ in }, destinationPicker: { destination in
                    controller.pickLegDestination(destination)
                }, autoFocusSearch: true)
                    .presentationDetents([.large])
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
