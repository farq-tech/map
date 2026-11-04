import Foundation
import Observation
import SwiftUI

// MARK: - Preference values

enum SaryColorSchemePreference: String, CaseIterable, Codable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "حسب الجهاز"
        case .light: return "نهاري"
        case .dark: return "داكن"
        }
    }
}

enum SaryTriMode: String, CaseIterable, Codable, Identifiable {
    case auto, on, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "تلقائي"
        case .on: return "تشغيل"
        case .off: return "إيقاف"
        }
    }

    /// Bridge to the screen contracts' `TriModeUI`.
    init(_ ui: TriModeUI) {
        switch ui {
        case .automatic: self = .auto
        case .on: self = .on
        case .off: self = .off
        }
    }

    var ui: TriModeUI {
        switch self {
        case .auto: return .automatic
        case .on: return .on
        case .off: return .off
        }
    }

    func resolve(auto: Bool) -> Bool {
        switch self {
        case .auto: return auto
        case .on: return true
        case .off: return false
        }
    }
}

enum SaryCardStyle: String, CaseIterable, Codable, Identifiable {
    /// Filled surface with a soft shadow.
    case elevated
    /// Filled surface, no shadow.
    case flat
    /// Background colour with a hairline outline.
    case outlined
    var id: String { rawValue }
    var label: String {
        switch self {
        case .elevated: return "مرفوعة"
        case .flat: return "مسطحة"
        case .outlined: return "محددة"
        }
    }
}

enum SaryDensity: String, CaseIterable, Codable, Identifiable {
    case compact, regular, spacious
    var id: String { rawValue }
    var label: String {
        switch self {
        case .compact: return "مضغوط"
        case .regular: return "عادي"
        case .spacious: return "مريح"
        }
    }

    var factor: CGFloat {
        switch self {
        case .compact: return 0.8
        case .regular: return 1
        case .spacious: return 1.2
        }
    }
}

/// Steps on top of the system Dynamic Type size (never replaces it).
enum SaryTextSize: String, CaseIterable, Codable, Identifiable {
    case smaller, standard, larger, largest
    var id: String { rawValue }
    var label: String {
        switch self {
        case .smaller: return "أصغر"
        case .standard: return "عادي"
        case .larger: return "أكبر"
        case .largest: return "الأكبر"
        }
    }

    var steps: Int {
        switch self {
        case .smaller: return -1
        case .standard: return 0
        case .larger: return 1
        case .largest: return 2
        }
    }

    func apply(to size: DynamicTypeSize) -> DynamicTypeSize {
        let all = DynamicTypeSize.allCases
        guard let i = all.firstIndex(of: size) else { return size }
        let j = min(max(i + steps, 0), all.count - 1)
        return all[j]
    }
}

enum SaryButtonSize: String, CaseIterable, Codable, Identifiable {
    case regular, large, extraLarge
    var id: String { rawValue }
    var label: String {
        switch self {
        case .regular: return "عادي"
        case .large: return "كبير"
        case .extraLarge: return "كبير جدًا"
        }
    }

    var height: CGFloat {
        switch self {
        case .regular: return 50
        case .large: return 56
        case .extraLarge: return 64
        }
    }
}

enum SaryGlassIntensity: String, CaseIterable, Codable, Identifiable {
    /// Most see-through (Liquid Glass `.clear` / thin material).
    case clear
    case regular
    /// No translucency at all.
    case opaque
    var id: String { rawValue }
    var label: String {
        switch self {
        case .clear: return "شفاف"
        case .regular: return "عادي"
        case .opaque: return "معتم"
        }
    }
}

/// How panels that sit over the map (sheet, alert cards) look.
enum SaryPanelLook: String, CaseIterable, Codable, Identifiable {
    /// Glass / material, the map shows through.
    case translucent
    /// Solid surface colour.
    case solid
    var id: String { rawValue }
    var label: String {
        switch self {
        case .translucent: return "زجاجية"
        case .solid: return "صلبة"
        }
    }
}

