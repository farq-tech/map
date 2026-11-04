import SwiftUI

/// Everything the speedometer shows.
struct SpeedometerUI: Equatable {
    var current: SpeedReading
    /// The trip's top / average moving speed (nil until there is any).
    var trip: TripSpeedSummary?
    /// Over the person's «نبّهني إذا تجاوزت» limit (only when that nudge is on).
    var overLimit = false
}

/// «سرعة المركبة» over the map: a compact glass readout, large and opaque in
/// drive mode. Shows «—» when there is no current, trustworthy speed. A tap
/// shows the trip's top and average moving speed for a few seconds.
struct SarySpeedometer: View {
    var ui: SpeedometerUI
    @Environment(\.sary) private var theme
    @State private var showingTrip = false

    var body: some View {
        let p = theme.palette
        let shape = RoundedRectangle(cornerRadius: theme.drive ? SaryRadius.l : SaryRadius.m, style: .continuous)
        let trip = showingTrip ? ui.trip : nil
        Button {
            guard ui.trip?.isEmpty == false else { return }
            showingTrip.toggle()
        } label: {
            ZStack {
                if let trip { tripFace(trip) } else { currentFace }
            }
            .frame(width: theme.drive ? 100 : 66, height: theme.drive ? 92 : 62)
            .background {
                /* Drive mode: fully opaque, readable at a glance in sun. */
                if theme.drive { shape.fill(p.chromeOpaque) }
            }
            .saryGlass(shape, role: .control, interactive: true)
            .overlay {
                if ui.overLimit { shape.stroke(p.emergency, lineWidth: theme.drive ? 3 : 2) }
            }
            .contentShape(shape)
        }
        .buttonStyle(SaryPressStyle())
        .environment(\.layoutDirection, .rightToLeft)
        .task(id: showingTrip) {
            guard showingTrip else { return }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            showingTrip = false
        }
        .animation(theme.animation(.snappy), value: showingTrip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibility))
        .accessibilityHint(Text(ui.trip?.isEmpty == false ? "اضغط لعرض أعلى سرعة والمتوسط" : ""))
        .accessibilityIdentifier("speedometer")
    }

    private var currentFace: some View {
        let p = theme.palette
        return VStack(spacing: theme.drive ? 0 : -2) {
            Text(SaryFormat.speedValue(kmh: ui.current.kmh))
                .saryNumber(theme.drive ? .display : .title, weight: .heavy)
                .foregroundStyle(ui.current == .unknown ? p.textTertiary : (ui.overLimit ? p.emergencyText : p.textPrimary))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(theme.animation(.snappy), value: ui.current.kmh.map { Int($0.rounded()) })
                .accessibilityIdentifier("speedometer.value")
            Text(SaryFormat.speedUnit)
                .saryText(theme.drive ? .footnote : .micro, weight: .bold)
                .foregroundStyle(p.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    private func tripFace(_ t: TripSpeedSummary) -> some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: theme.drive ? 4 : 1) {
            row("أعلى", t.maxKmh)
            row("متوسط", t.avgMovingKmh)
        }
        .foregroundStyle(p.textPrimary)
        .padding(.horizontal, 6)
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityIdentifier("speedometer.trip")
    }

    private func row(_ k: String, _ v: Double?) -> some View {
        VStack(alignment: .leading, spacing: -2) {
            Text(k).saryText(theme.drive ? .caption : .micro, weight: .bold).foregroundStyle(theme.palette.textSecondary)
            Text(SaryFormat.speedValue(kmh: v)).saryNumber(theme.drive ? .title2 : .subhead, weight: .heavy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private var accessibility: String {
        if showingTrip, let t = ui.trip {
            return "أعلى سرعة \(SaryFormat.speed(kmh: t.maxKmh))، متوسط السرعة أثناء الحركة \(SaryFormat.speed(kmh: t.avgMovingKmh))"
        }
        guard let k = ui.current.kmh else { return "سرعتك غير معروفة الآن" }
        return "سرعتك \(SaryFormat.speed(kmh: k))" + (ui.overLimit ? "، تجاوزت حدّك" : "")
    }
}

/// A friend's speed on their row and card: "٨٧ كم/س" or «واقف». Only ever
/// given a live position's speed (stale rows show «آخر موقع قبل …» instead).
struct SarySpeedLabel: View {
    var kmh: Double
    var style: SaryTextStyle = .caption
    @Environment(\.sary) private var theme

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: style.size * 0.95, weight: .semibold))
                .environment(\.layoutDirection, .leftToRight)
            Text(SaryFormat.friendSpeed(kmh: kmh)).saryNumber(style, weight: .medium).lineLimit(1).fixedSize()
        }
        .foregroundStyle(style == .caption ? theme.palette.textSecondary : theme.palette.textPrimary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.accessibility(kmh: kmh)))
        .accessibilityIdentifier("participant.speed")
    }

    static func accessibility(kmh: Double) -> String {
        kmh < Speed.parkedKmh ? "واقف" : "السرعة \(SaryFormat.speed(kmh: kmh))"
    }
}
