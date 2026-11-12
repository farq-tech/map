import SwiftUI

// MARK: - Lookups: «أقرب مطر» and «أقرب ربيع»

/// A lookup answered with something other than 200: the server's own Arabic reason when it gave one
/// («نجهّز صور الخضرة…»).
struct CompassLookupError: Error {
    var message: String?
}

extension WeatherLayerAPI {
    /// `GET /api/weather/rain/recent?days=1&bbox=w,s,e,n` (NASA GPM IMERG via GIBS): the rain cells around me.
    /// Only the bbox is sent (no user id), as the rain layer does.
    static func recentRainCells(bbox: String, base: URL = Endpoints.apiBase, session: URLSession = .shared) async throws -> [CompassRainCell] {
        var c = URLComponents(url: base.appendingPathComponent("api/weather/rain/recent"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "days", value: "1"), .init(name: "bbox", value: bbox)]
        var req = URLRequest(url: c.url!, timeoutInterval: 60)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw CompassLookupError(message: (try? JSONDecoder().decode(RecentRainResponse.self, from: data))?.message_ar)
        }
        let body = try JSONDecoder().decode(RecentRainResponse.self, from: data)
        return CompassRain.cells(body.grid?.cells ?? [])
    }

    /// `GET /api/weather/green/regions?bbox=w,s,e,n` (NASA VIIRS NDVI via GIBS): the spring regions around me.
    static func greenRegions(bbox: String, base: URL = Endpoints.apiBase, session: URLSession = .shared) async throws -> [GreenRegion] {
        var c = URLComponents(url: base.appendingPathComponent("api/weather/green/regions"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "bbox", value: bbox)]
        var req = URLRequest(url: c.url!, timeoutInterval: 90)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw CompassLookupError(message: (try? JSONDecoder().decode(GreenRegionsResponse.self, from: data))?.message_ar)
        }
        let body = try JSONDecoder().decode(GreenRegionsResponse.self, from: data)
        return body.regions ?? []
    }
}

/// The compass's rain / spring answers for this outing, in memory: one request per kind per 15 min
/// (or after moving ~30 km), only while the compass is on screen.
@MainActor
final class CompassNearbyStore: ObservableObject {
    struct Lookup<Value: Equatable>: Equatable {
        var value: Value?
        /// Why there is nothing to point at («ما فيه مطر قريب آخر ٢٤ ساعة»، «يحتاج إنترنت»…).
        var reason: String?
        var loading = false
        var fetchedAt: Date?
        var origin: LngLat?
    }

    @Published private(set) var rain = Lookup<[CompassRainCell]>()
    @Published private(set) var spring = Lookup<[GreenRegion]>()

    func refresh(me: LngLat, online: Bool, now: Date = Date()) {
        if !rain.loading, DestinationCompass.needsFetch(fetchedAt: rain.fetchedAt, origin: rain.origin, me: me, now: now) {
            if online { fetchRain(me) } else if rain.value == nil { rain.reason = DestinationCompass.needsInternet }
        }
        if !spring.loading, DestinationCompass.needsFetch(fetchedAt: spring.fetchedAt, origin: spring.origin, me: me, now: now) {
            if online { fetchSpring(me) } else if spring.value == nil { spring.reason = DestinationCompass.needsInternet }
        }
    }

    /// A failed lookup is tried again after about a minute (not at once, not after the full 15 min).
    private static func retryStamp() -> Date { Date().addingTimeInterval(-(DestinationCompass.cacheS - 60)) }

    private static func reason(_ error: Error, fallback: String) -> String {
        if let e = error as? CompassLookupError, let m = e.message, !m.isEmpty { return m }
        if let u = error as? URLError,
           [URLError.Code.notConnectedToInternet, .dataNotAllowed, .networkConnectionLost, .internationalRoamingOff].contains(u.code) {
            return DestinationCompass.needsInternet
        }
        return fallback
    }

    private func fetchRain(_ me: LngLat) {
        rain.loading = true
        let bbox = DestinationCompass.bbox(around: me)
        Task { [weak self] in
            do {
                let cells = try await WeatherLayerAPI.recentRainCells(bbox: bbox)
                self?.rain = Lookup(value: cells, reason: CompassRain.nearest(cells, me: me) == nil ? CompassRain.none : nil,
                                    loading: false, fetchedAt: Date(), origin: me)
            } catch {
                guard let self else { return }
                var l = self.rain
                l.loading = false
                l.fetchedAt = CompassNearbyStore.retryStamp()
                l.origin = me
                if l.value == nil { l.reason = CompassNearbyStore.reason(error, fallback: CompassRain.failed) }
                self.rain = l
            }
        }
    }

