import SwiftUI

/// What the trip header says, as plain values (unit-tested in `DeclutterTests`).
struct TripHeaderUI: Equatable {
    var title: String
    var line: String?
    var level: SarySignalLevel
    var bell: Int
}

enum TripHeaderPresenter {
    /// Title: the destination (the outing's name when there is none, the trip is off, or it
    /// ended: after «انتهت الطلعة» nobody is heading anywhere, e.g. a return trip's «نقطة البداية»).
    static func title(outingName: String, trip: TripPanelUI?, ended: Bool = false) -> String {
        guard !ended, let t = trip else { return outingName }
        if case .needsDestination = t.phase { return outingName }
        return t.destinationName.isEmpty ? outingName : t.destinationName
    }

    /// Second line: «باقي ١٢ كم · نوصل ٧:١١», the trip's phase, or (following the plan) its status.
    static func line(status: OutingStatusUI, trip: TripPanelUI?, follow: String?, connection: ConnectionStateUI, nearbyCars: Int) -> String? {
        if let follow { return follow }
        if status == .paused { return "الطلعة متوقفة مؤقتًا" }
        if status == .ended { return "انتهت الطلعة" }
        if let t = trip {
            switch t.phase {
            case let .needsDestination(canSet): return canSet ? "حدّد الوجهة" : "بانتظار الوجهة"
            case .notStarted: return "لم تبدأ"
            case .waitingFix: return "ننتظر موقعك"
            case .arrived: return "وصلت"
            case .ended: return "انتهت الرحلة"
            case .underway:
                if let s = t.myFixStaleSince { return SaryFormat.lastUpdate(since: s, now: Date()) }
                let parts = [t.remainingLine, t.etaLine].compactMap { $0 }
                if !parts.isEmpty { return parts.joined(separator: " · ") }
            }
        }
        if let n = LiveOutingPresenter.nearbyLabel(nearbyCars) { return n }
        if connection != .connected { return connection.label }
        return status == .notStarted ? "لم تبدأ" : nil
    }

    /// «اتبع الخطة» status as the header's second line.
    static func follow(_ s: FollowPlanStatus) -> String {
        switch s.kind {
        case .waitingForFix: return "اتبع الخطة · ننتظر موقعك"
        case .onRoute: return "على المسار · باقي \(SaryFormat.distance(meters: s.remainingM))"
        case .offRoute: return "خارج المسار بـ \(SaryFormat.distance(meters: s.offM)) · ارجع \(Geo.directionLabel(s.backBearing))"
        case .arrived: return "وصلت نهاية الخطة"
        }
    }

    /// ONE dot: the worst of connection / GPS / internet; grey when my sharing is off.
    static func level(connection: ConnectionStateUI, sharing: MySharingUI, warnings: [LiveWarningUI]) -> SarySignalLevel {
        let s = SaryStatusSignals(connection: connection, sharing: sharing, warnings: warnings)
        let all = [s.connection, s.gps, s.internet]
        if all.contains(.bad) { return .bad }
        if all.contains(.degraded) || !warnings.isEmpty { return .degraded }
        if sharing == .paused { return .unknown }
        return .good
    }
}

/// The header's ♪: what «إذاعة الطلعة» is doing, in one glyph.
struct RadioHeaderUI: Equatable {
    var title: String
    var playing: Bool
    var muted: Bool
    var open: Bool
}

/// The single top bar of the live screen (docs/IA-REDESIGN.md §2.2):
/// back · [dot] destination / «باقي … · نوصل …» · weather · bell.
struct TripHeader: View {
    var ui: TripHeaderUI
    var weather: WeatherChipUI?
    var accessibility: String
    var back: () -> Void
    var open: () -> Void
    var statusTapped: () -> Void
    var weatherTapped: () -> Void
    var bellTapped: () -> Void
    var bellOpen = false
    /// Past alerts exist: the bell stays reachable (the history) even with nothing queued.
    var hasHistory = false
    /// «استكشاف» (stopped only): the round map button after the header.
    var exploreTapped: (() -> Void)? = nil
    /// «إذاعة الطلعة» plays: a small ♪ in the header instead of a wide bar («تخفيف الزحمة» ٢).
    var radio: RadioHeaderUI? = nil
    var radioTapped: () -> Void = {}
    @Environment(\.sary) private var theme

    private var barHeight: CGFloat { theme.drive ? 64 : 52 }

