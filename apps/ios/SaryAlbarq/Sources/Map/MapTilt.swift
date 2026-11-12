@_spi(Experimental) import MapboxMaps
import SwiftUI
import UIKit

// The map's camera tilt (owner, Build 45): the person no longer tilts the map with two fingers on any map; ONE
// «٣د» / «٢د» button in the map's permanent control column does it instead. Pan, pinch zoom and rotation stay.
// Pure rules here (unit-tested in `MapTiltTests`), the persisted choice, one shared button and the binding every
// Mapbox map uses to follow the choice. Programmatic cameras (follow camera, fits, `MapCameraRequest`) keep
// controlling pitch exactly as before; only this button and the existing automatic rules change it.

/// Which pitch choice a map is in. Each has its own remembered 2D / 3D choice.
enum CameraTiltMode: String, CaseIterable, Equatable {
    /// A map you look at: the outing standing / exploring, the plan map, solo «اتجه», following a track, the legacy home map.
    case overview
    /// The idle navigation map (the one map without a trip, `sary.oneMap`): its look is 3D from the start.
    case idle
    /// «باتجاهي»: the heading-up follow camera (navigation and driving).
    case navigation
}

enum CameraTiltRules {
    /// The ease between 2D and 3D.
    static let duration: TimeInterval = 0.4
    /// The pitch of 3D while following my heading (`FollowZoom.headingPitch`).
    static let navigation3D = FollowZoom.headingPitch
    /// The pitch of 3D on a map you look at (the idle map's 40°).
    static let overview3D = IdleMapRules.pitch

    /// What the person sees before they ever press the button.
    static func default3D(_ mode: CameraTiltMode) -> Bool { mode != .overview }

    /// The pitch (degrees) for a choice. 2D is top-down. Looking maps tilt less in Low Power Mode / a hot phone.
    static func pitch(mode: CameraTiltMode, is3D: Bool, lowPower: Bool = false, thermalHot: Bool = false) -> Double {
        guard is3D else { return 0 }
        switch mode {
        case .navigation: return navigation3D
        case .overview, .idle: return IdleMapRules.idlePitch(lowPower: lowPower, thermalHot: thermalHot)
        }
    }

    /// The mode a map is in: heading-up follow wins, then the idle map, else a map you look at.
    static func mode(heading: Bool, idle: Bool) -> CameraTiltMode {
        heading ? .navigation : (idle ? .idle : .overview)
    }

    /// The button names the view a tap leads to (as Apple Maps does): «٣د» while flat, «٢د» while tilted.
    static func glyph(is3D: Bool) -> String { is3D ? "٢د" : "٣د" }
    /// The button's icon: the view a tap leads to (SF Symbols `view.2d` / `view.3d`).
    static func symbol(is3D: Bool) -> String { is3D ? "view.2d" : "view.3d" }
    static let label = "٣د / ٢د"
    static func hint(is3D: Bool) -> String { is3D ? "اعرض الخريطة من الأعلى" : "اعرض الخريطة مائلة بثلاثة أبعاد" }
    static func value(is3D: Bool) -> String { is3D ? "ثلاثي الأبعاد" : "من الأعلى" }

    /// Rounded for the debug readout / tests: a settled pitch counts as 3D above this.
    static let threeDThreshold = 5.0
}

/// The remembered 2D / 3D choice per mode (UserDefaults on this phone, like the other map preferences).
final class MapTiltModel: ObservableObject {
    static let shared = MapTiltModel()
    static let changed = Notification.Name("sary.map.tilt.changed")
    static func key(_ m: CameraTiltMode) -> String { "sary.map.tilt3d.\(m.rawValue).v1" }

    private let defaults: UserDefaults
    /// Bumped on every change so SwiftUI hosts re-render.
    @Published private(set) var revision = 0
    /// The idle navigation map is on screen (its mode is `.idle`, not `.overview`).
    var idleHome = false
    /// DEBUG / UI tests: the pitch of the last settled map (rounded degrees), for `-SaryUITest` readouts.
    @Published private(set) var settledPitch = 0

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func is3D(_ m: CameraTiltMode) -> Bool {
        defaults.object(forKey: Self.key(m)) as? Bool ?? CameraTiltRules.default3D(m)
    }

    func set(_ m: CameraTiltMode, _ on: Bool) {
        guard is3D(m) != on else { return }
        defaults.set(on, forKey: Self.key(m))
        revision += 1
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func toggle(_ m: CameraTiltMode) { set(m, !is3D(m)) }

    /// The mode a map without a follow camera is in right now.
    var lookingMode: CameraTiltMode { CameraTiltRules.mode(heading: false, idle: idleHome) }

    func pitch(_ m: CameraTiltMode) -> Double {
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        return CameraTiltRules.pitch(mode: m, is3D: is3D(m), lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermalHot: hot)
    }

    func reportSettled(pitch: Double) {
        #if DEBUG
        let r = Int(pitch.rounded())
        if r != settledPitch { settledPitch = r }
        #endif
    }
}

/// Keeps one Mapbox map's pitch on the person's choice. A map whose follow camera drives the pitch every frame says so
/// through `external` (it returns true after taking the change itself); otherwise the pitch eases here.
final class MapTiltBinding {
    private weak var map: MapView?
    private let mode: () -> CameraTiltMode
    private let external: () -> Bool
    private var observer: NSObjectProtocol?
    private var idle: AnyCancelable?
    private var moved: AnyCancelable?
    private var reportPending = false

