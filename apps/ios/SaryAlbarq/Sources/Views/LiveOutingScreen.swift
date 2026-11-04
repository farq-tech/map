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
    @State private var frames: [String: CGRect] = [:]
    @State private var sheetTop: CGFloat = 0
    @State private var screenHeight: CGFloat = 0

    var body: some View {
        let ui = controller.ui
        GeometryReader { geo in
            let full = CGSize(width: geo.size.width, height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom)
            ZStack {
                Color.clear.onAppear { screenHeight = full.height }.onChange(of: full.height) { _, h in screenHeight = h }
                OutingMapboxView(
                    members: controller.mapMembers(theme: theme),
                    rally: controller.rallyPoint,
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
                    onWaterways: { controller.weather.setWaterways($0) }
                )
                .ignoresSafeArea()

                EdgeArrowLayer(overlay: controller.overlay, controller: controller, area: clearArea(full: full), avoid: avoidRects(full: full))
                    .ignoresSafeArea()
                    .allowsHitTesting(true)

                chrome(ui, full: full, safeBottom: geo.safeAreaInsets.bottom)
            }
            .onPreferenceChange(ChromeFramesKey.self) { frames = $0 }
        }
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
        let cluster = frames["cluster"]
        let left = cluster.map { $0.minX < full.width / 2 ? $0.maxX + 4 : 0 } ?? 0
        let right = cluster.map { $0.minX >= full.width / 2 ? full.width - $0.minX + 4 : 0 } ?? 0
        return UIEdgeInsets(top: topChromeBottom + 4, left: left, bottom: bottom + 4, right: right)
    }

    /// The part of the screen that is really map, for edge arrows.
    private func clearArea(full: CGSize) -> CGRect {
        let top = topChromeBottom + 4
        let bottom = full.height - bottomInset - 4
        return CGRect(x: 4, y: top, width: full.width - 8, height: max(1, bottom - top))
    }

    private func avoidRects(full: CGSize) -> [CGRect] {
        ["cluster", "cluster-row", "sos", "ptt", "top", "picking"].compactMap { frames[$0] }
    }

    // MARK: chrome

    @ViewBuilder
    private func chrome(_ ui: LiveOutingUIState, full: CGSize, safeBottom: CGFloat) -> some View {
        let rowMode = controller.sheetDetent == .half
        /* This layer sits inside the safe area; the sheet edge is measured on the whole screen. */
        let lift = max(0, bottomInset - safeBottom)
        let items = controlItems(ui)
        ZStack {
            VStack(spacing: theme.space(.s)) {
                VStack(spacing: theme.space(.s)) {
                    if case let .active(since) = ui.sos.mine {
                        SaryMySOSStrip(since: since, now: ui.now, imOK: controller.actions.sos.imOK,
                                       withLocation: controller.session.view?.me?.sos?.fix != nil)
                    }
                    ForEach(ui.sos.incoming.filter(\.acknowledged)) { a in
                        SaryFriendSOSStrip(alert: a, now: ui.now, show: { controller.showSOS(a.id) })
                    }
                    SaryStatusCapsule(outingName: ui.outingName, status: ui.status, connection: ui.connection, sharing: ui.sharing,
                                      warnings: ui.warnings, expanded: $controller.statusExpanded, back: controller.actions.back,
                                      warningTapped: controller.actions.warningTapped)
                    if !rowMode {
                        SaryAlertLane(alerts: ui.alerts, limit: theme.drive ? 1 : 3, tapped: controller.actions.alertTapped,
                                      dismiss: controller.actions.dismissAlert, voice: controller.actions.voice)
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

            if controller.sheetDetent == .peek {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
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
                HStack(alignment: .bottom) {
                    SaryPTTButton(state: ui.ptt, actions: controller.actions.ptt, showsCaption: !rowMode)
                        .chromeFrame("ptt")
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
    }

    private func controlItems(_ ui: LiveOutingUIState) -> [SaryMapControlItem] {
        let unread = ui.alerts.filter { if case .note = $0.kind { return true }; return false }.count
        let all = SaryMapControlItem.liveDefaults(following: controller.following, unreadNotes: unread > 0 ? unread : nil)
        return theme.drive ? Array(all.prefix(2)) : all
    }

    private func controlTapped(_ id: String) {
        let a = controller.actions
        switch id {
        case "locate": a.locateMe()
        case "fit": a.fitGroup()
        case "note": a.openNoteComposer()
        case "nearest": a.openNearestStations()
        default: break
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
