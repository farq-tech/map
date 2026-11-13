import SwiftUI

/// W-1 of docs/UNIFIED-SURFACES.md: ONE weather page, reached from ONE small status chip on the map.
/// The page holds everything weather: the layer choice and the rain period, play / pause and the time
/// scrubber, the colour key, the cloud's direction and arrival line, the area / destination cards,
/// the wadi estimate and the official warnings. The old floating card stays behind a DEBUG flag
/// (`-SaryLegacyWeatherCard`) until the parity screenshots are accepted.
enum WeatherPageFlag {
    /// Build 49: the unified weather (one chip on the map + one page + one layers row) is part of the new UI,
    /// so it follows «الواجهة الجديدة (تجريبي)» (off by default). The old floating strip / card stays the
    /// default until the owner approves the parity screenshots. DEBUG launch arguments win:
    /// `-SaryUnifiedWeather` forces the page, `-SaryLegacyWeatherCard` forces the old card.
    static func unified(arguments: [String] = ProcessInfo.processInfo.arguments, newUIOn: Bool = NewUI.isOn()) -> Bool {
        #if DEBUG
        if arguments.contains("-SaryLegacyWeatherCard") { return false }
        if arguments.contains("-SaryUnifiedWeather") { return true }
        #endif
        return newUIOn
    }

    /// The unified weather is on (the chip, the page, the layers row).
    static var isOn: Bool { unified() }

    /// The pre-W-1 floating strip / card on the map.
    static var legacyCard: Bool { !isOn }
}

/// How the map (a UIKit overlay) asks the live screen to open the page. The live screen sets it on appear.
@MainActor
enum WeatherPageRouter {
    static var open: (() -> Void)?
}

/// The words on the map's one weather chip (tested in `WeatherPageTests`).
enum WeatherPageRules {
    /// «السحاب الآن · ١٢:٤٠»: the layer's name and the age of the picture (clouds) or the period / time of the others.
    static func statusLine(kind: WeatherOverlayKind, time: String, age: String) -> String {
        let when = kind == .clouds && !age.isEmpty ? age : time
        return when.isEmpty ? kind.label : "\(kind.label) · \(when)"
    }

    /// The chip only exists while a layer is on; with none, the header's temperature chip is the entry.
    static func showsStatusChip(kind: WeatherOverlayKind) -> Bool { kind != .none }

    /// Where the page's map section sits: after the "now" cards, before the warnings.
    static let mapSectionTitle = "الطقس على الخريطة"
}

