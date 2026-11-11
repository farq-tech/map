import SwiftUI

/// «جودة GPS» (and «أداء التطبيق», `MetricsEntryRow`): developer-only readouts under «الإعدادات › متقدم › تشخيص». Hidden for everyone
/// else; shown in Debug builds, with `-SaryDevGPS`, or after a 3-second press on the diagnostics
/// content (toggles `sary.dev.unlocked`, kept across account wipes like every `sary.dev.` key).
enum GpsDevAccess {
    static let key = "sary.dev.unlocked"

    static func enabled(_ d: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        #if DEBUG
        return true
        #else
        return d.bool(forKey: key) || arguments.contains("-SaryDevGPS")
        #endif
    }
}

/// Wraps the diagnostics content: a long press unlocks / hides the GPS readout under it.
struct GpsDevGate<Content: View>: View {
    @ObservedObject var location: LocationSharer
    @ViewBuilder var content: Content
    @AppStorage(GpsDevAccess.key) private var unlocked = false

    var body: some View {
        VStack(spacing: 0) {
            content
                .onLongPressGesture(minimumDuration: 3) { unlocked.toggle() }
            if unlocked || GpsDevAccess.enabled() {
                GpsQualityRow(location: location)
                /* «أداء التطبيق»: MetricKit summaries stored on this phone (docs/METRICS.md). */
                MetricsEntryRow()
            }
        }
    }
}

struct GpsQualityRow: View {
    @ObservedObject var location: LocationSharer
    @Environment(\.sary) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("جودة الموقع").font(.sary(14, .medium)).foregroundStyle(theme.palette.textPrimary)
            ForEach(Array((location.quality.lines + [NavVoiceStats.current.line]).enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(2).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.gpsQuality")
    }
}
