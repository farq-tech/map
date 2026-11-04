import SwiftUI

/// Health of one signal shown in the status capsule.
enum SarySignalLevel: Equatable {
    case good, degraded, bad, unknown

    func color(_ p: SaryPalette) -> Color {
        switch self {
        case .good: return p.live
        case .degraded: return p.warning
        case .bad: return p.emergency
        case .unknown: return p.stale
        }
    }
}

/// The three indicators, derived from the live-outing contract values.
struct SaryStatusSignals: Equatable {
    var connection: SarySignalLevel
    var gps: SarySignalLevel
    var internet: SarySignalLevel

    init(connection: SarySignalLevel, gps: SarySignalLevel, internet: SarySignalLevel) {
        self.connection = connection
        self.gps = gps
        self.internet = internet
    }

    init(connection c: ConnectionStateUI, sharing: MySharingUI, warnings: [LiveWarningUI]) {
        switch c {
        case .connected: connection = .good
        case .connecting, .limited: connection = .degraded
        case .offline: connection = .bad
        }
        if warnings.contains(.locationOff) { gps = .bad }
        else if warnings.contains(.weakGPS) || sharing == .starting { gps = .degraded }
        else if sharing == .paused { gps = .unknown }
        else { gps = .good }
        internet = (warnings.contains(.noInternet) || c == .offline) ? .bad : (c == .limited ? .degraded : .good)
    }

    var allGood: Bool { connection == .good && gps == .good && internet == .good }
}

/// Top-of-map status: back button + capsule with outing name and the
/// connection / GPS / internet dots. Tapping the capsule expands warnings.
struct SaryStatusCapsule: View {
    var outingName: String
    var status: OutingStatusUI
    var connection: ConnectionStateUI
    var sharing: MySharingUI
    var warnings: [LiveWarningUI]
    @Binding var expanded: Bool
    var back: () -> Void = {}
    var warningTapped: (LiveWarningUI) -> Void = { _ in }

    @Environment(\.sary) private var theme

    private var signals: SaryStatusSignals { .init(connection: connection, sharing: sharing, warnings: warnings) }

    var body: some View {
        HStack(alignment: .top, spacing: theme.space(.s)) {
            Button(action: back) {
                Image(systemName: SaryIcon.back)
                    .font(.system(size: theme.drive ? 22 : 17, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .frame(width: barHeight, height: barHeight)
                    .saryGlass(Circle(), role: .chrome, interactive: true)
            }
            .buttonStyle(SaryPressStyle())
            .accessibilityLabel(Text("رجوع"))
            .accessibilityIdentifier("outing-back")

            capsule
        }
        // Chrome over the map caps at AX1 so it never buries the map;
        // full-size text is available in the sheet / screens.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private var barHeight: CGFloat { theme.drive ? 64 : 48 }

    private var capsule: some View {
        let shape = RoundedRectangle(cornerRadius: barHeight / 2, style: .continuous)
        return VStack(spacing: 0) {
            Button {
                guard !warnings.isEmpty else { return }
                expanded.toggle()
            } label: {
                HStack(spacing: theme.space(.s)) {
                    SaryStatusDots(signals: signals)
                        .accessibilityIdentifier("outing-link-state")
                    VStack(alignment: .leading, spacing: 0) {
                        Text(outingName)
                            .saryText(.headline)
                            .foregroundStyle(theme.palette.textPrimary)
                            .lineLimit(2)
                            .accessibilityIdentifier("outing-title")
                        if status != .active || connection != .connected {
                            Text(subtitle)
                                .saryText(.caption, weight: .medium)
                                .foregroundStyle(theme.palette.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !warnings.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: SaryIcon.warning)
                                .font(.system(size: 12, weight: .bold))
                            Text(SaryFormat.number(warnings.count)).saryNumber(.caption)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .bold))
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                        }
                        .foregroundStyle(theme.palette.warningText)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 26)
                        .background(Capsule().fill(theme.palette.warning.opacity(0.16)))
                    }
                }
                .padding(.horizontal, theme.space(.l))
                .frame(minHeight: barHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(accessibilitySummary))
            .accessibilityHint(Text(warnings.isEmpty ? "" : (expanded ? "اضغط لإخفاء التنبيهات" : "اضغط لعرض التنبيهات")))

            if expanded && !warnings.isEmpty {
                VStack(spacing: 0) {
                    ForEach(warnings, id: \.self) { w in
                        Divider().overlay(theme.palette.separator)
                        Button { warningTapped(w) } label: {
                            HStack(spacing: theme.space(.s)) {
                                Image(systemName: icon(w))
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(level(w).color(theme.palette))
                                    .frame(width: 22)
                                Text(w.label)
                                    .saryText(.subhead)
                                    .foregroundStyle(theme.palette.textPrimary)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if w == .locationOff {
                                    Image(systemName: "chevron.backward")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(theme.palette.textTertiary)
                                }
                            }
                            .padding(.horizontal, theme.space(.l))
                            .padding(.vertical, theme.space(.m))
                            .frame(minHeight: theme.minTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipShape(shape)
        .saryGlass(shape, role: .chrome)
        .animation(theme.animation(.smooth), value: expanded)
        .sensoryFeedback(.selection, trigger: expanded)
    }

    private var subtitle: String {
        if connection != .connected { return connection.label }
        return status.label
    }

    private var accessibilitySummary: String {
        var parts = [outingName, connection.label]
        switch signals.gps {
        case .good: parts.append("الموقع دقيق")
        case .degraded: parts.append("إشارة الموقع ضعيفة")
        case .bad: parts.append("الموقع غير متاح")
        case .unknown: parts.append("مشاركة الموقع متوقفة")
        }
        if !warnings.isEmpty { parts.append("\(SaryFormat.number(warnings.count)) تنبيه") }
        return parts.joined(separator: "، ")
    }

    private func icon(_ w: LiveWarningUI) -> String {
        switch w {
        case .weakGPS: return SaryIcon.gps
        case .noInternet: return SaryIcon.offline
        case .keepScreenOn: return "iphone"
        case .locationOff: return SaryIcon.gpsOff
        }
    }

    private func level(_ w: LiveWarningUI) -> SarySignalLevel {
        switch w {
        case .weakGPS: return .degraded
        case .noInternet, .locationOff: return .bad
        case .keepScreenOn: return .unknown
        }
    }
}

/// Three small glyph-dots: shape carries meaning, not only colour.
struct SaryStatusDots: View {
    var signals: SaryStatusSignals
    @Environment(\.sary) private var theme

    var body: some View {
        HStack(spacing: 3) {
            dot(SaryIcon.connection, signals.connection)
            dot(signals.gps == .bad ? SaryIcon.gpsOff : SaryIcon.gps, signals.gps)
            dot(signals.internet == .bad ? SaryIcon.offline : SaryIcon.internet, signals.internet)
        }
        .environment(\.layoutDirection, .leftToRight)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private func dot(_ symbol: String, _ level: SarySignalLevel) -> some View {
        let c = level.color(theme.palette)
        let d: CGFloat = theme.drive ? 26 : 20
        return Image(systemName: symbol)
            .font(.system(size: d * 0.5, weight: .bold))
            .foregroundStyle(level == .good ? c : theme.palette.onEmergency)
            .frame(width: d, height: d)
            .background(Circle().fill(level == .good ? c.opacity(0.18) : c))
            .accessibilityHidden(true)
    }
}