    private func fetchSpring(_ me: LngLat) {
        spring.loading = true
        let bbox = DestinationCompass.bbox(around: me)
        Task { [weak self] in
            do {
                let regions = try await WeatherLayerAPI.greenRegions(bbox: bbox)
                self?.spring = Lookup(value: regions, reason: CompassSpring.nearest(regions, me: me) == nil ? CompassSpring.none : nil,
                                      loading: false, fetchedAt: Date(), origin: me)
            } catch {
                guard let self else { return }
                var l = self.spring
                l.loading = false
                l.fetchedAt = CompassNearbyStore.retryStamp()
                l.origin = me
                if l.value == nil { l.reason = CompassNearbyStore.reason(error, fallback: CompassSpring.warming) }
                self.spring = l
            }
        }
    }
}

// MARK: - The host: targets from the live outing

/// Builds the compass from the live outing: my fix, the targets, the path for «على المسار».
/// Hidden without a recent fix (an old one would point the wrong way).
struct DestinationCompassHost: View {
    @ObservedObject var controller: LiveOutingController
    @ObservedObject var nav: NavSession
    @ObservedObject var nearby: CompassNearbyStore
    /// The person's choice for this outing (nil: the default, `DestinationCompass.resolve`).
    @Binding var chosen: DestinationCompass.Target?
    var online: Bool
    @EnvironmentObject private var location: LocationSharer

    var body: some View {
        if let raw = location.lastFix, let me = Self.position(controller.session.smoothedFix(raw)) {
            content(me: me, raw: raw)
        }
    }

    /// A fix younger than 2 min (the qibla ray's rule on this screen).
    private static func position(_ f: DeviceFix?) -> LngLat? {
        guard let f else { return nil }
        let ageMs = Date().timeIntervalSince1970 * 1000 - f.atMs
        guard ageMs >= 0, ageMs <= 120_000 else { return nil }
        return LngLat(lng: f.lng, lat: f.lat)
    }

    /// «الوجهة»: where the guidance goes, else the trip's (the current leg's, else the plan's) destination.
    private var destination: LngLat? {
        if nav.isActive, let t = nav.target { return t.position }
        return controller.tripDestination.map { LngLat(lng: $0.lng, lat: $0.lat) }
    }

    /// «الرجعة»: the start of the trail «طريق الرجعة» follows (or of my own trail when it is not running).
    private var backStart: LngLat? {
        controller.backTrack?.startPoint ?? controller.session.trail.start?.position
    }

    private func routeGuide(me: LngLat, speed: Double?, target: LngLat) -> DestinationCompass.PathGuide? {
        guard nav.phase == .guiding, let r = nav.active, r.coordinates.count >= 2 else { return nil }
        guard let g = DestinationCompass.guide(path: r.coordinates, me: me, speedMps: speed, cum: NavRouteMetrics.tables(r).cum) else { return nil }
        return DestinationCompass.addingTail(g, pathEnd: r.end, target: target)
    }

    /// Back along my trail, from where I am toward its start (what «طريق الرجعة» follows).
    private func backGuide(me: LngLat, speed: Double?) -> DestinationCompass.PathGuide? {
        let trail = controller.backTrack?.path ?? controller.session.displayTrail
        guard trail.count >= 2 else { return nil }
        return DestinationCompass.guide(path: trail.reversed().map { $0.position }, me: me, speedMps: speed)
    }

    private func refreshKey(_ me: LngLat) -> String {
        /* Looked at again when I move ~10 km, the network comes back, or a 15-min slot passes (the store's own rules decide). */
        "\(Int((me.lat * 10).rounded())),\(Int((me.lng * 10).rounded())),\(online),\(Int(Date().timeIntervalSince1970 / DestinationCompass.cacheS))"
    }

    private func note<V: Equatable>(_ l: CompassNearbyStore.Lookup<V>, none: String) -> String {
        if l.loading || (l.fetchedAt == nil && l.reason == nil) { return DestinationCompass.loading }
        return l.reason ?? none
    }

