import Combine
import SwiftUI
import UIKit

// «وضع السيارة / بث الشاشة»: the phone's own screen is mirrored to a car display (a CarTV-style
// box or an AirPlay screen) while CarPlay waits for Apple's approval. The mirrored picture is
// exactly the phone's, so the app lays itself out for a WIDE, SHORT viewport (≈2.7:1 for a
// 1280×480 car screen, ≈2:1, 16:9) when the phone is held in landscape.
//
// Off by default («متقدم» → «وضع السيارة»). Off, nothing here runs: the phone stays portrait-only
// and the live screen is the normal one. docs/CAR-MODE.md.

enum CarMode {
    static let key = "sary.carMode.v1"
    /// DEBUG: forces the mode on from a launch argument (simulator and screenshots).
    static let argument = "-SaryCarMode"
    /// DEBUG: `-SaryCarModeSize 1280x480` lays the car layer out in that viewport (letterboxed) so a
    /// phone-sized simulator previews a car screen.
    static let sizeArgument = "-SaryCarModeSize"

    static let settingsTitle = "وضع السيارة (بث الشاشة)"
    static let settingsDetail = "للي يبث شاشة الجوال على شاشة السيارة: تخطيط عريض بأزرار كبيرة. دور الجوال أفقيًا."

    static func isOn(defaults: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        #if DEBUG
        if arguments.contains(argument) { return true }
        #endif
        return defaults.bool(forKey: key)
    }

    /// DEBUG preview viewport (`-SaryCarModeSize 1280x480`); nil in release builds.
    static func previewSize(arguments: [String] = ProcessInfo.processInfo.arguments) -> CGSize? {
        #if DEBUG
        guard let i = arguments.firstIndex(of: sizeArgument), i + 1 < arguments.count else { return nil }
        return parseSize(arguments[i + 1])
        #else
        return nil
        #endif
    }

    /// «1280x480» → 1280 × 480 (also «1280×480»); nil for anything else.
    static func parseSize(_ text: String) -> CGSize? {
        let parts = text.lowercased().replacingOccurrences(of: "×", with: "x").split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w >= 200, h >= 200 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// What the app delegate allows on this device: the phone is portrait-only unless the car mode is on
    /// (the iPad keeps every orientation it always had).
    static func orientationMask(carMode: Bool, idiom: UIUserInterfaceIdiom) -> UIInterfaceOrientationMask {
        if idiom == .pad { return .all }
        return carMode ? .landscape : .portrait
    }
}

// MARK: - Layout (pure: unit-tested)

/// The car layer's sizes for one viewport. Buttons are at least 64 pt, text at least 20 pt, at every size.
struct CarModeLayout: Equatable {
    enum Kind: String { case ultraWide, wide, standard }

    static let minButton: CGFloat = 64
    static let minFont: CGFloat = 20

    var size: CGSize
    var kind: Kind
    var button: CGFloat
    var gap: CGFloat
    /// Columns the control buttons need so that none is smaller than `minButton`.
    var columns: Int
    var cardWidth: CGFloat
    var distanceFont: CGFloat
    var instructionFont: CGFloat
    var barFont: CGFloat
    var labelFont: CGFloat
    /// Whether the buttons carry a text label under the icon (only with room: not on the shortest screens).
    var showsLabels: Bool

    static func kind(for size: CGSize) -> Kind {
        guard size.height > 0 else { return .standard }
        let aspect = size.width / size.height
        if aspect >= 2.4 { return .ultraWide }
        if aspect >= 1.9 { return .wide }
        return .standard
    }

    /// `safe` is the viewport's safe area (the layout lives inside it). `buttons`: how many control buttons.
    static func make(size: CGSize, safe: EdgeInsets = EdgeInsets(), buttons: Int = 7) -> CarModeLayout {
        let usableH = max(1, size.height - safe.top - safe.bottom)
        let usableW = max(1, size.width - safe.leading - safe.trailing)
        let k = kind(for: size)
        let button = min(96, max(minButton, usableH * 0.17))
        let gap = max(10, button * 0.16)
        let perColumn = max(1, Int(((usableH + gap) / (button + gap)).rounded(.down)))
        let columns = min(3, max(1, Int((Double(buttons) / Double(perColumn)).rounded(.up))))
        let cardShare: CGFloat = k == .ultraWide ? 0.36 : (k == .wide ? 0.40 : 0.44)
        return CarModeLayout(
            size: size, kind: k, button: button, gap: gap, columns: columns,
            cardWidth: min(usableW * cardShare, 560),
            distanceFont: min(104, max(52, usableH * 0.17)),
            instructionFont: min(44, max(24, usableH * 0.07)),
            barFont: min(34, max(22, usableH * 0.052)),
            labelFont: max(minFont, min(24, usableH * 0.042)),
            showsLabels: usableH >= 520)
    }

    /// The width the control columns take (so the map keeps its camera inset on that side).
    var controlsWidth: CGFloat { CGFloat(columns) * button + CGFloat(max(0, columns - 1)) * gap + 24 }

    /// Map camera insets (left, right are PHYSICAL): the card is on the leading edge, the controls on the trailing one.
    func mapInsets(rtl: Bool) -> UIEdgeInsets {
        let card = cardWidth + 24
        let controls = controlsWidth
        return UIEdgeInsets(top: 8, left: rtl ? controls : card, bottom: 8, right: rtl ? card : controls)
    }
}

// MARK: - State

/// The switch's live value for every view (the settings row writes the same UserDefaults key).
@MainActor
final class CarModeState: ObservableObject {
    static let shared = CarModeState()

    @Published private(set) var on: Bool
    private var token: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        on = CarMode.isOn(defaults: defaults)
        token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { if let token { NotificationCenter.default.removeObserver(token) } }

    func set(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: CarMode.key)
        refresh(defaults: defaults)
    }

    func refresh(defaults: UserDefaults = .standard) {
        let now = CarMode.isOn(defaults: defaults)
        guard now != on else { return }
        on = now
        CarModeOrientation.apply(on: now)
    }
}

enum CarModeOrientation {
    /// Asks UIKit to re-read the allowed orientations and turns the phone's window to match.
    @MainActor
    static func apply(on: Bool) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication }
        guard let scene else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: on ? .landscape : .portrait)) { _ in }
    }
}

/// Whether this screen is being mirrored or sent to another display (a CarTV box, AirPlay, a cable):
/// the live screen then offers «وضع السيارة» once.
@MainActor
final class CarModeCapture: ObservableObject {
    static let shared = CarModeCapture()

    @Published private(set) var mirrored = false
    /// «لاحقًا»: not offered again until the app is launched again.
    @Published var dismissed = false
    private var tokens: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NotificationCenter.default
        for name in [UIScreen.capturedDidChangeNotification, UIScreen.didConnectNotification, UIScreen.didDisconnectNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
    }

    deinit { for t in tokens { NotificationCenter.default.removeObserver(t) } }

    func refresh() {
        mirrored = Self.isMirrored(captured: UIScreen.screens.map(\.isCaptured), screenCount: UIScreen.screens.count)
    }

    /// Pure rule (unit-tested): any captured screen, or more than one screen.
    static func isMirrored(captured: [Bool], screenCount: Int) -> Bool {
        captured.contains(true) || screenCount > 1
    }
}
