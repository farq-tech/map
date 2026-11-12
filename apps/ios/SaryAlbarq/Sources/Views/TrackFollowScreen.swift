import SwiftUI

/// «اسلك هذا المسار» outside a live outing (from a trip summary, a GPX track): my position
/// from this phone's GPS only (nothing is sent), the track on clean satellite imagery, the
/// follow panel and at most one alert. Pure geometry: works offline; only the road route
/// to a far track needs the internet.
struct TrackFollowScreen: View {
    @StateObject var model: TrackFollowModel
    var close: () -> Void
    @EnvironmentObject private var location: LocationSharer
    @EnvironmentObject private var app: AppModel
    @Environment(\.sary) private var theme
    @State private var alerts: [LiveAlertUI] = []
    @State private var approach: [LngLat] = []
    @State private var approaching = false
    @State private var fitKey = 0
    @State private var followMe = true
    @State private var topHeight: CGFloat = 200
    /// The map's top in window points (it runs under the status bar / Dynamic Island).
    @State private var mapTop: CGFloat = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let nowMs = ctx.date.timeIntervalSince1970 * 1000
            let fresh = location.lastFix.flatMap { nowMs - $0.atMs <= TrackFollowModel.staleMs ? $0 : nil }
            let ui = model.ui(course: fresh.flatMap { Policy.trustedHeading($0.heading, speed: $0.speed) }, mapBearing: 0, online: app.online)
            ZStack(alignment: .top) {
                TrackMapView(line: model.drawLine, highlight: true, me: fresh.map { LngLat(lng: $0.lng, lat: $0.lat) }, approach: approach,
                             padding: UIEdgeInsets(top: topHeight, left: 0, bottom: 40, right: 0), fitKey: fitKey, followMe: followMe,
                             onUserGesture: { followMe = false })
                    .ignoresSafeArea()
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { mapTop = g.frame(in: .global).minY }
                            .onChange(of: g.frame(in: .global).minY) { _, y in mapTop = y }
                    })
                VStack(spacing: theme.space(.s)) {
                    FollowTrackPanel(ui: ui, reverse: {
                        model.reverse()
                        approach = []
                        fitKey += 1
                    }, exit: close, approach: approaching ? nil : { Task { await routeToTrack() } })
                    if let a = AlertQueue.card(alerts, driving: theme.drive) {
                        SaryAlertLane(alerts: [a], limit: 1, tapped: { _ in }, dismiss: { id in alerts.removeAll { $0.id == id } })
                    }
                    if let t = AlertQueue.toast(alerts) {
                        SaryAlertCard(alert: t).onTapGesture { alerts.removeAll { $0.id == t.id } }
                    }
                    if approaching { ProgressView().padding(theme.space(.s)).saryGlass(Capsule(), role: .control) }
                }
                .padding(.horizontal, theme.space(.m))
                /* Map chrome: the live screen's cap (the panel and the alerts grew over the whole map). */
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                /* The map runs under the status bar / Dynamic Island: its top padding is where the panel
                 * really ends on screen (was the panel's height + 70 pt, one device's status bar, measured
                 * once — an alert arriving later covered the track). */
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { topHeight = g.frame(in: .global).maxY - mapTop + 12 }
                        .onChange(of: g.frame(in: .global).maxY) { _, y in topHeight = y - mapTop + 12 }
                })
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        MapTiltButton()
                        Button {
                            followMe = true
                            fitKey += 1
                        } label: {
                            Image(systemName: "location.fill").font(.system(size: 17, weight: .bold)).frame(width: 48, height: 48)
                        }
                        .foregroundStyle(theme.palette.textPrimary)
                        .saryGlass(Circle(), role: .control, interactive: true)
                        .accessibilityLabel(Text("موقعي والمسار"))
                        .accessibilityIdentifier("follow.recenter")
                    }
                    .padding(theme.space(.m))
                }
            }
            .onChange(of: ctx.date) { _, d in model.ingest(location.lastFix, nowMs: d.timeIntervalSince1970 * 1000) }
        }
        .onAppear {
            model.onDeviation = { e in deviation(e) }
            location.watchForeground()
            model.ingest(location.lastFix, nowMs: Date().timeIntervalSince1970 * 1000)
        }
        .onChange(of: location.lastFix) { _, f in model.ingest(f, nowMs: Date().timeIntervalSince1970 * 1000) }
        .onDisappear { location.stopWatchingForeground() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("follow.screen")
    }

    private func deviation(_ e: FollowDeviation.Event) {
        switch e {
        case let .raise(m):
            let a = LiveAlertUI(id: LiveOutingController.followAlertId, kind: .offTrack(FollowDeviationAlertUI(trackName: model.subject.name, meters: m)))
            alerts.removeAll { $0.id == a.id }
            alerts.insert(a, at: 0)
            UINotificationFeedback.warning()
        case .clear: alerts.removeAll { $0.id == LiveOutingController.followAlertId }
        case .none: break
        }
    }

    /// The road route from me to the track's nearest point (same routing as «الملاحة»).
    private func routeToTrack() async {
        guard app.online else { return }
        guard let target = model.approachTarget, let f = location.lastFix else { return }
        approaching = true
        defer { approaching = false }
        let provider = RestrictedZoneGuardProvider(base: SwitchingRouteProvider(mapbox: MapboxNavRoutingProvider()))
        let req = NavRouteRequest(origin: LngLat(lng: f.lng, lat: f.lat), heading: f.heading,
                                  target: NavTarget(source: .point, name: "أقرب نقطة من المسار", position: target), options: .load())
        do {
            let plan = try await provider.routes(req)
            if let r = plan.routes.first {
                approach = r.coordinates
                fitKey += 1
            }
        } catch let e as NavRoutingError {
            alerts.insert(LiveAlertUI(id: "toast:\(UUID().uuidString)", kind: .toast(e.message)), at: 0)
        } catch {
            alerts.insert(LiveAlertUI(id: "toast:\(UUID().uuidString)", kind: .toast(NavRoutingError.failed("").message)), at: 0)
        }
    }
}
