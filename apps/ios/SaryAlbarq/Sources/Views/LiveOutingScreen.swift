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
    /// While a finger is on the screen the alert lane holds still (a card arriving mid-tap
    /// must not shift or cover what the person is touching); it catches up just after.
    @State private var frozenAlerts: [LiveAlertUI]?
    @State private var touching = false
    @ObservedObject private var savedPlaces = SavedPlacesStore.shared
    @ObservedObject private var trackLibrary = TrackLibrary.shared
    /// «الوضع الواقعي» (Apple 3D imagery), presented over the live sheet.
    @State private var realistic: RealisticScene?

    var body: some View {
        let ui = controller.ui
        GeometryReader { geo in
            let full = CGSize(width: geo.size.width, height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom)
            ZStack {
                Color.clear.onAppear { screenHeight = full.height }.onChange(of: full.height) { _, h in screenHeight = h }
                let members = controller.mapMembers(theme: theme)
                let exploring = controller.liveContext(drive: theme.drive) == .exploring
                PlanObserving(plan: app.plans.model(controller.session.id), picked: controller.planPicked) { plan in
                OutingMapboxView(
                    members: members,
                    rally: controller.rallyPoint,
                    trails: controller.mapTrails(members: members, driving: controller.liveContext(drive: theme.drive) == .driving),
                    camera: controller.camera,
                    chrome: chromeInsets(full: full),
                    theme: theme,
                    picking: controller.picking.active,
                    following: controller.following,
                    onMemberTap: { controller.openParticipant($0) },
                    onRallyTap: { controller.actions.participantsTab.rallyShow() },
                    onMapTap: { controller.picked($0) },
                    onProjection: { controller.overlay.projection = $0 },
                    onUserGesture: {
                        controller.following = false
                        controller.userPannedMap = true
                        controller.navUserMovedMap()
                    },
                    waypoints: controller.mapWaypoints,
                    onWaypointTap: { controller.features.modal = .waypoint($0) },
                    plan: plan,
                    onLongPress: { controller.planLongPress($0, at: $1) },
                    onWaterways: { controller.weather.setWaterways($0) },
                    nav: controller.mapNav,
                    onSelectRoute: { controller.nav.select($0) },
                    /* The chosen layer and the 3D view are exploration's; the trip map stays on satellite
                     * (the layer offline areas always cover). */
                    layer: exploring ? controller.mapLayer : .satellite,
                    terrain3D: exploring && controller.terrain3D,
                    explore: controller.mapExplore(places: savedPlaces.places, tracks: trackLibrary),
                    /* Build 10: clean imagery when a track is the subject; road names while navigating. */
                    labels: (exploring && controller.mapLayer == .satellite) || controller.trackFollow != nil || controller.backTrack != nil ? .clean : (controller.nav.isActive ? .driving : .standard),
                    onCenter: { controller.mapCenterChanged($0) },
                    hiRes: controller.hiResRequest(ui, exploring: exploring)
                )
                }
                .ignoresSafeArea()

                if exploring {
                    ExploreCrosshair(model: controller.exploreReading)
                        .ignoresSafeArea()
                }

                EdgeArrowLayer(overlay: controller.overlay, controller: controller, area: clearArea(full: full), avoid: avoidRects(full: full),
                               driving: controller.liveContext(drive: theme.drive) == .driving, alerting: controller.alertingMemberIds)
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
                .realisticCover($realistic)
                .background {
                    /* The sheet's real top edge on screen (its content height leaves out the home-indicator area). */
                    GeometryReader { g in
                        Color.clear
                            .onAppear { sheetTop = g.frame(in: .global).minY }
                            .onChange(of: g.frame(in: .global).minY) { _, y in sheetTop = y }
                    }
                }
                .saryAppearance(appearance)
                .sarySheetPresentation(detent: $controller.sheetDetent, trip: false)
        }
    }

    /// The chip sits level with the button's disc, above its caption.
    private func showsCaptionPad(_ rowMode: Bool) -> CGFloat { rowMode ? 8 : 34 }

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
        return max(measured, SheetDetentUI.peekHeight(drive: theme.drive, trip: false))
    }

    private var topChromeBottom: CGFloat {
        ["top"].compactMap { frames[$0]?.maxY }.max() ?? 120
    }

    /// What our chrome covers, for the map's keep-group framing and ornaments.
    private func chromeInsets(full: CGSize) -> UIEdgeInsets {
        let dockTop = ["dock", "cluster-row", "readout"].compactMap { frames[$0]?.minY }.min() ?? (full.height - bottomInset)
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
        ["cluster", "cluster-row", "sos", "ptt", "top", "picking", "speed", "speedlimit", "readout"].compactMap { frames[$0] }
    }

    // MARK: chrome

    @ViewBuilder
    private func chrome(_ ui: LiveOutingUIState, full: CGSize, safeBottom: CGFloat) -> some View {
        let rowMode = controller.sheetDetent == .half
        let context = controller.liveContext(drive: theme.drive)
        let driving = context == .driving
        let exploring = context == .exploring
        /* This layer sits inside the safe area; the sheet edge is measured on the whole screen. */
        let lift = max(0, bottomInset - safeBottom)
        let items = exploring ? SaryMapControlItem.explore(terrain3D: controller.terrain3D, tracksShown: trackLibrary.shown.count)
            : groupItems(driving: driving)
        ZStack {
            VStack(spacing: theme.space(.s)) {
                LiveTopStack(controller: controller, ui: ui, alerts: frozenAlerts ?? ui.alerts, driving: driving, exploring: exploring, rowMode: rowMode,
                             maxListHeight: max(220, full.height * 0.42), weather: controller.weather,
                             plan: app.plans.model(controller.session.id), media: MediaCenters.of(controller))
                    .chromeFrame("top")
                if controller.picking.active {
                    PickingBanner(moving: controller.picking.moving, cancel: controller.cancelPicking)
                        .chromeFrame("picking")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.space(.m))
            .padding(.top, 4)

            if controller.sheetDetent == .peek {
                VStack {
                    Spacer()
                    HStack(alignment: .bottom, spacing: theme.space(.s)) {
                        Spacer()
                        SaryControlCluster(items: items, axis: .vertical, action: controlTapped)
                            .chromeFrame("cluster")
                            .transition(.opacity)
                    }
                    .padding(.horizontal, theme.space(.m))
                    Spacer().frame(height: lift + theme.bigButton + (theme.drive ? 72 : 56) + (exploring ? 76 : 0))
                }
            }

            VStack(spacing: theme.space(.s)) {
                Spacer()
                if exploring && controller.sheetDetent == .peek {
                    ExploreReadout(model: controller.exploreReading, format: controller.coordFormat,
                                   toggleFormat: { controller.coordFormat = controller.coordFormat == .decimal ? .dms : .decimal },
                                   copy: controller.copyCrosshair, save: controller.saveCrosshair)
                        .chromeFrame("readout")
                        .padding(.horizontal, theme.space(.m))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                HStack(alignment: .bottom) {
                    SaryPTTButton(state: ui.ptt, actions: controller.actions.ptt, showsCaption: !rowMode, level: controller.pttLevel)
                        .chromeFrame("ptt")
                        .overlay(alignment: .top) {
                            /* «سرعة المركبة» only while driving, right above «اضغط وتكلم», on the other side
                             * from the map buttons; while guiding the posted limit sits beside it. An overlay,
                             * so the dock's measured frame stays as it was. */
                            HStack(alignment: .center, spacing: theme.space(.s)) {
                                if driving {
                                    SarySpeedometer(ui: controller.speedometerUI)
                                        .chromeFrame("speed")
                                        .transition(.opacity)
                                    if controller.nav.phase == .guiding, let k = controller.nav.progress?.speedLimitKmh {
                                        NavSpeedLimitSign(kmh: k)
                                            .chromeFrame("speedlimit")
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                }
                            }
                            .fixedSize()
                            .alignmentGuide(.top) { $0[.bottom] + theme.space(.m) }
                        }
                    /* «ترددات»: which channel the button talks on; tap for all of them. */
                    if controller.session.walkie.showsChannels {
                        PTTChannelChip(walkie: controller.session.walkie, open: { controller.modal = .pttChannels })
                            .chromeFrame("ptt-channel")
                            .padding(.bottom, showsCaptionPad(rowMode))
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
        .animation(theme.animation(.smooth), value: driving)
        .animation(theme.animation(.smooth), value: exploring)
        .environment(\.safetyAlertActions, controller.safety.alertActions)
        .environment(\.convoyAlertActions, controller.convoyAlertActions)
        .animation(theme.animation(.smooth), value: controller.backTrack != nil)
        .animation(theme.animation(.smooth), value: controller.nav.phase)
    }

    /// The one floating group: «موقعي» · «المجموعة» (+ «طريق العودة» when it fits the moment)
    /// + «+» when stopped. Guiding: the guidance camera takes «موقعي»'s place.
    private func groupItems(driving: Bool) -> [SaryMapControlItem] {
        let all = SaryMapControlItem.liveDefaults(following: controller.following, backTracking: controller.backTrack != nil)
        let pick = { (id: String) in all.first { $0.id == id } }
        var items: [SaryMapControlItem] = []
        if controller.nav.isActive, let cam = controller.navControlItems.first {
            items = [cam] + [pick("fit")].compactMap { $0 }
        } else {
            items = ["locate", "fit"].compactMap(pick)
            if controller.showsBackTrackShortcut, let b = pick("backtrack") { items.append(b) }
        }
        if !driving {
            var plus = SaryMapControlItem.actions
            /* I am stuck: «غرّزت» is in there. */
            if controller.safety.myStuck != nil { plus.badge = 1 }
            items.append(plus)
        }
        return items
    }

    private func controlTapped(_ id: String) {
        let a = controller.actions
        switch id {
        case "locate": a.locateMe()
        case "fit": a.fitGroup()
        case "backtrack": controller.backTrack == nil ? controller.startBackTrack() : controller.stopBackTrack()
        case "actions": controller.modal = .actions
        case "layers": controller.modal = .layers
        case "terrain": controller.terrain3D.toggle()
        case "places": controller.modal = .places
        case "tracks": controller.modal = .tracks
        case "realistic":
            /* Looking, not driving: navigation and movement stay on the trip map. */
            if controller.nav.isActive || controller.motion.moving { controller.toast("الوضع الواقعي متاح وأنت واقف") }
            else { realistic = .live(controller, plan: app.plans.model(controller.session.id), places: savedPlaces.places) }
        default: controller.navControlTapped(id)
        }
    }
}

/// Everything at the top of the live screen: safety strips, then ONE top bar (the trip
/// header, or the maneuver banner / «طريق العودة» while driving), the status details or
/// the bell's list, and at most ONE alert card (docs/IA-REDESIGN.md §2.2, §2.5).
private struct LiveTopStack: View {
    @ObservedObject var controller: LiveOutingController
    var ui: LiveOutingUIState
    var alerts: [LiveAlertUI]
    var driving: Bool
    var exploring = false
    var rowMode: Bool
    var maxListHeight: CGFloat
    @ObservedObject var weather: OutingWeather
    @ObservedObject var plan: PlanModel
    @ObservedObject var media: MediaCenter
    @EnvironmentObject private var location: LocationSharer
    @Environment(\.sary) private var theme

    var body: some View {
        let nav = controller.nav
        let guidance = nav.phase == .guiding || nav.phase == .offRoad || nav.phase == .arrived
        /* Driving with a banner of its own (guidance or «طريق العودة»): that banner IS the top bar. */
        let bannerOnly = driving && (guidance || controller.backTrackUI != nil || controller.followUI != nil)
        let card = rowMode || controller.bellOpen ? nil : AlertQueue.card(alerts, driving: driving)
        let mediaQueued = media.notice != nil && (driving || card != nil || rowMode)
        let bell = AlertQueue.ordered(alerts).count - (card == nil ? 0 : 1) + (mediaQueued ? 1 : 0)
        VStack(spacing: theme.space(.s)) {
            if case let .active(since) = ui.sos.mine {
                SaryMySOSStrip(since: since, now: ui.now, imOK: controller.actions.sos.imOK,
                               withLocation: controller.session.displayView?.me?.sos?.fix != nil,
                               enjad: { controller.openEnjad(.emergency) })
            }
            ForEach(ui.sos.incoming.filter(\.acknowledged)) { a in
                SaryFriendSOSStrip(alert: a, now: ui.now, show: { controller.showSOS(a.id) })
            }
            if let stuck = controller.safety.myStuck {
                MyStuckStrip(report: stuck, sharing: controller.session.isSharingNow, now: ui.now,
                             clear: { Task { await controller.safety.clearStuck() } }, busy: controller.safety.stuckBusy,
                             enjad: { controller.openEnjad(.stuck) })
            }
            if exploring {
                ExploreHeader(layer: controller.mapLayer, bell: bell, bellOpen: controller.bellOpen, hasHistory: !controller.alertHistory.isEmpty,
                              back: controller.actions.back, exit: { controller.exitExplore() },
                              bellTapped: { controller.statusExpanded = false; controller.bellOpen.toggle() })
            } else if !bannerOnly {
                header(bell: bell)
                if controller.statusExpanded {
                    TripStatusDetails(connection: ui.connection, sharing: ui.sharing, warnings: ui.warnings, nearbyCars: ui.nearbyCars,
                                      warningTapped: controller.actions.warningTapped)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            navTop
            if let bt = controller.backTrackUI {
                BackTrackPanel(ui: bt, exit: controller.stopBackTrack)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            /* «اسلك هذا المسار»; while «الملاحة» guides me to the track, its banner is the one header. */
            if !guidance, let f = controller.followUI {
                FollowTrackPanel(ui: f, reverse: controller.reverseFollow, exit: controller.stopFollow, approach: controller.approachFollow)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if controller.bellOpen {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: theme.space(.s)) {
                        SaryAlertLane(alerts: AlertQueue.ordered(alerts), limit: 99, tapped: controller.actions.alertTapped,
                                      dismiss: controller.actions.dismissAlert, voice: controller.actions.voice, silent: controller.actions.silent)
                        MediaNoticeLane(center: media)
                        let active = Set(alerts.map(\.id))
                        let past = controller.alertHistory.filter { !active.contains($0.id) }
                        if !past.isEmpty { AlertHistoryList(entries: past, now: ui.now) }
                        if past.isEmpty && AlertQueue.ordered(alerts).isEmpty && media.notice == nil {
                            Text("ما فيه تنبيهات").saryText(.subhead).foregroundStyle(theme.palette.textSecondary)
                                .frame(maxWidth: .infinity).padding(theme.space(.m))
                                .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .chrome)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: maxListHeight)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("alerts.list")
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if let card {
                SaryAlertLane(alerts: [card], limit: 1, tapped: controller.actions.alertTapped,
                              dismiss: controller.actions.dismissAlert, voice: controller.actions.voice, silent: controller.actions.silent)
            } else if !driving && !rowMode {
                /* «في قناة الطلعة»: the lowest tier, shown only when nothing else wants the spot. */
                MediaNoticeLane(center: media)
            }
            if let t = AlertQueue.toast(alerts) {
                SaryAlertCard(alert: t)
                    .transition(.opacity)
            }
        }
        .animation(theme.animation(.smooth), value: controller.bellOpen)
        .animation(theme.animation(.smooth), value: controller.statusExpanded)
        .animation(theme.animation(.enter), value: card?.id)
    }

    private func header(bell: Int) -> some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            let trip = controller.showsTripStrip ? controller.tripPanel : nil
            let follow = plan.following && plan.plan.hasRoute ? TripHeaderPresenter.follow(plan.followStatus(fix: location.lastFix, now: ctx.date)) : nil
            let h = TripHeaderUI(title: TripHeaderPresenter.title(outingName: ui.outingName, trip: trip),
                                 line: TripHeaderPresenter.line(status: ui.status, trip: trip, follow: follow, connection: ui.connection, nearbyCars: ui.nearbyCars),
                                 level: TripHeaderPresenter.level(connection: ui.connection, sharing: ui.sharing, warnings: ui.warnings),
                                 bell: bell)
            TripHeader(ui: h, weather: weather.chip(now: ctx.date),
                       accessibility: [ui.outingName, h.title == ui.outingName ? nil : "إلى \(h.title)", h.line, ui.connection.label].compactMap { $0 }.joined(separator: "، "),
                       back: controller.actions.back,
                       open: controller.openTripDetails,
                       statusTapped: { controller.bellOpen = false; controller.statusExpanded.toggle() },
                       weatherTapped: { controller.modal = .weather },
                       bellTapped: { controller.statusExpanded = false; controller.bellOpen.toggle() },
                       bellOpen: controller.bellOpen,
                       hasHistory: !controller.alertHistory.isEmpty,
                       exploreTapped: driving || controller.nav.isActive ? nil : { controller.enterExplore() })
        }
        .task { controller.feedWeather(force: true) }
    }

    /// «الملاحة» at the top: the maneuver banner, the off-road leg, or «وصلت».
    @ViewBuilder
    private var navTop: some View {
        let nav = controller.nav
        switch nav.phase {
        case .guiding:
            NavManeuverBanner(nav: nav)
                .transition(.move(edge: .top).combined(with: .opacity))
            if let moved = controller.navMemberMovedMeters, let t = nav.target {
                Button { controller.navigateToMember(t.memberId ?? "") } label: {
                    SaryButtonLabel(title: "\(t.name) تحرّك \(SaryFormat.distance(meters: moved)) · حدّث الطريق", systemImage: SaryIcon.retry)
                }
                .buttonStyle(.sary(.secondary, compact: true))
                .accessibilityIdentifier("nav.memberMoved")
            }
        case .offRoad:
            NavOffRoadPanel(nav: nav, reference: controller.navReferenceBearing)
                .transition(.move(edge: .top).combined(with: .opacity))
        case .arrived:
            NavArrivalCard(nav: nav, end: controller.endNav)
                .transition(.move(edge: .top).combined(with: .opacity))
        default:
            EmptyView()
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
    /// Driving: only members in an alert state get an arrow.
    var driving = false
    var alerting: Set<String> = []
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
        let all = overlay.projection.points.filter { $0.key != me }.map { (id: $0.key, point: $0.value) }.sorted { $0.id < $1.id }
        /* At most three, alert members first then the nearest (docs/IA-REDESIGN.md §2.6). */
        let off = all.filter { EdgeArrows.spot(id: $0.id, point: $0.point, area: area, chip: Self.chip) != nil }
        let keep = Set(EdgeArrows.pick(candidates: off.map { (id: $0.id, distance: parts[$0.id]?.distanceMeters) }, alerting: alerting, driving: driving))
        let pts = off.filter { keep.contains($0.id) }
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
