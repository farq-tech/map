import SwiftUI

/// What the trip header says, as plain values (unit-tested in `DeclutterTests`).
struct TripHeaderUI: Equatable {
    var title: String
    var line: String?
    var level: SarySignalLevel
    var bell: Int
    /// A solo outing: «على جوالك فقط» under the title (nothing is shared, docs/SOLO-OUTING.md (ج)).
    var localOnly = false
}

enum TripHeaderPresenter {
    /// Title (Lovable): the outing's name — «كشتة النفود الكبير». Where to is the second line.
    static func title(outingName: String, trip: TripPanelUI?, ended: Bool = false) -> String {
        outingName
    }

    /// Second line (Lovable): «إلى مخيم النفود • باقي ١٢ كم • نوصل ٧:١١», the trip's phase, or
    /// (following the plan) its status.
    static func line(status: OutingStatusUI, trip: TripPanelUI?, follow: String?, connection: ConnectionStateUI, nearbyCars: Int) -> String? {
        if let follow { return follow }
        if status == .paused { return "الطلعة متوقفة مؤقتًا" }
        if status == .ended { return "انتهت الطلعة" }
        if let t = trip {
            switch t.phase {
            case let .needsDestination(canSet): return canSet ? "حدّد الوجهة" : "بانتظار الوجهة"
            case .notStarted: return "ما بدأت"
            case .waitingFix: return "ننتظر موقعك"
            case .arrived: return t.destinationName.isEmpty ? "وصلت" : "وصلت \(t.destinationName)"
            case .ended: return "انتهت الطلعة"
            case .underway:
                if let s = t.myFixStaleSince { return SaryFormat.lastUpdate(since: s, now: Date()) }
                let to = t.destinationName.isEmpty ? nil : "إلى \(t.destinationName)"
                let parts = [to, t.remainingLine, t.etaLine].compactMap { $0 }
                if !parts.isEmpty { return parts.joined(separator: " • ") }
            }
        }
        if let n = LiveOutingPresenter.nearbyLabel(nearbyCars) { return n }
        if connection != .connected { return connection.label }
        return status == .notStarted ? "ما بدأت" : nil
    }

