import CoreText
import SwiftUI
import UIKit

// MARK: - Typography

/// ITF Huwiya Arabic (bundled from Farq) registered at runtime.
enum SaryFonts {
    static let files = ["itfHuwiyaArabic-Regular", "itfHuwiyaArabic-Medium", "itfHuwiyaArabic-Bold", "itfHuwiyaArabic-Black"]

    private static let registered: Bool = {
        for name in files {
            guard let url = Bundle.main.url(forResource: name, withExtension: "otf") else { continue }
            // Already registered returns an error we can ignore.
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return true
    }()

    /// Idempotent; safe from any view body.
    @discardableResult
    static func registerIfNeeded() -> Bool { registered }
}

enum SaryWeight: CaseIterable {
    case regular, medium, bold, heavy

    var postScript: String {
        switch self {
        case .regular: return "itfHuwiyaArabic-Regular"
        case .medium: return "itfHuwiyaArabic-Medium"
        case .bold: return "itfHuwiyaArabic-Bold"
        case .heavy: return "itfHuwiyaArabic-Black"
        }
    }

    var system: Font.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .bold: return .semibold
        case .heavy: return .bold
        }
    }
}

/// The type ramp. Every style scales with Dynamic Type (relative to a system
/// text style) and grows 15 % in drive mode.
enum SaryTextStyle: String, CaseIterable {
    case display, title, title2, headline, body, bodyStrong, callout, subhead, footnote, caption, micro

    var size: CGFloat {
        switch self {
        case .display: return 34
        case .title: return 26
        case .title2: return 21
        case .headline: return 17
        case .body: return 16
        case .bodyStrong: return 16
        case .callout: return 15
        case .subhead: return 14
        case .footnote: return 13
        case .caption: return 12
        case .micro: return 11
        }
    }

    var weight: SaryWeight {
        switch self {
        case .display: return .heavy
        case .title, .title2, .headline, .bodyStrong: return .bold
        case .body: return .regular
        case .callout, .subhead, .footnote: return .medium
        case .caption, .micro: return .bold
        }
    }

    var relativeTo: Font.TextStyle {
        switch self {
        case .display: return .largeTitle
        case .title: return .title
        case .title2: return .title2
        case .headline: return .headline
        case .body, .bodyStrong: return .body
        case .callout: return .callout
        case .subhead: return .subheadline
        case .footnote: return .footnote
        case .caption: return .caption
        case .micro: return .caption2
        }
    }

    var label: String { rawValue }

    /// Drive mode: no ramp style is drawn smaller than this (before the drive
    /// scale), so `.micro` reads like `.caption` at arm's length: 12 × 1.15 ≈ 14 pt.
    static let driveFloor: CGFloat = 12
    /// Drive mode text scale on top of Dynamic Type (`SaryTheme.typeScale`).
    static let driveScale: CGFloat = 1.15

    /// Point size before Dynamic Type: the ramp size, floored and scaled in drive mode.
    func size(drive: Bool) -> CGFloat {
        drive ? max(size, Self.driveFloor) * Self.driveScale : size
    }

    /// `size(drive:)` as a factor of the ramp size, for metrics already scaled by Dynamic Type.
    func scale(drive: Bool) -> CGFloat { size(drive: drive) / size }
}

/// Small SF Symbols beside tiny text (map badges, chat ticks, chip icons, 6–11 pt):
/// they follow Dynamic Type a little — never smaller than designed, at most
/// `maxGrowth` times — so they keep up with their label without bursting the
/// badge or dot they sit in. Applied by `.saryGlyph(_:)`.
enum SaryGlyph {
    /// Default cap: a 10 pt glyph stops at 14 pt.
    static let maxGrowth: CGFloat = 1.4
    /// Glyphs inside a fixed small shape (a 10 pt dot, a 16 pt badge) grow less.
    static let tightGrowth: CGFloat = 1.2

    /// `scaled` is `base` after `@ScaledMetric`; the result is clamped to
    /// `base ... base × maxGrowth` (a cap below 1 means «never grows»).
    static func size(base: CGFloat, scaled: CGFloat, maxGrowth: CGFloat = maxGrowth) -> CGFloat {
        guard base > 0 else { return 0 }
        guard scaled.isFinite else { return base }
        return min(max(scaled, base), base * max(1, maxGrowth))
    }
}

