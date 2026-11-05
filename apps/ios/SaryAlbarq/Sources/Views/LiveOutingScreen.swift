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
    /// Tilted over a city: «اعرضها بالوضع الواقعي».
    @ObservedObject private var visuals = MapVisualsHub.shared

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
                    followMode: controller.mapFollowMode,
                    onMemberTap: { controller.openParticipant($0) },
                    onRallyTap: { controller.actions.participantsTab.rallyShow() },
                    onMapTap: { controller.picked($0) },
                    onEmptyTap: { controller.mapTappedEmpty($0, name: $1) },
                    onProjection: { controller.overlay.projection = $0 },
                    onUserGesture: {
                        controller.cameraUserMoved()
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
        .onChange(of: controller.realisticRequest) { _, _ in openRealistic() }
        .ignoresSafeArea(.keyboard)
        /* SOS never disappears: over the full-height sheet and any sheet on top, it floats in
         * its own window (the dock's copy is hidden or covered then). */
        .background(SOSOverlayHost(visible: controller.sheetDetent == .full || controller.modal != nil,
                                   state: ui.sos.mine, theme: theme, trigger: controller.actions.sos.trigger))
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

    private func touchChanged(_ down: Bool) {
        touching = down
        controller.cameraTouch(down: down)
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
        let dockTop = ["dock", "convoy", "cluster-row", "readout"].compactMap { frames[$0]?.minY }.min() ?? (full.height - bottomInset)
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
        ["cluster", "cluster-row", "sos", "ptt", "ptt-channel", "convoy", "top", "picking", "speed", "speedlimit", "readout", "recenter"].compactMap { frames[$0] }
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
        let ended = controller.tripEnded
        let side = exploring ? SaryMapControlItem.explore(terrain3D: controller.terrain3D, tracksShown: trackLibrary.shown.count)
            : sideItems(driving: driving, ended: ended)
        ZStack {
            VStack(spacing: theme.space(.s)) {
                LiveTopStack(controller: controller, ui: ui, alerts: frozenAlerts ?? ui.alerts, driving: driving, exploring: exploring, rowMode: rowMode,
                             maxListHeight: max(220, full.height * 0.42), weather: controller.weather,
                             plan: app.plans.model(controller.session.id), media: MediaCenters.of(controller),
                             radio: GroupAudioCenters.of(controller))
                    .chromeFrame("top")
                if let title = controller.recenterTitle, !exploring, controller.sheetDetent != .full {
                    /* «رجّعني للتوجيه»: the pan left «باتجاهي»; one big tap brings it back. Under the
                       banner, where «استأنف التوجيه» sits too: never over the speed or the dock. */
                    RecenterPill(title: title, action: controller.recenterCamera)
                        .chromeFrame("recenter")
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if controller.picking.active {
                    PickingBanner(moving: controller.picking.moving, cancel: controller.cancelPicking)
                        .chromeFrame("picking")
                }
                if offersCityRealistic(exploring: exploring, driving: driving) {
                    /* A city tilted on draped imagery smears; Apple's photoreal 3D is one tap away, at the same camera. */
                    RealisticEntryButton(id: "explore.city-realistic", title: "اعرضها بالوضع الواقعي") { openRealistic(atMapCamera: true) }
                        .chromeFrame("city-realistic")
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.space(.m))
            .padding(.top, 4)

            /* «تخفيف الزحمة» ١: no side column while driving. Stopped: «تتبعني» and «أدوات» on the
             * map's side, each with its caption; exploring: «الطبقات»، «أماكني ومساراتي»، «موقعي». */
            if controller.sheetDetent == .peek && !side.isEmpty {
                VStack {
                    Spacer()
                    HStack(alignment: .bottom, spacing: theme.space(.s)) {
                        Group {
                            if exploring {
                                SaryControlCluster(items: side, axis: .vertical, action: controlTapped)
                            } else {
                                LiveSideButtons(items: side, action: controlTapped)
                            }
                        }
                        .chromeFrame("cluster")
                        .transition(.opacity)
                        Spacer()
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
                if ended {
                    /* Build 11: an ended trip kept «اضغط وتكلم» and SOS as if it were still on. */
                    EndedTripBanner(summary: controller.openSummary, home: controller.onExit, more: { controller.modal = .actions })
                        .chromeFrame("dock")
                        .padding(.horizontal, theme.space(.m))
                        .padding(.bottom, lift + theme.space(.m))
                        .opacity(controller.sheetDetent == .full ? 0 : 1)
                        .allowsHitTesting(controller.sheetDetent != .full)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    if driving, controller.nav.isActive, controller.sheetDetent == .peek,
                       let line = LiveCalmRules.convoyLine(ui.participantsTab.participants) {
                        /* The guidance bar holds the peek: the group in one small line above the dock. */
                        ConvoyLinePill(text: line) { controller.selectedTab = .group; controller.sheetDetent = .half }
                            .chromeFrame("convoy")
                            .transition(.opacity)
                    }
                    HStack(alignment: .bottom) {
                        VStack(spacing: 6) {
                            SaryPTTButton(state: ui.ptt, actions: controller.actions.ptt, showsCaption: !rowMode, level: controller.pttLevel, pill: true)
                                .chromeFrame("ptt")
                            /* «تردد ١» under «اضغط وتكلم»: a tap opens the channels (the talk button keeps
                             * every touch for talking: no long-press tricks, «تخفيف الزحمة» ٣). */
                            if controller.session.walkie.showsChannels && !rowMode {
                                PTTChannelChip(walkie: controller.session.walkie, open: { controller.modal = .pttChannels })
                                    .chromeFrame("ptt-channel")
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            /* «سرعة المركبة» while driving, above «اضغط وتكلم», only once a real speed was
                             * read (never an empty «— كم/س», «تخفيف الزحمة» ٨); the posted limit beside it. */
                            HStack(alignment: .center, spacing: theme.space(.s)) {
                                if driving && controller.speed.everRead {
                                    SarySpeedometer(ui: controller.speedometerUI)
                                        .chromeFrame("speed")
                                        .transition(.opacity)
                                }
                                if driving, controller.nav.phase == .guiding, let k = controller.nav.progress?.speedLimitKmh {
                                    NavSpeedLimitSign(kmh: k)
                                        .chromeFrame("speedlimit")
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .fixedSize()
                            .alignmentGuide(.top) { $0[.bottom] + theme.space(.m) }
                        }
                        Spacer()
                        if rowMode {
                            SaryControlCluster(items: rowItems(exploring: exploring), axis: .horizontal, action: controlTapped)
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
        }
        .animation(theme.animation(.smooth), value: controller.sheetDetent)
        .animation(theme.animation(.smooth), value: controller.tripEnded)
        .animation(theme.animation(.smooth), value: sheetTop)
        .animation(theme.animation(.smooth), value: driving)
        .animation(theme.animation(.smooth), value: exploring)
        .animation(theme.animation(.snappy), value: controller.recenterTitle)
        .environment(\.safetyAlertActions, controller.safety.alertActions)
        .environment(\.convoyAlertActions, controller.convoyAlertActions)
        .animation(theme.animation(.smooth), value: controller.backTrack != nil)
        .animation(theme.animation(.smooth), value: controller.nav.phase)
        .animation(theme.animation(.smooth), value: visuals.cityTilt)
    }

    /// Exploring, tilted over a city, online, stopped and not guiding (the realistic view's own rules).
    private func offersCityRealistic(exploring: Bool, driving: Bool) -> Bool {
        exploring && !driving && visuals.cityTilt && app.online && !controller.nav.isActive && !controller.motion.moving
            && !controller.picking.active && controller.sheetDetent != .full
    }

    private func openRealistic(atMapCamera: Bool = false) {
        /* Looking, not driving: navigation and movement stay on the trip map. */
        if controller.nav.isActive || controller.motion.moving { controller.toast("الوضع الواقعي متاح وأنت واقف"); return }
        var scene = RealisticScene.live(controller, plan: app.plans.model(controller.session.id), places: savedPlaces.places)
        if atMapCamera { scene.camera = visuals.realisticCamera() }
        realistic = scene
    }

    /// The map's side (stopped): «تتبعني» and «أدوات» (+ «طريق العودة» when it fits the moment).
    /// «المجموعة» (fit everyone) is in «أدوات» → الخريطة; «نظرة عامة» in the guidance bar.
    private func sideItems(driving: Bool, ended: Bool) -> [SaryMapControlItem] {
        let all = SaryMapControlItem.liveDefaults(following: controller.following, backTracking: controller.backTrack != nil)
        let back = controller.showsBackTrackShortcut && !ended ? all.first { $0.id == "backtrack" } : nil
        /* I am stuck: «غرّزت» is in there. */
        return LiveCalmRules.sideItems(camera: controller.cameraModeItem, backTrack: back,
                                       plusBadge: controller.safety.myStuck != nil ? 1 : nil, driving: driving, ended: ended)
    }

    /// The same buttons in one row when the sheet is at half height.
    private func rowItems(exploring: Bool) -> [SaryMapControlItem] {
        exploring ? SaryMapControlItem.explore(terrain3D: controller.terrain3D, tracksShown: trackLibrary.shown.count)
            : sideItems(driving: false, ended: controller.tripEnded)
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
        case "realistic": openRealistic()
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
    @ObservedObject var radio: GroupAudioCenter
    @EnvironmentObject private var location: LocationSharer
    @Environment(\.sary) private var theme
    /// The radio's bar shows a few seconds when the track changes («تخفيف الزحمة» ٢).
    @State private var radioFlash: String?

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
            if !exploring, let prompt = controller.guidancePrompt {
                /* The trip runs without guidance on this phone: one tap, for me only. */
                GuidancePromptRow(prompt: prompt, leaderName: controller.leaderName, start: controller.startGuidanceForMe)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            /* «إذاعة الطلعة»: a ♪ in the header; its small control under it when opened from the ♪ or
             * for a few seconds when the track changes. Never the wide bar while driving. */
            if !driving && !exploring && radio.showsNowPlaying && (controller.radioBarOpen || radioFlash != nil) {
                GroupAudioMiniBar(center: radio)
            }
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
                HStack(alignment: .center, spacing: theme.space(.s)) {
                    SaryAlertLane(alerts: [card], limit: 1, tapped: controller.actions.alertTapped,
                                  dismiss: controller.actions.dismissAlert, voice: controller.actions.voice, silent: controller.actions.silent)
                    if bannerOnly {
                        /* No header (the guidance banner is the top bar): the history is on the alert itself. */
                        AlertHistoryButton(open: controller.bellOpen) { controller.statusExpanded = false; controller.bellOpen.toggle() }
                    }
                }
            } else if bannerOnly && (bell > 0 || !controller.alertHistory.isEmpty) {
                HStack {
                    Spacer()
                    AlertHistoryButton(open: controller.bellOpen) { controller.statusExpanded = false; controller.bellOpen.toggle() }
                }
            } else if !driving && !rowMode {
                /* «في قناة الطلعة»: the lowest tier, shown only when nothing else wants the spot. */
                MediaNoticeLane(center: media)
            }
            if let t = AlertQueue.toast(alerts), !(driving && card != nil) {
                /* Driving: one alert at a time; the toast waits behind the card (it is in the history). */
                SaryAlertCard(alert: t)
                    .transition(.opacity)
            }
        }
        .animation(theme.animation(.smooth), value: controller.bellOpen)
        .animation(theme.animation(.smooth), value: controller.radioBarOpen)
        .animation(theme.animation(.smooth), value: radioFlash)
        .animation(theme.animation(.smooth), value: controller.statusExpanded)
        .task(id: radio.nowItem?.id) {
            guard let id = radio.nowItem?.id else { radioFlash = nil; return }
            radioFlash = id
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled, radioFlash == id { radioFlash = nil }
        }
        .animation(theme.animation(.enter), value: card?.id)
    }

    private func header(bell: Int) -> some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            let trip = controller.showsTripStrip ? controller.tripPanel : nil
            let follow = plan.following && plan.plan.hasRoute ? TripHeaderPresenter.follow(plan.followStatus(fix: location.lastFix, now: ctx.date)) : nil
            let h = TripHeaderUI(title: TripHeaderPresenter.title(outingName: ui.outingName, trip: trip, ended: controller.tripEnded),
                                 line: TripHeaderPresenter.line(status: ui.status, trip: trip, follow: follow, connection: ui.connection, nearbyCars: ui.nearbyCars),
                                 level: TripHeaderPresenter.level(connection: ui.connection, sharing: ui.sharing, warnings: ui.warnings),
                                 bell: bell)
            /* «تخفيف الزحمة» ٤–٥: the weather while stopped only (dangerous weather comes as an alert);
             * no binoculars here («أدوات» → «استكشاف وطبقات»); nothing live after the end. */
            let ended = controller.tripEnded
            TripHeader(ui: h, weather: driving || ended ? nil : weather.chip(now: ctx.date),
                       accessibility: [ui.outingName, h.title == ui.outingName ? nil : "إلى \(h.title)", h.line, ui.connection.label].compactMap { $0 }.joined(separator: "، "),
                       back: controller.actions.back,
                       open: controller.openTripDetails,
                       statusTapped: { controller.bellOpen = false; controller.statusExpanded.toggle() },
                       weatherTapped: { controller.modal = .weather },
                       bellTapped: { controller.statusExpanded = false; controller.bellOpen.toggle() },
                       bellOpen: controller.bellOpen,
                       hasHistory: !controller.alertHistory.isEmpty,
                       exploreTapped: nil,
                       radio: radio.showsNowPlaying && !ended
                           ? RadioHeaderUI(title: radio.nowItem?.title ?? "", playing: radio.state.playing, muted: radio.muted, open: controller.radioBarOpen)
                           : nil,
                       radioTapped: {
                           if driving { radio.open() } else { controller.radioBarOpen.toggle() }
                       })
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
            if controller.autoNavFollowId != nil, let f = controller.followUI {
                /* The trip's off-road leg along the plan's drawn route: the track panel is the one header. */
                FollowTrackPanel(ui: f, reverse: controller.reverseFollow, exit: controller.endNav, approach: controller.approachFollow)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                NavOffRoadPanel(nav: nav, reference: controller.navReferenceBearing)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
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

/// «الرحلة انتهت» in place of the walkie-talkie and SOS once the outing has ended:
/// the summary, or back to the outings list.
struct EndedTripBanner: View {
    var summary: () -> Void
    var home: () -> Void
    /// «المزيد»: what still makes sense after the end (explore, search, weather…) — «أدوات الطلعة».
    var more: (() -> Void)? = nil
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.space(.s)) {
            HStack(spacing: theme.space(.s)) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(p.accentText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("الرحلة انتهت").saryText(.headline, weight: .heavy).foregroundStyle(p.textPrimary)
                    Text("ما أحد يشارك موقعه الآن.").saryText(.footnote).foregroundStyle(p.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("live.ended.title")
                Spacer(minLength: 0)
            }
            HStack(spacing: theme.space(.s)) {
                Button(action: summary) { SaryButtonLabel(title: "اعرض الملخص", systemImage: "chart.bar.doc.horizontal") }
                    .buttonStyle(.sary(.primary, compact: true))
                    .accessibilityIdentifier("live.ended.summary")
                Button(action: home) { SaryButtonLabel(title: "ارجع لطلعاتي", systemImage: "list.bullet") }
                    .buttonStyle(.sary(.secondary, compact: true))
                    .accessibilityIdentifier("live.ended.home")
                if let more {
                    Button(action: more) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(p.textPrimary)
                            .frame(width: 48, height: 48)
                            .saryGlass(Circle(), role: .control, interactive: true)
                    }
                    .buttonStyle(SaryPressStyle())
                    .accessibilityLabel(Text("المزيد: استكشاف، بحث، طقس"))
                    .accessibilityIdentifier("outing-actions")
                }
            }
        }
        .padding(theme.space(.m))
        .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .control)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live.ended")
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

/// «رجّعني للتوجيه»: big, one tap, above the dock (≥ 56 pt while driving).
struct RecenterPill: View {
    var title: String
    var action: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.space(.s)) {
                Image(systemName: "location.north.line.fill")
                    .font(.system(size: theme.drive ? 22 : 18, weight: .bold))
                Text(title)
                    .saryText(theme.drive ? .headline : .callout, weight: .bold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(theme.palette.onAccent)
            .padding(.horizontal, theme.space(.l))
            .frame(minHeight: theme.drive ? 60 : 50)
            .background(Capsule().fill(theme.palette.accent))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        }
        .buttonStyle(SaryPressStyle())
        .sensoryFeedback(.impact, trigger: title)
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text("يرجّع الخريطة خلف سيارتك وباتجاه سيرك"))
        .accessibilityIdentifier("camera.recenter")
    }
}
