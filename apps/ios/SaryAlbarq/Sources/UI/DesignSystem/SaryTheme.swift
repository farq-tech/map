import SwiftUI

/// The resolved theme every component reads: palette + metrics + motion +
/// the customisation choices, already combined with the system environment
/// (colour scheme, Reduce Motion, increased contrast) and with night / drive.
struct SaryTheme: Equatable {
    var palette: SaryPalette
    var scheme: ColorScheme
    var night: Bool
    var drive: Bool
    var accent: SaryAccent
    /// Requested glass intensity (drive forces opaque, see `effectiveGlass`).
    var glass: SaryGlassIntensity
    var cardStyle: SaryCardStyle
    var density: SaryDensity
    var buttonSize: SaryButtonSize
    var panelLook: SaryPanelLook
    var reduceMotion: Bool
    var increasedContrast: Bool
    var participantMarker: SaryParticipantMarker
    var nameDisplay: SaryNameDisplay
    /// DEBUG: draw the iOS 17–25 fallback even where Liquid Glass exists.
    var forceGlassFallback: Bool

    // MARK: Resolution

    static func resolve(
        prefs: AppearancePreferences,
        scheme: ColorScheme,
        night: Bool,
        drive: Bool,
        systemReduceMotion: Bool = false,
        increasedContrast: Bool = false,
        forceGlassFallback: Bool = false
    ) -> SaryTheme {
        let light = scheme == .light && !night
        var palette: SaryPalette = night ? .night(accent: prefs.accent)
            : (light ? .light(accent: prefs.accent) : .dark(accent: prefs.accent))
        if drive || increasedContrast { palette = palette.driveAdjusted(light: light) }
        let reduce: Bool = {
            switch prefs.motion {
            case .system: return systemReduceMotion
            case .reduced: return true
            case .full: return false
            }
        }()
        return SaryTheme(
            palette: palette,
            scheme: light ? .light : .dark,
            night: night,
            drive: drive,
            accent: prefs.accent,
            glass: prefs.glass,
            cardStyle: prefs.cardStyle,
            density: prefs.density,
            buttonSize: prefs.buttonSize,
            panelLook: prefs.panelLook,
            reduceMotion: reduce,
            increasedContrast: increasedContrast,
            participantMarker: prefs.participantMarker,
            nameDisplay: prefs.nameDisplay,
            forceGlassFallback: forceGlassFallback
        )
    }

    static let `default` = SaryTheme.resolve(prefs: .init(), scheme: .dark, night: false, drive: false)

    var isLight: Bool { scheme == .light }

    // MARK: Glass

    /// Drive mode and increased contrast never use translucency (sun glare,
    /// legibility at a glance).
    var effectiveGlass: SaryGlassIntensity {
        (drive || increasedContrast) ? .opaque : glass
    }

    /// True when Liquid Glass should be drawn (iOS 26+, not forced off, not opaque).
    var usesLiquidGlass: Bool {
        guard !forceGlassFallback, effectiveGlass != .opaque else { return false }
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// Tint laid into Liquid Glass so chrome keeps the theme's tone.
    func glassTint(_ intensity: SaryGlassIntensity) -> Color {
        let base: UInt32 = night ? 0x0D0C0B : (isLight ? 0xFFFBF3 : 0x1A1612)
        let amount: Double = {
            if night { return intensity == .clear ? 0.45 : 0.68 }
            if isLight { return intensity == .clear ? 0.2 : 0.42 }
            return intensity == .clear ? 0.35 : 0.58
        }()
        return Color(rgb: base, opacity: amount)
    }

    /// Panels over the map (alert cards, sheet) follow the panel look too.
    var panelGlass: SaryGlassIntensity {
        panelLook == .solid ? .opaque : effectiveGlass
    }

    // MARK: Metrics

    func space(_ s: SarySpace) -> CGFloat { (s.rawValue * density.factor).rounded() }

    /// Minimum touch target: 44 pt, 64 pt while driving.
    var minTarget: CGFloat { drive ? 64 : 44 }
    /// Floating round map buttons.
    var mapButton: CGFloat { drive ? 64 : 48 }
    /// SOS / push-to-talk.
    var bigButton: CGFloat { drive ? 84 : 68 }
    /// Full-width buttons.
    var buttonHeight: CGFloat { drive ? max(64, buttonSize.height) : buttonSize.height }
    /// Drive mode text scale on top of Dynamic Type.
    var typeScale: CGFloat { drive ? 1.15 : 1 }

    // MARK: Motion

    func animation(_ m: SaryMotion) -> Animation {
        reduceMotion ? SaryMotion.reduced : m.animation
    }
}

// MARK: - Environment

private struct SaryThemeKey: EnvironmentKey {
    static let defaultValue = SaryTheme.default
}

extension EnvironmentValues {
    /// The resolved theme. Read it with `@Environment(\.sary) private var theme`.
    var sary: SaryTheme {
        get { self[SaryThemeKey.self] }
        set { self[SaryThemeKey.self] = newValue }
    }
}

// MARK: - Root modifier

extension View {
    /// Attach ONCE at the app root (and on any sheet / full-screen cover whose
    /// content is built outside this hierarchy). Injects `AppearanceSettings`
    /// into the environment, resolves the theme, forces Arabic RTL, registers
    /// Tajawal and applies the text-size step on top of Dynamic Type.
    func saryAppearance(_ settings: AppearanceSettings) -> some View {
        SaryFonts.registerIfNeeded()
        return modifier(SaryAppearanceRoot(settings: settings))
    }