extension Font {
    /// ITF Huwiya Arabic at `size`, scaling with Dynamic Type relative to `style`.
    static func sary(_ size: CGFloat, _ weight: SaryWeight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        SaryFonts.registerIfNeeded()
        return .custom(weight.postScript, size: size, relativeTo: style)
    }

    /// ITF Huwiya Arabic that does NOT follow Dynamic Type: for glyph-like
    /// text inside a fixed-size shape (avatar initials), which would otherwise
    /// outgrow its circle at large text sizes.
    static func saryFixed(_ size: CGFloat, _ weight: SaryWeight = .regular) -> Font {
        SaryFonts.registerIfNeeded()
        return .custom(weight.postScript, fixedSize: size)
    }

    /// Numbers that update live (distances, timers, battery): the system font
    /// (SF Arabic covers Arabic-Indic digits) with tabular figures, because
    /// Huwiya's digits are proportional and would jitter while ticking.
    /// `size` is already scaled — use `.saryNumber(_:)` in views.
    static func saryNumeric(scaled size: CGFloat, _ weight: SaryWeight = .bold) -> Font {
        .system(size: size, weight: weight.system).monospacedDigit()
    }
}

extension Font.TextStyle {
    var uiKit: UIFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
}

// MARK: - Widths (screen-size adaptation)

/// How much horizontal room the current window or presentation gives.
/// Nothing in the design system multiplies sizes by the screen: points stay
/// points. Components only change ARRANGEMENT by width (stack instead of
/// row, wrap instead of overflow), so a 393 pt iPhone looks as designed.
enum SaryWidthClass: Equatable, Sendable {
    /// Under 360 pt: Display Zoom («تكبير الشاشة») on a 375/393 pt iPhone
    /// (320 pt wide), or a narrow iPad split view / Slide Over.
    case narrow
    /// An upright phone at standard zoom (360–599 pt).
    case regular
    /// iPad, a wide split view (600 pt and up).
    case wide

    static let narrowBelow: CGFloat = 360
    static let wideFrom: CGFloat = 600

    /// A width of 0 or less means «not measured yet»: treated as a phone.
    static func of(width: CGFloat) -> SaryWidthClass {
        guard width > 0 else { return .regular }
        if width < narrowBelow { return .narrow }
        if width < wideFrom { return .regular }
        return .wide
    }
}

/// Maximum widths for content that must not stretch across an iPad.
enum SaryLayout {
    /// Scrolling page content (same as `SaryPage`).
    static let readableWidth: CGFloat = 640
    /// Single-column forms, onboarding, full-screen alerts.
    static let formWidth: CGFloat = 480
    /// In-app dialogs and empty / error states.
    static let dialogWidth: CGFloat = 400

    /// The width a centred column takes in `container`: all of it minus
    /// `margin` on each side, but never more than `max` and never negative.
    static func columnWidth(container: CGFloat, max: CGFloat, margin: CGFloat = 0) -> CGFloat {
        Swift.max(0, Swift.min(container - 2 * margin, max))
    }
}

private struct SaryWidthClassKey: EnvironmentKey {
    static let defaultValue: SaryWidthClass = .regular
}

extension EnvironmentValues {
    /// Width class of the enclosing window / sheet, measured by `saryAppearance`.
    /// Read it with `@Environment(\.saryWidthClass) private var widthClass`.
    var saryWidthClass: SaryWidthClass {
        get { self[SaryWidthClassKey.self] }
        set { self[SaryWidthClassKey.self] = newValue }
    }
}

extension View {
    /// Caps the content at `max` points and centres it; full width when the
    /// window is narrower (every iPhone for the default 640). Backgrounds that
    /// must stay full-bleed go OUTSIDE this modifier.
    func saryReadableWidth(_ max: CGFloat = SaryLayout.readableWidth) -> some View {
        frame(maxWidth: max).frame(maxWidth: .infinity)
    }
}

