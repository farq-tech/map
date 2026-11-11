import SwiftUI
import UIKit

// MARK: - Presence styling (one source of truth)

/// How presence is drawn everywhere. An old position NEVER looks live:
/// stale = desaturated + dashed ring + age; paused = desaturated + pause glyph.
struct SaryPresenceStyle {
    var presence: ParticipantPresence

    var saturation: Double { presence.isLive ? 1 : 0.15 }
    var opacity: Double { presence.isLive ? 1 : 0.72 }
    var dashed: Bool { if case .stale = presence { return true }; return false }
    var paused: Bool { presence == .paused }

    /// The presence without its timestamp: what motion keys on, so a member
    /// going live → stale → paused animates once per change (a smooth colour
    /// and opacity shift), not every time the «since» moves.
    enum Phase: Equatable { case live, stale, paused }
    var phase: Phase {
        switch presence {
        case .live: return .live
        case .stale: return .stale
        case .paused: return .paused
        }
    }

    func label(now: Date) -> String {
        switch presence {
        case .live: return "مباشر"
        /* Stale is never «الآن»: under a minute it is still «آخر موقع», not live. */
        case .stale(let since): return now.timeIntervalSince(since) < 60 ? "آخر موقع" : SaryFormat.elapsed(since: since, now: now)
        case .paused: return "متوقف"
        }
    }

    func accessibilityLabel(now: Date) -> String {
        switch presence {
        case .live: return "موقعه مباشر"
        case .stale(let since): return SaryFormat.lastUpdate(since: since, now: now)
        case .paused: return "أوقف مشاركة موقعه"
        }
    }
}

// MARK: - Avatar

/// Initials (or photo) on the car colour, with a colour ring. Stale = grey,
/// dashed ring; paused = grey with a pause badge.
struct SaryAvatar: View {
    var name: String
    var color: UInt32
    var photo: UIImage? = nil
    var presence: ParticipantPresence = .live
    var size: CGFloat = 44
    /// A small badge of their car (CarIcon) in their colour, at the bottom corner.
    var car: Bool = false
    @Environment(\.sary) private var theme

    var body: some View {
        let style = SaryPresenceStyle(presence: presence)
        let carColor = Color(rgb: color)
        ZStack {
            Circle().fill(carColor)
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill().clipShape(Circle())
            } else {
                /* Fixed size: the circle does not grow with Dynamic Type, so neither does its letter. */
                Text(initial)
                    .font(.saryFixed(size * 0.44, .bold))
                    .foregroundStyle(SaryCarColors.ink(on: color))
                    .offset(y: size * 0.03)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if SaryCarColors.needsOutline(color, onDark: !theme.isLight) {
                Circle().strokeBorder(theme.palette.textTertiary.opacity(0.6), lineWidth: 1)
            }
        }
        .saturation(style.saturation)
        .opacity(style.opacity)
        .padding(3.5)
        .overlay {
            Circle()
                .strokeBorder(presence.isLive ? carColor : theme.palette.stale,
                              style: StrokeStyle(lineWidth: 2.5, dash: style.dashed ? [4, 3] : []))
        }
        .overlay(alignment: .bottomLeading) {
            if car, let img = CarIcon.image(color) {
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(height: size * 0.62)
                    .saturation(style.saturation)
                    .offset(x: -size * 0.14, y: size * 0.12)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if style.paused {
                Image(systemName: SaryIcon.pause)
                    .font(.system(size: size * 0.22, weight: .heavy))
                    .foregroundStyle(theme.palette.textPrimary)
                    .frame(width: size * 0.42, height: size * 0.42)
                    .background(Circle().fill(theme.palette.surface))
                    .overlay(Circle().stroke(theme.palette.stale, lineWidth: 1.5))
                    /* Outward on the trailing side in RTL and LTR alike (not `.offset(x:)`). */
                    .padding(.trailing, -2).padding(.bottom, -2)
                    .transition(SaryTransition.chipPop(theme))
            }
        }
        /* Live → late → silent: colour drains and the ring turns dashed smoothly, never a jump. */
        .saryAnimation(.smooth, value: style.phase)
        .accessibilityHidden(true)
    }

    private var initial: String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(1))
    }
}

// MARK: - Presence badge