    private func content(me: LngLat, raw: DeviceFix) -> some View {
        let dest = destination
        let back = backStart
        let rainCell = nearby.rain.value.flatMap { CompassRain.nearest($0, me: me) }
        let springPick = nearby.spring.value.flatMap { CompassSpring.nearest($0, me: me) }
        var available: Set<DestinationCompass.Target> = [.qibla]
        if dest != nil { available.insert(.destination) }
        if back != nil { available.insert(.back) }
        if rainCell != nil { available.insert(.rain) }
        if springPick != nil { available.insert(.spring) }
        let returning = controller.backTrack != nil || controller.returnOrigin != nil
        let target = DestinationCompass.resolve(chosen: chosen, available: available, returning: returning)

        var point = DestinationCompass.kaaba
        var guide: DestinationCompass.PathGuide?
        var subtitle: String?
        var credit: String?
        switch target {
        case .destination:
            if let dest {
                point = dest
                guide = routeGuide(me: me, speed: raw.speed, target: dest)
            }
        case .back:
            if let back {
                point = back
                guide = backGuide(me: me, speed: raw.speed)
            }
        case .qibla:
            break
        case .rain:
            if let rainCell {
                point = rainCell.position
                subtitle = CompassRain.line(rainCell)
                credit = CompassRain.credit
            }
        case .spring:
            if let springPick {
                point = springPick.point
                subtitle = CompassSpring.line(springPick)
                credit = CompassSpring.credit
            }
        }
        let reading = DestinationCompass.reading(me: me, course: raw.heading, speed: raw.speed, target: point, kind: target, guide: guide)
        let detail = [subtitle, credit].compactMap { $0 }.joined(separator: " · ")

        let options: [DestinationCompassView.Option] = [
            .init(target: .destination, enabled: dest != nil, note: dest == nil ? DestinationCompass.noDestination : nil),
            .init(target: .back, enabled: back != nil, note: back == nil ? DestinationCompass.noTrail : nil),
            .init(target: .qibla, enabled: true, note: nil),
            .init(target: .rain, enabled: rainCell != nil,
                  note: rainCell.map { "\(CompassRain.line($0)) · \(CompassRain.credit)" } ?? note(nearby.rain, none: CompassRain.none)),
            .init(target: .spring, enabled: springPick != nil,
                  note: springPick.map { "\(CompassSpring.line($0)) · \(CompassSpring.credit)" } ?? note(nearby.spring, none: CompassSpring.none)),
        ]

        return DestinationCompassView(reading: reading, subtitle: subtitle, accessibility: DestinationCompass.accessibility(reading, detail: detail),
                                      options: options, pick: { chosen = $0 })
            .chromeFrame("compass")
            .task(id: refreshKey(me)) { nearby.refresh(me: me, online: online) }
    }
}

// MARK: - The dial

/// The round compass (owner-approved mockup): the rose («ش ق ج غ» and ticks) turns with the car, the
/// orange needle leads to the target (along the path when there is one), a small grey dot on the ring
/// shows the target itself in a straight line, the distance in the middle, the target's name under the
/// dial. One tap target: the dial opens the choice of target. Never mirrored by the RTL layout.
struct DestinationCompassView: View {
    struct Option: Identifiable, Equatable {
        var target: DestinationCompass.Target
        var enabled: Bool
        /// A line under the option: why it is off, or what it points at.
        var note: String?
        var id: String { target.rawValue }
    }

    var reading: DestinationCompass.Reading
    var subtitle: String?
    var accessibility: String
    var options: [Option]
    var pick: (DestinationCompass.Target) -> Void
    @Environment(\.sary) private var theme
    /// Accumulated angles (`DestinationCompass.unwrap`): 359° → 1° turns 2°, never back round.
    @State private var rose: Double?
    @State private var needle: Double?
    @State private var marker: Double?

    static let dial: CGFloat = 112

    private struct Letter: Hashable {
        var text: String
        var deg: Double
    }

    private static let letters = [Letter(text: "ش", deg: 0), Letter(text: "ق", deg: 90), Letter(text: "ج", deg: 180), Letter(text: "غ", deg: 270)]