// MARK: - Flow layout

/// Pure line-breaking math for `SaryFlowLayout` (unit-tested).
enum SaryFlow {
    /// Frames for items of `sizes`, laid out leading-to-trailing in lines no
    /// wider than `maxWidth` and wrapped when the next item does not fit. Each
    /// item is centred vertically in its line; an item wider than a whole line
    /// gets a line to itself, clamped to `maxWidth`. Origins start at (0, 0).
    static func frames(sizes: [CGSize], spacing: CGFloat, lineSpacing: CGFloat, maxWidth: CGFloat) -> [CGRect] {
        let limit = Swift.max(0, maxWidth)
        var lines: [[Int]] = []
        var current: [Int] = []
        var x: CGFloat = 0
        for (i, s) in sizes.enumerated() {
            let w = Swift.min(s.width, limit)
            if !current.isEmpty && x + spacing + w > limit {
                lines.append(current)
                current = []
                x = 0
            }
            x += (current.isEmpty ? 0 : spacing) + w
            current.append(i)
        }
        if !current.isEmpty { lines.append(current) }

        var frames = Array(repeating: CGRect.zero, count: sizes.count)
        var y: CGFloat = 0
        for (n, line) in lines.enumerated() {
            let height = line.map { sizes[$0].height }.max() ?? 0
            var lx: CGFloat = 0
            for i in line {
                let w = Swift.min(sizes[i].width, limit)
                let h = sizes[i].height
                frames[i] = CGRect(x: lx, y: y + (height - h) / 2, width: w, height: h)
                lx += w + spacing
            }
            y += height + (n < lines.count - 1 ? lineSpacing : 0)
        }
        return frames
    }

    /// The size the frames above occupy.
    static func size(of frames: [CGRect]) -> CGSize {
        CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }
}

/// A row that wraps to the next line instead of overflowing: badges, chips,
/// swatches. When everything fits it looks exactly like an `HStack` with the
/// same spacing (centred vertically). Placement is mirrored in RTL by SwiftUI.
struct SaryFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        SaryFlow.size(of: frames(proposal.width, subviews))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (f, v) in zip(frames(bounds.width, subviews), subviews) {
            v.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY),
                    proposal: ProposedViewSize(width: f.width, height: f.height))
        }
    }

    private func frames(_ width: CGFloat?, _ subviews: Subviews) -> [CGRect] {
        SaryFlow.frames(sizes: subviews.map { $0.sizeThatFits(.unspecified) }, spacing: spacing,
                        lineSpacing: lineSpacing, maxWidth: width ?? .infinity)
    }
}

// MARK: - Spacing / radius / sizes

/// 4-pt spacing scale. `SaryTheme.space(_:)` applies the density setting.
enum SarySpace: CGFloat, CaseIterable {
    case xxs = 2, xs = 4, s = 8, m = 12, l = 16, xl = 20, xxl = 24, xxxl = 32
}

enum SaryRadius {
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 22
    static let xl: CGFloat = 28
    /// Sheet top corners.
    static let sheet: CGFloat = 30
}

/// Elevation tokens. Glass surfaces carry their own depth on iOS 26; these
/// are used for the material fallback, opaque chrome and cards.
enum SaryShadow: CaseIterable {
    case none, raised, floating, overlay

    func radius() -> CGFloat {
        switch self {
        case .none: return 0
        case .raised: return 4
        case .floating: return 12
        case .overlay: return 24
        }
    }

    func y() -> CGFloat {
        switch self {
        case .none: return 0
        case .raised: return 1
        case .floating: return 4
        case .overlay: return 10
        }
    }

    func opacity() -> Double {
        switch self {
        case .none: return 0
        case .raised: return 0.5
        case .floating: return 0.8
        case .overlay: return 1
        }
    }
}

extension View {
    func saryShadow(_ s: SaryShadow, _ theme: SaryTheme) -> some View {
        shadow(color: theme.palette.shadow.opacity(s.opacity()), radius: s.radius(), x: 0, y: s.y())
    }

