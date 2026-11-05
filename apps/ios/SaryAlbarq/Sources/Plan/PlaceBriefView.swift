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
                    facts
                }
                if let a = ui.assessment { AssessmentView(a: a, compact: compact) }
                if !compact, !ui.hours.isEmpty { HoursStrip(hours: ui.hours).accessibilityIdentifier("brief.hours") }
            }
            if !compact {
                sunRow
                terrainRow
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
        .accessibilityElement(children: .combine)
    }

    private var facts: some View {
        let p = theme.palette
        let windHot = (ui.wind?.level ?? 0) > 0
        let dustHot = (ui.dustLevel ?? .clear) >= .moderate
        return VStack(alignment: .leading, spacing: theme.space(.s)) {
            if let w = ui.wind {
                HStack(spacing: theme.space(.s)) {
                    WindArrow(degrees: w.arrowDeg, size: 18, tint: windHot ? p.warningText : p.accentText)
                    Text([w.name, w.speed, w.gust].compactMap { $0 }.joined(separator: " · "))
                        .saryNumber(.subhead, weight: windHot ? .bold : .medium)
                        .foregroundStyle(windHot ? p.warningText : p.textPrimary).lineLimit(2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("brief.wind")
            }
            fact("sun.dust.fill", ui.dust, hot: dustHot, id: "brief.dust")
            fact("eye.fill", "الرؤية \(ui.visibility)", id: "brief.visibility")
            fact("humidity.fill", ui.humidity, id: "brief.humidity")
            fact("sun.max.fill", "الأشعة فوق البنفسجية \(ui.uv)", id: "brief.uv")
            fact("cloud.rain.fill", ui.rain, id: "brief.rain")
        }
    }

    private func fact(_ icon: String, _ text: String, hot: Bool = false, id: String) -> some View {
        let p = theme.palette
        return HStack(spacing: theme.space(.s)) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(hot ? p.warningText : p.textSecondary).frame(width: 18)
            Text(text).saryNumber(.subhead, weight: hot ? .bold : .medium).foregroundStyle(hot ? p.warningText : p.textPrimary).lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
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
            Text(parts.joined(separator: " · ")).saryNumber(.subhead, weight: .medium)
                .foregroundStyle(terrain.elevationM == nil ? p.textTertiary : p.textPrimary).lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("brief.elevation")
    }

    private var sourceRow: some View {
        let p = theme.palette
        let warn = ui.stale || ui.offline
        return HStack(spacing: theme.space(.xs)) {
            if warn { Image(systemName: ui.offline ? SaryIcon.offline : "clock.badge.exclamationmark").font(.system(size: 11, weight: .bold)) }
            if let prov = ui.provider, !ui.source.isEmpty {
                Link(destination: prov.attributionURL) { Text(ui.source).saryNumber(.caption, weight: warn ? .bold : .regular).lineLimit(2) }
            } else {
                Text(ui.offline ? "بلا إنترنت" : OpenMeteo.attribution).saryNumber(.caption)
            }
        }
        .foregroundStyle(warn ? p.warningText : p.textTertiary)
        .accessibilityIdentifier("brief.source")
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
        .accessibilityValue(Text(String(describing: a.level)))
    }
}