    var body: some View {
        Menu {
            ForEach(options) { o in
                Button { pick(o.target) } label: {
                    Label {
                        Text(DestinationCompass.title(o.target))
                        if let n = o.note { Text(n) }
                    } icon: {
                        Image(systemName: o.target == reading.target ? "checkmark" : DestinationCompass.icon(o.target))
                    }
                }
                .disabled(!o.enabled)
                .accessibilityIdentifier("live.compass.\(o.target.rawValue)")
            }
        } label: {
            VStack(spacing: 6) {
                dialView
                chip
                if let subtitle {
                    Text(subtitle)
                        .saryText(.micro, weight: .medium)
                        .foregroundStyle(theme.palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: 150)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .saryGlass(RoundedRectangle(cornerRadius: 10, style: .continuous), role: .chrome)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibility))
        .accessibilityHint(Text("اضغط تختار وين تأشر البوصلة: الوجهة، الرجعة، القبلة، أقرب مطر، أقرب ربيع"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("live.compass")
        .onChange(of: reading.roseDegrees) { _, v in
            withAnimation(theme.animation(.smooth)) { rose = DestinationCompass.unwrap(previous: rose ?? v, next: v) }
        }
        .onChange(of: reading.needleDegrees) { _, v in
            withAnimation(theme.animation(.smooth)) { needle = DestinationCompass.unwrap(previous: needle ?? v, next: v) }
        }
        .onChange(of: reading.markerDegrees) { _, v in
            guard let v else { return }
            withAnimation(theme.animation(.smooth)) { marker = DestinationCompass.unwrap(previous: marker ?? v, next: v) }
        }
    }

    private var dialView: some View {
        let p = theme.palette
        let d = Self.dial
        let roseAngle = rose ?? reading.roseDegrees
        let needleAngle = needle ?? reading.needleDegrees
        return ZStack {
            ZStack {
                ForEach(0..<24, id: \.self) { i in
                    Capsule()
                        .fill(i % 6 == 0 ? p.textPrimary : p.textTertiary)
                        .frame(width: i % 6 == 0 ? 2.5 : 1.5, height: i % 6 == 0 ? 9 : 5)
                        .offset(y: -(d / 2 - 9))
                        .rotationEffect(.degrees(Double(i) * 15))
                }
                ForEach(Self.letters, id: \.self) { l in
                    Text(l.text)
                        .font(.sary(13, .heavy))
                        .foregroundStyle(l.deg == 0 ? p.accentText : p.textSecondary)
                        /* The letters stay upright while the rose turns. */
                        .rotationEffect(.degrees(-(l.deg + roseAngle)))
                        .offset(y: -(d / 2 - 23))
                        .rotationEffect(.degrees(l.deg))
                }
            }
            .rotationEffect(.degrees(roseAngle))
            if let m = reading.markerDegrees {
                /* The target itself, in a straight line (only while a path leads the needle). */
                Circle()
                    .fill(p.textSecondary)
                    .frame(width: 7, height: 7)
                    .offset(y: -(d / 2 - 4))
                    .rotationEffect(.degrees(marker ?? m))
            }
            CompassNeedleShape()
                .fill(p.accent)
                .frame(width: 16, height: 20)
                .offset(y: -(d / 2 - 15))
                .rotationEffect(.degrees(needleAngle))
            VStack(spacing: 0) {
                Text(SaryFormat.distance(meters: reading.distanceM))
                    .saryNumber(.headline, weight: .heavy)
                    .foregroundStyle(p.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(DestinationCompass.caption(reading))
                    .saryText(.micro, weight: .medium)
                    .foregroundStyle(reading.offPath ? p.warningText : p.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 4)
            .frame(width: 64, height: 64)
            .background(Circle().fill(p.chromeOpaque))
        }
        .frame(width: d, height: d)
        .saryGlass(Circle(), role: .control)
        /* A real-world direction: never mirrored by the RTL layout. */
        .environment(\.layoutDirection, .leftToRight)
    }

    private var chip: some View {
        let p = theme.palette
        return HStack(spacing: 4) {
            Text(DestinationCompass.title(reading.target))
                .saryText(.caption, weight: .bold)
                .foregroundStyle(p.textPrimary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(p.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .saryGlass(Capsule(), role: .chrome)
    }
}

/// The needle's head: an arrowhead pointing up.
private struct CompassNeedleShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY - r.height * 0.3))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
