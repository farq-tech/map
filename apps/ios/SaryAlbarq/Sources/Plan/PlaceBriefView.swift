import SwiftUI

/// What the point card needs to show «بريف المكان».
struct PlaceBriefOptions {
    /// My position when it is fresh (distance + bearing); nil hides that line.
    var me: LngLat?
    /// Driving: one line of weather + the assessment, nothing to read at length.
    var compact = false
    var saved: [SavedPlace] = []
}

/// «بريف المكان» inside the point card: weather now at the spot, the next hours, sun,
/// terrain, the camping line and where the numbers came from.
struct PlaceBriefSection: View {
    var ui: PlaceBriefUI
    var terrain: TerrainSample
    var compact: Bool
    @Environment(\.sary) private var theme
    @State private var detailsExpanded = false

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.space(.m)) {
            switch ui.phase {
            case .loading:
                HStack(spacing: theme.space(.s)) {
                    ProgressView()
                    Text("نجيب طقس هذه النقطة…").saryText(.subhead).foregroundStyle(p.textSecondary)
                }
                .accessibilityIdentifier("brief.loading")
            case .unavailable(let m):
                SaryBanner(text: m, tone: ui.offline ? .warning : .info, systemImage: ui.offline ? SaryIcon.offline : "cloud")
                    .accessibilityIdentifier("brief.unavailable")
            case .ready:
                nowRow
                if compact {
                    Text(PlaceBriefPresenter.compactLine(ui)).saryNumber(.subhead, weight: .bold).foregroundStyle(p.textPrimary)
                } else {
                    keyFacts
                }
                if let a = ui.assessment { AssessmentView(a: a, compact: compact || !detailsExpanded) }
                if !compact { detailsToggle }
                if !compact, detailsExpanded {
                    secondaryFacts
                    sunRow
                    terrainRow
                    if !ui.hours.isEmpty {
                        VStack(alignment: .leading, spacing: theme.space(.s)) {
                            Text("الساعات القادمة").saryText(.caption, weight: .bold).foregroundStyle(p.textSecondary)
                            /* The floating SOS window occupies the bottom-left corner over sheets.
                             * In RTL, reserve that edge so forecast tiles remain fully readable. */
                            HoursStrip(hours: ui.hours)
                                .padding(.trailing, 104)
                                .accessibilityIdentifier("brief.hours")
                        }
                    }
                }
            }
            sourceRow
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("brief.section")
    }

    private var nowRow: some View {
        let p = theme.palette
        return HStack(alignment: .center, spacing: theme.space(.m)) {
            Image(systemName: ui.symbol).symbolRenderingMode(.multicolor).font(.system(size: compact ? 26 : 32)).frame(width: 44)
            VStack(alignment: .leading, spacing: 0) {
                Text(ui.nowLabel).saryText(.caption, weight: .bold).foregroundStyle(ui.stale ? p.warningText : p.textSecondary)
                HStack(alignment: .firstTextBaseline, spacing: theme.space(.s)) {
                    Text(ui.temp).saryNumber(.title, weight: .heavy).foregroundStyle(p.textPrimary)
                        .accessibilityIdentifier("brief.temp")
                    Text(ui.condition).saryText(.callout, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(1)
                }
                if let f = ui.feelsLike {
                    Text(f).saryNumber(.footnote).foregroundStyle(p.textSecondary).accessibilityIdentifier("brief.feels")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(theme.space(.m))
        .background(RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous).fill(p.sunken))
        .accessibilityElement(children: .combine)
    }

    /// The first view answers the immediate questions for a point in the desert:
    /// what is it like now, is anything concerning, and what changes soon?
    private var keyFacts: some View {
        let columns = [GridItem(.flexible(), spacing: theme.space(.s)), GridItem(.flexible(), spacing: theme.space(.s))]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: theme.space(.s)) {
            if let w = ui.wind {
                metric(icon: "wind", value: [w.name, w.speed, w.gust].compactMap { $0 }.joined(separator: " • "),
                       hot: w.level > 0, id: "brief.wind", arrow: w.arrowDeg)
            }
            metric(icon: "sun.dust.fill", value: ui.dust, hot: (ui.dustLevel ?? .clear) >= .moderate, id: "brief.dust")
            metric(icon: "eye.fill", value: "الرؤية \(ui.visibility)", hot: (ui.dustLevel ?? .clear) >= .moderate, id: "brief.visibility")
            metric(icon: "cloud.rain.fill", value: ui.rain, id: "brief.rain")
        }
    }

    private var secondaryFacts: some View {
        let columns = [GridItem(.flexible(), spacing: theme.space(.s)), GridItem(.flexible(), spacing: theme.space(.s))]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: theme.space(.s)) {
            metric(icon: "humidity.fill", value: ui.humidity, id: "brief.humidity")
            metric(icon: "sun.max.fill", value: "الأشعة فوق البنفسجية \(ui.uv)", id: "brief.uv")
        }
    }

    private func metric(icon: String, value: String, hot: Bool = false, id: String, arrow: Double? = nil) -> some View {
        let p = theme.palette
        return HStack(alignment: .top, spacing: theme.space(.s)) {
            Group {
                if icon == "wind" {
                    WindArrow(degrees: arrow, size: 17, tint: hot ? p.warningText : p.accentText)
                } else {
                    Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(hot ? p.warningText : p.textSecondary)
                }
            }
            .frame(width: 18, height: 18)
            Text(value).saryNumber(.footnote, weight: hot ? .bold : .medium)
                .foregroundStyle(hot ? p.warningText : p.textPrimary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .padding(.horizontal, theme.space(.m))
        .padding(.vertical, theme.space(.s))
        .background(RoundedRectangle(cornerRadius: SaryRadius.s, style: .continuous).fill(p.sunken))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    private var detailsToggle: some View {
        let p = theme.palette
        return Button {
            withAnimation(theme.animation(.snappy)) { detailsExpanded.toggle() }
        } label: {
            HStack(spacing: theme.space(.s)) {
                Image(systemName: detailsExpanded ? "chevron.up" : "chevron.down")
                    .saryGlyph(11, weight: .bold)
                Text(detailsExpanded ? "إخفاء التفاصيل" : "التفاصيل والتوقعات")
                    .saryText(.footnote, weight: .bold)
                Spacer(minLength: 0)
            }
            .foregroundStyle(p.accentText)
            .padding(.vertical, theme.space(.xs))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("brief.more")
        .accessibilityValue(detailsExpanded ? "مفتوحة" : "مغلقة")
    }

    private var sunRow: some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: theme.space(.m)) {
                Label(ui.sunrise ?? "—", systemImage: "sunrise.fill")
                Label(ui.sunset ?? "—", systemImage: "sunset.fill")
            }
            .saryNumber(.subhead, weight: .medium).foregroundStyle(p.textPrimary)
            .symbolRenderingMode(.multicolor)
            Text(ui.daylight).saryNumber(.footnote).foregroundStyle(p.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("brief.sun")
    }

    private var terrainRow: some View {
        let p = theme.palette
        let parts = [PlaceBriefRules.elevationText(terrain), PlaceBriefRules.slopeText(terrain)].compactMap { $0 }
        return HStack(spacing: theme.space(.s)) {
            Image(systemName: "mountain.2.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(p.textSecondary).frame(width: 18)
            Text(parts.joined(separator: " • ")).saryNumber(.subhead, weight: .medium)
                .foregroundStyle(terrain.elevationM == nil ? p.textTertiary : p.textPrimary).lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("brief.elevation")
    }

    private var sourceRow: some View {
        let p = theme.palette
        let warn = ui.stale || ui.offline
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: theme.space(.xs)) {
                if warn { Image(systemName: ui.offline ? SaryIcon.offline : "clock.badge.exclamationmark").saryGlyph(11, weight: .bold) }
                if let prov = ui.provider, !ui.source.isEmpty {
                    Link(destination: prov.attributionURL) { Text(ui.source).saryNumber(.caption, weight: warn ? .bold : .regular).lineLimit(2) }
                } else {
                    Text(ui.offline ? "بلا إنترنت" : OpenMeteo.attribution).saryNumber(.caption)
                }
            }
            .foregroundStyle(warn ? p.warningText : p.textTertiary)
            .accessibilityIdentifier("brief.source")
            /* Where the forecast is for (Build 36 item 12); not in the driving one-liner. */
            if !compact, let point = ui.forecastPoint {
                Label(point, systemImage: "scope").saryNumber(.caption).foregroundStyle(p.textTertiary).lineLimit(2)
                    .accessibilityIdentifier("brief.forecastPoint")
            }
        }
    }
}

/// «تقييم للتخييم/الطلعة»: the level, and every reason behind it.
private struct AssessmentView: View {
    var a: PlaceAssessment
    var compact: Bool
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let (color, icon): (Color, String) = {
            switch a.level {
            case .good: return (p.liveText, "checkmark.seal.fill")
            case .caution: return (p.warningText, "exclamationmark.triangle.fill")
            case .poor: return (p.emergencyText, "xmark.octagon.fill")
            case .unknown: return (p.textSecondary, "questionmark.circle.fill")
            }
        }()
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: theme.space(.s)) {
                Image(systemName: icon).font(.system(size: 15, weight: .bold)).foregroundStyle(color)
                Text(a.title).saryText(.subhead, weight: .bold).foregroundStyle(color)
            }
            let shown = compact ? Array(a.reasons.prefix(1)) : a.reasons
            ForEach(shown, id: \.self) { r in
                Text("• \(r)").saryNumber(.footnote).foregroundStyle(p.textPrimary).fixedSize(horizontal: false, vertical: true)
            }
            if let n = a.note { Text(n).saryNumber(.caption).foregroundStyle(p.warningText) }
            if !compact {
                Text("تقدير من أرقام التوقعات، ليس تحذيرًا رسميًا. التحذيرات: \(NCM.name).").saryText(.caption).foregroundStyle(p.textTertiary)
            }
        }
        .padding(theme.space(.m))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: SaryRadius.s, style: .continuous).fill(p.sunken))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("brief.assessment")
        .accessibilityValue(Text(levelLabel))
    }

    /// VoiceOver value in Arabic (was the enum's English case name).
    private var levelLabel: String {
        switch a.level {
        case .good: return "مناسب"
        case .caution: return "انتبه"
        case .poor: return "غير مناسب"
        case .unknown: return "غير معروف"
        }
    }
}
