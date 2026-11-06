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

    var body: some View {
        let p = theme.palette
        let shape = RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous)
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            VStack(alignment: .leading, spacing: theme.space(.s)) {
                HStack(spacing: theme.space(.m)) {
                    Button(action: tapped) {
                        HStack(spacing: theme.space(.m)) {
                            ZStack(alignment: .bottomTrailing) {
                                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(p.emergencyText)
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(LinearGradient(colors: [p.emergency.opacity(0.22), p.warning.opacity(0.26)],
                                                                             startPoint: .topLeading, endPoint: .bottomTrailing)))
                                Circle().fill(Color(rgb: alert.color)).frame(width: 12, height: 12)
                                    .overlay(Circle().stroke(p.background, lineWidth: 2))
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(SilenceText.title(name: alert.name, since: alert.since, now: ctx.date))
                                    .saryText(.callout, weight: .bold)
                                    .foregroundStyle(p.textPrimary)
                                    .lineLimit(2)
                                Text(SilenceText.lastFix(alert.hasLast ? (alert.lastAt ?? alert.since) : nil, now: ctx.date))
                                    .saryNumber(.footnote, weight: .medium)
                                    .foregroundStyle(p.warningText)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("\(SilenceText.title(name: alert.name, since: alert.since, now: ctx.date))، \(SilenceText.lastFix(alert.hasLast ? (alert.lastAt ?? alert.since) : nil, now: ctx.date))"))
                    .accessibilityHint(Text("اضغط لعرض آخر موقع على الخريطة"))
                    SaryDismissButton(action: dismiss)
                }
                if alert.hasLast || alert.hasPhone {
                    HStack(spacing: theme.space(.s)) {
                        if alert.hasLast {
                            pill("اتجه", icon: SaryIcon.directions, fill: p.warning, ink: p.warningText) { actions.go(alert.participantId) }
                                .accessibilityIdentifier("silent-go")
                        }
                        if alert.hasPhone {
                            pill("اتصال", icon: SaryIcon.phone, fill: p.emergency, ink: p.emergencyText) { actions.call(alert.participantId) }
                                .accessibilityIdentifier("silent-call")
                        }
                    }
                    .padding(.leading, 36 + theme.space(.m))
                }
            }
            .padding(.leading, theme.space(.m))
            .padding(.trailing, theme.space(.xs))
            .padding(.vertical, theme.space(.s))
            .frame(minHeight: theme.minTarget + 12)
            .saryGlass(shape, role: .panel)
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [p.emergency.opacity(0.85), p.warning.opacity(0.85)], startPoint: .leading, endPoint: .trailing),
                                   lineWidth: alert.level >= 30 ? 2 : 1.4)
            }
        }
        .accessibilityIdentifier("silent-card")
    }

    private func pill(_ title: String, icon: String, fill: Color, ink: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .saryText(.footnote, weight: .bold)
                .foregroundStyle(ink)
                .padding(.horizontal, theme.space(.m))
                .frame(minHeight: max(36, theme.minTarget - 8))
                .background(Capsule().fill(fill.opacity(0.16)))
                .overlay(Capsule().strokeBorder(fill.opacity(0.45), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(SaryPressStyle())
    }
}

/// «انقطع منذ ١٠ د» — replaces the presence badge on a row while a friend is silent.
struct SarySilentBadge: View {
    var since: Date
    var now: Date
    var compact = false
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        HStack(spacing: 4) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash").font(.system(size: compact ? 8 : 10, weight: .bold))
            Text(SilenceText.badge(since: since, now: now))
                .saryText(compact ? .micro : .caption, weight: .bold)
                .lineLimit(1)
        }
        .foregroundStyle(p.emergencyText)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 3)
        .background(Capsule().fill(LinearGradient(colors: [p.emergency.opacity(0.16), p.warning.opacity(0.22)], startPoint: .leading, endPoint: .trailing)))
        .overlay(Capsule().strokeBorder(p.warning.opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(SilenceText.badge(since: since, now: now)))
        .accessibilityIdentifier("silent-badge")
    }
}
