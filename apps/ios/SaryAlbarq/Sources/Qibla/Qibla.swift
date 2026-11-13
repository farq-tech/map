import CoreLocation
import SwiftUI
import UIKit

enum QiblaLocationState: Equatable {
    case locating
    case denied
    case failed

    static func authorization(_ status: CLAuthorizationStatus) -> Self {
        switch status {
        case .notDetermined, .authorizedAlways, .authorizedWhenInUse: return .locating
        case .restricted, .denied: return .denied
        @unknown default: return .failed
        }
    }

    static func failure(_ error: Error) -> Self {
        (error as? CLError)?.code == .denied ? .denied : .failed
    }
}

/// «القبلة»: the direction of the Kaaba from where the person stands.
enum Qibla {
    /// The Kaaba, Makkah.
    static let kaaba = CLLocationCoordinate2D(latitude: 21.4225, longitude: 39.8262)

    /// Great-circle initial bearing (degrees from true north, 0..<360) from `from` to the Kaaba.
    static func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D = kaaba) -> Double {
        let φ1 = from.latitude * .pi / 180
        let φ2 = to.latitude * .pi / 180
        let Δλ = (to.longitude - from.longitude) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return normalize(atan2(y, x) * 180 / .pi)
    }

    /// Great-circle distance in km (haversine, mean Earth radius).
    static func distanceKm(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D = kaaba) -> Double {
        let φ1 = from.latitude * .pi / 180
        let φ2 = to.latitude * .pi / 180
        let dφ = φ2 - φ1
        let dλ = (to.longitude - from.longitude) * .pi / 180
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * 6371.0088 * asin(min(1, sqrt(h)))
    }

    static func normalize(_ d: Double) -> Double {
        let r = d.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// How far to turn (−180..<180, + = clockwise) so the top of the phone points at the Qibla.
    static func turn(qibla: Double, heading: Double) -> Double {
        let d = normalize(qibla - heading)
        return d >= 180 ? d - 360 : d
    }

    /// Facing the Qibla within this many degrees.
    static let alignedWithin = 5.0

    /// The compass's design size (pointer + rose) on a standard phone.
    static let compassDesign = CGSize(width: 300, height: 320)

    /// Scale (0.72…1) for the compass in a `page`-sized sheet: full size whenever it fits
    /// (every 390 pt+ phone), smaller when the width or the height left after the header,
    /// degrees and hint (`reservedHeight`) is short, e.g. an SE's 375×667.
    static func compassScale(page: CGSize, sideMargins: CGFloat = 40, reservedHeight: CGFloat = 340) -> CGFloat {
        guard page.width > 0, page.height > 0 else { return 1 }
        let byWidth = (page.width - sideMargins) / compassDesign.width
        let byHeight = (page.height - reservedHeight) / compassDesign.height
        return min(1, max(0.72, min(byWidth, byHeight)))
    }
    /// A heading accuracy worse than this (degrees) asks for calibration.
    static let poorAccuracy = 20.0

    enum Calibration: Equatable {
        case good
        case poor
        /// No compass reading at all (simulator, no magnetometer, or not yet).
        case unavailable
    }

    /// CoreLocation's `headingAccuracy`: negative = invalid.
    static func calibration(accuracy: Double?) -> Calibration {
        guard let a = accuracy else { return .unavailable }
        if a < 0 { return .unavailable }
        return a > poorAccuracy ? .poor : .good
    }

    /// «اتجاه ٢٤٤° من الشمال».
    static func degreesLabel(_ d: Double) -> String {
        "\(SaryFormat.number(Int(d.rounded()) % 360))°"
    }

    /// Continuous dial angle: the previous unwrapped value plus the shortest step to `next`.
    static func unwrap(previous: Double?, next: Double) -> Double {
        guard let p = previous else { return normalize(next) }
        return p + turn(qibla: next, heading: p)
    }

    /// Facing the Qibla, with hysteresis: in at `alignedWithin`, out only past `alignedLeave`,
    /// so a hand's tremble at the edge never buzzes again and again.
    static let alignedLeave = 8.0
    static func aligned(turn: Double, was: Bool) -> Bool {
        abs(turn) <= (was ? alignedLeave : alignedWithin)
    }

    static func turnHint(_ turn: Double) -> String {
        let a = abs(turn)
        if a <= alignedWithin { return "أنت مقابل القبلة" }
        let n = SaryFormat.number(Int(a.rounded()))
        return turn > 0 ? "لِف يمين \(n)°" : "لِف يسار \(n)°"
    }
}