enum SaryMotionPreference: String, CaseIterable, Codable, Identifiable {
    case system, reduced, full
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "حسب الجهاز"
        case .reduced: return "أقل حركة"
        case .full: return "كاملة"
        }
    }
}

enum SaryParticipantMarker: String, CaseIterable, Codable, Identifiable {
    case cars, dots
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cars: return "سيارات"
        case .dots: return "نقاط"
        }
    }
}

enum SaryNameDisplay: String, CaseIterable, Codable, Identifiable {
    case always, onTap
    var id: String { rawValue }
    var label: String {
        switch self {
        case .always: return "دائمًا"
        case .onTap: return "عند اللمس"
        }
    }
}

// MARK: - Stored preferences

/// Everything a person can customise about how the app looks. One Codable
/// value so it persists atomically and new fields fall back to defaults.
struct AppearancePreferences: Codable, Equatable {
    var colorScheme: SaryColorSchemePreference = .system
    var accent: SaryAccent = .ember
    var cardStyle: SaryCardStyle = .elevated
    var density: SaryDensity = .regular
    var textSize: SaryTextSize = .standard
    var buttonSize: SaryButtonSize = .regular
    var glass: SaryGlassIntensity = .regular
    var panelLook: SaryPanelLook = .translucent
    var nightMode: SaryTriMode = .auto
    var driveMode: SaryTriMode = .auto
    var motion: SaryMotionPreference = .system
    var participantMarker: SaryParticipantMarker = .cars
    var nameDisplay: SaryNameDisplay = .always

    init() {}

    // Tolerant decoding: an unknown/missing key keeps its default, so adding
    // a setting in a later version never resets the others.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        let d = AppearancePreferences()
        colorScheme = v(.colorScheme, d.colorScheme)
        accent = v(.accent, d.accent)
        cardStyle = v(.cardStyle, d.cardStyle)
        density = v(.density, d.density)
        textSize = v(.textSize, d.textSize)
        buttonSize = v(.buttonSize, d.buttonSize)
        glass = v(.glass, d.glass)
        panelLook = v(.panelLook, d.panelLook)
        nightMode = v(.nightMode, d.nightMode)
        driveMode = v(.driveMode, d.driveMode)
        motion = v(.motion, d.motion)
        participantMarker = v(.participantMarker, d.participantMarker)
        nameDisplay = v(.nameDisplay, d.nameDisplay)
    }
}

// MARK: - The one settings object

/// The app's single appearance/customisation model. Create ONE at the app root,
/// attach it with `.saryAppearance(settings)`, and every screen reads the
/// resolved `@Environment(\.sary)` theme. Screens never re-implement any of
/// these options; a settings screen edits `settings.prefs` via `@Bindable`.
@Observable
final class AppearanceSettings {
    static let storageKey = "sary.appearance.v1"

    /// Persisted on every change.
    var prefs: AppearancePreferences {
        didSet { if prefs != oldValue { save() } }
    }

    /// Context the wiring layer feeds in for the "automatic" modes (not persisted).
    /// True after sunset at the current position.
    var autoNight = false
    /// True while moving at driving speed.
    var autoDrive = false

    /// DEBUG/showcase only: render the iOS 17–25 material fallback even on iOS 26+.
    var forceGlassFallback = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String

    init(defaults: UserDefaults = .standard, key: String = AppearanceSettings.storageKey) {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode(AppearancePreferences.self, from: data) {
            prefs = stored
        } else {
            prefs = AppearancePreferences()
        }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(prefs) else { return }
        defaults.set(data, forKey: key)
    }

    func reset() { prefs = AppearancePreferences() }

    /// Night / drive resolved with the automatic context.
    var isNight: Bool { prefs.nightMode.resolve(auto: autoNight) }
    var isDriving: Bool { prefs.driveMode.resolve(auto: autoDrive) }
}