    var body: some View {
        let p = theme.palette
        let shape = RoundedRectangle(cornerRadius: barHeight / 2, style: .continuous)
        HStack(spacing: theme.space(.s)) {
            Button(action: back) {
                Image(systemName: SaryIcon.back)
                    .font(.system(size: theme.drive ? 22 : 17, weight: .semibold))
                    .foregroundStyle(p.textPrimary)
                    .frame(width: barHeight, height: barHeight)
                    .saryGlass(Circle(), role: .chrome, interactive: true)
            }
            .buttonStyle(SaryPressStyle())
            .accessibilityLabel(Text("رجوع"))
            .accessibilityIdentifier("outing-back")

            HStack(spacing: 0) {
                Button(action: statusTapped) {
                    Circle().fill(ui.level.color(p))
                        .frame(width: theme.drive ? 14 : 11, height: theme.drive ? 14 : 11)
                        .overlay(Circle().stroke(p.background.opacity(0.6), lineWidth: 1.5))
                        .frame(width: 40, height: barHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("حالة الاتصال"))
                .accessibilityValue(Text(levelText))
                .accessibilityIdentifier("outing-link-state")

                Button(action: open) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(ui.title)
                            .saryText(theme.drive ? .title2 : .headline, weight: .bold)
                            .foregroundStyle(p.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .accessibilityIdentifier("outing-title")
                        if let line = ui.line {
                            Text(line)
                                .saryNumber(theme.drive ? .callout : .footnote, weight: .bold)
                                .foregroundStyle(p.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .accessibilityIdentifier("trip.header.line")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: barHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(accessibility))
                .accessibilityHint(Text("يفتح تفاصيل الرحلة"))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("trip.header")

                if let r = radio {
                    Button(action: radioTapped) {
                        Image(systemName: r.muted ? "speaker.slash.fill" : (r.playing ? "music.note" : SaryIcon.pause))
                            .font(.system(size: theme.drive ? 18 : 15, weight: .bold))
                            .foregroundStyle(r.muted ? p.textSecondary : p.accentText)
                            .symbolEffect(.pulse, isActive: r.playing && !r.muted && !theme.reduceMotion)
                            .frame(width: 36, height: barHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SaryPressStyle())
                    .accessibilityLabel(Text("إذاعة الطلعة"))
                    .accessibilityValue(Text(r.muted ? "ساكت عندك · \(r.title)" : (r.playing ? "يشغّل الآن · \(r.title)" : "موقّفة · \(r.title)")))
                    .accessibilityHint(Text(r.open ? "يخفي التحكم" : "يفتح التحكم: إيقاف وكتم"))
                    .accessibilityIdentifier("radio.header")
                    .transition(.scale.combined(with: .opacity))
                }

                if let w = weather, w.phase != .unavailable {
                    Button(action: weatherTapped) {
                        HStack(spacing: 3) {
                            if w.phase == .loading {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: w.symbol).symbolRenderingMode(.multicolor)
                                    .font(.system(size: theme.drive ? 18 : 15, weight: .semibold))
                            }
                            Text(w.temp).saryNumber(theme.drive ? .headline : .subhead, weight: .heavy)
                                .foregroundStyle(w.alertLevel >= 2 ? p.emergencyText : (w.alertLevel == 1 ? p.warningText : p.textPrimary))
                        }
                        .padding(.horizontal, 6)
                        .frame(minWidth: 44, minHeight: barHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(w.accessibility))
                    .accessibilityHint(Text("يفتح تفاصيل الطقس"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("weather.chip")
                }

                if ui.bell > 0 || bellOpen || hasHistory {
                    Button(action: bellTapped) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: bellOpen ? "bell.slash.fill" : "bell.fill")
                                .font(.system(size: theme.drive ? 19 : 16, weight: .semibold))
                                .foregroundStyle(p.textPrimary)
                                .frame(width: 30, height: 30)
                            if ui.bell > 0 && !bellOpen {
                                Text(SaryFormat.number(ui.bell))
                                    .saryNumber(.micro, weight: .heavy)
                                    .foregroundStyle(p.onAccent)
                                    .padding(.horizontal, 4)
                                    .frame(minWidth: 17, minHeight: 17)
                                    .background(Capsule().fill(p.accent))
                                    .offset(x: 6, y: -4)
                            }
                        }
                        .frame(width: 44, height: barHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SaryPressStyle())
                    .accessibilityLabel(Text(bellOpen ? "أخفِ التنبيهات" : (ui.bell == 0 ? "سجل التنبيهات" : "\(SaryFormat.number(ui.bell)) \(ui.bell == 1 ? "تنبيه" : "تنبيهات")")))
                    .accessibilityIdentifier("alerts.bell")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.trailing, theme.space(.xs))
            .saryGlass(shape, role: .chrome)

            if let exploreTapped {
                Button(action: exploreTapped) {
                    Image(systemName: "binoculars.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(p.textPrimary)
                        .frame(width: barHeight, height: barHeight)
                        .saryGlass(Circle(), role: .chrome, interactive: true)
                }
                .buttonStyle(SaryPressStyle())
                .accessibilityLabel(Text("استكشاف"))
                .accessibilityHint(Text("الطبقات والتضاريس والإحداثيات وأماكنك"))
                .accessibilityIdentifier("trip.explore")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .animation(theme.animation(.snappy), value: ui.bell)
    }

    private var levelText: String {
        switch ui.level {
        case .good: return "كل شيء تمام"
        case .degraded: return "فيه تنبيه"
        case .bad: return "مشكلة في الاتصال أو الموقع"
        case .unknown: return "مشاركة موقعك متوقفة"
        }
    }
}

/// Under the header when the dot is tapped: connection, GPS, sharing and every warning.
struct TripStatusDetails: View {
    var connection: ConnectionStateUI
    var sharing: MySharingUI
    var warnings: [LiveWarningUI]
    var nearbyCars: Int
    var warningTapped: (LiveWarningUI) -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let s = SaryStatusSignals(connection: connection, sharing: sharing, warnings: warnings)
        VStack(alignment: .leading, spacing: 0) {
            row(s.connection, SaryIcon.connection, connection.label)
            row(s.gps, SaryIcon.gps, gpsText(s.gps))
            row(sharing == .sharing ? .good : (sharing == .starting ? .degraded : .unknown), SaryIcon.locate, sharingText)
            if let n = LiveOutingPresenter.nearbyLabel(nearbyCars) { row(.good, SaryNearbyMark.icon, n) }
            ForEach(warnings, id: \.self) { w in
                Button { warningTapped(w) } label: {
                    HStack(spacing: theme.space(.s)) {
                        Image(systemName: SaryIcon.warning).font(.system(size: 13, weight: .bold)).foregroundStyle(p.warningText).frame(width: 22)
                        Text(w.label).saryText(.subhead).foregroundStyle(p.textPrimary).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, theme.space(.s))
                    .frame(minHeight: theme.minTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("status.warning")
            }
        }
        .padding(.horizontal, theme.space(.l))
        .padding(.vertical, theme.space(.s))
        .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .chrome)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("status.details")
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private func row(_ level: SarySignalLevel, _ icon: String, _ text: String) -> some View {
        HStack(spacing: theme.space(.s)) {
            Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundStyle(level.color(theme.palette)).frame(width: 22)
            Text(text).saryText(.subhead, weight: .medium).foregroundStyle(theme.palette.textPrimary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var sharingText: String {
        switch sharing {
        case .sharing: return "موقعك مُشارَك"
        case .starting: return "جارٍ تحديد موقعك…"
        case .paused: return "مشاركة موقعك متوقفة"
        }
    }

    private func gpsText(_ l: SarySignalLevel) -> String {
        switch l {
        case .good: return "الموقع دقيق"
        case .degraded: return "إشارة الموقع ضعيفة"
        case .bad: return "الموقع غير متاح"
        case .unknown: return "الموقع غير مستخدم"
        }
    }
}

/// Behind the bell, under the live queue: every earlier alert, newest first.
struct AlertHistoryList: View {
    var entries: [AlertHistoryEntry]
    var now: Date
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 0) {
            Text("السجل").saryText(.footnote, weight: .bold).foregroundStyle(p.textSecondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.vertical, theme.space(.xs))
            ForEach(entries) { e in
                HStack(spacing: theme.space(.s)) {
                    Image(systemName: e.symbol).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(e.priority >= .returnTimer ? p.emergencyText : p.textSecondary).frame(width: 22)
                    Text(e.text).saryText(.subhead).foregroundStyle(p.textPrimary).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(SaryFormat.lastUpdate(since: e.at, now: now).replacingOccurrences(of: "آخر تحديث ", with: ""))
                        .saryNumber(.caption).foregroundStyle(p.textTertiary)
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("alerts.history.row")
            }
        }
        .padding(.horizontal, theme.space(.l))
        .padding(.vertical, theme.space(.s))
        .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .chrome)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alerts.history")
    }
}
