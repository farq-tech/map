import Combine
import SwiftUI

/// «المؤثرات البصرية» (Settings → الخرائط والبيانات): on by default, with one switch per effect.
/// Stored on the device only (UserDefaults).
enum VisualEffectsKeys {
    static let master = "sary.visuals.on.v1"
    static let terrain = "sary.visuals.terrain.v1"
    static let atmosphere = "sary.visuals.atmosphere.v1"
    static let sky = "sary.visuals.sky.v1"
    static let glow = "sary.visuals.glow.v1"
    static let slope = "sary.visuals.slope.v1"
}

struct VisualEffectsSettings: Equatable {
    var master = true
    /// Dunes in 3D (pitch-aware exaggeration) + the hillshade lit by the real sun.
    var terrain = true
    /// Fog / haze from the weather layer's cached forecast (dust, rain, clouds, visibility).
    var atmosphere = true
    /// Light preset and sky colours from the real sun altitude.
    var sky = true
    /// A soft glow under routes and tracks.
    var glow = true
    /// «انحدار تقريبي» along routes and tracks.
    var slope = true

    static var current: VisualEffectsSettings {
        let d = UserDefaults.standard
        func b(_ k: String) -> Bool { d.object(forKey: k) as? Bool ?? true }
        return VisualEffectsSettings(master: b(VisualEffectsKeys.master), terrain: b(VisualEffectsKeys.terrain), atmosphere: b(VisualEffectsKeys.atmosphere),
                                     sky: b(VisualEffectsKeys.sky), glow: b(VisualEffectsKeys.glow), slope: b(VisualEffectsKeys.slope))
    }
}

/// Where the map is and what the phone is doing: what the budget decides from.
struct VisualContext: Equatable {
    var driving = false
    var exploring = false
    var terrain3D = false
    var flying = false
    var lowPower = false
    var reduceMotion = false
    var layer: MapLayer = .satellite
    var pitch = 0.0
}

/// What is actually on, after Low Power Mode, driving and Reduce Motion had their say.
struct EffectiveVisuals: Equatable {
    /// False: the map behaves exactly as before this pack (legacy light and terrain).
    var managed: Bool
    var exaggeration: Double
    var hillshade: Bool
    var atmosphere: Bool
    var sky: Bool
    var glow: Bool
    var slope: Bool
    var drone: Bool
    var stars: Bool
    /// Fog / light transitions (0 with Reduce Motion: changes are instant, nothing glides).
    var transitionMs: Int
    /// The drone flight orbits (false with Reduce Motion: a still oblique view instead).
    var orbit: Bool
    /// The 60 fps target (30 in Low Power Mode, which iOS caps anyway).
    var maxFps: Int
}

enum VisualBudget {
    /// The map's terrain before this pack: 1.15, 1.6 in the 3D terrain view.
    static func legacyExaggeration(terrain3D: Bool) -> Double { terrain3D ? 1.6 : 1.15 }

    /// 1.0 while driving (true heights under a moving car); 1.15 flat; up to 1.5 in exploration
    /// / the 3D view / a drone flight (1.3 elsewhere) as the camera tilts — never a jump.
    static func exaggeration(_ c: VisualContext) -> Double {
        if c.driving { return 1.0 }
        let maxEx = c.exploring || c.terrain3D || c.flying ? 1.5 : 1.3
        return Smooth.lerp(1.15, maxEx, Smooth.step(15, 60, c.pitch))
    }

    static func resolve(_ s: VisualEffectsSettings, _ c: VisualContext) -> EffectiveVisuals {
        guard s.master else {
            return EffectiveVisuals(managed: false, exaggeration: legacyExaggeration(terrain3D: c.terrain3D), hillshade: false, atmosphere: false,
                                    sky: false, glow: false, slope: false, drone: false, stars: false, transitionMs: 0, orbit: false, maxFps: 60)
        }
        let lean = c.lowPower
        return EffectiveVisuals(
            managed: true,
            exaggeration: s.terrain ? exaggeration(c) : legacyExaggeration(terrain3D: c.terrain3D),
            /* Outdoors has its own hillshade; Low Power Mode drops ours (an extra raster pass). */
            hillshade: s.terrain && !lean && c.layer != .topo,
            atmosphere: s.atmosphere,
            sky: s.sky,
            /* The glow is steady (never animated); Low Power Mode drops it (a wide blurred pass). */
            glow: s.glow && !lean,
            /* Not while driving: the road is the subject, not a colour legend. */
            slope: s.slope && !lean && !c.driving,
            drone: DroneOrbit.allowed(driving: c.driving),
            stars: !lean,
            transitionMs: c.reduceMotion ? 0 : 1_800,
            orbit: !c.reduceMotion,
            maxFps: lean ? 30 : 60)
    }

