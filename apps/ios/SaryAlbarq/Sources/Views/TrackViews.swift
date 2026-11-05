import SwiftUI

enum FollowIcon {
    static let follow = "point.topleft.down.to.point.bottomright.curvepath.fill"
    static let reverse = "arrow.left.arrow.right"
    static let offTrack = "exclamationmark.triangle.fill"
    static let approach = "arrow.triangle.turn.up.right.diamond.fill"
}

// MARK: - the three big numbers

/// The dark card under a track: «المسافة · أعلى سرعة · مدة القيادة» and «اسلك هذا المسار».
/// Always dark (it sits on satellite imagery), in our sand / ember palette.
struct TrackStatsCard: View {
    var stats: TrackStats
    /// The line is coloured by speed: show the legend.
    var speedLegend = false
    var follow: (() -> Void)?
    @Environment(\.sary) private var theme

    static let ink = Color(rgb: 0x17110B)
    static let sand = Color(rgb: 0xEAD9BD)

    var body: some View {
        VStack(spacing: theme.space(.m)) {
            HStack(alignment: .top, spacing: 0) {
                cell("المسافة", stats.distanceText, "كم", id: "track.stat.distance")
                divider
                cell("أعلى سرعة", stats.maxSpeedText, stats.maxKmh == nil ? nil : "كم/س", id: "track.stat.maxSpeed")
                divider
                cell("مدة القيادة", stats.movingText, stats.movingS == nil ? nil : "س:د", id: "track.stat.moving")
            }
            if speedLegend {
                HStack(spacing: theme.space(.s)) {
                    Text("بطيء").saryText(.micro, weight: .bold).foregroundStyle(Self.sand.opacity(0.8))
                    Capsule()
                        .fill(LinearGradient(colors: TrackGradient.ramp.map { Color(rgb: $0.rgb) }, startPoint: .leading, endPoint: .trailing))
                        .frame(height: 6)
                        /* Slow → fast reads the same way as the words around it (RTL: from the right). */
                        .environment(\.layoutDirection, .rightToLeft)
                    Text("سريع").saryText(.micro, weight: .bold).foregroundStyle(Self.sand.opacity(0.8))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("لون المسار حسب السرعة: فاتح بطيء، غامق سريع"))
            }
            if let follow {
                Button(action: follow) {
                    SaryButtonLabel(title: "اسلك هذا المسار", systemImage: FollowIcon.follow)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.sary(.primary))
                .accessibilityIdentifier("track.follow")
            }
        }
        .padding(theme.space(.l))
        .background(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous).fill(Self.ink.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous).stroke(Self.sand.opacity(0.14), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("track.stats")
    }

    private var divider: some View {
        Rectangle().fill(Self.sand.opacity(0.16)).frame(width: 1, height: 52).padding(.top, 4)
    }

    private func cell(_ label: String, _ value: String, _ unit: String?, id: String) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .saryNumber(.title, weight: .heavy)
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit).saryText(.caption, weight: .bold).foregroundStyle(Self.sand.opacity(0.75))
                }
            }
            Text(label).saryText(.caption, weight: .medium).foregroundStyle(Self.sand.opacity(0.85)).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(label): \(value == "—" ? "غير معروف" : value) \(unit ?? "")"))
        .accessibilityIdentifier(id)
    }
}

// MARK: - track detail (full screen)

/// One saved track on clean satellite imagery with its three numbers and «اسلك هذا المسار».
struct TrackDetailView: View {
    var subject: FollowSubject
    var close: () -> Void
    var follow: (FollowSubject) -> Void
    @Environment(\.sary) private var theme
    @State private var cardHeight: CGFloat = 220

    var body: some View {
        ZStack(alignment: .bottom) {
            TrackMapView(line: subject.line, padding: UIEdgeInsets(top: 90, left: 0, bottom: cardHeight, right: 0))
                .ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: theme.space(.s)) {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).frame(width: 44, height: 44)
                    }
                    .foregroundStyle(theme.palette.textPrimary)
                    .saryGlass(Circle(), role: .control, interactive: true)
                    .accessibilityLabel(Text("إغلاق"))
                    .accessibilityIdentifier("track.close")
                    VStack(alignment: .leading, spacing: 0) {
                        Text(subject.name).saryText(.headline, weight: .bold).foregroundStyle(theme.palette.textPrimary).lineLimit(1)
                        Text(subject.origin).saryText(.caption).foregroundStyle(theme.palette.textSecondary)
                    }
                    .padding(.horizontal, theme.space(.m))
                    .frame(minHeight: 44)
                    .saryGlass(Capsule(), role: .chrome)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, theme.space(.m))
                Spacer()
            }
            TrackStatsCard(stats: subject.stats, speedLegend: subject.line.hasSpeeds) { follow(subject) }
                .padding(.horizontal, theme.space(.m))
                .padding(.bottom, theme.space(.s))
                .background(GeometryReader { g in Color.clear.onAppear { cardHeight = g.size.height + 24 } })
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("track.detail")
    }
}

// MARK: - follow panel