    /// Use a fixed theme for a subtree (showcase comparisons, previews).
    func saryTheme(_ theme: SaryTheme) -> some View {
        SaryFonts.registerIfNeeded()
        return self
            .environment(\.sary, theme)
            .environment(\.colorScheme, theme.scheme)
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, Locale(identifier: "ar"))
            .tint(theme.palette.accent)
    }
}

private struct SaryAppearanceRoot: ViewModifier {
    var settings: AppearanceSettings

    func body(content: Content) -> some View {
        let prefs = settings.prefs
        let forced: ColorScheme? = settings.isNight ? .dark : {
            switch prefs.colorScheme {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }()
        return content
            .modifier(SaryThemeResolver(settings: settings))
            .environment(settings)
            .preferredColorScheme(forced)
    }
}

private struct SaryThemeResolver: ViewModifier {
    var settings: AppearanceSettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        let theme = SaryTheme.resolve(
            prefs: settings.prefs,
            scheme: scheme,
            night: settings.isNight,
            drive: settings.isDriving,
            systemReduceMotion: reduceMotion,
            increasedContrast: contrast == .increased,
            forceGlassFallback: settings.forceGlassFallback
        )
        return content
            .environment(\.sary, theme)
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, Locale(identifier: "ar"))
            .dynamicTypeSize(settings.prefs.textSize.apply(to: typeSize))
            .tint(theme.palette.accent)
    }
}

// MARK: - Text modifiers

/// Tajawal in a ramp style, Dynamic Type + drive scale.
private struct SaryTextModifier: ViewModifier {
    @Environment(\.sary) private var theme
    var style: SaryTextStyle
    var weight: SaryWeight?

    func body(content: Content) -> some View {
        content.font(.sary(style.size * theme.typeScale, weight ?? style.weight, relativeTo: style.relativeTo))
    }
}

/// Tabular system digits that scale with Dynamic Type (see `Font.saryNumeric`).
private struct SaryNumberModifier: ViewModifier {
    @Environment(\.sary) private var theme
    @ScaledMetric private var size: CGFloat
    var weight: SaryWeight

    init(style: SaryTextStyle, weight: SaryWeight?) {
        _size = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTo)
        self.weight = weight ?? style.weight
    }

    func body(content: Content) -> some View {
        content.font(.saryNumeric(scaled: size * theme.typeScale, weight))
    }
}

extension View {
    func saryText(_ style: SaryTextStyle, weight: SaryWeight? = nil) -> some View {
        modifier(SaryTextModifier(style: style, weight: weight))
    }

    /// For live numbers (distance, timers, battery): fixed-width digits.
    func saryNumber(_ style: SaryTextStyle, weight: SaryWeight? = nil) -> some View {
        modifier(SaryNumberModifier(style: style, weight: weight))
    }

    /// Animation that respects Reduce Motion / the motion preference.
    func saryAnimation<V: Equatable>(_ motion: SaryMotion, value: V) -> some View {
        modifier(SaryAnimationModifier(motion: motion, value: value))
    }
}

private struct SaryAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.sary) private var theme
    var motion: SaryMotion
    var value: V
    func body(content: Content) -> some View {
        content.animation(theme.animation(motion), value: value)
    }
}