    /// «اتبع الخطة» status as the header's second line.
    static func follow(_ s: FollowPlanStatus) -> String {
        switch s.kind {
        case .waitingForFix: return "اتبع الخطة • ننتظر موقعك"
        case .onRoute: return "على المسار • باقي \(SaryFormat.distance(meters: s.remainingM))"
        case .offRoute: return "خارج المسار بـ \(SaryFormat.distance(meters: s.offM)) • ارجع \(Geo.directionLabel(s.backBearing))"
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
/// back • [dot] destination / «باقي … • نوصل …» • weather • bell.
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
    /// UI-AUDIT م3: the history button only with something in it (`LiveScreenRules.showsBell`).
    var showsBell = true
    /// «استكشاف» (stopped only): the round map button after the header.
    var exploreTapped: (() -> Void)? = nil
    /// «إذاعة الطلعة» plays: a small ♪ in the header instead of a wide bar («تخفيف الزحمة» ٢).
    var radio: RadioHeaderUI? = nil
    var radioTapped: () -> Void = {}
    @Environment(\.sary) private var theme

    /// «الإعدادات» (Lovable's gear): the trip's settings.
    var settingsTapped: (() -> Void)? = nil

    private var barHeight: CGFloat { theme.drive ? 80 : 70 }
    /// UX ٢١: every header button is at least 44 pt wide, 56 pt while driving.
    private var hit: CGFloat { theme.drive ? 56 : 44 }

    /// Lovable: ONE dark card, 22 pt corners — title and «إلى … • ١٢٫٤ كم» on the right; the weather
    /// pill, the alerts' history and the gear on the left. «رجوع» is a small chevron before the title.
    var body: some View {
        let p = theme.palette
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        HStack(spacing: 2) {
            Button(action: back) {
                Image(systemName: SaryIcon.back)
                    .font(.system(size: theme.drive ? 18 : 15, weight: .semibold))
                    .foregroundStyle(p.textSecondary)
                    .frame(width: hit, height: barHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SaryPressStyle())
            .accessibilityLabel(Text("رجوع"))
            .accessibilityIdentifier("outing-back")

            statusDot

            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ui.title)
                        .font(.sary(theme.drive ? 19 : 16, .bold))
                        .foregroundStyle(p.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityIdentifier("outing-title")
                    if ui.localOnly {
                        /* In place of a sharing state: this outing never leaves the phone. */
                        Label(SoloCopy.localOnly, systemImage: "lock.fill")
                            .font(.sary(theme.drive ? 13 : 11, .bold))
                            .foregroundStyle(p.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .accessibilityIdentifier("solo.header.local")
                    }
                    if let line = ui.line {
                        /* Drive mode: medium weight, so the state line holds up in sun. */
                        Text(line)
                            .font(.sary(theme.drive ? 14 : 12, theme.drive ? .medium : .regular))
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
            .accessibilityHint(Text("يفتح تفاصيل الطلعة"))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("trip.header")

            if let r = radio {
                Button(action: radioTapped) {
                    Image(systemName: r.muted ? "speaker.slash.fill" : (r.playing ? "music.note" : SaryIcon.pause))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(r.muted ? p.textSecondary : p.accentText)
                        .symbolEffect(.pulse, isActive: r.playing && !r.muted && !theme.reduceMotion)
                        .frame(width: hit, height: hit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SaryPressStyle())
                .accessibilityLabel(Text("إذاعة الطلعة"))
                .accessibilityValue(Text(r.muted ? "ساكت عندك • \(r.title)" : (r.playing ? "يشغّل الآن • \(r.title)" : "موقّفة • \(r.title)")))
                .accessibilityHint(Text(r.open ? "يخفي التحكم" : "يفتح التحكم: إيقاف وكتم"))
                .accessibilityIdentifier("radio.header")
                .transition(.scale.combined(with: .opacity))
            }

            if let w = weather, w.phase != .unavailable {
                Button(action: weatherTapped) {
                    HStack(spacing: 4) {
                        if w.phase == .loading {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: w.symbol).symbolRenderingMode(.multicolor)
                                .font(.system(size: 13, weight: .semibold))
                        }
                        Text(w.temp).font(.sary(12, .regular))
                            .foregroundStyle(w.alertLevel >= 2 ? p.emergencyText : (w.alertLevel == 1 ? p.warningText : p.textPrimary))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(p.sunken.opacity(0.7)))
                    .frame(minWidth: hit, minHeight: hit)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(w.accessibility))
                .accessibilityHint(Text("يفتح تفاصيل الطقس"))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("weather.chip")
            }

            /* The alerts' history (Lovable): with something in it; a count while some wait. */
            if showsBell {
                Button(action: bellTapped) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: bellOpen ? "xmark" : "clock.arrow.circlepath")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(p.textPrimary)
                            .frame(width: hit, height: hit)
                        if ui.bell > 0 && !bellOpen {
                            Text(SaryFormat.number(ui.bell))
                                .saryNumber(.micro, weight: .heavy)
                                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                                .foregroundStyle(p.onAccent)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Capsule().fill(p.accent))
                                .saryBadgeOutset(trailing: 2, top: -4)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(SaryPressStyle())
                .accessibilityLabel(Text(bellOpen ? "أخفِ التنبيهات" : (ui.bell == 0 ? "سجل التنبيهات" : "\(SaryFormat.number(ui.bell)) \(ui.bell == 1 ? "تنبيه" : "تنبيهات")")))
                .accessibilityIdentifier("alerts.bell")
            }

            if let settingsTapped {
                Button(action: settingsTapped) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(p.textPrimary)
                        .frame(width: hit, height: hit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SaryPressStyle())
                .accessibilityLabel(Text("الإعدادات"))
                .accessibilityIdentifier("tab.more")
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, 6)
        .frame(minHeight: barHeight)
        .background { shape.fill(p.chromeOpaque.opacity(0.88)) }
        .saryGlass(shape, role: .chrome)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .animation(theme.animation(.snappy), value: ui.bell)
    }

    /// The connection dot, small, after the title (it opens the status details).
    private var statusDot: some View {
        Button(action: statusTapped) {
            Circle().fill(ui.level.color(theme.palette))
                .frame(width: 8, height: 8)
                .frame(width: 28, height: hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("حالة الاتصال"))
        .accessibilityValue(Text(levelText))
        .accessibilityIdentifier("outing-link-state")
    }

    private var levelText: String {
        switch ui.level {
        case .good: return "كل شي تمام"
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