/// «اسلك هذا المسار»: arrow, distance left along the track, my progress, the deviation
/// warning, «اعكس الاتجاه» and «إنهاء». Opaque and bigger while driving (one header only).
struct FollowTrackPanel: View {
    var ui: FollowTrackUI
    var reverse: () -> Void
    var exit: () -> Void
    /// «وجّهني لأقرب نقطة» (nil: not offered here).
    var approach: (() -> Void)?
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let off = ui.phase == .offTrack
        let arrived = ui.phase == .arrived
        let arrowSize: CGFloat = theme.drive ? 88 : 64
        let tone: Color = off ? p.emergency : (arrived ? p.live : (ui.phase == .far ? Color(rgb: 0x2B7BF0) : p.accent))
        VStack(alignment: .leading, spacing: theme.space(.s)) {
            HStack(spacing: theme.space(.m)) {
                ZStack {
                    Circle().fill(tone)
                    if arrived {
                        Image(systemName: "flag.checkered").font(.system(size: arrowSize * 0.42, weight: .heavy)).foregroundStyle(Color.white)
                    } else if ui.phase == .waitingFix {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: arrowSize * 0.5, weight: .black))
                            .foregroundStyle(Color.white)
                            .rotationEffect(.degrees(ui.arrowDegrees))
                            .animation(theme.animation(.smooth), value: ui.arrowDegrees)
                    }
                }
                .frame(width: arrowSize, height: arrowSize)
                .environment(\.layoutDirection, .leftToRight)
                .overlay(Circle().stroke(Color.white, lineWidth: 3))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .saryText(theme.drive ? .title2 : .headline, weight: .bold)
                        .foregroundStyle(off ? p.emergencyText : p.textPrimary)
                        .lineLimit(1)
                        .accessibilityIdentifier("follow.title")
                    if let m = ui.remainingMeters, !arrived {
                        Text(SaryFormat.distance(meters: m))
                            .saryNumber(theme.drive ? .display : .title, weight: .heavy)
                            .foregroundStyle(p.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .accessibilityLabel(Text("باقي \(SaryFormat.distance(meters: m)) على المسار"))
                            .accessibilityIdentifier("follow.distance")
                    }
                    Text(detail)
                        .saryText(theme.drive ? .callout : .footnote, weight: .medium)
                        .foregroundStyle(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: exit) { Text("إنهاء").saryText(theme.drive ? .body : .callout, weight: .bold) }
                    .buttonStyle(.sary(.secondary, width: .hug, compact: !theme.drive))
                    .accessibilityIdentifier("follow.exit")
            }
            if let pr = ui.progress, !arrived, ui.phase != .far {
                HStack(spacing: theme.space(.s)) {
                    ProgressView(value: pr)
                        .tint(tone)
                        .environment(\.layoutDirection, .rightToLeft)
                    Text("قطعت \(SaryFormat.percent(Int((pr * 100).rounded(.down))))")
                        .saryNumber(.caption, weight: .bold).foregroundStyle(p.textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("قطعت \(SaryFormat.percent(Int((pr * 100).rounded(.down)))) من المسار"))
                .accessibilityIdentifier("follow.progress")
            }
            if ui.phase == .far {
                if ui.online, let approach {
                    Button(action: approach) {
                        SaryButtonLabel(title: "وجّهني لأقرب نقطة من المسار", systemImage: FollowIcon.approach).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.sary(.primary, compact: !theme.drive))
                    .accessibilityIdentifier("follow.approach")
                } else {
                    Text(ui.online ? "اتجه بالسهم إلى أقرب نقطة من المسار." : "بدون إنترنت ما نقدر نحسب طريقًا إلى المسار؛ اتجه بالسهم، والتوجيه على المسار نفسه يشتغل بدون إنترنت.")
                        .saryText(.footnote, weight: .medium).foregroundStyle(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("follow.approachOffline")
                }
            }
            if !theme.drive, !arrived {
                Button(action: reverse) {
                    SaryButtonLabel(title: "اعكس الاتجاه", systemImage: FollowIcon.reverse).frame(maxWidth: .infinity)
                }
                .buttonStyle(.sary(.secondary, compact: true))
                .accessibilityIdentifier("follow.reverse")
            }
        }
        .padding(theme.space(.m))
        .background {
            if theme.drive || off { RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous).fill(p.chromeOpaque) }
        }
        .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .control)
        .overlay {
            if off { RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous).stroke(p.emergency, lineWidth: 3) }
        }
        .sensoryFeedback(.warning, trigger: off) { was, now in now && !was }
        .sensoryFeedback(.success, trigger: arrived) { was, now in now && !was }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("follow.panel")
    }

    private var title: String {
        switch ui.phase {
        case .waitingFix, .onTrack: return ui.name
        case .offTrack: return "خرجت عن المسار"
        case .far: return "المسار بعيد عنك"
        case .arrived: return "وصلت نهاية المسار"
        }
    }

    private var detail: String {
        let dir = ui.reversed ? "بالاتجاه المعاكس" : "إلى نهايته"
        switch ui.phase {
        case .waitingFix: return "ننتظر موقعك من GPS…"
        case .arrived: return ui.name
        case .far:
            return "أقرب نقطة منه على بعد \(ui.offsetMeters.map { SaryFormat.distance(meters: $0) } ?? "") · \(ui.directionLabel)"
        case .offTrack:
            let m = ui.offsetMeters.map { SaryFormat.distance(meters: $0) } ?? ""
            return "أنت على بعد \(m) من المسار · ارجع له باتجاه السهم (\(ui.directionLabel))"
        case .onTrack:
            if ui.onGap { return "هذا الجزء لم يُسجَّل: خط مستقيم تقريبي، انتبه للطريق" }
            return "باقي على المسار \(dir) · \(ui.directionLabel)"
        }
    }
}
