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
    var typeScale: CGFloat { drive ? SaryTextStyle.driveScale : 1 }

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
    /// Huwiya, applies the text-size step on top of Dynamic Type and measures
    /// the width class (`\.saryWidthClass`). It never scales or fixes the
    /// frame of the content: Display Zoom and Dynamic Type pass through.
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
    /// Width class of this window / presentation (see `SaryWidthClass`). Only
    /// the class is stored, so the tree is not re-rendered while a width animates.
    @State private var widthClass: SaryWidthClass = .regular

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
            .environment(\.saryWidthClass, widthClass)
            .onGeometryChange(for: SaryWidthClass.self) { SaryWidthClass.of(width: $0.size.width) } action: { widthClass = $0 }
    }
}

// MARK: - Text modifiers

/// Huwiya in a ramp style, Dynamic Type + drive scale.
private struct SaryTextModifier: ViewModifier {
    @Environment(\.sary) private var theme
    var style: SaryTextStyle
    var weight: SaryWeight?

    func body(content: Content) -> some View {
        /* Drive mode floors the tiny styles (`SaryTextStyle.driveFloor`) before scaling. */
        content.font(.sary(style.size(drive: theme.drive), weight ?? style.weight, relativeTo: style.relativeTo))
    }
}

/// Tabular system digits that scale with Dynamic Type (see `Font.saryNumeric`).
private struct SaryNumberModifier: ViewModifier {
    @Environment(\.sary) private var theme
    @ScaledMetric private var size: CGFloat
    var style: SaryTextStyle
    var weight: SaryWeight

    init(style: SaryTextStyle, weight: SaryWeight?) {
        _size = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTo)
        self.style = style
        self.weight = weight ?? style.weight
    }

    func body(content: Content) -> some View {
        content.font(.saryNumeric(scaled: size * style.scale(drive: theme.drive), weight))
    }
}

/// A small SF Symbol that grows a little with Dynamic Type (`SaryGlyph`), and
/// with the drive scale like the text beside it.
private struct SaryGlyphModifier: ViewModifier {
    @Environment(\.sary) private var theme
    @ScaledMetric private var scaled: CGFloat
    var base: CGFloat
    var weight: Font.Weight
    var maxGrowth: CGFloat

    init(size: CGFloat, weight: Font.Weight, relativeTo style: Font.TextStyle, maxGrowth: CGFloat) {
        _scaled = ScaledMetric(wrappedValue: size, relativeTo: style)
        base = size
        self.weight = weight
        self.maxGrowth = maxGrowth
    }

