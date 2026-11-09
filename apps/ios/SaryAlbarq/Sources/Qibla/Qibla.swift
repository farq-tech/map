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

    static func turnHint(_ turn: Double) -> String {
        let a = abs(turn)
        if a <= alignedWithin { return "أنت مقابل القبلة" }
        let n = SaryFormat.number(Int(a.rounded()))
        return turn > 0 ? "لِف يمين \(n)°" : "لِف يسار \(n)°"
    }
}

/// Live heading (true north) and position for «القبلة». Uses its own `CLLocationManager`
/// (When-In-Use is enough; the app already has it for the outing).
@MainActor
final class QiblaCompass: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var heading: Double?
    @Published private(set) var accuracy: Double?
    /// True north when CoreLocation has a location fix; magnetic otherwise.
    @Published private(set) var isTrueNorth = false
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var locationState: QiblaLocationState = .locating

    private let manager = CLLocationManager()
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
            case "denied": simulatedLocationState = .denied; locationState = .denied
            case "failed": simulatedLocationState = .failed; locationState = .failed
            default: break
            }
        }
        #endif
    }

    func start() {
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

    init(fallback: CLLocationCoordinate2D?, close: @escaping () -> Void) {
        _compass = StateObject(wrappedValue: QiblaCompass(fallback: fallback))
        self.close = close
    }

    var body: some View {
        let p = theme.palette
        SaryPage(title: "القبلة", close: close) {
            VStack(spacing: theme.space(.l)) {
                if let c = compass.coordinate {
                    content(c)
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
                    .frame(maxWidth: .infinity, minHeight: 320)
                }
            }
        }
        .onAppear { compass.start() }
        .onDisappear { compass.stop() }
    }

    @ViewBuilder
    private func content(_ c: CLLocationCoordinate2D) -> some View {
        let p = theme.palette
        let q = Qibla.bearing(from: c)
        let cal = Qibla.calibration(accuracy: compass.heading == nil ? nil : compass.accuracy)
        let heading = compass.heading ?? 0
        let turn = Qibla.turn(qibla: q, heading: heading)
        let aligned = compass.heading != nil && abs(turn) <= Qibla.alignedWithin

        VStack(spacing: theme.space(.xs)) {
            Text(Qibla.degreesLabel(q))
                .font(.sary(44, .bold))
                .foregroundStyle(p.textPrimary)
                .accessibilityIdentifier("qibla.degrees")
            Text("اتجاه القبلة من الشمال الحقيقي · مكة على بعد \(SaryFormat.number(Int(Qibla.distanceKm(from: c).rounded()))) كم")
                .saryText(.footnote).foregroundStyle(p.textSecondary)
                .multilineTextAlignment(.center)
        }

        ZStack {
            /* The rose turns with the phone: north stays north. */
            QiblaRose(qibla: q)
                .rotationEffect(.degrees(-heading))
            /* The fixed pointer at the top: line it up with the Kaaba. */
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(aligned ? p.liveText : p.textPrimary)
                .offset(y: -150)
            Image(systemName: "location.north.fill")
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(aligned ? p.liveText : p.accent)
                .rotationEffect(.degrees(compass.heading == nil ? q : turn))
                .accessibilityHidden(true)
        }
        .frame(width: 300, height: 320)
        .animation(.easeOut(duration: 0.25), value: heading)
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
    struct Cardinal { var angle: Double; var label: String }
    static let cardinals = [Cardinal(angle: 0, label: "ش"), Cardinal(angle: 90, label: "ق"), Cardinal(angle: 180, label: "ج"), Cardinal(angle: 270, label: "غ")]
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        ZStack {
            Circle().fill(p.sunken.opacity(0.6))
            Circle().stroke(p.separator, lineWidth: 1.5)
            ForEach(0..<36, id: \.self) { i in
                Rectangle()
                    .fill(i % 9 == 0 ? p.textPrimary : p.textTertiary)
                    .frame(width: i % 9 == 0 ? 3 : 1.5, height: i % 9 == 0 ? 14 : 8)
                    .offset(y: -128)
                    .rotationEffect(.degrees(Double(i) * 10))
            }
            ForEach(Self.cardinals, id: \.angle) { c in
                let a = c.angle
                Text(c.label)
                    .font(.sary(16, .bold))
                    .foregroundStyle(a == 0 ? p.emergencyText : p.textSecondary)
                    .rotationEffect(.degrees(-a))
                    .offset(y: -104)
                    .rotationEffect(.degrees(a))
            }
            /* The Kaaba on the rim. */
            Image(systemName: "cube.fill")
                .font(.system(size: 18))
                .foregroundStyle(p.textPrimary)
                .padding(6)
                .background(Circle().fill(p.accent.opacity(0.25)))
                .rotationEffect(.degrees(-qibla))
                .offset(y: -150)
                .rotationEffect(.degrees(qibla))
        }
        .frame(width: 280, height: 280)
        .environment(\.layoutDirection, .leftToRight)
    }
}