    init(map: MapView, mode: @escaping () -> CameraTiltMode, external: @escaping () -> Bool = { false }) {
        self.map = map
        self.mode = mode
        self.external = external
        observer = NotificationCenter.default.addObserver(forName: MapTiltModel.changed, object: nil, queue: .main) { [weak self] _ in
            self?.changed()
        }
        idle = map.mapboxMap.onMapIdle.observe { [weak map] _ in
            guard let map else { return }
            MapTiltModel.shared.reportSettled(pitch: map.mapboxMap.cameraState.pitch)
        }
        #if DEBUG
        /* A follow camera moves every frame and the map never goes idle: report the pitch at most 4 times a second as well. */
        moved = map.mapboxMap.onCameraChanged.observe { [weak self] _ in
            guard let self, !self.reportPending else { return }
            self.reportPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, let map = self.map else { return }
                self.reportPending = false
                MapTiltModel.shared.reportSettled(pitch: map.mapboxMap.cameraState.pitch)
            }
        }
        #endif
        /* A remembered 3D choice is on from the first frame (no ease on a map nobody has seen yet). */
        apply(animated: false)
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func changed() {
        if external() { return }
        apply(animated: true)
    }

    func apply(animated: Bool) {
        guard let map else { return }
        let target = MapTiltModel.shared.pitch(mode())
        guard abs(map.mapboxMap.cameraState.pitch - target) > 0.5 else { return }
        let d = animated ? (MapCameraMotion.reduceMotionNow ? 0 : CameraTiltRules.duration) : 0
        if d == 0 {
            map.mapboxMap.setCamera(to: CameraOptions(pitch: target))
        } else {
            map.camera.ease(to: CameraOptions(pitch: target), duration: d, curve: .easeInOut, completion: nil)
        }
    }
}

// MARK: - The one button

extension SaryMapControlItem {
    /// THE camera-angle button (docs/ONE-MAP-UNIFICATION.md §6): one glyph, one identifier (`map.tilt`), second in the
    /// side column after the layers button on every map. `is3D` is the current choice; the glyph names the view a tap leads to.
    static func cameraTilt(is3D: Bool, settledPitch: Int? = nil, newUI: Bool = NewUI.enabled) -> SaryMapControlItem {
        var value = CameraTiltRules.value(is3D: is3D)
        #if DEBUG
        if let settledPitch { value += " pitch=\(settledPitch)" }
        #endif
        /* An icon, not «٢د» / «٣د»: beside the guidance bar's «٢ د» (minutes) the text read as a second ETA (owner, Build 46). */
        if newUI {
            return SaryMapControlItem(id: "tilt", systemImage: CameraTiltRules.symbol(is3D: is3D), label: CameraTiltRules.label, accessibilityID: "map.tilt",
                                      isActive: false, hint: CameraTiltRules.hint(is3D: is3D), value: value)
        }
        /* The previous design (flag off): the «٢د» / «٣د» glyph, unchanged. */
        return SaryMapControlItem(id: "tilt", systemImage: "view.3d", label: CameraTiltRules.label, accessibilityID: "map.tilt",
                                  isActive: false, hint: CameraTiltRules.hint(is3D: is3D), value: value, glyph: CameraTiltRules.glyph(is3D: is3D))
    }
}

/// The same button for screens whose controls are not a `SaryMapControlItem` column (the legacy home, solo «اتجه», following a track,
/// the plan editor): it reads the model itself, so hosting it is one line.
struct MapTiltButton: View {
    var mode: CameraTiltMode = .overview
    @ObservedObject private var model = MapTiltModel.shared
    @Environment(\.sary) private var theme

    var body: some View {
        let on = model.is3D(mode)
        Button { model.toggle(mode) } label: {
            SaryMapControlFace(item: .cameraTilt(is3D: on, settledPitch: model.settledPitch))
                .saryGlass(Circle(), role: .control, interactive: true)
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityLabel(Text(CameraTiltRules.label))
        .accessibilityHint(Text(CameraTiltRules.hint(is3D: on)))
        .accessibilityValue(Text(SaryMapControlItem.cameraTilt(is3D: on, settledPitch: model.settledPitch).value ?? ""))
        .accessibilityIdentifier("map.tilt")
    }
}
