import SwiftUI

/// Frames of the chrome over the map, in screen (window) coordinates —
/// measured, not guessed, so camera framing and edge arrows avoid them.
struct ChromeFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, b in b })
    }
}

extension View {
    func chromeFrame(_ key: String) -> some View {
        background(GeometryReader { g in
            /* Window coordinates: the same space as the map's own screen points. */
            Color.clear.preference(key: ChromeFramesKey.self, value: [key: g.frame(in: .global)])
        })
    }
}

/// The live outing: the real Mapbox map with the design system's chrome over it,
/// driven by `LiveOutingController` (which maps the session's data through
/// `LiveOutingPresenter` into the UI contracts).
struct LiveOutingScreen: View {
    @StateObject var controller: LiveOutingController
    @Environment(\.sary) private var theme
    @Environment(AppearanceSettings.self) private var appearance
    @EnvironmentObject private var app: AppModel
    @State private var frames: [String: CGRect] = [:]
    @State private var sheetTop: CGFloat = 0
    @State private var screenHeight: CGFloat = 0
    /// «المزيد» menu beside the control cluster.
    @State private var moreOpen = false
    /// While a finger is on the screen the alert lane holds still (a card arriving mid-tap
    /// must not shift or cover what the person is touching); it catches up just after.
    @State private var frozenAlerts: [LiveAlertUI]?
    @State private var touching = false

    var body: some View {
        let ui = controller.ui
        GeometryReader { geo in
            let full = CGSize(width: geo.size.width, height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom)
            ZStack {
                Color.clear.onAppear { screenHeight = full.height }.onChange(of: full.height) { _, h in screenHeight = h }
                let members = controller.mapMembers(theme: theme)
                PlanObserving(plan: app.plans.model(controller.session.id), picked: controller.planPicked) { plan in
                OutingMapboxView(
                    members: members,
                    rally: controller.rallyPoint,
                    trails: controller.mapTrails(members: members),
                    camera: controller.camera,
                    chrome: chromeInsets(full: full),
                    theme: theme,
                    picking: controller.picking.active,
                    following: controller.following,
                    onMemberTap: { controller.openParticipant($0) },
                    onRallyTap: { controller.actions.participantsTab.rallyShow() },
                    onMapTap: { controller.picked($0) },
                    onProjection: { controller.overlay.projection = $0 },
                    onUserGesture: { controller.following = false },
                    waypoints: controller.mapWaypoints,
                    onWaypointTap: { controller.features.modal = .waypoint($0) },
                    plan: plan,
                    onLongPress: { controller.planLongPress($0, at: $1) },
                    onWaterways: { controller.weather.setWaterways($0) }
                )
                }
                .ignoresSafeArea()

                EdgeArrowLayer(overlay: controller.overlay, controller: controller, area: clearArea(full: full), avoid: avoidRects(full: full))
                    .ignoresSafeArea()
                    .allowsHitTesting(true)

                chrome(ui, full: full, safeBottom: geo.safeAreaInsets.bottom)
            }
            .onPreferenceChange(ChromeFramesKey.self) { frames = $0 }
        }
        .background(TouchWatcherView { down in touchChanged(down) }.allowsHitTesting(false))
        .ignoresSafeArea(.keyboard)
        .sheet(isPresented: .constant(true)) {
            LiveSheet(controller: controller)
                .background {
                    /* The sheet's real top edge on screen (its content height leaves out the home-indicator area). */
                    GeometryReader { g in
                        Color.clear
                            .onAppear { sheetTop = g.frame(in: .global).minY }
                            .onChange(of: g.frame(in: .global).minY) { _, y in sheetTop = y }
                    }
                }
                .saryAppearance(appearance)
                .sarySheetPresentation(detent: $controller.sheetDetent)
        }
    }