    func body(content: Content) -> some View {
        content.font(.system(size: SaryGlyph.size(base: base, scaled: scaled, maxGrowth: maxGrowth) * theme.typeScale, weight: weight))
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

    /// A small SF Symbol (6–11 pt: map badges, chip icons, chat ticks) instead of
    /// `.font(.system(size:))`: it grows with Dynamic Type up to `maxGrowth`
    /// (`SaryGlyph`) and with the drive scale. Same size at the default text size.
    func saryGlyph(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .caption2,
                   maxGrowth: CGFloat = SaryGlyph.maxGrowth) -> some View {
        modifier(SaryGlyphModifier(size: size, weight: weight, relativeTo: style, maxGrowth: maxGrowth))
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

// MARK: - Motion modifiers (see docs/MOTION.md)

/// What a repeating indicator draws at the peak of its cycle.
enum SaryPulseStyle: Equatable {
    /// Fades down and back (and grows a touch when motion is full).
    case breathe
    /// A ring expanding from the subject and fading out, then starting over:
    /// SOS, on-air.
    case ripple
    /// A soft halo behind a small dot, growing and fading: «مباشر».
    case halo
    /// A barely visible scale beat on the subject itself: the SOS disc.
    case heartbeat
    /// Opacity only, never a scale: loading placeholders.
    case dim
}

extension View {
    /// Haptic for a semantic event, fired when `trigger` changes. Applies the
    /// drive-mode rule (`SaryHaptics.allows`): only critical events while driving.
    func saryHaptic<T: Equatable>(_ event: SaryHapticEvent, trigger: T) -> some View {
        modifier(SaryHapticModifier(event: event, trigger: trigger, condition: nil))
    }

    /// Same, only when `condition(old, new)` holds (e.g. `{ !$0 && $1 }` for
    /// «became true»).
    func saryHaptic<T: Equatable>(_ event: SaryHapticEvent, trigger: T, condition: @escaping (T, T) -> Bool) -> some View {
        modifier(SaryHapticModifier(event: event, trigger: trigger, condition: condition))
    }

    /// A repeating indicator with every stop condition built in: it runs only
    /// while `active`, while the view is on screen and the app is in the
    /// foreground, and as `SaryMotionPolicy.loop` allows (no live loops in
    /// drive mode or under Reduce Motion; SOS fades instead of moving).
    /// Never use `repeatForever` directly.
    func saryPulse(_ kind: SaryLoopKind, style: SaryPulseStyle, active: Bool = true) -> some View {
        modifier(SaryPulseModifier(kind: kind, style: style, active: active))
    }

    /// A one-shot emphasis each time `trigger` changes: a small scale that
    /// settles back (`SaryMotion.emphasis`). Nothing under Reduce Motion or,
    /// for peripheral pieces, in drive mode.
    func saryEmphasis<T: Equatable>(trigger: T, scale: CGFloat = 1.06, peripheral: Bool = false) -> some View {
        modifier(SaryEmphasisModifier(trigger: trigger, scale: scale, peripheral: peripheral))
    }

    /// Settles into place when it first appears (a small scale + fade).
    /// For decorative pieces only (glyphs, illustrations): it starts
    /// transparent, so never put it on something a test or a finger must hit
    /// at once.
    func saryAppearOnMount() -> some View {
        modifier(SaryAppearOnMountModifier())
    }
}

private struct SaryHapticModifier<T: Equatable>: ViewModifier {
    @Environment(\.sary) private var theme
    var event: SaryHapticEvent
    var trigger: T
    var condition: ((T, T) -> Bool)?

    func body(content: Content) -> some View {
        let allowed = SaryHaptics.allows(event, driving: theme.drive)
        let feedback = event.feedback
        let condition = self.condition
        return content.sensoryFeedback(trigger: trigger) { old, new in
            guard allowed, condition?(old, new) ?? true else { return nil }
            return feedback
        }
    }
}

private struct SaryPulseModifier: ViewModifier {
    var kind: SaryLoopKind
    var style: SaryPulseStyle
    var active: Bool
    @Environment(\.sary) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var beat = 0
    @State private var onScreen = false

    private var mode: SaryLoopMode {
        guard onScreen else { return .off }
        return SaryMotionPolicy.loop(kind, active: active, reduceMotion: theme.reduceMotion,
                                     drive: theme.drive, sceneActive: scenePhase == .active)
    }

    func body(content: Content) -> some View {
        let mode = self.mode
        let style = self.style
        let period = kind.period
        return content
            .phaseAnimator([false, true], trigger: beat) { view, peak in
                view.modifier(SaryPulseFrame(style: style, mode: mode, peak: peak))
            } animation: { peak in
                /* Ripples and halos travel out, then snap back unseen (they are
                 * transparent at the peak); breaths ease in and out evenly. */
                let out = (style == .ripple || style == .halo) && mode == .full
                if peak { return Animation.easeOut(duration: out ? period * 0.9 : period / 2) }
                return out ? nil : Animation.easeInOut(duration: period / 2)
            }
            .onAppear { onScreen = true }
            .onDisappear { onScreen = false }
            /* Restarts (or ends) whenever the mode changes; SwiftUI cancels it on disappear. */
            .task(id: mode) {
                guard mode != .off else { return }
                while !Task.isCancelled {
                    beat &+= 1
                    try? await Task.sleep(for: .seconds(period))
                }
            }
    }
}

private struct SaryPulseFrame: ViewModifier {
    var style: SaryPulseStyle
    var mode: SaryLoopMode
    var peak: Bool

    func body(content: Content) -> some View {
        let on = peak && mode != .off
        let full = mode == .full
        switch style {
        case .breathe:
            content
                .opacity(on ? 0.45 : 1)
                .scaleEffect(on && full ? 1.12 : 1)
        case .ripple:
            content
                .scaleEffect(full ? (on ? 1.12 : 0.92) : 1)
                .opacity(mode == .off ? 0 : (on ? (full ? 0 : 0.35) : 1))
        case .halo:
            content
                .scaleEffect(full && on ? 1.8 : 1)
                .opacity(mode == .off ? 0 : (on ? 0 : 0.55))
        case .heartbeat:
            content
                .scaleEffect(on && full ? 1.04 : 1)
                .opacity(on && !full ? 0.82 : 1)
        case .dim:
            content.opacity(on ? 0.55 : 1)
        }
    }
}

private struct SaryEmphasisModifier<T: Equatable>: ViewModifier {
    var trigger: T
    var scale: CGFloat
    var peripheral: Bool
    @Environment(\.sary) private var theme

    func body(content: Content) -> some View {
        let travels = SaryMotionPolicy.travels(reduceMotion: theme.reduceMotion, drive: theme.drive, peripheral: peripheral)
        let scale = self.scale
        return content.phaseAnimator([false, true], trigger: trigger) { view, peak in
            view.scaleEffect(peak && travels ? scale : 1)
        } animation: { peak in
            peak ? SaryMotion.emphasis.animation : SaryMotion.smooth.animation
        }
    }
}

private struct SaryAppearOnMountModifier: ViewModifier {
    @Environment(\.sary) private var theme
    @State private var shown = false

    func body(content: Content) -> some View {
        let travels = SaryMotionPolicy.travels(reduceMotion: theme.reduceMotion, drive: theme.drive, peripheral: false)
        return content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown || !travels ? 1 : 0.9)
            .onAppear {
                guard !shown else { return }
                withAnimation(theme.animation(.appear)) { shown = true }
            }
    }
}