    /// A count badge in a `.topTrailing` overlay, pushed `trailing` pt out past
    /// the trailing edge and `top` pt up. Uses negative semantic padding, so it
    /// goes outward on the trailing side in RTL (left) and LTR (right) alike —
    /// unlike `.offset(x:)` with a hard-coded sign.
    func saryBadgeOutset(trailing: CGFloat, top: CGFloat = 0) -> some View {
        padding(.trailing, -trailing).padding(.top, -top)
    }
}

// MARK: - Motion

/// Motion tokens. Always go through `SaryTheme.animation(_:)` so the Reduce
/// Motion setting (system or the app's own motion preference) is respected:
/// under reduced motion, movement becomes a short cross-fade.
/// The motion language (when to use which token) is in `docs/MOTION.md`.
enum SaryMotion: CaseIterable {
    /// Taps, toggles, small state changes.
    case snappy
    /// Layout changes: cluster morph, sheet content, expanding capsule.
    case smooth
    /// Things entering from off-screen (alert cards, strips).
    case enter
    /// Emergency: quick and decisive.
    case urgent
    /// Something appearing in place: a state view, a card's content, a chip.
    case appear
    /// Something leaving: quicker than it came and without bounce, so the
    /// eye is not pulled back to what is going away.
    case dismiss
    /// One-shot attention: a small scale or glow that settles back once
    /// (a value crossed a threshold, a new alert landed). Never repeated.
    case emphasis
    /// Arrival («وصلت»): a warm, slightly springier settle. Once per arrival.
    case celebrate
    /// One half-breath of a live indicator (in OR out). A full breath is
    /// `livePulsePeriod`; loops only run through `View.saryPulse`.
    case livePulse

    var animation: Animation {
        switch self {
        case .snappy: return .spring(response: 0.28, dampingFraction: 0.86)
        case .smooth: return .spring(response: 0.42, dampingFraction: 0.88)
        case .enter: return .spring(response: 0.5, dampingFraction: 0.82)
        case .urgent: return .spring(response: 0.22, dampingFraction: 0.92)
        case .appear: return .spring(response: 0.36, dampingFraction: 0.9)
        case .dismiss: return .easeOut(duration: 0.2)
        case .emphasis: return .spring(response: 0.3, dampingFraction: 0.62)
        case .celebrate: return .spring(response: 0.55, dampingFraction: 0.7)
        case .livePulse: return .easeInOut(duration: Self.livePulsePeriod / 2)
        }
    }

    /// Roughly how long the movement takes to settle (s). For the docs, for
    /// tests, and for timing a follow-up after the motion ends.
    var duration: TimeInterval {
        switch self {
        case .snappy: return 0.28
        case .smooth: return 0.42
        case .enter: return 0.5
        case .urgent: return 0.22
        case .appear: return 0.36
        case .dismiss: return 0.2
        case .emphasis: return 0.3
        case .celebrate: return 0.55
        case .livePulse: return Self.livePulsePeriod / 2
        }
    }

    static let reduced: Animation = .easeInOut(duration: reducedDuration)
    static let reducedDuration: TimeInterval = 0.18

    /// A full breath (in + out) of a live indicator: slow enough to read as
    /// «alive», never as «look at me».
    static let livePulsePeriod: TimeInterval = 2.4
    /// SOS: deliberate, not frantic (50 per minute, a calm heartbeat).
    static let urgentPulsePeriod: TimeInterval = 1.2
}

/// Which kind of repeating indicator is asking to run.
enum SaryLoopKind: Equatable, CaseIterable {
    /// «مباشر»: the live dot, an on-air halo. Never in drive mode.
    case live
    /// SOS (mine or a friend's): the only loop allowed while driving.
    case urgent
    /// Loading placeholders.
    case skeleton

    /// One full cycle (s).
    var period: TimeInterval {
        switch self {
        case .live: return SaryMotion.livePulsePeriod
        case .urgent: return SaryMotion.urgentPulsePeriod
        case .skeleton: return 1.8
        }
    }
}

/// How a repeating indicator may run right now.
enum SaryLoopMode: Equatable {
    /// Static: nothing repeats.
    case off
    /// Opacity only (Reduce Motion: no scale, no travel).
    case fade
    /// The designed breathe / ripple.
    case full
}