    private func touchChanged(_ down: Bool) {
        touching = down
        if down {
            if frozenAlerts == nil { frozenAlerts = controller.ui.alerts }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if !touching { frozenAlerts = nil }
            }
        }
    }

    // MARK: measured chrome

    /// How much of the screen the sheet covers, measured from its real top edge.
    private var bottomInset: CGFloat {
        if controller.sheetDetent == .full { return 0 }
        let measured = sheetTop > 0 && screenHeight > 0 ? screenHeight - sheetTop + SaryRadius.sheet * 0.25 : 0
        return max(measured, SheetDetentUI.peekHeight(drive: theme.drive))
    }

    private var topChromeBottom: CGFloat {
        ["top"].compactMap { frames[$0]?.maxY }.max() ?? 120
    }

    /// What our chrome covers, for the map's keep-group framing and ornaments.
    private func chromeInsets(full: CGSize) -> UIEdgeInsets {
        let dockTop = ["dock", "cluster-row"].compactMap { frames[$0]?.minY }.min() ?? (full.height - bottomInset)
        let sheetTop = full.height - bottomInset
        let bottom = max(0, full.height - min(dockTop, sheetTop))
        let side = ["cluster", "speed"].compactMap { frames[$0] }
        let left = side.map { $0.minX < full.width / 2 ? $0.maxX + 4 : 0 }.max() ?? 0
        let right = side.map { $0.minX >= full.width / 2 ? full.width - $0.minX + 4 : 0 }.max() ?? 0
        return UIEdgeInsets(top: topChromeBottom + 4, left: left, bottom: bottom + 4, right: right)
    }

    /// The part of the screen that is really map, for edge arrows.
    private func clearArea(full: CGSize) -> CGRect {
        let top = topChromeBottom + 4
        let bottom = full.height - bottomInset - 4
        return CGRect(x: 4, y: top, width: full.width - 8, height: max(1, bottom - top))
    }

    private func avoidRects(full: CGSize) -> [CGRect] {
        ["cluster", "cluster-row", "sos", "ptt", "top", "picking", "more", "speed"].compactMap { frames[$0] }
    }

    // MARK: chrome

    @ViewBuilder
    private func chrome(_ ui: LiveOutingUIState, full: CGSize, safeBottom: CGFloat) -> some View {
        let rowMode = controller.sheetDetent == .half
        /* This layer sits inside the safe area; the sheet edge is measured on the whole screen. */
        let lift = max(0, bottomInset - safeBottom)
        let items = controlItems(ui)
        let more = moreItems(ui)
        ZStack {
            VStack(spacing: theme.space(.s)) {
                VStack(spacing: theme.space(.s)) {
                    if case let .active(since) = ui.sos.mine {
                        SaryMySOSStrip(since: since, now: ui.now, imOK: controller.actions.sos.imOK,
                                       withLocation: controller.session.displayView?.me?.sos?.fix != nil)
                    }
                    ForEach(ui.sos.incoming.filter(\.acknowledged)) { a in
                        SaryFriendSOSStrip(alert: a, now: ui.now, show: { controller.showSOS(a.id) })
                    }
                    if let stuck = controller.safety.myStuck {
                        MyStuckStrip(report: stuck, sharing: controller.session.isSharingNow, now: ui.now,
                                     clear: { Task { await controller.safety.clearStuck() } }, busy: controller.safety.stuckBusy)
                    }
                    SaryStatusCapsule(outingName: ui.outingName, status: ui.status, connection: ui.connection, sharing: ui.sharing,
                                      warnings: ui.warnings, expanded: $controller.statusExpanded, nearbyCars: ui.nearbyCars, back: controller.actions.back,
                                      warningTapped: controller.actions.warningTapped)
                    if let bt = controller.backTrackUI {
                        BackTrackPanel(ui: bt, exit: controller.stopBackTrack)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if !rowMode {
                        SaryAlertLane(alerts: frozenAlerts ?? ui.alerts, limit: theme.drive || controller.backTrack != nil ? 1 : 3, tapped: controller.actions.alertTapped,
                                      dismiss: controller.actions.dismissAlert, voice: controller.actions.voice)
                        LivePlanStrip(controller: controller)
                    }
                }
                .chromeFrame("top")
                if controller.picking.active {
                    PickingBanner(moving: controller.picking.moving, cancel: controller.cancelPicking)
                        .chromeFrame("picking")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.space(.m))
            .padding(.top, 4)

            if moreOpen {
                /* Tap anywhere outside the menu to close it. */
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { moreOpen = false }
                    .accessibilityHidden(true)
            }

            if controller.sheetDetent == .peek {
                VStack {
                    Spacer()
                    HStack(alignment: .bottom, spacing: theme.space(.s)) {
                        Spacer()
                        if moreOpen {
                            SaryMoreMenu(items: more, action: controlTapped)
                                .chromeFrame("more")
                                .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
                        }
                        SaryControlCluster(items: items, axis: .vertical, action: controlTapped)
                            .chromeFrame("cluster")
                            .transition(.opacity)
                    }
                    .padding(.horizontal, theme.space(.m))
                    Spacer().frame(height: lift + theme.bigButton + (theme.drive ? 72 : 56))
                }
            }

            VStack {
                Spacer()
                if moreOpen && rowMode {
                    SaryMoreMenu(items: more, action: controlTapped)
                        .chromeFrame("more")
                        .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
                        .padding(.bottom, theme.space(.s))
                }
                HStack(alignment: .bottom) {
                    SaryPTTButton(state: ui.ptt, actions: controller.actions.ptt, showsCaption: !rowMode, level: controller.pttLevel)
                        .chromeFrame("ptt")
                        .overlay(alignment: .top) {
                            /* «سرعة المركبة»: right above «اضغط وتكلم», on the other side from the control
                             * cluster. An overlay, so the dock's measured frame stays as it was; its own frame
                             * («speed») joins the keep-out rects and the map's side inset. */
                            SarySpeedometer(ui: controller.speedometerUI)
                                .chromeFrame("speed")
                                .alignmentGuide(.top) { $0[.bottom] + theme.space(.m) }
                        }
                    Spacer()
                    if rowMode {
                        SaryControlCluster(items: items, axis: .horizontal, action: controlTapped)
                            .chromeFrame("cluster-row")
                            .transition(.opacity)
                        Spacer()
                    }
                    SarySOSButton(state: ui.sos.mine, trigger: controller.actions.sos.trigger)
                        .chromeFrame("sos")
                        .padding(.bottom, rowMode ? 0 : 22)
                }
                .chromeFrame("dock")
                .padding(.horizontal, theme.space(.l))
                .padding(.bottom, lift + theme.space(.m))
                .opacity(controller.sheetDetent == .full ? 0 : 1)
                .allowsHitTesting(controller.sheetDetent != .full)
            }
        }
        .animation(theme.animation(.smooth), value: controller.sheetDetent)
        .animation(theme.animation(.smooth), value: sheetTop)
        .environment(\.safetyAlertActions, controller.safety.alertActions)
        .animation(theme.animation(.smooth), value: controller.backTrack != nil)
        .animation(theme.animation(.snappy), value: moreOpen)
        .onChange(of: controller.sheetDetent) { _, d in if d == .full { moreOpen = false } }
        .onChange(of: theme.drive) { _, d in if d { moreOpen = false } }
    }

    /// Every side control the live screen offers, in order.
    private func allControls(_ ui: LiveOutingUIState) -> [SaryMapControlItem] {
        let unread = ui.alerts.filter { if case .note = $0.kind { return true }; return false }.count
        return SaryMapControlItem.liveDefaults(following: controller.following, unreadNotes: unread > 0 ? unread : nil,
                                               backTracking: controller.backTrack != nil)
            + [.safetyStuck(active: controller.safety.myStuck != nil), .addWaypoint, .copyMyLocation, .search]
    }

    /// On the map: «موقعي», «المجموعة», «رسالة», «طريق العودة» + «المزيد»
    /// (drive mode: «موقعي», «المجموعة», «طريق العودة», nothing hidden behind a menu).
    private func controlItems(_ ui: LiveOutingUIState) -> [SaryMapControlItem] {
        let all = allControls(ui)
        if theme.drive { return all.filter { SaryMapControlItem.driveIDs.contains($0.id) } }
        var more = SaryMapControlItem.more(open: moreOpen)
        /* I am stuck: the menu that holds «غرّزت» shows it. */
        if controller.safety.myStuck != nil && !moreOpen { more.badge = 1 }
        return all.filter { SaryMapControlItem.primaryIDs.contains($0.id) } + [more]
    }

    /// Behind «المزيد»: أقرب محطة، غرّزت، أضف نقطة، انسخ موقعي، ابحث.
    private func moreItems(_ ui: LiveOutingUIState) -> [SaryMapControlItem] {
        allControls(ui).filter { !SaryMapControlItem.primaryIDs.contains($0.id) }
    }

    private func controlTapped(_ id: String) {
        let a = controller.actions
        if id == "more" { moreOpen.toggle(); return }
        moreOpen = false
        switch id {
        case "locate": a.locateMe()
        case "fit": a.fitGroup()
        case "note": a.openNoteComposer()
        case "nearest": a.openNearestStations()
        case "stuck": controller.stuckControlTapped()
        case "waypoint": controller.features.composeAtMe(controller.location.lastFix)
        case "backtrack": controller.backTrack == nil ? controller.startBackTrack() : controller.stopBackTrack()
        case "copyme": controller.modal = .plan(.me)
        case "search": controller.modal = .plan(.search)
        default: break
        }
    }
}

/// «طريق العودة»: big arrow, distance back to «نقطة البداية» along my trail, and the
/// off-track warning. Opaque and larger in drive mode; works offline (all on the phone).
struct BackTrackPanel: View {
    var ui: BackTrackUI
    var exit: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let off = ui.phase == .offTrack
        let arrived = ui.phase == .arrived
        let arrowSize: CGFloat = theme.drive ? 92 : 68
        let tone: Color = off ? p.emergency : (arrived ? p.live : p.accent)
        HStack(spacing: theme.space(.m)) {
            ZStack {
                Circle().fill(tone)
                if arrived {
                    Image(systemName: "flag.checkered").font(.system(size: arrowSize * 0.42, weight: .heavy)).foregroundStyle(Color.white)
                } else if ui.phase == .waitingFix {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: arrowSize * 0.5, weight: .black))
                        .foregroundStyle(Color.white)
                        .rotationEffect(.degrees(ui.arrowDegrees))
                        .animation(theme.animation(.smooth), value: ui.arrowDegrees)
                }
            }
            .frame(width: arrowSize, height: arrowSize)
            /* A real-world direction: never mirrored by the RTL layout. */
            .environment(\.layoutDirection, .leftToRight)
            .overlay(Circle().stroke(Color.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .saryText(theme.drive ? .title2 : .headline, weight: .bold)
                    .foregroundStyle(off ? p.emergencyText : p.textPrimary)
                    .accessibilityIdentifier("backtrack.title")
                if let m = ui.remainingMeters, !arrived {
                    Text(SaryFormat.distance(meters: m))
                        .saryNumber(theme.drive ? .display : .title, weight: .heavy)
                        .foregroundStyle(p.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .accessibilityIdentifier("backtrack.distance")
                }
                Text(detail)
                    .saryText(theme.drive ? .callout : .footnote, weight: .medium)
                    .foregroundStyle(p.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: exit) {
                Text("إنهاء").saryText(theme.drive ? .body : .callout, weight: .bold)
            }
            .buttonStyle(.sary(.secondary, width: .hug, compact: !theme.drive))
            .accessibilityIdentifier("backtrack.exit")
        }
        .padding(theme.space(.m))
        .background {
            /* Drive mode and the warning: fully opaque, readable at a glance in sun. */
            if theme.drive || off {
                RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous).fill(p.chromeOpaque)
            }
        }
        .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .control)
        .overlay {
            if off { RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous).stroke(p.emergency, lineWidth: 3) }
        }
        .sensoryFeedback(.warning, trigger: off) { was, now in now && !was }
        .sensoryFeedback(.success, trigger: arrived) { was, now in now && !was }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("backtrack.panel")
    }

    private var title: String {
        switch ui.phase {
        case .waitingFix: return "طريق العودة"
        case .onTrail: return "طريق العودة"
        case .offTrack: return "خرجت عن الطريق"
        case .arrived: return "وصلت نقطة البداية"
        }
    }

    private var detail: String {
        switch ui.phase {
        case .waitingFix: return "ننتظر موقعك من GPS…"
        case .arrived: return "هنا دخلت أول مرة."
        case .offTrack:
            let m = ui.offsetMeters.map { SaryFormat.distance(meters: $0) } ?? ""
            return "أنت على بعد \(m) من مسارك · ارجع له باتجاه السهم (\(ui.directionLabel))"
        case .onTrail:
            if ui.onGap { return "هذا الجزء لم يُسجَّل: خط مستقيم تقريبي، انتبه للطريق" }
            return "باقي إلى نقطة البداية على مسارك · \(ui.directionLabel)"
        }
    }
}

