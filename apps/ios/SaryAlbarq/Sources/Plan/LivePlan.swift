import SwiftUI

/// The plan's modals on the live screen (one `LiveModal.plan` case).
enum LivePlanModal: Equatable {
    /// The single long-press card for a point.
    case point(LngLat)
    /// «انسخ موقعي» (control cluster or long-press on «أنت»).
    case me
    case search
    case editor

    var id: String {
        switch self {
        case let .point(p): return "plan.point.\(p.lat),\(p.lng)"
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
        return nil
    }
}

/// The modal content for `LiveModal.plan`.
struct LivePlanModalView: View {
    let controller: LiveOutingController
    let modal: LivePlanModal
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var location: LocationSharer

    var body: some View {
        let plan = model.plans.model(controller.session.id)
        let close = { controller.modal = nil }
        Group {
            switch modal {
            case let .point(p):
                PointCard(subject: .point(p, name: nil), actions: actions(plan), close: close)
                    .presentationDetents([.height(440), .large])
            case .me:
                if let f = CoordinateShare.Fix(location.lastFix) {
                    PointCard(subject: .me(f), actions: actions(plan), close: close)
                        .presentationDetents([.height(460), .large])
                } else {
                    SaryStateView(kind: .empty(title: "ما عندنا موقعك بعد", message: "فعّل الموقع وانتظر قليلًا.", systemImage: SaryIcon.gpsOff))
                        .presentationDetents([.medium])
                }
            case .search:
                CoordinateSearchSheet(near: location.lastFix.map { LngLat(lng: $0.lng, lat: $0.lat) }, myFix: location.lastFix, actions: actions(plan), close: close)
                    .presentationDetents([.large])
            case .editor:
                PlanEditorView(plan: plan, outingName: controller.ui.outingName, canEdit: controller.session.view?.iLead == true, myFix: location.lastFix, close: close)
                    .presentationDetents([.large])
                    .interactiveDismissDisabled()
            }
        }
        .rtl()
    }

    private func actions(_ plan: PlanModel) -> PointActions {
        let lead = controller.session.view?.iLead == true
        var a = PointActions(setDestination: nil, addPoint: nil, rally: nil)
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

/// Under the status capsule: «اتبع الخطة» and the destination, or the follow status.
struct LivePlanStrip: View {
    let controller: LiveOutingController
    @EnvironmentObject private var model: AppModel

    var body: some View {
        LivePlanStripContent(controller: controller, plan: model.plans.model(controller.session.id))
    }
}

private struct LivePlanStripContent: View {
    let controller: LiveOutingController
    @ObservedObject var plan: PlanModel
    @EnvironmentObject private var location: LocationSharer
    @Environment(\.sary) private var theme

    var body: some View {
        let tp = plan.plan
        let lead = controller.session.view?.iLead == true
        if plan.following, tp.hasRoute {
            TimelineView(.periodic(from: .now, by: 5)) { ctx in
                followBar(plan.followStatus(fix: location.lastFix, now: ctx.date))
            }
        } else if tp.hasRoute || tp.destination != nil || lead {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: theme.space(.s)) {
                    if tp.hasRoute {
                        pill("اتبع الخطة", "point.topleft.down.to.point.bottomright.curvepath.fill", id: "plan.follow") { plan.following = true }
                    }
                    if let d = tp.destination { destinationPill(d) }
                    pill(tp.isEmpty ? "خطّط" : "الخطة", "map", id: "plan.openEditor") { controller.modal = .plan(.editor) }
                    pill("بحث", "magnifyingglass", id: "plan.openSearch") { controller.modal = .plan(.search) }
                }
            }
        }
    }

    private func pill(_ t: String, _ icon: String, id: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(t, systemImage: icon)
                .saryText(.subhead, weight: .bold)
                .foregroundStyle(theme.palette.textPrimary)
                .padding(.horizontal, theme.space(.m))
                .frame(minHeight: theme.drive ? 52 : 40)
                .saryGlass(Capsule(), role: .control, interactive: true)
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityIdentifier(id)
    }

    private func destinationPill(_ d: OutingDestination) -> some View {
        let dest = LngLat(lng: d.lng, lat: d.lat)
        let fix = location.lastFix
        let fresh = fix.map { Date().timeIntervalSince1970 - $0.atMs / 1000 <= FollowPlan.maxFixAgeS } ?? false
        return Menu {
            Button("افتح في Apple Maps") { UIApplication.shared.open(CoordinateShare.directionsLink(dest, .apple)) }
            Button("افتح في Google Maps") { UIApplication.shared.open(CoordinateShare.directionsLink(dest, .google)) }
            Button("انسخ إحداثية الوجهة") { PlanClipboard.copy(CoordinateShare.copyDecimal(dest)); controller.toast("نُسخ") }
        } label: {
            HStack(spacing: 6) {
                if let fix, fresh {
                    let me = LngLat(lng: fix.lng, lat: fix.lat)
                    let b = PlanGeo.bearing(me, dest)
                    Image(systemName: "location.north.fill").rotationEffect(.degrees(fix.heading.map { b - $0 } ?? b))
                    Text("\(d.name) · \(SaryFormat.distance(meters: PlanGeo.meters(me, dest)))").saryNumber(.subhead, weight: .bold)
                } else {
                    Image(systemName: "flag.checkered")
                    Text(d.name).saryText(.subhead, weight: .bold)
                }
                Text("اتجه").saryText(.caption, weight: .bold).foregroundStyle(theme.palette.accentText)
            }
            .foregroundStyle(theme.palette.textPrimary)
            .padding(.horizontal, theme.space(.m))
            .frame(minHeight: theme.drive ? 52 : 40)
            .saryGlass(Capsule(), role: .control, interactive: true)
        }
        .accessibilityIdentifier("plan.destination")
    }

    private func followBar(_ s: FollowPlanStatus) -> some View {
        let p = theme.palette
        let (icon, text, tone): (String, String, Color) = {
            switch s.kind {
            case .waitingForFix: return (SaryIcon.gpsOff, "بانتظار موقعك الحالي…", p.textSecondary)
            case .onRoute: return ("checkmark.circle.fill", "على المسار · باقي \(SaryFormat.distance(meters: s.remainingM))", p.liveText)
            case .offRoute: return (SaryIcon.warning, "خارج المسار بـ \(SaryFormat.distance(meters: s.offM)) · ارجع باتجاه \(Geo.directionLabel(s.backBearing))", p.warningText)
            case .arrived: return (SaryIcon.rallyArrived, "وصلت نهاية الخطة", p.liveText)
            }
        }()
        return HStack(spacing: theme.space(.s)) {
            Image(systemName: icon).font(.system(size: 16, weight: .bold)).foregroundStyle(tone)
            Text(text).saryNumber(.subhead, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(2)
                .accessibilityIdentifier("plan.followStatus")
            Spacer(minLength: 0)
            Button("إيقاف") { plan.following = false }
                .buttonStyle(.sary(.secondary, width: .hug, compact: true))
                .accessibilityIdentifier("plan.followStop")
        }
        .padding(theme.space(.s))
        .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .control)
        .accessibilityElement(children: .contain)
    }
}
