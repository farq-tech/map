import SwiftUI

// «انقطع الإرسال»: the alert-lane card and the small badge on a chip / row.
// Red-amber: more than a stale fix (amber), less than an SOS (red).

/// A friend whose sharing went silent (the server decided, 10 or 30 min).
struct SilentAlertUI: Equatable {
    var participantId: String
    var name: String
    var color: UInt32
    /// When their last fix reached the server (device clock).
    var since: Date
    /// 10 or 30.
    var level: Int
    /// Their last known fix: «اتجه» goes there. Nil hides «اتجه».
    var lastLat: Double?
    var lastLng: Double?
    /// When that fix was taken (device clock).
    var lastAt: Date?
    /// They added a phone number: «اتصال».
    var hasPhone: Bool

    var hasLast: Bool { lastLat != nil && lastLng != nil }
}

struct SilentAlertActions {
    /// «اتجه»: directions to their last known position.
    var go: (_ participantId: String) -> Void = { _ in }
    /// «اتصال»: dial them.
    var call: (_ participantId: String) -> Void = { _ in }
}

struct SarySilentCard: View {
    var alert: SilentAlertUI
    var tapped: () -> Void = {}
    var dismiss: () -> Void = {}
    var actions: SilentAlertActions = .init()
    @Environment(\.sary) private var theme
    @Environment(\.saryWidthClass) private var widthClass

    var body: some View {
        let p = theme.palette
        let shape = RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous)
        /* On a 320 pt screen the three round buttons leave ~40 pt for the name: let it wrap there
         * rather than shrink to «انقطع…». Standard iPhones keep the one compact line. */
        let titleLines = widthClass == .narrow ? 2 : 1
        /* UX ٢١: one compact row (~56 pt) — it must not cover the map while driving. The actions
         * are round 44 pt buttons beside the text, not a second row of pills. */
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            HStack(spacing: theme.space(.s)) {
                Button(action: tapped) {
                    HStack(spacing: theme.space(.s)) {
                        ZStack(alignment: .bottomTrailing) {
                            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(p.emergencyText)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(LinearGradient(colors: [p.emergency.opacity(0.22), p.warning.opacity(0.26)],
                                                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
                            Circle().fill(Color(rgb: alert.color)).frame(width: 10, height: 10)
                                .overlay(Circle().stroke(p.background, lineWidth: 2))
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(SilenceText.title(name: alert.name, since: alert.since, now: ctx.date))
                                .saryText(.footnote, weight: .bold)
                                .foregroundStyle(p.textPrimary)
                                .lineLimit(titleLines)
                                .minimumScaleFactor(0.8)
                            Text(SilenceText.lastFix(alert.hasLast ? (alert.lastAt ?? alert.since) : nil, now: ctx.date))
                                .saryNumber(.caption, weight: .medium)
                                .foregroundStyle(p.warningText)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("\(SilenceText.title(name: alert.name, since: alert.since, now: ctx.date))، \(SilenceText.lastFix(alert.hasLast ? (alert.lastAt ?? alert.since) : nil, now: ctx.date))"))
                .accessibilityHint(Text("اضغط لعرض آخر موقع على الخريطة"))
                if alert.hasLast {
                    roundAction("اتجه", icon: SaryIcon.directions, fill: p.warning, ink: p.warningText) { actions.go(alert.participantId) }
                        .accessibilityIdentifier("silent-go")
                }
                if alert.hasPhone {
                    roundAction("اتصال", icon: SaryIcon.phone, fill: p.emergency, ink: p.emergencyText) { actions.call(alert.participantId) }
                        .accessibilityIdentifier("silent-call")
                }
                SaryDismissButton(action: dismiss)
            }
            .padding(.leading, theme.space(.s))
            .padding(.trailing, theme.space(.xs))
            .padding(.vertical, theme.space(.xs))
            .saryGlass(shape, role: .panel)
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [p.emergency.opacity(0.85), p.warning.opacity(0.85)], startPoint: .leading, endPoint: .trailing),
                                   lineWidth: alert.level >= 30 ? 2 : 1.4)
            }
        }
        .accessibilityIdentifier("silent-card")
    }

    private func roundAction(_ title: String, icon: String, fill: Color, ink: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(ink)
                .frame(width: 44, height: 44)
                .background(Circle().fill(fill.opacity(0.16)))
                .overlay(Circle().strokeBorder(fill.opacity(0.45), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityLabel(Text(title))
    }
}

/// «انقطع منذ ١٠ د» — replaces the presence badge on a row while a friend is silent.
struct SarySilentBadge: View {
    var since: Date
    var now: Date
    var compact = false
    /// Known reason: «ما فيه شبكة — آخر موقع قبل ٥ د» (compact: the reason only, the map stays calm).
    var reason: PresenceReason? = nil

    private var line: String {
        guard let reason else { return SilenceText.badge(since: since, now: now) }
        return compact ? reason.text : SilenceText.badge(since: since, now: now, reason: reason)
    }

    private var icon: String {
        switch reason {
        case .hidden: return "eye.slash.fill"
        case .locationOff: return "location.slash.fill"
        case .appClosed: return "xmark.app.fill"
        case .whenInUse: return "lock.fill"
        case .web: return "safari.fill"
        case .noGps: return "location.magnifyingglass"
        case .lowPower: return "battery.25percent"
        case .noNetwork, .none: return "antenna.radiowaves.left.and.right.slash"
        }
    }
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        HStack(spacing: 4) {
            Image(systemName: icon).saryGlyph(compact ? 8 : 10, weight: .bold)
            Text(line)
                .saryText(compact ? .micro : .caption, weight: .bold)
                .lineLimit(1)
        }
        .foregroundStyle(p.emergencyText)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 3)
        .background(Capsule().fill(LinearGradient(colors: [p.emergency.opacity(0.16), p.warning.opacity(0.22)], startPoint: .leading, endPoint: .trailing)))
        .overlay(Capsule().strokeBorder(p.warning.opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(reason.map { SilenceText.badge(since: since, now: now, reason: $0) } ?? SilenceText.badge(since: since, now: now)))
        .accessibilityIdentifier("silent-badge")
    }
}
