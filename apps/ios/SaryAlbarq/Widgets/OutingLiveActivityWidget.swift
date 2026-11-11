import ActivityKit
import SwiftUI
import WidgetKit

/// The design system's tokens the activity needs (Sources/UI/DesignSystem/SaryColors —
/// Dark Sand and Day Desert), copied because an extension cannot link the app's UI layer.
private enum Ink {
    static func hex(_ rgb: UInt32, _ o: Double = 1) -> Color {
        Color(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255, opacity: o)
    }

    struct Palette {
        var background: Color
        var text: Color
        var secondary: Color
        var live: Color
        var emergency: Color
        var onEmergency: Color
        var warning: Color
        var warningText: Color
        var stale: Color
        var accent: Color
    }

    /// Lock Screen: light for direct sun, dark otherwise.
    static func palette(_ scheme: ColorScheme) -> Palette {
        scheme == .dark
            ? Palette(background: hex(0x1A1612), text: hex(0xF4EFE6), secondary: hex(0xB9AE9C), live: hex(0x45C083), emergency: hex(0xD6452F),
                      onEmergency: .white, warning: hex(0xF2B630), warningText: hex(0x1A1612), stale: hex(0x8C8478), accent: hex(0xE8842C))
            : Palette(background: hex(0xF5EFE4), text: hex(0x1F1A14), secondary: hex(0x3D352B), live: hex(0x1A7347), emergency: hex(0xC93A24),
                      onEmergency: .white, warning: hex(0xE2A11C), warningText: hex(0x1F1A14), stale: hex(0x5C5244), accent: hex(0x9E4C0B))
    }

    /// The Dynamic Island is always black, and the Lock Screen platter is drawn
    /// dark too (iOS renders it over any wallpaper; dark sand keeps it legible in sun).
    static let island = palette(.dark)
}

private extension Font {
    static func tajawal(_ size: CGFloat, _ weight: String = "Bold") -> Font { .custom("Tajawal-\(weight)", size: size) }
    static func number(_ size: CGFloat) -> Font { .system(size: size, weight: .bold).monospacedDigit() }
}

struct OutingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OutingActivityAttributes.self) { context in
            LockScreenView(name: context.attributes.outingName,
                           d: OutingActivityDisplay.make(context.state, now: Date(), systemStale: context.isStale))
                .widgetURL(OutingActivityState.url(outingId: context.attributes.outingId))
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "ar_SA@numbers=arab"))
        } dynamicIsland: { context in
            let d = OutingActivityDisplay.make(context.state, now: Date(), systemStale: context.isStale)
            let p = Ink.island
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandMetric(icon: "arrow.uturn.backward", value: d.backShort, caption: "طريق الرجعة", tint: p.accent, dim: d.isStale)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandMetric(icon: "dot.radiowaves.left.and.right", value: ActivityFormat.number(context.state.liveCount), caption: "مباشر", tint: d.isStale ? p.stale : p.live, dim: d.isStale)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.attributes.outingName).font(.tajawal(15)).foregroundStyle(p.text).lineLimit(1)
                        SpeedPill(text: d.speedText, palette: p, dim: d.isStale || d.speedText == "—", size: 14)
                    }
                    .environment(\.layoutDirection, .rightToLeft)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        if let b = d.banner { BannerView(banner: b, palette: p, compact: true) }
                        if let n = d.navLine { NavRow(line: n, symbol: d.navSymbol, palette: p, compact: true) }
                        if let line = d.tripLine { TripRow(line: line, fraction: d.tripFraction ?? 0, palette: p, dim: d.isStale, compact: true) }
                        HStack {
                            if let f = d.farthestLine {
                                Label { Text("الأبعد: \(f)") } icon: { Image(systemName: "arrow.up.and.down.and.arrow.left.and.right") }
                                    .font(.tajawal(14, "Medium")).foregroundStyle(p.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            StaleTag(d: d, palette: p)
                        }
                    }
                    .padding(.horizontal, 10)
                    .environment(\.layoutDirection, .rightToLeft)
                    .environment(\.locale, Locale(identifier: "ar_SA@numbers=arab"))
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    if let t = d.tripShort {
                        /* «الرحلة»: what is left to the destination leads. */
                        Image(systemName: "flag.checkered").font(.system(size: 12, weight: .bold)).foregroundStyle(p.live)
                        Text(t).font(.number(14)).foregroundStyle(d.isStale ? p.stale : p.text)
                    } else {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 12, weight: .bold)).foregroundStyle(p.accent)
                        Text(d.backShort).font(.number(14)).foregroundStyle(d.isStale ? p.stale : p.text)
                    }
                }
            } compactTrailing: {
                if d.showAlertDot {
                    Circle().fill(p.emergency).frame(width: 12, height: 12)
                } else {
                    Text(ActivityFormat.number(context.state.liveCount)).font(.number(14)).foregroundStyle(d.isStale ? p.stale : p.live)
                }
            } minimal: {
                if d.showAlertDot {
                    Circle().fill(p.emergency).frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 13, weight: .bold)).foregroundStyle(d.isStale ? p.stale : p.accent)
                }
            }
            .widgetURL(OutingActivityState.url(outingId: context.attributes.outingId))
            .keylineTint(d.showAlertDot ? p.emergency : p.accent)
        }
    }
}

// MARK: - Lock Screen