struct SaryPresenceBadge: View {
    var presence: ParticipantPresence
    var now: Date
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let style = SaryPresenceStyle(presence: presence)
        HStack(spacing: 4) {
            switch presence {
            case .live:
                Circle().fill(p.live).frame(width: 7, height: 7)
            case .stale:
                Image(systemName: "clock").saryGlyph(10, weight: .bold)
            case .paused:
                Image(systemName: SaryIcon.pause).saryGlyph(9, weight: .heavy)
            }
            Text(style.label(now: now))
                .saryText(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(presence.isLive ? p.liveText : p.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(presence.isLive ? p.live.opacity(0.15) : p.stale.opacity(0.18)))
        .overlay {
            if style.dashed {
                Capsule().strokeBorder(p.stale, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .saryAnimation(.smooth, value: style.phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(style.accessibilityLabel(now: now)))
    }
}

// MARK: - Bearing arrow (never mirrored)

struct SaryArrowShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY - r.height * 0.3))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Points toward `degrees` (clockwise from screen-up). Drawn in an LTR
/// context so RTL layout never mirrors a real-world direction.
struct SaryBearingArrow: View {
    var degrees: Double
    var color: Color
    var size: CGFloat = 14
    @Environment(\.sary) private var theme

    var body: some View {
        SaryArrowShape()
            .fill(color)
            .frame(width: size * 0.78, height: size)
            .rotationEffect(.degrees(degrees))
            .animation(theme.animation(.smooth), value: degrees)
            .frame(width: size * 1.2, height: size * 1.2)
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityHidden(true)
    }
}

/// «٩٠٠ م» + arrow, fixed-width digits so it never jitters while updating.
struct SaryDistanceLabel: View {
    var meters: Double?
    var bearing: Double?
    var color: Color? = nil
    var style: SaryTextStyle = .subhead
    @Environment(\.sary) private var theme

    var body: some View {
        HStack(spacing: 4) {
            if let bearing {
                SaryBearingArrow(degrees: bearing, color: color ?? theme.palette.accentText,
                                 size: style.size * theme.typeScale * 0.95)
            }
            if let meters {
                Text(SaryFormat.distance(meters: meters))
                    .saryNumber(style)
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibility))
    }

    private var accessibility: String {
        var s: [String] = []
        if let meters { s.append("على بعد \(SaryFormat.distance(meters: meters))") }
        if let bearing { s.append(SaryFormat.relativeDirection(bearing)) }
        return s.joined(separator: "، ")
    }
}

// MARK: - Battery

struct SaryBatteryLabel: View {
    var percent: Int
    @Environment(\.sary) private var theme

    var body: some View {
        let low = percent <= 20
        HStack(spacing: 3) {
            Image(systemName: SaryIcon.battery(percent))
                .font(.system(size: 13, weight: .semibold))
                .environment(\.layoutDirection, .leftToRight)
            Text(SaryFormat.percent(percent)).saryNumber(.caption, weight: .medium)
        }
        .foregroundStyle(low ? theme.palette.emergencyText : theme.palette.textSecondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("البطارية \(SaryFormat.percent(percent))"))
    }
}

// MARK: - Role chip

struct SaryRoleChip: View {
    var role: ParticipantRole
    @Environment(\.sary) private var theme
    var body: some View {
        if role != .member {
            HStack(spacing: 3) {
                Image(systemName: role == .leader ? SaryIcon.crown : SaryIcon.shield)
                    .saryGlyph(9, weight: .bold)
                /* Stays 11 pt (it sits beside the one-line name, which would truncate sooner);
                 * the heaviest weight keeps it legible. Drive mode floors it at 12 pt. */
                Text(role == .leader ? "أمير الطلعة" : "نائب الأمير").saryText(.micro, weight: .heavy)
            }
            .foregroundStyle(theme.palette.accentText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.palette.accent.opacity(0.14)))
        }
    }
}

// MARK: - Participant row

struct SaryParticipantRow: View {
    var participant: ParticipantUI
    var now: Date
    var action: () -> Void = {}
    @Environment(\.sary) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            let stack = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: theme.space(.s)))
                : AnyLayout(HStackLayout(spacing: theme.space(.m)))
            stack {
                HStack(spacing: theme.space(.m)) {
                    SaryAvatar(name: participant.name, color: participant.color, photo: participant.photo,
                               presence: participant.presence, size: theme.drive ? 48 : 40, car: true)
                    let ax = typeSize.isAccessibilitySize
                    let line = ax ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        line {
                            Text(participant.isMe ? "\(participant.name) (أنت)" : participant.name)
                                .saryText(.bodyStrong)
                                .foregroundStyle(participant.presence.isLive ? theme.palette.textPrimary : theme.palette.textSecondary)
                                .lineLimit(ax ? 3 : 1)
                            SaryRoleChip(role: participant.role)
                        }
                        if let nick = participant.nickname {
                            Text(nick).saryText(.caption).foregroundStyle(theme.palette.textTertiary).lineLimit(1)
                                .accessibilityIdentifier("participant.nickname")
                        }
                        /* Badges wrap to a second line instead of overflowing into the distance
                         * (Display Zoom, large text); one line, as before, when they fit. */
                        let badges = ax ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(SaryFlowLayout(spacing: 6, lineSpacing: 4))
                        badges {
                            if let s = participant.silentSince { SarySilentBadge(since: s, now: now, reason: participant.presenceReason) }
                            else if let r = participant.presenceReason, let s = participant.presence.staleSince ?? (participant.neverShared ? now : nil) {
                                /* Not live yet not «silent» (under 10 min, or never sent): say why, calmly. */
                                SarySilentBadge(since: s, now: now, reason: r).accessibilityIdentifier("participant.presenceReason")
                            }
                            else if participant.neverShared {
                                Text(SaryParticipantRow.neverSharedText).saryText(.caption, weight: .bold).foregroundStyle(theme.palette.textSecondary)
                                    .accessibilityIdentifier("participant.neverShared")
                            }
                            else { SaryPresenceBadge(presence: participant.presence, now: now) }
                            if participant.viaNearby { SaryNearbyMark() }
                            if let k = participant.speedKmh, participant.presence.isLive { SarySpeedLabel(kmh: k) }
                            if let b = participant.batteryPercent { SaryBatteryLabel(percent: b) }
                        }
                        if let line = SaryConvoyLine.text(participant, now: now) {
                            Text(line)
                                .saryNumber(.caption, weight: .bold)
                                .foregroundStyle(participant.stoppedSince != nil ? theme.palette.warningText : theme.palette.textSecondary)
                                .lineLimit(1)
                                .accessibilityIdentifier("participant.convoy")
                        }
                        if participant.tripArrived {
                            SaryTripArrivedBadge().transition(SaryTransition.chipPop(theme))
                        } else if let r = participant.tripRemainingMeters {
                            Text("باقي \(SaryFormat.distance(meters: r))" + (participant.tripRemainingApprox ? " تقريبًا" : "") + " للوجهة")
                                .saryNumber(.caption, weight: .bold)
                                .foregroundStyle(theme.palette.textSecondary)
                                .lineLimit(1)
                                .accessibilityIdentifier("participant.tripRemaining")
                        }
                    }
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: 4) }
                if !participant.isMe {
                    SaryDistanceLabel(meters: participant.distanceMeters, bearing: participant.bearingDegrees,
                                      color: participant.presence.isLive ? nil : theme.palette.stale)
                        .opacity(participant.presence.isLive ? 1 : 0.7)
                }
            }
            .padding(.vertical, theme.space(.s))
            .padding(.horizontal, theme.space(.m))
            .frame(minHeight: theme.minTarget + 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            /* Presence changes (live → late → silent) recolour the row in one smooth shift. */
            .saryAnimation(.smooth, value: SaryPresenceStyle(presence: participant.presence).phase)
            .saryAnimation(.smooth, value: participant.silentSince != nil)
            .saryAnimation(.celebrate, value: participant.tripArrived)
        }
        .buttonStyle(SaryRowPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibility))
        .accessibilityHint(Text("اضغط لعرض بطاقة المشارك"))
    }

    static let neverSharedText = "ما شارك موقعه"

    private var accessibility: String {
        var parts = [participant.name]
        if let n = participant.nickname { parts.append(n) }
        if let r = participant.roleLabel { parts.append(r) }
        if let n = SaryCarColors.name(for: participant.color) { parts.append("السيارة \(n)") }
        parts.append(participant.silentSince.map { SilenceText.badge(since: $0, now: now, reason: participant.presenceReason) }
                     ?? participant.presenceReason.map { $0.text }
                     ?? (participant.neverShared ? Self.neverSharedText : SaryPresenceStyle(presence: participant.presence).accessibilityLabel(now: now)))
        if participant.viaNearby { parts.append(SaryNearbyMark.text) }
        if let d = participant.distanceMeters, !participant.isMe { parts.append("على بعد \(SaryFormat.distance(meters: d))") }
        if let b = participant.bearingDegrees, !participant.isMe { parts.append(SaryFormat.relativeDirection(b)) }
        if let k = participant.speedKmh, participant.presence.isLive { parts.append(SarySpeedLabel.accessibility(kmh: k)) }
        if let bat = participant.batteryPercent { parts.append("البطارية \(SaryFormat.percent(bat))") }
        if let c = SaryConvoyLine.text(participant, now: now) { parts.append(c) }
        if participant.tripArrived { parts.append("وصل الوجهة") }
        else if let r = participant.tripRemainingMeters { parts.append("باقي \(SaryFormat.distance(meters: r)) للوجهة") }
        return parts.joined(separator: "، ")
    }
}