/// Pure rules deciding when motion may play (unit-tested in DesignSystemTests).
enum SaryMotionPolicy {
    /// A loop never runs when its subject is not live, when the app is not in
    /// the foreground, or when the view is gone (the caller stops on
    /// disappear). Only SOS loops in drive mode; under Reduce Motion only SOS
    /// keeps a slow fade, everything else is static.
    static func loop(_ kind: SaryLoopKind, active: Bool, reduceMotion: Bool, drive: Bool, sceneActive: Bool) -> SaryLoopMode {
        guard active, sceneActive else { return .off }
        switch kind {
        case .urgent: return reduceMotion ? .fade : .full
        case .live, .skeleton: return (reduceMotion || drive) ? .off : .full
        }
    }

    /// Whether a transition may travel (move / scale) or must only fade.
    /// Peripheral motion (chips on the map, toasts, status chrome) only fades
    /// in drive mode: movement in the corner of the eye pulls it off the road.
    static func travels(reduceMotion: Bool, drive: Bool, peripheral: Bool) -> Bool {
        !reduceMotion && !(drive && peripheral)
    }
}

// MARK: - Transitions

/// Insert / remove transitions. They take the theme because an
/// `AnyTransition` cannot read the environment: under Reduce Motion (and for
/// peripheral pieces in drive mode) every one of them is a plain cross-fade.
/// Pair with an animation from `theme.animation(_:)` at the change site.
/// Edges are semantic (`.leading` / `.trailing`), so RTL mirrors for free.
enum SaryTransition {
    /// A card rising from the bottom edge (sheet cards, arrival card).
    /// Leaves by fading and settling a little, without travelling back.
    static func card(_ theme: SaryTheme) -> AnyTransition {
        guard SaryMotionPolicy.travels(reduceMotion: theme.reduceMotion, drive: theme.drive, peripheral: false) else { return .opacity }
        return .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                           removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
    }

    /// A banner sliding down from the top edge (navigation banner, alert lane
    /// cards under the status capsule). Leaves in place, fading and settling.
    static func banner(_ theme: SaryTheme) -> AnyTransition {
        guard SaryMotionPolicy.travels(reduceMotion: theme.reduceMotion, drive: theme.drive, peripheral: false) else { return .opacity }
        return .asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                           removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
    }

    /// A short confirmation («نُسخ»): a small rise and fade. Peripheral.
    static func toast(_ theme: SaryTheme) -> AnyTransition {
        guard SaryMotionPolicy.travels(reduceMotion: theme.reduceMotion, drive: theme.drive, peripheral: true) else { return .opacity }
        return .offset(y: 10).combined(with: .opacity)
    }

    /// A chip or badge popping in place (map chips, a badge on a chip).
    /// Peripheral: only fades in drive mode.
    static func chipPop(_ theme: SaryTheme) -> AnyTransition {
        guard SaryMotionPolicy.travels(reduceMotion: theme.reduceMotion, drive: theme.drive, peripheral: true) else { return .opacity }
        return .scale(scale: 0.6).combined(with: .opacity)
    }

    /// Content appearing in place (state views, a card's body).
    static func appear(_ theme: SaryTheme) -> AnyTransition {
        guard SaryMotionPolicy.travels(reduceMotion: theme.reduceMotion, drive: theme.drive, peripheral: false) else { return .opacity }
        return .scale(scale: 0.96).combined(with: .opacity)
    }

    /// A panel entering from a side. `.leading` is the right edge in Arabic.
    static func side(_ edge: HorizontalEdge, _ theme: SaryTheme) -> AnyTransition {
        guard SaryMotionPolicy.travels(reduceMotion: theme.reduceMotion, drive: theme.drive, peripheral: false) else { return .opacity }
        return .move(edge: edge == .leading ? .leading : .trailing).combined(with: .opacity)
    }

    /// Number roll for a live value (speed, distance, count): digits roll in
    /// the direction the value moved; a cross-fade under Reduce Motion.
    static func number(_ value: Double, _ theme: SaryTheme) -> ContentTransition {
        theme.reduceMotion ? .opacity : .numericText(value: value)
    }
}

