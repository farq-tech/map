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
    @Environment(\.dynamicTypeSize) private var typeSize
    @EnvironmentObject private var app: AppModel
    @State private var frames: [String: CGRect] = [:]
    @State private var sheetTop: CGFloat = 0
    @State private var screenHeight: CGFloat = 0
    /// While a finger is on the screen the alert lane holds still (a card arriving mid-tap
    /// must not shift or cover what the person is touching); it catches up just after.
    @State private var frozenAlerts: [LiveAlertUI]?
    @State private var touching = false
    /// The sheet's detent shape held still while a finger is down and through the settle after it
    /// (`LiveSheetShape`): a detent set changing mid-gesture makes SwiftUI re-snap the sheet.
    @State private var frozenSheetShape: LiveSheetShape?
    @ObservedObject private var savedPlaces = SavedPlacesStore.shared
    @ObservedObject private var trackLibrary = TrackLibrary.shared
    /// «الوضع الواقعي» (Apple 3D imagery), presented over the live sheet.
    @State private var realistic: RealisticScene?
    @AppStorage(MapLayerCatalog.qiblaVisibleKey) private var showQiblaOnMap = true
    /// Tilted over a city: «اعرضها بالوضع الواقعي».
    @ObservedObject private var visuals = MapVisualsHub.shared

    var body: some View {
        /* One presenter pass per render: the map's members and the edge arrows reuse it. */
        let input = controller.input
        let ui = LiveOutingPresenter.state(input)
        GeometryReader { geo in
            let full = CGSize(width: geo.size.width, height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom)
            ZStack {
                Color.clear.onAppear { screenHeight = full.height }.onChange(of: full.height) { _, h in screenHeight = h }
                let members = controller.mapMembers(theme: theme, input: input, participants: ui.participantsTab.participants)
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
                    onProjection: { controller.overlay.enqueueProjection($0) },
                    onUserGesture: {
                        controller.cameraUserMoved()
                        controller.userPannedMap = true
                        controller.navUserMovedMap()
                    },
                    onGestureEnd: { controller.cameraGestureEnded(negligible: $0) },
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
                    tripEnded: controller.tripEnded,
                    explore: controller.mapExplore(places: savedPlaces.places, tracks: trackLibrary),
                    /* Build 10: clean imagery when a track is the subject; road names while navigating. */
                    labels: (exploring && controller.mapLayer == .satellite) || controller.trackFollow != nil || controller.backTrack != nil ? .clean : (controller.nav.isActive ? .driving : .standard),
                    onCenter: { controller.mapCenterChanged($0) },
                    hiRes: controller.hiResRequest(ui, exploring: exploring),
                    qiblaOrigin: qiblaMapOrigin,
                    userPoint: weatherUserPoint
                )
                }
                .ignoresSafeArea()

                if exploring {
                    ExploreCrosshair(model: controller.exploreReading)
                        .ignoresSafeArea()
                }

                EdgeArrowLayer(overlay: controller.overlay, controller: controller, area: clearArea(full: full), avoid: avoidRects(full: full),
                               driving: controller.liveContext(drive: theme.drive) == .driving, alerting: controller.alertingMemberIds(ui: ui),
                               parts: Dictionary(ui.participantsTab.participants.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
                    .ignoresSafeArea()
                    .allowsHitTesting(true)

                chrome(ui, full: full, safeBottom: geo.safeAreaInsets.bottom)
            }
            .onPreferenceChange(ChromeFramesKey.self) { frames = $0 }
        }
        .background(TouchWatcherView { down in touchChanged(down) }.allowsHitTesting(false))
        .onChange(of: controller.realisticRequest) { _, _ in openRealistic() }
        /* «أماكن مقترحة للكشتة»: a site tapped on the map opens its card. */
        .onReceive(CampSitesHub.shared.$tapped.compactMap { $0 }) { id in
            CampSitesHub.shared.tapped = nil
            if controller.modal == nil { controller.modal = .campSite(id) }
        }
        .ignoresSafeArea(.keyboard)
        /* SOS never disappears: over the full-height sheet and any sheet on top, it floats in
         * its own window (the dock's copy is hidden or covered then). */
        .background(SOSOverlayHost(visible: (controller.sheetDetent == .full || controller.modal != nil) && !controller.tripEnded && !controller.settingsOpen,
                                   state: ui.sos.mine, theme: theme, trigger: controller.actions.sos.trigger,
                                   frame: frames["sos"], size: controller.liveContext(drive: theme.drive) == .driving ? 60 : 52,
                                   countdown: controller.groupUI.serverSOS))
        /* A friend's SOS: full screen in its own window, over every sheet, page and dialog (UI-AUDIT 0.1). */
        .background(FriendSOSAlertHost(alert: LiveOutingPresenter.fullScreenSOS(ui.sos), theme: theme,
                                       show: { controller.showSOS($0) }, call: { controller.actions.sos.call($0) }))
        .sheet(isPresented: .constant(true)) {
            /* The presenter state this render already built: the sheet does not run it again. */
            LiveSheet(controller: controller, ui: ui)
                .realisticCover($realistic)
                .background {
                    /* The sheet's real top edge on screen (its content height leaves out the home-indicator area). */
                    GeometryReader { g in
                        Color.clear
                            .onAppear { sheetTop = g.frame(in: .global).minY }
                            .onChange(of: g.frame(in: .global).minY) { _, y in
                                /* A finger on the sheet: the chrome above it follows 1:1 (no spring chasing the
                                 * finger). Otherwise (a tap on the summary, a programmatic lower, the settle)
                                 * it eases to the new edge. */
                                var t = Transaction()
                                if touching { t.disablesAnimations = true } else { t.animation = theme.animation(.smooth) }
                                withTransaction(t) { sheetTop = y }
                            }
                    }
                }
                .saryAppearance(appearance)
                .sarySheetPresentation(detent: $controller.sheetDetent, shape: sheetShape)
        }
    }

    /// The live sheet's detent shape: frozen during a touch, else from the context at peek.
    private var sheetShape: LiveSheetShape {
        LiveSheetShape.resolve(live: controller.sheetShape(drive: theme.drive), frozen: frozenSheetShape)
    }

    private func touchChanged(_ down: Bool) {
        touching = down
        controller.cameraTouch(down: down)
        if down {
            /* `ui.alerts` is the controller's `alerts` as is: no presenter pass for one touch. */
            if frozenAlerts == nil { frozenAlerts = controller.alerts }
            if frozenSheetShape == nil { frozenSheetShape = controller.sheetShape(drive: theme.drive) }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if !touching { frozenAlerts = nil }
            }
            /* After the native settle animation (~0.4 s) the sheet may take a changed shape. */
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if !touching { frozenSheetShape = nil }
            }
        }
    }

    // MARK: measured chrome

    /// How much of the screen the sheet covers, measured from its real top edge.
    private var bottomInset: CGFloat {
        if controller.sheetDetent == .full { return 0 }
        let measured = sheetTop > 0 && screenHeight > 0 ? screenHeight - sheetTop + SaryRadius.sheet * 0.25 : 0
        return max(measured, sheetShape.peekHeight)
    }

    /// The qibla ray follows only a recent accepted fix; stale/low-quality GPS must not move it.
    private var qiblaMapOrigin: LngLat? {
        let navigating = controller.nav.phase == .guiding || controller.nav.phase == .offRoad
        guard QiblaMapOverlay.shows(userChoice: showQiblaOnMap, navigating: navigating),
              let fix = controller.location.lastFix else { return nil }
        let ageMs = Date().timeIntervalSince1970 * 1000 - fix.atMs
        guard ageMs >= 0, ageMs <= 120_000, let accuracy = fix.accuracy, accuracy <= 500 else { return nil }
        return LngLat(lng: fix.lng, lat: fix.lat)
    }

    /// The cloud outlook's own-position point: a fix younger than 10 min and accurate to 2 km.
    private var weatherUserPoint: LngLat? {
        guard let fix = controller.location.lastFix else { return nil }
        let ageMs = Date().timeIntervalSince1970 * 1000 - fix.atMs
        guard ageMs >= 0, ageMs <= 600_000, let accuracy = fix.accuracy, accuracy <= 2000 else { return nil }
        return LngLat(lng: fix.lng, lat: fix.lat)
    }

    private var topChromeBottom: CGFloat {
        ["top"].compactMap { frames[$0]?.maxY }.max() ?? 120
    }

    /// What our chrome covers, for the map's keep-group framing and ornaments.
    private func chromeInsets(full: CGSize) -> UIEdgeInsets {
        let dockTop = ["flow", "dock", "convoy", "cluster-row", "readout"].compactMap { frames[$0]?.minY }.min() ?? (full.height - bottomInset)
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
        /* Guiding (v2): up to four round buttons on the right, my speed and the limit bottom-left. */
        let guidingHUD = controller.nav.phase == .guiding && !exploring && !ended
        let side = LiveCalmRules.withLayers(exploring ? exploreSide : (guidingHUD ? controller.navSideItems : sideItems(driving: driving, ended: ended)),
                                            layers: .layers(active: controller.terrain3D))
        /* After the end only «طريق الرجعة» stays on the map (on this phone, no network: UI-AUDIT 0.3). */
        let showSide = controller.sheetDetent == .peek && !side.isEmpty && (!ended || !exploring)
            && LiveFit.sideWithAlertList(bellOpen: controller.bellOpen, screenHeight: full.height)
        /* iPhone SE (667 pt): the side captions drop out so the column stays above the dock (`LiveFit`). */
        /* Driving: bare round buttons (the name is spoken by VoiceOver), at the drive size. */
        let sideCaptions = LiveFit.sideCaptions(guiding: guidingHUD, screenHeight: full.height) && !driving
        ZStack {
            /* TOP (Lovable): the header (or the guidance header, or the end card), then the one alert
             * with SOS on its left, then «تتبعني» / «أدوات» on the right. */
            VStack(spacing: theme.space(.s)) {
                if exploring {
                    ExploreTopBar(controller: controller, exit: { controller.exitExplore() })
                        .transition(SaryTransition.banner(theme))
                }
                if ended {
                    EndedTripBanner(summary: controller.openSummary, home: controller.onExit, more: { controller.modal = .actions },
                                    subtitle: endedSubtitle(ui))
                        .opacity(controller.sheetDetent == .full ? 0 : 1)
                        .allowsHitTesting(controller.sheetDetent != .full)
                        .transition(SaryTransition.banner(theme))
                }
                LiveTopStack(controller: controller, ui: ui, alerts: frozenAlerts ?? ui.alerts, driving: driving, exploring: exploring, rowMode: rowMode,
                             maxListHeight: LiveFit.alertListMaxHeight(screenHeight: full.height), width: full.width, weather: controller.weather,
                             plan: app.plans.model(controller.session.id), media: MediaCenters.of(controller),
                             radio: GroupAudioCenters.of(controller),
                             sos: ended ? nil : AnyView(LovableSOS(state: ui.sos.mine, size: driving ? 60 : 52, trigger: controller.actions.sos.trigger,
                                                                   countdown: controller.groupUI.serverSOS)),
                             /* My SOS on (focused mode): no side buttons — the strip, the walkie-talkie and the map. */
                             side: showSide && !controller.sosFocused ? AnyView(sideView(side, exploring: exploring, captions: sideCaptions).chromeFrame("cluster")) : nil)
                    .chromeFrame("top")
                if let title = controller.recenterTitle, !exploring, controller.sheetDetent != .full {
                    /* «رجّعني للتوجيه»: the pan left «باتجاهي»; one big tap brings it back. */
                    RecenterPill(title: title, action: controller.recenterCamera)
                        .chromeFrame("recenter")
                        .transition(SaryTransition.banner(theme))
                }
                if controller.picking.active {
                    PickingBanner(moving: controller.picking.moving, cancel: controller.cancelPicking)
                        .chromeFrame("picking")
                }
                /* «اعرضها بالوضع الواقعي» over a city is the side «واقعي» button itself (one entry): tilted
                 * over a city it opens at the map's camera (`exploreSide`, `controlTapped`). */
                Spacer(minLength: 0)
            }
            /* Map chrome: the text grows with Dynamic Type up to the cap the header, the alert lane and
             * the status details already use (pieces from other modules — strips, banners, the end card,
             * «رجّعني للتوجيه» — had none and grew until they covered the map and the dock). */
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 12)
            .padding(.top, 4)

            /* BOTTOM (Lovable): driving — the convoy line, then the speed and the big «اضغط وتكلم»;
             * stopped — «اضغط وتكلم» on the left; exploring — the brief hint. */
            VStack(spacing: 10) {
                Spacer()
                if exploring {
                    if controller.sheetDetent == .peek {
                        /* The hint in the middle; a small walkie-talkie stays reachable (UI-AUDIT م3). */
                        HStack(alignment: .center, spacing: theme.space(.s)) {
                            Spacer(minLength: 0)
                            Text("اضغط على أي مكان بالخريطة عشان تشوف بريفه")
                                .saryText(.caption, weight: .medium)
                                .foregroundStyle(theme.palette.textSecondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 200)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .saryGlass(Capsule(), role: .chrome)
                                .accessibilityIdentifier("explore.hint")
                                .chromeFrame("dock")
                            Spacer(minLength: 0)
                            /* A solo outing has no walkie-talkie (`LiveScreenRules.solo`). */
                            if !ended && controller.groupUI.walkieTalkie {
                                SaryPTTButton(state: ui.ptt, actions: controller.actions.ptt, showsCaption: false, level: controller.pttLevel,
                                              openChannels: { controller.modal = .pttChannels })
                                    .chromeFrame("ptt")
                            }
                        }
                        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                        .padding(.horizontal, 16)
                        .padding(.bottom, lift + theme.space(.m))
                    }
                } else if !ended {
                    if driving, controller.nav.isActive, controller.sheetDetent == .peek, LiveScreenRules.showsConvoyLine(ui.alerts),
                       let line = LiveCalmRules.convoyLine(ui.participantsTab.participants) {
                        ConvoyLinePill(text: line) { controller.selectedTab = .group; controller.sheetDetent = .half }
                            .chromeFrame("convoy")
                            .transition(.opacity)
                    }
                    /* «رسالة صوتية»: the recording bar, «فلان يتكلم…», unheard notes — just over the dock.
                     * Never in a solo outing: a recording would be uploaded, refused and deleted. */
                    let talk = controller.groupUI.walkieTalkie && controller.groupUI.voiceNotes
                    if talk {
                        VoiceNoteDock(center: controller.session.voiceNotes, openList: { controller.modal = .pttChannels })
                            .chromeFrame("voice-note")
                            .padding(.horizontal, theme.space(.m))
                            .opacity(controller.sheetDetent == .full ? 0 : 1)
                            .allowsHitTesting(controller.sheetDetent != .full)
                    }
                    /* ONE big button at a time (ux/الطلعة-والمشوار.md): stopped — the outing's primary action
                     * («ابدأ الطلعة» / «وين رايحين؟» / «ابدأ المشوار») is big and the walkie-talkie is a round
                     * button beside it; driving — the walkie-talkie is big and «وصلنا» is compact. */
                    let flow = controller.flowUI(ui: ui)
                    /* My SOS on (focused mode): the CTA steps aside; the SOS strip has «أنا بخير». */
                    /* «طريق الرجعة» running: its panel is the one action (UI-AUDIT, device test of PR #149). */
                    let hasCTA = flow.primary != nil && !controller.sosFocused && controller.backTrack == nil
                    /* Owner (2026-11-11): while driving every primary («وين رايحين؟», «وصلنا»…) is a compact pill;
                     * the sheet raised also shrinks it so it never covers the cars above the sheet. */
                    let ctaCompact = LiveScreenRules.primaryCompact(sheetRaised: controller.sheetDetent != .peek, driving: driving)
                    let pttBig = talk && driving && (ctaCompact || !hasCTA)
                    let pttPill = talk && (pttBig || !hasCTA)
                    let showsSpeedBubble = driving && controller.speed.everRead && controller.speedometerUI.current.kmh != nil && !guidingHUD
                    /* The row's room on this phone (`LiveFit.dock`): at 375 pt the speed, the 200 pt pill and
                     * a compact primary (or the guiding speed cluster) were wider than the screen — the
                     * pill narrows first, then the primary takes its own row just above. */
                    let dockFit = LiveFit.dock(
                        width: min(full.width, 680) - 32,
                        ptt: pttPill ? (pttBig ? LiveFit.bigPTTWidth : LiveFit.pillPTTWidth) : 0,
                        speed: showsSpeedBubble ? LiveFit.speedBubbleWidth : 0,
                        cta: pttPill && hasCTA && ctaCompact ? flow.primary.map { LiveFit.compactCTAWidth(title: $0.title, textScale: LiveFit.textScale(typeSize)) } : nil,
                        cluster: guidingHUD && controller.speed.everRead
                            ? LiveFit.navSpeedClusterWidth(drive: theme.drive, limit: controller.nav.progress?.speedLimitKmh != nil) : 0,
                        spacing: theme.space(.s))
                    let ctaOwnRow = dockFit.ctaOwnRow && hasCTA && ctaCompact
                    if ctaOwnRow {
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            OutingPrimaryCTA(ui: flow, compact: true, tapped: controller.flowTapped)
                                .fixedSize()
                                .chromeFrame("flow")
                        }
                        .padding(.horizontal, 16)
                        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                        .opacity(controller.sheetDetent == .full ? 0 : 1)
                        .allowsHitTesting(controller.sheetDetent != .full)
                        .transition(.opacity)
                    }
                    HStack(alignment: .center, spacing: theme.space(.s)) {
                        /* UX ٢١: no empty «—» bubble — only with a real reading. Guiding (v2) uses NavSpeedCluster. */
                        if showsSpeedBubble {
                            LovableSpeedBubble(ui: controller.speedometerUI)
                                .chromeFrame("speed")
                                .transition(.opacity)
                        }
                        if hasCTA && !ctaCompact {
                            OutingPrimaryCTA(ui: flow, compact: false, tapped: controller.flowTapped)
                                .chromeFrame("flow")
                        } else if !driving {
                            Spacer()
                        }
                        /* Round beside the big primary: no caption under it (its label is spoken by VoiceOver).
                         * A solo outing: no walkie-talkie at all. */
                        if talk {
                            SaryPTTButton(state: ui.ptt, actions: controller.actions.ptt, showsCaption: pttPill, level: controller.pttLevel, pill: pttPill, big: pttBig,
                                          channelLabel: controller.session.walkie.showsChannels ? PTTChannels.chipLabel(controller.session.walkie.currentChannel) : nil,
                                          openChannels: { controller.modal = .pttChannels },
                                          pillMinWidth: pttPill ? dockFit.pttMinWidth : nil)
                                .chromeFrame("ptt")
                        }
                        if ctaCompact && hasCTA && !ctaOwnRow {
                            Spacer(minLength: 0)
                            /* Its whole label always: the talk pill is the one that gives way. */
                            OutingPrimaryCTA(ui: flow, compact: true, tapped: controller.flowTapped)
                                .fixedSize()
                                .chromeFrame("flow")
                        } else if (driving && !hasCTA) || ctaOwnRow {
                            Spacer()
                        }
                        /* UI-AUDIT م3: no red «أنهِ الطلعة» flag on the map. Ending is in «المزيد» → «الطلعة»
                         * (the owner) and this CTA when «رجعتوا؟» suggests it — one confirmation below. */
                        if guidingHUD && controller.speed.everRead {
                            NavSpeedCluster(ui: controller.speedometerUI, limit: controller.nav.progress?.speedLimitKmh)
                                .chromeFrame("speed")
                                .transition(.opacity)
                        }
                        /* No side row at the sheet's middle height (UI-AUDIT م3): the camera is on the map,
                         * «طريق الرجعة» is the side shortcut or «المزيد» → «الطريق». */
                    }
                    .overlay(alignment: .topTrailing) {
                        /* Guiding with no speed read yet: the posted limit alone, where the speed will be. */
                        if guidingHUD, !controller.speed.everRead, let k = controller.nav.progress?.speedLimitKmh {
                            NavSpeedLimitSign(kmh: k)
                                .chromeFrame("speedlimit")
                                .alignmentGuide(.top) { $0[.bottom] + 8 }
                                .transition(SaryTransition.chipPop(theme))
                        }
                    }
                    /* The primary morphs between states («ابدأ الطلعة» → «وين رايحين؟» → «وصلنا»): the dock
                     * re-lays out in the same transaction, so the talk pill gives way smoothly. */
                    .animation(theme.animation(LiveMotion.primaryMorph(drive: driving)), value: flow.primary)
                    /* The dock's widths are budgeted at this cap (the talk pill already had it). */
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                    .chromeFrame("dock")
                    .padding(.horizontal, 16)
                    .padding(.bottom, lift + theme.space(.s))
                    .opacity(controller.sheetDetent == .full ? 0 : 1)
                    .allowsHitTesting(controller.sheetDetent != .full)
                    .confirmationDialog(EndOutingCopy.title, isPresented: Binding(get: { controller.legConfirmEnd }, set: { controller.legConfirmEnd = $0 }),
                                        titleVisibility: .visible) {
                        Button(EndOutingCopy.confirm, role: .destructive) { controller.endOutingFlow() }
                            .accessibilityIdentifier("outing-end-confirm")
                        Button(EndOutingCopy.cancel, role: .cancel) {}
                    } message: {
                        Text(EndOutingCopy.message(everyoneArrived: controller.tripPanel.everyoneArrived))
                    }
                }
            }
            /* The rest of the bottom chrome (the voice-note bar, the convoy line): the map chrome's cap. */
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity, alignment: .bottom)
        }
        .animation(theme.animation(.smooth), value: controller.sheetDetent)
        .animation(theme.animation(.smooth), value: controller.tripEnded)
        /* No `.animation(value: sheetTop)`: during a drag it sprang the dock after the finger every
         * frame. The sheet-top update itself carries its transaction (see the sheet's GeometryReader). */
        .animation(theme.animation(.smooth), value: driving)
        .animation(theme.animation(.smooth), value: exploring)
        .animation(theme.animation(.snappy), value: controller.recenterTitle)
        .environment(\.safetyAlertActions, controller.safety.alertActions)
        .environment(\.convoyAlertActions, controller.convoyAlertActions)
        .animation(theme.animation(.smooth), value: controller.backTrack != nil)
        .animation(theme.animation(.smooth), value: controller.nav.phase)
        .animation(theme.animation(.smooth), value: visuals.cityTilt)
    }

    /// VoiceOver value of «واقعي» while it opens the city at the map's own camera.
    static let cityRealisticValue = "المدينة بزاوية الخريطة"

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

    /// Exploring (Lovable): «درون» and «واقعي» on the right, with «أماكني ومساراتي».
    private var exploreSide: [SaryMapControlItem] {
        [
            SaryMapControlItem(id: "drone", systemImage: "airplane", label: "درون", accessibilityID: "explore-drone",
                               hint: "طيران درون استكشافي حول علامة الوسط"),
            SaryMapControlItem(id: "realistic", systemImage: visuals.cityTilt ? "building.2" : "mountain.2", label: "واقعي", accessibilityID: "explore-realistic",
                               hint: "اعرضها بالوضع الواقعي",
                               value: offersCityRealistic(exploring: true, driving: false) ? Self.cityRealisticValue : nil),
        ] + SaryMapControlItem.explore(terrain3D: controller.terrain3D, tracksShown: trackLibrary.shown.count).filter { $0.id == "places" }
            .map { var i = $0; i.label = "أماكني"; return i }
    }

    @ViewBuilder
    private func sideView(_ items: [SaryMapControlItem], exploring: Bool, captions: Bool = true) -> some View {
        BearingObserving(overlay: controller.overlay) { b in
            LiveSideButtons(items: items, action: controlTapped, bearing: b, captions: captions)
        }
    }

    /// «كشتة النفود الكبير · وصلتوا مخيم النفود» (Lovable's end card).
    private func endedSubtitle(_ ui: LiveOutingUIState) -> String {
        if case .arrived = controller.tripPanel.phase, !controller.tripPanel.destinationName.isEmpty {
            return "\(ui.outingName) · وصلتوا \(controller.tripPanel.destinationName)"
        }
        return "\(ui.outingName) · ما أحد يشارك موقعه الآن"
    }

    /// The map's side (stopped): «تتبعني» and «أدوات» (+ «طريق العودة» when it fits the moment).
    /// «المجموعة» (fit everyone) is in «أدوات» → الخريطة; «نظرة عامة» in the guidance bar.
    private func sideItems(driving: Bool, ended: Bool) -> [SaryMapControlItem] {
        let all = SaryMapControlItem.liveDefaults(following: controller.following, backTracking: controller.backTrack != nil)
        /* After the end: «طريق الرجعة» alone, on this phone along my trail (works with no network,
         * UI-AUDIT 0.3). Never while driving (the calm rule). */
        if ended {
            guard !driving, controller.showsBackTrackAfterEnd, let b = all.first(where: { $0.id == "backtrack" }) else { return [] }
            return [b]
        }
        let back = controller.showsBackTrackShortcut ? all.first { $0.id == "backtrack" } : nil
        /* I am stuck: «غرّزت» is in there. */
        let items = LiveCalmRules.sideItems(camera: controller.cameraModeItem, backTrack: back,
                                            plusBadge: controller.safety.myStuck != nil ? 1 : nil, driving: driving, ended: ended)
        /* Two buttons at most (the owner's «زحمة» review): «طريق العودة» is in «أدوات» and «وين رايحين؟». */
        guard items.count > 2 else { return items }
        /* While «طريق العودة» runs it is the way out: it stays, «تتبعني» steps aside. */
        return controller.backTrack != nil ? items.filter { $0.id != controller.cameraModeItem.id } : items.filter { $0.id != "backtrack" }
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
        case "realistic": openRealistic(atMapCamera: offersCityRealistic(exploring: controller.exploreActive, driving: false))
        case "drone": if let c = controller.exploreReading.reading?.center { MapVisualsHub.shared.fly(to: c) }
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
    /// The live screen's real width (not `UIScreen.main`): what the header can fit.
    var width: CGFloat = 0
    @ObservedObject var weather: OutingWeather
    @ObservedObject var plan: PlanModel
    @ObservedObject var media: MediaCenter
    @ObservedObject var radio: GroupAudioCenter
    /// Lovable: SOS on the left of the alert row, «تتبعني» / «أدوات» on the right under it.
    var sos: AnyView? = nil
    var side: AnyView? = nil
    @EnvironmentObject private var location: LocationSharer
    @Environment(\.sary) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
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
        let toast = AlertQueue.toast(alerts)
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
            if exploring || controller.tripEnded {
                /* Exploring: the layer bar is the top (ExploreTopBar); ended: the end card. */
            } else if !bannerOnly {
                header(bell: bell)
                if controller.statusExpanded {
                    TripStatusDetails(connection: ui.connection, sharing: ui.sharing, warnings: ui.warnings, nearbyCars: ui.nearbyCars,
                                      warningTapped: controller.actions.warningTapped)
                        .transition(SaryTransition.banner(theme))
                }
            }
            navTop
            if !exploring && !controller.tripEnded {
                /* After an invite: «نحدد موقعك…», the one-time welcome, «موقعك مو ظاهر للعيال». */
                InviteeArrivalStack(controller: controller)
            }
            if !exploring, !controller.tripEnded, let line = controller.fixWaitLine {
                /* Guidance asked for, my fix is old: never silent («ننتظر موقعك…»), starts by itself. */
                NavFixWaitRow(text: line, slow: controller.fixWait?.slow(now: Date()) == true, cancel: controller.cancelFixWait)
                    .transition(.opacity)
            }
            if !exploring, let prompt = controller.guidancePrompt {
                /* The trip runs without guidance on this phone: one tap, for me only. */
                GuidancePromptRow(prompt: prompt, leaderName: controller.leaderName, start: controller.startGuidanceForMe)
                    .transition(SaryTransition.banner(theme))
            }
            /* «إذاعة الطلعة»: a ♪ in the header; its small control under it when opened from the ♪ or
             * for a few seconds when the track changes. Never the wide bar while driving. */
            if !driving && !exploring && radio.showsNowPlaying && (controller.radioBarOpen || radioFlash != nil) {
                GroupAudioMiniBar(center: radio)
            }
            if let bt = controller.backTrackUI {
                BackTrackPanel(ui: bt, exit: controller.stopBackTrack)
                    .transition(SaryTransition.banner(theme))
            }
            /* «اسلك هذا المسار»; while «الملاحة» guides me to the track, its banner is the one header. */
            if !guidance, let f = controller.followUI {
                FollowTrackPanel(ui: f, reverse: controller.reverseFollow, exit: controller.stopFollow, approach: controller.approachFollow)
                    .transition(SaryTransition.banner(theme))
            }
            /* The alert row (Lovable): the alert (or the list) on the right, SOS on the left; the side
             * buttons under the alert. */
            HStack(alignment: .top, spacing: theme.space(.s)) {
                VStack(spacing: theme.space(.s)) {
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
                                .transition(SaryTransition.banner(theme))
                            } else if let card {
                                HStack(alignment: .center, spacing: theme.space(.s)) {
                                    SaryAlertLane(alerts: [card], limit: 1, tapped: controller.actions.alertTapped,
                                                  dismiss: controller.actions.dismissAlert, voice: controller.actions.voice, silent: controller.actions.silent)
                                    if LiveScreenRules.historyBesideCard(bannerOnly: bannerOnly) {
                                        /* No header (the guidance banner is the top bar): the history is on the alert itself.
                                         * With the header, its bell is the one way in (was `if true`: two at once). */
                                        AlertHistoryButton(open: controller.bellOpen) { controller.statusExpanded = false; controller.bellOpen.toggle() }
                                    }
                                }
                                /* The first card comes down from the top and the last one leaves in place (the lane
                                 * itself swaps one card for the next). */
                                .transition(SaryTransition.banner(theme))
                            } else if bannerOnly && (bell > 0 || !controller.alertHistory.isEmpty) {
                                HStack {
                                    Spacer()
                                    AlertHistoryButton(open: controller.bellOpen) { controller.statusExpanded = false; controller.bellOpen.toggle() }
                                }
                            } else if !driving && !rowMode {
                                /* «في قناة الطلعة»: the lowest tier, shown only when nothing else wants the spot. */
                                MediaNoticeLane(center: media)
                            }
                    if let side {
                        HStack { side; Spacer(minLength: 0) }
                    }
                }
                .frame(maxWidth: .infinity)
                if let sos {
                    sos.padding(.top, !driving && card != nil && !controller.bellOpen ? 60 : 0)
                }
            }
            if let t = toast, !(driving && card != nil) {
                /* Driving: one alert at a time; the toast waits behind the card (it is in the history). */
                SaryAlertCard(alert: t)
                    /* Outside the lane (which caps its cards): the same cap. */
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    /* A small rise and fade; only a fade in drive mode (peripheral). */
                    .id(t.id)
                    .transition(SaryTransition.toast(theme))
            }
        }
        .animation(theme.animation(.snappy), value: toast?.id)
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
        /* Shorter while driving. */
        .animation(theme.animation(theme.drive ? .snappy : .enter), value: card?.id)
    }

    private func header(bell: Int) -> some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            let trip = controller.showsTripStrip ? controller.tripPanel : nil
            let follow = plan.following && plan.plan.hasRoute ? TripHeaderPresenter.follow(plan.followStatus(fix: location.lastFix, now: ctx.date)) : nil
            let h = TripHeaderUI(title: TripHeaderPresenter.title(outingName: ui.outingName, trip: trip, ended: controller.tripEnded),
                                 /* «الطلعة» و«المشوار»: the state, unmistakable (ux/الطلعة-والمشوار.md). */
                                 line: follow ?? (controller.showsTripStrip || ui.status == .notStarted ? controller.flowUI(ui: ui).line
                                     : TripHeaderPresenter.line(status: ui.status, trip: trip, follow: follow, connection: ui.connection, nearbyCars: ui.nearbyCars)),
                                 level: TripHeaderPresenter.level(connection: ui.connection, sharing: ui.sharing, warnings: ui.warnings),
                                 bell: bell,
                                 localOnly: controller.isSolo)
            /* «تخفيف الزحمة» ٤–٥: the weather while stopped only (dangerous weather comes as an alert);
             * no binoculars here («أدوات» → «استكشاف وطبقات»); nothing live after the end. */
            let ended = controller.tripEnded
            /* A narrow phone (SE, mini) or large text: the state line needs the width more than the
             * weather pill (the weather stays in the sheet and its own alerts). `LiveFit`. */
            let roomForWeather = LiveFit.showsHeaderWeather(width: width, largeText: typeSize >= .xxLarge)
            TripHeader(ui: h, weather: driving || ended || !roomForWeather ? nil : weather.chip(now: ctx.date),
                       accessibility: [ui.outingName, h.localOnly ? SoloCopy.localOnlyLong : nil, h.title == ui.outingName ? nil : "إلى \(h.title)", h.line,
                                       trip?.phase == .underway ? trip?.remainingLine : nil, ui.connection.label].compactMap { $0 }.joined(separator: "، "),
                       back: controller.actions.back,
                       open: controller.openTripDetails,
                       statusTapped: { controller.bellOpen = false; controller.statusExpanded.toggle() },
                       weatherTapped: { controller.modal = .weather },
                       bellTapped: { controller.statusExpanded = false; controller.bellOpen.toggle() },
                       bellOpen: controller.bellOpen,
                       hasHistory: !controller.alertHistory.isEmpty,
                       showsBell: LiveScreenRules.showsBell(bell: bell, hasHistory: !controller.alertHistory.isEmpty, open: controller.bellOpen),
                       exploreTapped: nil,
                       radio: radio.showsNowPlaying && !ended
                           ? RadioHeaderUI(title: radio.nowItem?.title ?? "", playing: radio.state.playing, muted: radio.muted, open: controller.radioBarOpen)
                           : nil,
                       radioTapped: {
                           if driving { radio.open() } else { controller.radioBarOpen.toggle() }
                       },
                       /* UI-AUDIT م3: no gear in the header — «الإعدادات» is «المزيد» → «الطلعة». */
                       settingsTapped: nil)
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
                .transition(SaryTransition.banner(theme))
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
                FollowTrackPanel(ui: f, reverse: controller.reverseFollow, exit: controller.stopGuidanceTapped, approach: controller.approachFollow)
                    .transition(SaryTransition.banner(theme))
            } else {
                NavOffRoadPanel(nav: nav, reference: controller.navReferenceBearing)
                    .transition(SaryTransition.banner(theme))
            }
        case .arrived:
            NavArrivalCard(nav: nav, end: controller.endNav)
                .transition(SaryTransition.banner(theme))
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
    /// «طريق الرجعة» just started: the arrow disc settles in once (the panel itself comes down as a banner).
    @State private var settled = false

    var body: some View {
        let p = theme.palette
        let off = ui.phase == .offTrack
        let arrived = ui.phase == .arrived
        let arrowSize: CGFloat = theme.drive ? 92 : 68
        let tone: Color = off ? p.emergency : (arrived ? p.live : p.accent)
        /* Dark ink on the accent fill; light ink on red / green. */
        let ink: Color = (off || arrived) ? p.onEmergency : p.onAccent
        HStack(spacing: theme.space(.m)) {
            ZStack {
                Circle().fill(tone)
                if arrived {
                    Image(systemName: "flag.checkered").font(.system(size: arrowSize * 0.42, weight: .heavy)).foregroundStyle(ink)
                } else if ui.phase == .waitingFix {
                    ProgressView().tint(ink)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: arrowSize * 0.5, weight: .black))
                        .foregroundStyle(ink)
                        .rotationEffect(.degrees(ui.arrowDegrees))
                        .animation(theme.animation(.smooth), value: ui.arrowDegrees)
                }
            }
            .frame(width: arrowSize, height: arrowSize)
            /* A real-world direction: never mirrored by the RTL layout. */
            .environment(\.layoutDirection, .leftToRight)
            .overlay(Circle().stroke(Color.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .scaleEffect(settled || theme.reduceMotion || theme.drive ? 1 : 0.7)
            .onAppear {
                guard !settled else { return }
                withAnimation(theme.animation(.appear)) { settled = true }
            }
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
                Text(SaryCopy.endBackTrack).saryText(theme.drive ? .body : .callout, weight: .bold)
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
        .saryHaptic(.warning, trigger: off) { was, now in now && !was }
        .saryHaptic(.arrival, trigger: arrived) { was, now in now && !was }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("backtrack.panel")
    }

    private var title: String {
        switch ui.phase {
        case .waitingFix: return "طريق الرجعة"
        case .onTrail: return "طريق الرجعة"
        case .offTrack: return "خرجت عن الطريق"
        case .arrived: return "وصلت نقطة البداية"
        }
    }

    private var detail: String {
        switch ui.phase {
        case .waitingFix: return "ننتظر موقعك…"
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
    /// «كشتة النفود الكبير · وصلتوا مخيم النفود».
    var subtitle: String = "ما أحد يشارك موقعه الآن."
    @Environment(\.sary) private var theme

    /// Lovable: at the top, one card — the green flag, «الرحلة انتهت», then two 44 pt buttons.
    var body: some View {
        let p = theme.palette
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "flag.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(p.liveText)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(p.live.opacity(0.2)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("انتهت الطلعة").font(.sary(16, .bold)).foregroundStyle(p.textPrimary)
                    Text(subtitle).font(.sary(12, .regular)).foregroundStyle(p.textSecondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("live.ended.title")
                if let more {
                    Button(action: more) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(p.textPrimary)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(p.sunken))
                            .frame(width: theme.minTarget, height: theme.minTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SaryPressStyle())
                    .accessibilityLabel(Text("المزيد: استكشاف، بحث، طقس"))
                    .accessibilityIdentifier("outing-actions")
                }
            }
            HStack(spacing: 8) {
                Button(action: summary) {
                    Text("اعرض الملخص").font(.sary(14, .bold)).foregroundStyle(p.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(p.accent))
                }
                .buttonStyle(SaryPressStyle())
                .accessibilityIdentifier("live.ended.summary")
                Button(action: home) {
                    Text("ارجع لطلعاتي").font(.sary(14, .medium)).foregroundStyle(p.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(p.sunken))
                }
                .buttonStyle(SaryPressStyle())
                .accessibilityIdentifier("live.ended.home")
            }
        }
        .padding(17)
        .background { shape.fill(p.chromeOpaque.opacity(0.72)) }
        .saryGlass(shape, role: .chrome)
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
    /// Participants by id, from the screen's render (`ui`). Passed in rather than rebuilt here:
    /// this layer redraws with every camera projection (10 Hz while panning), and rebuilding the
    /// presenter input each time was the costliest part of it. Only name, colour, distance,
    /// presence and note are read (not the bearing, which follows the map).
    var parts: [String: ParticipantUI] = [:]
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
        /* Silent in drive mode (`SaryHaptics.allows`). */
        .saryHaptic(.selection, trigger: title)
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text("يرجّع الخريطة خلف سيارتك وباتجاه سيرك"))
        .accessibilityIdentifier("camera.recenter")
    }
}

/// Re-renders its content with the map's bearing (the camera button's north).
private struct BearingObserving<Content: View>: View {
    @ObservedObject var overlay: MapOverlayModel
    @ViewBuilder var content: (Double) -> Content
    var body: some View { content(overlay.projection.bearing) }
}