/// «عن أمير الرحلة ١٫٢ كم» / «عن المقدمة …» · «واقف منذ ٤ د» on a member's row (unit-tested).
enum SaryConvoyLine {
    /// Shown once a live car has stood still this long (a red light is not «واقف»).
    static let stoppedAfterS: TimeInterval = 60

    static func text(_ p: ParticipantUI, now: Date) -> String? {
        var parts: [String] = []
        /* The owner's row already says «أمير الرحلة» on its role chip; «المقدمة» is said here. */
        if p.isConvoyLeader { if p.leaderTitle == "المقدمة" { parts.append("المقدمة") } }
        else if let d = p.leaderDistanceMeters { parts.append("عن \(p.leaderTitle) \(SaryFormat.distance(meters: d))") }
        if let s = p.stoppedSince, p.presence.isLive, now.timeIntervalSince(s) >= stoppedAfterS {
            parts.append("واقف منذ \(SaryFormat.number(Int(now.timeIntervalSince(s) / 60))) د")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct SaryRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        var configuration: ButtonStyleConfiguration
        @Environment(\.sary) private var theme
        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: SaryRadius.s, style: .continuous)
                        .fill(theme.palette.textPrimary.opacity(configuration.isPressed ? 0.07 : 0))
                )
        }
    }
}