/// The only weather element on the map: layer icon, name + time, the cloud's direction. Tap opens the page.
struct WeatherStatusChip: View {
    @ObservedObject var model: WeatherLegendModel
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        Button { model.onOpenPage() } label: {
            HStack(spacing: 8) {
                Image(systemName: model.kind.systemImage)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(p.accentText)
                Text(WeatherPageRules.statusLine(kind: model.kind, time: model.time, age: model.age))
                    .saryText(.subhead, weight: .bold).foregroundStyle(p.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityIdentifier("weather.legend.time")
                if let deg = model.outlook?.arrowDegrees {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(p.accentText)
                        .rotationEffect(.degrees(deg)).environment(\.layoutDirection, .leftToRight)
                        .accessibilityIdentifier("weather.status.arrow")
                }
                Image(systemName: "chevron.up").font(.system(size: 10, weight: .bold)).foregroundStyle(p.textTertiary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .saryGlass(Capsule(), role: .chrome)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .environment(\.layoutDirection, .rightToLeft)
        .accessibilityLabel(Text("\(model.kind.label)، افتح صفحة الطقس"))
        .accessibilityIdentifier("weather.status.chip")
    }
}

/// What the map shows for weather: the one chip, or (DEBUG flag) the legacy strip / card.
struct WeatherLegendHost: View {
    @ObservedObject var model: WeatherLegendModel

    var body: some View {
        if WeatherPageFlag.legacyCard { WeatherLegendCard(model: model) } else { WeatherStatusChip(model: model) }
    }
}

/// «الطقس على الخريطة» inside the page: the layer choice (same rows and identifiers as the layers sheet),
/// then, while a layer is on, its controls: play / pause, the time scrubber, the colour key, the direction.
struct WeatherMapSection: View {
    @ObservedObject var layers = WeatherLayers.shared
    @ObservedObject var model: WeatherLegendModel
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.space(.m)) {
            WeatherLayersSection()
            if layers.kind != .none { controls(p) }
        }
        .accessibilityIdentifier("weather.page.map")
    }

    @ViewBuilder
    private func controls(_ p: SaryPalette) -> some View {
        VStack(alignment: .leading, spacing: theme.space(.m)) {
            HStack(spacing: 8) {
                Text(model.time).saryText(.footnote, weight: .bold).foregroundStyle(p.textSecondary)
                    .accessibilityIdentifier("weather.page.time")
                Spacer(minLength: 4)
                if !model.age.isEmpty, model.kind == .clouds {
                    Text(model.age).saryText(.caption, weight: .bold).foregroundStyle(p.textSecondary)
                        .accessibilityIdentifier("weather.legend.age")
                }
            }
            if model.kind == .clouds {
                HStack(spacing: 8) {
                    Button { model.onTogglePlay() } label: {
                        Image(systemName: model.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(p.accentText)
                            .frame(width: theme.minTarget, height: theme.minTarget)
                            .background(Circle().fill(p.accent.opacity(0.2)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("weather.clouds.playpause")
                    .accessibilityLabel(Text(model.playing ? "إيقاف حركة السحاب" : "تشغيل حركة السحاب"))
                    if model.frameCount > 1 {
                        Slider(value: Binding(get: { Double(model.frameIndex) },
                                              set: { model.onScrub(Int($0.rounded())) }),
                               in: 0...Double(model.frameCount - 1), step: 1)
                            .tint(p.accent)
                            .environment(\.layoutDirection, .leftToRight)
                            .accessibilityIdentifier("weather.clouds.scrubber")
                    }
                }
            }
            legendKey(p)
            if let o = model.outlook {
                CloudOutlookRow(display: o, arrowLabel: model.kind == .wind ? "اتجاه هبوب الريح" : model.kind == .rain ? "اتجاه حركة المطر" : "اتجاه حركة السحاب")
            } else if model.outlookLoading {
                Text(model.outlookLoadingText).saryText(.caption).foregroundStyle(p.textSecondary)
                    .accessibilityIdentifier("weather.outlook.loading")
            }
            if !model.attribution.isEmpty {
                Text(model.attribution)
                    .saryGlyph(10, weight: .semibold, maxGrowth: SaryGlyph.tightGrowth)
                    .foregroundStyle(p.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.layoutDirection, .leftToRight)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityIdentifier("weather.legend.attribution")
            }
        }
        .padding(theme.space(.l))
        .sarySurface(radius: SaryRadius.l)
    }

    @ViewBuilder
    private func legendKey(_ p: SaryPalette) -> some View {
        if model.kind == .clouds {
            HStack(spacing: 10) {
                ForEach(model.items, id: \.self) { item in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3).fill(Color(rgb: item.hex)).frame(width: 14, height: 10)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(p.textTertiary.opacity(0.6), lineWidth: 0.5))
                        Text(item.label).saryText(.caption).foregroundStyle(p.textSecondary).lineLimit(1).minimumScaleFactor(0.75)
                    }
                }
            }
        } else {
            HStack(spacing: 0) {
                ForEach(model.items, id: \.self) { item in
                    VStack(spacing: 2) {
                        Rectangle().fill(Color(rgb: item.hex)).frame(height: 8)
                        Text(item.label).saryText(.caption).foregroundStyle(p.textSecondary).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}
