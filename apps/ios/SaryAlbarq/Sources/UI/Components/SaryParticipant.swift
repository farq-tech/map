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
    @Environment(\.sary) private var theme

    var body: some View {
        let style = SaryPresenceStyle(presence: presence)
        let carColor = Color(rgb: color)
        ZStack {
            Circle().fill(carColor)
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill().clipShape(Circle())
            } else {
                Text(initial)
                    .font(.sary(size * 0.44, .bold))
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
        .overlay(alignment: .bottomTrailing) {
            if style.paused {
                Image(systemName: SaryIcon.pause)
                    .font(.system(size: size * 0.22, weight: .heavy))
                    .foregroundStyle(theme.palette.textPrimary)
                    .frame(width: size * 0.42, height: size * 0.42)
                    .background(Circle().fill(theme.palette.surface))
                    .overlay(Circle().stroke(theme.palette.stale, lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
        }
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
                Image(systemName: "clock").font(.system(size: 10, weight: .bold))
            case .paused:
                Image(systemName: SaryIcon.pause).font(.system(size: 9, weight: .heavy))
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
                    .font(.system(size: 9, weight: .bold))
                Text(role == .leader ? "صاحب الطلعة" : "مساعد").saryText(.micro)
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
                               presence: participant.presence, size: theme.drive ? 48 : 40)
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
                        line {
                            SaryPresenceBadge(presence: participant.presence, now: now)
                            if let b = participant.batteryPercent { SaryBatteryLabel(percent: b) }
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
        }
        .buttonStyle(SaryRowPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibility))
        .accessibilityHint(Text("اضغط لعرض بطاقة المشارك"))
    }

    private var accessibility: String {
        var parts = [participant.name]
        if let r = participant.roleLabel { parts.append(r) }
        if let n = SaryCarColors.name(for: participant.color) { parts.append("السيارة \(n)") }
        parts.append(SaryPresenceStyle(presence: participant.presence).accessibilityLabel(now: now))
        if let d = participant.distanceMeters, !participant.isMe { parts.append("على بعد \(SaryFormat.distance(meters: d))") }
        if let b = participant.bearingDegrees, !participant.isMe { parts.append(SaryFormat.relativeDirection(b)) }
        if let bat = participant.batteryPercent { parts.append("البطارية \(SaryFormat.percent(bat))") }
        return parts.joined(separator: "، ")
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
    @State private var confirmRemove = false

    var body: some View {
        let p = state.participant
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

            if p.distanceMeters != nil || p.batteryPercent != nil {
                HStack(spacing: theme.space(.m)) {
                    stat(title: "المسافة") {
                        SaryDistanceLabel(meters: p.distanceMeters, bearing: p.bearingDegrees, style: .headline)
                    }
                    if let b = p.batteryPercent {
                        stat(title: "البطارية") { SaryBatteryLabel(percent: b).saryText(.headline) }
                    }
                }
            }

            if case .stale(let since) = p.presence {
                SaryInlineMessage(text: "\(SaryFormat.lastUpdate(since: since, now: state.now)) · قد يكون مكانه تغيّر", tone: .warning)
            }

            HStack(spacing: theme.space(.s)) {
                Button(action: actions.call) { SaryButtonLabel(title: "اتصال", systemImage: SaryIcon.phone) }
                    .buttonStyle(.sary(.secondary))
                    .disabled(!p.hasPhone)
                Button(action: actions.whatsApp) { SaryButtonLabel(title: "واتساب", systemImage: SaryIcon.message) }
                    .buttonStyle(.sary(.secondary))
                    .disabled(!p.hasPhone)
            }
            Button(action: actions.showOnMap) { SaryButtonLabel(title: "أظهره على الخريطة", systemImage: SaryIcon.showOnMap) }
                .buttonStyle(.saryPrimary)

            if state.canManage {
                VStack(spacing: 0) {
                    Button(action: actions.promoteCoLeader) { SaryButtonLabel(title: p.role == .coLeader ? "ألغِ صفة المساعد" : "اجعله مساعدًا", systemImage: SaryIcon.shield) }
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