// MARK: - Participant card

struct SaryParticipantCard: View {
    var state: ParticipantCardUIState
    var actions: ParticipantCardActions = .init()
    @Environment(\.sary) private var theme
    @Environment(\.saryWidthClass) private var widthClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var confirmRemove = false

    var body: some View {
        let p = state.participant
        /* Two buttons side by side leave ~100 pt each on a 320 pt screen: stack them there. */
        let pair = widthClass == .narrow || typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: theme.space(.s)))
            : AnyLayout(HStackLayout(spacing: theme.space(.s)))
        VStack(spacing: theme.space(.l)) {
            HStack(alignment: .center, spacing: theme.space(.m)) {
                SaryAvatar(name: p.name, color: p.color, photo: p.photo, presence: p.presence, size: theme.drive ? 68 : 58)
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.name)
                        .saryText(.title2)
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        SaryRoleChip(role: p.role)
                        SaryPresenceBadge(presence: p.presence, now: state.now)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            let speed = p.presence.isLive ? p.speedKmh : nil
            if p.distanceMeters != nil || p.batteryPercent != nil || speed != nil {
                /* Side by side when the numbers fit (every standard iPhone), stacked when they would
                 * overflow their boxes (Display Zoom, large text). */
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: theme.space(.m)) { stats(p, speed: speed) }
                    VStack(spacing: theme.space(.s)) { stats(p, speed: speed) }
                }
            }

            if let r = p.presenceReason {
                /* Why they are not live, and what fixes it — never a vague «انقطع». */
                SaryInlineMessage(text: [r.text, r.fix].compactMap { $0 }.joined(separator: " · "), tone: r == .hidden ? .info : .warning)
                    .accessibilityIdentifier("participant.reason")
            } else if case .stale(let since) = p.presence {
                SaryInlineMessage(text: "\(SaryFormat.lastUpdate(since: since, now: state.now)) · قد يكون مكانه تغيّر", tone: .warning)
            }
            if state.canNudge {
                Button(action: actions.nudge) { SaryButtonLabel(title: "نبّهه", systemImage: "bell.badge.fill") }
                    .buttonStyle(.sary(.secondary))
                    .accessibilityIdentifier("participant.nudge")
            }

            pair {
                Button(action: actions.call) { SaryButtonLabel(title: "اتصال", systemImage: SaryIcon.phone) }
                    .buttonStyle(.sary(.secondary))
                    .disabled(!p.hasPhone)
                Button(action: actions.whatsApp) { SaryButtonLabel(title: "واتساب", systemImage: SaryIcon.message) }
                    .buttonStyle(.sary(.secondary))
                    .disabled(!p.hasPhone)
            }
            pair {
                Button(action: actions.showOnMap) { SaryButtonLabel(title: "أظهره على الخريطة", systemImage: SaryIcon.showOnMap) }
                    .buttonStyle(.saryPrimary)
                if !p.isMe {
                    /* «اتجه» (was «روح له»): only to a live position; an old one explains why instead of guiding. */
                    Button(action: actions.navigate) { SaryButtonLabel(title: SaryCopy.go, systemImage: SaryIcon.directions) }
                        .buttonStyle(.sary(.secondary))
                        .opacity(p.presence.isLive ? 1 : 0.55)
                        .accessibilityIdentifier("participant.navigate")
                }
            }

            if state.canManage {
                VStack(spacing: 0) {
                    Button(action: actions.promoteCoLeader) { SaryButtonLabel(title: p.role == .coLeader ? "ألغِ صفة نائب الأمير" : "اجعله نائبًا للأمير", systemImage: SaryIcon.shield) }
                        .buttonStyle(.saryPlain)
                    Button(role: .destructive) { confirmRemove = true } label: {
                        SaryButtonLabel(title: "أزله من الطلعة", systemImage: "person.fill.xmark")
                    }
                    .buttonStyle(.sary(.plainDestructive))
                }
                .disabled(state.isBusy)
            }
            if let e = state.errorMessage { SaryInlineMessage(text: e, tone: .error) }
        }
        .padding(theme.space(.l))
        .confirmationDialog("إزالة \(p.name) من الطلعة؟", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("أزله", role: .destructive, action: actions.removeMember)
            Button("إلغاء", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func stats(_ p: ParticipantUI, speed: Double?) -> some View {
        if p.distanceMeters != nil {
            stat(title: "المسافة") {
                SaryDistanceLabel(meters: p.distanceMeters, bearing: p.bearingDegrees, style: .headline)
            }
        }
        if let k = speed {
            stat(title: "السرعة") { SarySpeedLabel(kmh: k, style: .headline) }
        }
        if let b = p.batteryPercent {
            stat(title: "البطارية") { SaryBatteryLabel(percent: b).saryText(.headline) }
        }
    }

    private func stat<C: View>(title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).saryText(.caption, weight: .medium).foregroundStyle(theme.palette.textSecondary)
            c()
        }
        .padding(theme.space(.m))
        .frame(maxWidth: .infinity, alignment: .leading)
        .sarySurface(radius: SaryRadius.s, fill: theme.palette.sunken)
    }
}