/// «اضغط على الخريطة لتحديد نقطة التجمع».
private struct PickingBanner: View {
    var moving: Bool
    var cancel: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        HStack(spacing: theme.space(.s)) {
            SaryRallyGlyph(size: 28)
            Text(moving ? "اضغط على الخريطة لنقل نقطة التجمع" : "اضغط على الخريطة لتحديد نقطة التجمع")
                .saryText(.callout, weight: .bold)
                .foregroundStyle(theme.palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("إلغاء", action: cancel)
                .buttonStyle(.sary(.secondary, width: .hug, compact: true))
                .accessibilityIdentifier("rally-pick-cancel")
        }
        .padding(theme.space(.s))
        .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .control)
    }
}

/// Arrow chips at the edge for friends whose car is off the visible map.
private struct EdgeArrowLayer: View {
    @ObservedObject var overlay: MapOverlayModel
    let controller: LiveOutingController
    var area: CGRect
    var avoid: [CGRect]
    @Environment(\.sary) private var theme

    static let chip = CGSize(width: 104, height: 38)

    /// Fixed chrome plus what moves with the camera: the rally flag and «أنت» (with my note, if any).
    private func keepOut(me: String?, parts: [String: ParticipantUI]) -> [CGRect] {
        var r = avoid
        if let f = overlay.projection.rally { r.append(CGRect(x: f.x - 55, y: f.y - 76, width: 110, height: 80)) }
        if let me, let p = overlay.projection.points[me] {
            let note = parts[me]?.note != nil && !theme.drive
            r.append(note ? CGRect(x: p.x - 105, y: p.y - 120, width: 210, height: 120) : CGRect(x: p.x - 45, y: p.y - 64, width: 90, height: 64))
        }
        /* A friend whose car is on screen keeps their name (and car) uncovered too. */
        for (id, p) in overlay.projection.points where id != me && area.contains(p) {
            r.append(CGRect(x: p.x - 50, y: p.y - 58, width: 100, height: 76))
        }
        return r
    }

    var body: some View {
        let parts = Dictionary(LiveOutingPresenter.participants(controller.input).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let me = controller.session.view?.myId
        let pts = overlay.projection.points.filter { $0.key != me }.map { (id: $0.key, point: $0.value) }.sorted { $0.id < $1.id }
        let spots = EdgeArrows.place(points: pts, area: area, chip: Self.chip, avoid: keepOut(me: me, parts: parts))
        SaryMapOverlayLayer {
            ForEach(spots, id: \.id) { s in
                if let p = parts[s.id] {
                    SaryEdgeArrowChip(chip: EdgeArrowChipUI(name: p.name, color: p.color, distanceMeters: p.distanceMeters,
                                                            bearingDegrees: s.angle, isStale: !p.presence.isLive)) {
                        controller.show(member: s.id)
                    }
                    .accessibilityIdentifier("edge-arrow")
                    .saryMapPoint(s.center.x, s.center.y)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(theme.animation(.snappy), value: spots.map(\.id))
    }
}