private struct LockScreenView: View {
    let name: String
    let d: OutingActivityDisplay
    var body: some View {
        let p = Ink.island
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(name).font(.tajawal(17, "ExtraBold")).foregroundStyle(p.text).lineLimit(1)
                Spacer(minLength: 6)
                SpeedPill(text: d.speedText, palette: p, dim: d.isStale || d.speedText == "—", size: 15)
                StaleTag(d: d, palette: p)
            }
            if let b = d.banner { BannerView(banner: b, palette: p, compact: false) }
            if let n = d.navLine { NavRow(line: n, symbol: d.navSymbol, palette: p, compact: false) }
            if let line = d.tripLine { TripRow(line: line, fraction: d.tripFraction ?? 0, palette: p, dim: d.isStale, compact: false) }
            HStack(alignment: .top, spacing: 10) {
                Metric(icon: "arrow.uturn.backward", title: "طريق الرجعة", value: d.backText ?? "—", tint: p.accent, palette: p, dim: d.isStale)
                Metric(icon: "dot.radiowaves.left.and.right", title: "الأعضاء", value: d.liveLine, tint: d.isStale ? p.stale : p.live, palette: p, dim: d.isStale)
                Metric(icon: "arrow.up.and.down.and.arrow.left.and.right", title: "الأبعد", value: d.farthestLine ?? "—", tint: p.secondary, palette: p, dim: d.isStale)
            }
        }
        .padding(14)
        .activityBackgroundTint(p.background)
        .activitySystemActionForegroundColor(p.text)
    }
}

private struct Metric: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color
    let palette: Ink.Palette
    let dim: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label { Text(title) } icon: { Image(systemName: icon).foregroundStyle(tint) }
                .font(.tajawal(13, "Medium")).foregroundStyle(palette.secondary).lineLimit(1)
            Text(value).font(.tajawal(19)).foregroundStyle(dim ? palette.stale : palette.text)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BannerView: View {
    let banner: OutingActivityDisplay.Banner
    let palette: Ink.Palette
    let compact: Bool

    var body: some View {
        let emergency = banner.tone == .emergency
        HStack(spacing: 8) {
            Image(systemName: emergency ? "sos.circle.fill" : "exclamationmark.triangle.fill").font(.system(size: compact ? 15 : 18, weight: .bold))
            Text(banner.text).font(.tajawal(compact ? 15 : 17)).lineLimit(1).minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
        .foregroundStyle(emergency ? palette.onEmergency : palette.warningText)
        .padding(.horizontal, 12).padding(.vertical, compact ? 6 : 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(emergency ? palette.emergency : palette.warning))
    }
}

/// «مباشر» while the picture is current; once old, its real age, ticking.
private struct StaleTag: View {
    let d: OutingActivityDisplay
    let palette: Ink.Palette

    var body: some View {
        if d.isStale {
            HStack(spacing: 4) {
                Image(systemName: "clock.badge.exclamationmark")
                Text("آخر تحديث قبل \(d.updatedAt, style: .relative)")
            }
            .font(.tajawal(13, "Medium")).foregroundStyle(palette.stale).lineLimit(1)
        } else {
            HStack(spacing: 4) {
                Circle().fill(palette.live).frame(width: 8, height: 8)
                Text("مباشر")
            }
            .font(.tajawal(13)).foregroundStyle(palette.live)
        }
    }
}

private struct IslandMetric: View {
    let icon: String
    let value: String
    let caption: String
    let tint: Color
    let dim: Bool

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundStyle(tint)
                Text(value).font(.number(17)).foregroundStyle(dim ? Ink.island.stale : Ink.island.text).lineLimit(1).minimumScaleFactor(0.7)
            }
            Text(caption).font(.tajawal(12, "Medium")).foregroundStyle(Ink.island.secondary)
        }
        .padding(.horizontal, 4)
    }
}

/// «سرعة المركبة»: my current speed, «—» when there is no fresh one.
private struct SpeedPill: View {
    let text: String
    let palette: Ink.Palette
    let dim: Bool
    let size: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.67percent").font(.system(size: size - 2, weight: .bold)).foregroundStyle(dim ? palette.stale : palette.accent)
            Text(text).font(.tajawal(size)).foregroundStyle(dim ? palette.stale : palette.text).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(palette.text.opacity(0.08)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("السرعة \(text)"))
    }
}


/// «الرحلة»: start → destination bar (filled from the start, right in RTL) and one line.
/// «الملاحة»: the next manoeuvre (or the off-road bearing line), in the accent tile.
private struct NavRow: View {
    let line: String
    let symbol: String
    let palette: Ink.Palette
    let compact: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 13 : 16, weight: .heavy))
                .foregroundStyle(Color.white)
                .frame(width: compact ? 24 : 30, height: compact ? 24 : 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.accent))
                .environment(\.layoutDirection, .leftToRight)
            Text(line).font(.tajawal(compact ? 14 : 16, "Bold")).foregroundStyle(palette.text).lineLimit(2).minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("الملاحة: \(line)"))
    }
}

private struct TripRow: View {
    let line: String
    let fraction: Double
    let palette: Ink.Palette
    let dim: Bool
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "flag.checkered").font(.system(size: compact ? 12 : 14, weight: .bold)).foregroundStyle(palette.live)
                Text(line).font(.tajawal(compact ? 14 : 16)).foregroundStyle(dim ? palette.stale : palette.text).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.text.opacity(0.14))
                    Capsule().fill(dim ? palette.stale : (fraction >= 1 ? palette.live : palette.accent))
                        .frame(width: max(6, g.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: compact ? 5 : 6)
            .environment(\.layoutDirection, .rightToLeft)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("الطلعة: \(line)"))
    }
}