    /// Why effects are reduced right now (the settings footer and the accessibility value).
    static func reducedNote(lowPower: Bool, driving: Bool) -> String? {
        switch (lowPower, driving) {
        case (true, true): return "مخفّفة الآن: وضع توفير الطاقة، وأثناء القيادة"
        case (true, false): return "مخفّفة الآن: وضع توفير الطاقة"
        case (false, true): return "مخفّفة الآن: أثناء القيادة"
        default: return nil
        }
    }
}

/// The live map's visuals as the rest of the app sees them: whether a drone flight may start
/// (not while driving), whether one is running, and the one entry point the buttons call.
final class MapVisualsHub: ObservableObject {
    static let shared = MapVisualsHub()

    @Published var driving = false
    @Published private(set) var flying = false
    /// A live map is on screen (the drone buttons are hidden otherwise).
    @Published private(set) var mapAttached = false
    /// DEBUG / UI tests: the last flight's measured frame pacing.
    @Published var lastFlightStats: String = ""

    weak var director: MapVisualsDirector? {
        didSet { mapAttached = director != nil }
    }

    /// «طيران درون استكشافي» around `point`. No-op while driving or with no live map.
    func fly(to point: LngLat) {
        guard DroneOrbit.allowed(driving: driving), let d = director else { return }
        d.startDrone(at: point)
    }

    func stopFlight() { director?.stopDrone() }

    func setFlying(_ on: Bool) { if flying != on { flying = on } }
}

// MARK: - Settings UI

/// «المؤثرات البصرية» in Settings: a master switch (on by default) and one per effect.
struct VisualEffectsSection: View {
    @AppStorage(VisualEffectsKeys.master) private var master = true
    @AppStorage(VisualEffectsKeys.terrain) private var terrain = true
    @AppStorage(VisualEffectsKeys.atmosphere) private var atmosphere = true
    @AppStorage(VisualEffectsKeys.sky) private var sky = true
    @AppStorage(VisualEffectsKeys.glow) private var glow = true
    @AppStorage(VisualEffectsKeys.slope) private var slope = true
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        SarySection(title: "المؤثرات البصرية", footer: footer) {
            SaryToggleRow(title: "المؤثرات البصرية", subtitle: "تضاريس وسماء وأجواء من بيانات حقيقية", systemImage: "sparkles",
                          isOn: $master, id: "settings.visuals")
            if master {
                SaryDivider()
                SaryToggleRow(title: "كثبان ثلاثية الأبعاد", subtitle: "تظليل التضاريس من موقع الشمس الحقيقي", systemImage: "mountain.2.fill",
                              isOn: $terrain, id: "settings.visuals.terrain")
                SaryDivider()
                SaryToggleRow(title: "السماء والإضاءة", subtitle: "فجر ونهار وغروب وليل حسب ارتفاع الشمس", systemImage: "sun.horizon.fill",
                              isOn: $sky, id: "settings.visuals.sky")
                SaryDivider()
                SaryToggleRow(title: "أجواء الطقس", subtitle: "غبار وغيوم ومطر من بيانات الطقس المحفوظة", systemImage: "sun.dust.fill",
                              isOn: $atmosphere, id: "settings.visuals.atmosphere")
                SaryDivider()
                SaryToggleRow(title: "توهج المسارات", subtitle: "هالة خفيفة ثابتة تُقرأ في الليل", systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill",
                              isOn: $glow, id: "settings.visuals.glow")
                SaryDivider()
                SaryToggleRow(title: "انحدار تقريبي", subtitle: "يلوّن المقاطع الحادة من نموذج ارتفاع ~٣٠ م", systemImage: "chart.line.uptrend.xyaxis",
                              isOn: $slope, id: "settings.visuals.slope")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    private var footer: String {
        var s = "تُخفَّف تلقائيًا أثناء القيادة (بلا حركة ولا ألوان إضافية) وفي وضع توفير الطاقة. «طيران درون» لا يعمل أثناء القيادة، ويتوقف عند أي لمسة."
        if lowPower { s += " وضع توفير الطاقة مفعّل الآن." }
        return s
    }
}