/// The dial's motion: an interpolating spring keeps its velocity when the next reading
/// retargets it mid-way, so a stream of compass readings reads as one smooth turn.
enum QiblaDial {
    static let spring: Animation = .interpolatingSpring(stiffness: 140, damping: 22)
}

/// Live heading (true north) and position for «القبلة». Uses its own `CLLocationManager`
/// (When-In-Use is enough; the app already has it for the outing).
@MainActor
final class QiblaCompass: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var heading: Double? {
        didSet { dialHeading = heading.map { Qibla.unwrap(previous: dialHeading, next: $0) } }
    }
    /// `heading` made continuous (359° → 1° is +2°, never −358°), for the dial's rotation: a
    /// spring then turns the rose and needle the short way instead of spinning round.
    @Published private(set) var dialHeading: Double?
    @Published private(set) var accuracy: Double?
    /// True north when CoreLocation has a location fix; magnetic otherwise.
    @Published private(set) var isTrueNorth = false
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var locationState: QiblaLocationState = .locating

    private let manager = CLLocationManager()
    /// Between `start()` and `stop()` (the screen is up). iOS also reports authorization changes after
    /// the screen closed (the permission prompt answered late): those must not restart the GPS.
    private(set) var isRunning = false
    private var locationTimeout: Task<Void, Never>?
    #if DEBUG
    private var simulatedLocationState: QiblaLocationState?
    #endif

    init(fallback: CLLocationCoordinate2D? = nil) {
        coordinate = fallback
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.headingFilter = 1
        manager.headingOrientation = .portrait
        #if DEBUG
        let a = ProcessInfo.processInfo.arguments
        func arg(_ k: String) -> Double? { a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? Double(a[$0 + 1]) : nil } }
        if let h = arg("-SaryQiblaHeading") {
            heading = h
            accuracy = arg("-SaryQiblaAccuracy") ?? 5
            isTrueNorth = true
        }
        if let lat = arg("-SaryQiblaLat"), let lng = arg("-SaryQiblaLng") { coordinate = .init(latitude: lat, longitude: lng) }
        if let i = a.firstIndex(of: "-SaryQiblaLocationState"), i + 1 < a.count {
            switch a[i + 1] {
            /* A simulated refusal / failure means no position: the outing's fallback fix must not hide it (UI tests, shots). */
            case "denied": simulatedLocationState = .denied; locationState = .denied; coordinate = nil
            case "failed": simulatedLocationState = .failed; locationState = .failed; coordinate = nil
            default: break
            }
        }
        #endif
    }

    func start() {
        isRunning = true
        #if DEBUG
        if simulatedLocationState != nil {
            if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
            return
        }
        #endif
        switch manager.authorizationStatus {
        case .notDetermined:
            locationState = .locating
            manager.requestWhenInUseAuthorization()
        case .restricted, .denied:
            locationState = .denied
        case .authorizedAlways, .authorizedWhenInUse:
            beginLocationRequest()
        @unknown default:
            locationState = .failed
        }
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    func retryLocation() {
        #if DEBUG
        if simulatedLocationState != nil {
            locationState = .locating
            scheduleLocationTimeout()
            return
        }
        #endif
        guard manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse else {
            locationState = .denied
            return
        }
        beginLocationRequest()
    }

    private func beginLocationRequest() {
        guard isRunning else { return }
        locationState = .locating
        manager.startUpdatingLocation()
        scheduleLocationTimeout()
    }

    private func scheduleLocationTimeout() {
        locationTimeout?.cancel()
        locationTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, self.coordinate == nil, self.locationState == .locating else { return }
            self.locationState = .failed
        }
    }

    func stop() {
        isRunning = false
        locationTimeout?.cancel()
        locationTimeout = nil
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { return }
        Task { @MainActor in
            self.coordinate = c
            self.locationTimeout?.cancel()
            self.locationState = .locating
            /* A kilometre is plenty for a direction; stop the GPS, keep the compass. */
            self.manager.stopUpdatingLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading h: CLHeading) {
        let trueH = h.trueHeading
        let mag = h.magneticHeading
        let acc = h.headingAccuracy
        Task { @MainActor in
            self.isTrueNorth = trueH >= 0
            self.heading = trueH >= 0 ? trueH : mag
            self.accuracy = acc
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            #if DEBUG
            // Keep the UI-test location state deterministic even when the simulator has
            // a persisted authorization choice from an earlier test.
            if self.simulatedLocationState != nil { return }
            #endif
            switch QiblaLocationState.authorization(status) {
            case .locating where status != .notDetermined:
                if self.coordinate == nil { self.beginLocationRequest() }
            case .denied:
                self.locationTimeout?.cancel()
                self.locationState = .denied
            case .locating:
                self.locationState = .locating
            case .failed:
                self.locationState = .failed
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let state = QiblaLocationState.failure(error)
        Task { @MainActor in
            self.locationTimeout?.cancel()
            self.locationState = state
        }
    }

    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool { false }
}

/// The «القبلة» sheet: an arrow to the Kaaba over a compass rose turning with the phone.
struct QiblaView: View {
    @StateObject private var compass: QiblaCompass
    var close: () -> Void
    @Environment(\.sary) private var theme
    /// Facing the Qibla (`Qibla.aligned`, with hysteresis).
    @State private var facing = false

    init(fallback: CLLocationCoordinate2D?, close: @escaping () -> Void) {
        _compass = StateObject(wrappedValue: QiblaCompass(fallback: fallback))
        self.close = close
    }

    var body: some View {
        GeometryReader { geo in page(scale: Qibla.compassScale(page: geo.size)) }
            .onAppear { compass.start() }
            .onDisappear { compass.stop() }
    }

    private func page(scale: CGFloat) -> some View {
        let p = theme.palette
        return SaryPage(title: "القبلة", close: close) {
            VStack(spacing: theme.space(.l)) {
                if let c = compass.coordinate {
                    content(c, scale: scale)
                } else if NewUI.enabled {
                    newState(scale: scale)
                } else {
                    VStack(spacing: theme.space(.m)) {
                        if compass.locationState == .locating {
                            ProgressView()
                            Text("ننتظر موقعك لنحسب اتجاه القبلة").saryText(.body).foregroundStyle(p.textSecondary)
                                .accessibilityIdentifier("qibla.waiting")
                        } else if compass.locationState == .denied {
                            Image(systemName: "location.slash.fill").font(.system(size: 28)).foregroundStyle(p.warning)
                            Text("اسمح للموقع لنحسب اتجاه القبلة").saryText(.body).foregroundStyle(p.textPrimary)
                                .accessibilityIdentifier("qibla.location-denied")
                            Button {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            } label: {
                                Label("إعدادات الموقع", systemImage: "gearshape.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("qibla.open-settings")
                        } else {
                            Image(systemName: "location.circle").font(.system(size: 28)).foregroundStyle(p.warning)
                            Text("ما قدرنا نحدد موقعك الآن").saryText(.body).foregroundStyle(p.textPrimary)
                                .accessibilityIdentifier("qibla.location-error")
                            Button("حاول مرة ثانية") { compass.retryLocation() }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("qibla.retry")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: Qibla.compassDesign.height * scale)
                }
            }
        }
    }

    /// Build 47: no location yet, from the shared screen components: an icon in a circle, ONE Najdi line, one primary button.
    @ViewBuilder
    private func newState(scale: CGFloat) -> some View {
        let p = theme.palette
        Group {
            switch compass.locationState {
            case .locating:
                VStack(spacing: theme.space(.l)) {
                    SarySkeleton(shape: .circle, width: 72, height: 72)
                    Text("ننتظر موقعك لنحسب اتجاه القبلة").saryType(.headline).foregroundStyle(p.textSecondary)
                        .multilineTextAlignment(.center).accessibilityIdentifier("qibla.waiting")
                }
                .padding(.horizontal, theme.space(.l))
            case .denied:
                SaryScreenState(kind: .empty, systemImage: "location.slash.fill", message: "اسمح للموقع لنحسب اتجاه القبلة",
                                actionTitle: "إعدادات الموقع", actionID: "qibla.open-settings", messageID: "qibla.location-denied") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            default:
                SaryScreenState(kind: .error, systemImage: "location.circle", message: "ما قدرنا نحدد موقعك الآن، حاول مرة ثانية",
                                actionTitle: "حاول مرة ثانية", actionID: "qibla.retry", messageID: "qibla.location-error") { compass.retryLocation() }
            }
        }
        .frame(maxWidth: .infinity, minHeight: Qibla.compassDesign.height * scale)
    }

    @ViewBuilder
    private func content(_ c: CLLocationCoordinate2D, scale: CGFloat) -> some View {
        let p = theme.palette
        let q = Qibla.bearing(from: c)
        let cal = Qibla.calibration(accuracy: compass.heading == nil ? nil : compass.accuracy)
        let heading = compass.heading ?? 0
        /* Continuous: the spring turns the short way across north. */
        let dial = compass.dialHeading ?? heading
        let turn = Qibla.turn(qibla: q, heading: heading)
        let aligned = compass.heading != nil && facing

        VStack(spacing: theme.space(.xs)) {
            Text(Qibla.degreesLabel(q))
                .font(NewUI.enabled ? .system(size: 52, weight: .bold, design: .rounded).monospacedDigit() : .sary(44, .bold))
                .foregroundStyle(p.textPrimary)
                .accessibilityIdentifier("qibla.degrees")
            Text("اتجاه القبلة من الشمال الحقيقي · مكة على بعد \(SaryFormat.number(Int(Qibla.distanceKm(from: c).rounded()))) كم")
                .saryText(.footnote).foregroundStyle(p.textSecondary)
                .multilineTextAlignment(.center)
        }

        ZStack {
            /* The rose turns with the phone: north stays north. */
            QiblaRose(qibla: q, diameter: QiblaRose.designDiameter * scale)
                .rotationEffect(.degrees(-dial))
            /* The fixed pointer at the top: line it up with the Kaaba. */
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(aligned ? p.liveText : p.textPrimary)
                .offset(y: -150 * scale)
            Image(systemName: "location.north.fill")
                .font(.system(size: 64 * scale, weight: .bold))
                .foregroundStyle(aligned ? p.liveText : p.accent)
                /* q − dial equals `turn` modulo 360 but never jumps at ±180°. */
                .rotationEffect(.degrees(compass.heading == nil ? q : q - dial))
                .accessibilityHidden(true)
        }
        .frame(width: Qibla.compassDesign.width * scale, height: Qibla.compassDesign.height * scale)
        /* A damped spring per heading reading (not per frame): the needle settles instead of
           twitching with each degree; a short fade-like ease under Reduce Motion. */
        .animation(theme.reduceMotion ? SaryMotion.reduced : QiblaDial.spring, value: dial)
        .saryAnimation(.snappy, value: aligned)
        .onChange(of: turn) { _, t in facing = Qibla.aligned(turn: t, was: facing) }
        .onAppear { facing = Qibla.aligned(turn: turn, was: false) }
        /* Lined up: one soft tap (again only after leaving the Qibla past the hysteresis). */
        .saryHaptic(.confirm, trigger: aligned) { was, now in !was && now }
        .accessibilityElement()
        .accessibilityLabel(Text(compass.heading == nil ? "اتجاه القبلة \(Qibla.degreesLabel(q)) من الشمال" : Qibla.turnHint(turn)))
        .accessibilityIdentifier("qibla.compass")

        Group {
            switch cal {
            case .unavailable:
                hint("location.north.circle", "البوصلة غير متوفرة الحين. وجّه أعلى الجوال \(Qibla.degreesLabel(q)) من الشمال.", tone: p.textSecondary)
            case .poor:
                hint("exclamationmark.triangle.fill", "دقة البوصلة ضعيفة: حرّك الجوال على شكل رقم ٨ وابعده عن الحديد والسيارة.", tone: p.warningText)
                    .accessibilityIdentifier("qibla.calibrate")
            case .good:
                Text(Qibla.turnHint(turn))
                    .saryText(.headline, weight: .bold)
                    .foregroundStyle(aligned ? p.liveText : p.textPrimary)
                    .accessibilityIdentifier("qibla.turn")
            }
        }
        if compass.heading != nil && !compass.isTrueNorth {
            Text("الاتجاه حسب الشمال المغناطيسي (ما وصل الموقع بعد)").saryText(.caption).foregroundStyle(p.textTertiary)
        }
    }

    private func hint(_ icon: String, _ text: String, tone: Color) -> some View {
        HStack(alignment: .top, spacing: theme.space(.s)) {
            Image(systemName: icon).foregroundStyle(tone)
            Text(text).saryText(.footnote, weight: .medium).foregroundStyle(theme.palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(theme.space(.m))
        .sarySurface(radius: SaryRadius.m)
    }
}

/// A compass rose (N/E/S/W in Arabic, ticks every 10°) with the Kaaba marked at `qibla`.
struct QiblaRose: View {
    var qibla: Double
    /// Rose diameter; every radius below is a fraction of the 280 pt design.
    var diameter: CGFloat = designDiameter
    static let designDiameter: CGFloat = 280
    struct Cardinal { var angle: Double; var label: String }
    static let cardinals = [Cardinal(angle: 0, label: "ش"), Cardinal(angle: 90, label: "ق"), Cardinal(angle: 180, label: "ج"), Cardinal(angle: 270, label: "غ")]
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let k = diameter / Self.designDiameter
        ZStack {
            Circle().fill(p.sunken.opacity(0.6))
            Circle().stroke(p.separator, lineWidth: 1.5)
            ForEach(0..<36, id: \.self) { i in
                Rectangle()
                    .fill(i % 9 == 0 ? p.textPrimary : p.textTertiary)
                    .frame(width: i % 9 == 0 ? 3 : 1.5, height: i % 9 == 0 ? 14 : 8)
                    .offset(y: -128 * k)
                    .rotationEffect(.degrees(Double(i) * 10))
            }
            ForEach(Self.cardinals, id: \.angle) { c in
                let a = c.angle
                Text(c.label)
                    .font(.sary(16, .bold))
                    .foregroundStyle(a == 0 ? p.emergencyText : p.textSecondary)
                    .rotationEffect(.degrees(-a))
                    .offset(y: -104 * k)
                    .rotationEffect(.degrees(a))
            }
            /* The Kaaba on the rim. */
            Image(systemName: "cube.fill")
                .font(.system(size: 18))
                .foregroundStyle(p.textPrimary)
                .padding(6)
                .background(Circle().fill(p.accent.opacity(0.25)))
                .rotationEffect(.degrees(-qibla))
                .offset(y: -150 * k)
                .rotationEffect(.degrees(qibla))
        }
        .frame(width: diameter, height: diameter)
        .environment(\.layoutDirection, .leftToRight)
    }
}
