import SwiftUI

/// Where a glass surface sits; decides tint strength and fallback fill.
enum SaryGlassRole {
    /// Small floating controls (map buttons, clusters, chips).
    case control
    /// Bars over the map (status capsule).
    case chrome
    /// Larger panels over the map (alert cards, sheet-like panels).
    case panel
}

/// THE abstraction for translucent chrome. On iOS 26+ it draws Liquid Glass
/// (`glassEffect`); on iOS 17–25 — or when the debug override / opaque
/// intensity / drive mode applies — a tasteful material + tint + hairline.
/// Use it only on functional layers over the map; content stays opaque.
private struct SaryGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.sary) private var theme
    var shape: S
    var role: SaryGlassRole
    var tint: Color?
    var interactive: Bool

    private var intensity: SaryGlassIntensity {
        role == .panel ? theme.panelGlass : theme.effectiveGlass
    }

    func body(content: Content) -> some View {
        if theme.usesLiquidGlass, intensity != .opaque {
            if #available(iOS 26.0, *) {
                content.glassEffect(glass, in: shape)
            } else {
                fallback(content)
            }
        } else {
            fallback(content)
        }
    }

    @available(iOS 26.0, *)
    private var glass: Glass {
        var g: Glass = intensity == .clear ? .clear : .regular
        // Liquid Glass adapts to what is behind it; over bright sand it turns
        // light and cream text loses contrast. A theme tint keeps chrome in
        // the app's appearance (dark sand stays dark, day stays light).
        g = g.tint(tint ?? theme.glassTint(intensity))
        if interactive { g = g.interactive() }
        return g
    }

    @ViewBuilder
    private func fallback(_ content: Content) -> some View {
        let p = theme.palette
        content
            .background {
                ZStack {
                    switch intensity {
                    case .opaque:
                        shape.fill(p.chromeOpaque)
                    case .regular:
                        shape.fill(.regularMaterial)
                        shape.fill(p.chromeTint)
                    case .clear:
                        shape.fill(.ultraThinMaterial)
                        shape.fill(p.chromeTint.opacity(0.4))
                    }
                    if let tint { shape.fill(tint.opacity(intensity == .opaque ? 1 : 0.85)) }
                    shape.stroke(p.stroke, lineWidth: theme.drive ? 1 : 0.5)
                }
                .compositingGroup()
                .saryShadow(role == .panel ? .overlay : .floating, theme)
            }
    }
}

extension View {
    /// Glass (iOS 26+) or its material fallback, clipped to `shape`.
    func saryGlass<S: Shape>(
        _ shape: S,
        role: SaryGlassRole = .control,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(SaryGlassModifier(shape: shape, role: role, tint: tint, interactive: interactive))
    }

    /// Morph identity inside a `SaryGlassGroup` (Liquid Glass only; the
    /// fallback animates through the layout change itself).
    @ViewBuilder
    func saryGlassID<ID: Hashable & Sendable>(_ id: ID, in ns: Namespace.ID, theme: SaryTheme) -> some View {
        if theme.usesLiquidGlass, #available(iOS 26.0, *) {
            glassEffectID(id, in: ns)
        } else {
            self
        }
    }
}

extension View {
    /// Merge several glass shapes into one continuous surface (iOS 26+).
    @ViewBuilder
    func saryGlassUnion<ID: Hashable & Sendable>(_ id: ID, in ns: Namespace.ID, theme: SaryTheme) -> some View {
        if theme.usesLiquidGlass, #available(iOS 26.0, *) {
            glassEffectUnion(id: id, namespace: ns)
        } else {
            self
        }
    }
}

/// Groups glass shapes so they blend and morph together (GlassEffectContainer
/// on iOS 26+, a plain container otherwise).
struct SaryGlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content
    @Environment(\.sary) private var theme

    init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if theme.usesLiquidGlass, #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// Opaque content surface (cards, rows): never glass. Honours card style.
private struct SarySurfaceModifier<S: Shape>: ViewModifier {
    @Environment(\.sary) private var theme
    var shape: S
    var fill: Color?

    func body(content: Content) -> some View {
        let p = theme.palette
        content.background {
            switch theme.cardStyle {
            case .elevated:
                shape.fill(fill ?? p.surface)
                    .saryShadow(theme.isLight ? .raised : .none, theme)
            case .flat:
                shape.fill(fill ?? p.surface)
            case .outlined:
                shape.fill(fill ?? p.elevated).overlay(shape.stroke(p.stroke, lineWidth: 1))
            }
        }
    }
}

extension View {
    func sarySurface<S: Shape>(_ shape: S, fill: Color? = nil) -> some View {
        modifier(SarySurfaceModifier(shape: shape, fill: fill))
    }

    func sarySurface(radius: CGFloat = SaryRadius.m, fill: Color? = nil) -> some View {
        modifier(SarySurfaceModifier(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), fill: fill))
    }
}