// MARK: - Nearby marker

/// «عبر الأجهزة القريبة»: this position came phone to phone, not from the
/// server. It says where it came from only — its age is still shown by the
/// presence badge, so a relayed old fix never looks live.
struct SaryNearbyMark: View {
    static let text = "عبر الأجهزة القريبة"
    static let icon = "antenna.radiowaves.left.and.right"
    var compact = false
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        HStack(spacing: 3) {
            Image(systemName: Self.icon).saryGlyph(compact ? 8 : 10, weight: .bold)
            /* 11 pt inside a name chip: bold (was medium) so it survives sun glare. */
            Text(Self.text).saryText(.micro, weight: .bold).lineLimit(1)
        }
        .foregroundStyle(p.textSecondary)
        .padding(.horizontal, compact ? 5 : 6)
        .padding(.vertical, compact ? 1 : 2)
        .background(Capsule().fill(p.stale.opacity(0.16)))
        .fixedSize()
        .accessibilityLabel(Text(Self.text))
        .accessibilityIdentifier("nearby-mark")
    }
}


/// «وصل»: reached the destination (the trip).
struct SaryTripArrivedBadge: View {
    @Environment(\.sary) private var theme

    var body: some View {
        Label("وصل", systemImage: "flag.checkered")
            .saryText(.caption, weight: .bold)
            .foregroundStyle(theme.palette.liveText)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(theme.palette.live.opacity(0.16)))
            .accessibilityIdentifier("participant.arrived")
    }
}