// MARK: - Haptics

/// The haptic vocabulary: five meanings, one feeling each. Components never
/// pick a raw `SensoryFeedback`; they name the event (`View.saryHaptic`).
enum SaryHapticEvent: Equatable, CaseIterable {
    /// A choice changed (segment, toggle, detent, capsule expanded).
    case selection
    /// An action the person took went through (copied, saved, sent).
    case confirm
    /// Arrived at a destination / rally point.
    case arrival
    /// Safety: needs attention now (off track, flood, someone separated).
    case warning
    /// Emergency (sending SOS, a friend's SOS).
    case sos

    /// Critical events still play while driving.
    var isCritical: Bool { self == .warning || self == .sos }

    var feedback: SensoryFeedback {
        switch self {
        case .selection: return .selection
        case .confirm: return .impact(flexibility: .soft, intensity: 0.7)
        case .arrival: return .success
        case .warning: return .warning
        case .sos: return .error
        }
    }
}

/// Pure haptics policy (unit-tested) plus an imperative player for code that
/// is not a view (controllers). The system «System Haptics» switch still
/// applies on top: the OS drops feedback the person turned off.
enum SaryHaptics {
    /// While driving only critical events vibrate (a phone in a mount buzzing
    /// for a tap is noise). SOS is never muted, not even by `enabled`.
    static func allows(_ event: SaryHapticEvent, driving: Bool, enabled: Bool = true) -> Bool {
        if event == .sos { return true }
        guard enabled else { return false }
        return !driving || event.isCritical
    }

    /// For controllers outside the view tree. Views use `.saryHaptic(_:trigger:)`.
    @MainActor
    static func play(_ event: SaryHapticEvent, driving: Bool, enabled: Bool = true) {
        guard allows(event, driving: driving, enabled: enabled) else { return }
        switch event {
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        case .confirm: UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7)
        case .arrival: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .sos: UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

// MARK: - Icons (SF Symbols)

/// One place for every symbol, so the same idea always uses the same glyph.
enum SaryIcon {
    static let back = "chevron.backward" // auto-mirrors in RTL
    /// Row disclosure («ادخل»): points left in RTL, right in LTR. Never `chevron.left`/`.right`.
    static let disclosure = "chevron.forward"
    static let close = "xmark"
    static let locate = "location.fill"
    static let locateFollow = "location.north.line.fill"
    static let fitGroup = "person.3.fill"
    static let note = "text.bubble.fill"
    static let nearest = "fuelpump.fill"
    static let layers = "square.3.layers.3d"
    static let compass = "safari"
    static let sos = "sos"
    static let mic = "mic.fill"
    static let send = "arrow.up"
    static let play = "play.fill"
    static let stop = "stop.fill"
    static let rally = "flag.fill"
    /// «طريق الرجعة» (back along my trail).
    static let backTrack = "arrow.uturn.backward"
    static let rallyArrived = "flag.checkered"
    static let drift = "arrow.up.right.and.arrow.down.left"
    static let warning = "exclamationmark.triangle.fill"
    static let connection = "antenna.radiowaves.left.and.right"
    static let gps = "location.fill"
    static let gpsOff = "location.slash.fill"
    static let internet = "network"
    static let offline = "wifi.slash"
    static let pause = "pause.fill"
    static let phone = "phone.fill"
    static let message = "message.fill"
    static let showOnMap = "scope"
    static let directions = "arrow.triangle.turn.up.right.diamond.fill"
    static let share = "square.and.arrow.up"
    static let copy = "doc.on.doc"
    static let settings = "gearshape.fill"
    static let car = "car.fill"
    static let drive = "steeringwheel"
    static let night = "moon.stars.fill"
    static let check = "checkmark"
    static let checkCircle = "checkmark.circle.fill"
    static let retry = "arrow.clockwise"
    static let empty = "tray"
    static let error = "exclamationmark.circle.fill"
    static let crown = "crown.fill"
    static let shield = "shield.lefthalf.filled"

    static func battery(_ percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
