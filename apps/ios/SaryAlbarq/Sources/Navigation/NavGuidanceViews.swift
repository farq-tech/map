import SwiftUI

/// Panels over the live map while navigating. Drive mode: opaque, bigger, readable in sun.
private extension View {
    func navPanel(_ theme: SaryTheme, stroke: Color? = nil) -> some View {
        /* The Lovable header: 22 pt corners, dark and nearly opaque over the map. */
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return self
            .background { shape.fill(theme.palette.chromeOpaque.opacity(theme.drive ? 1 : 0.88)) }
            .saryGlass(shape, role: .panel)
            .overlay { if let stroke { shape.stroke(stroke, lineWidth: 3) } }
    }
}

/// The maneuver glyph in its blue tile. Never mirrored.
struct NavManeuverGlyph: View {
    var maneuver: NavManeuver
    var size: CGFloat
    var tint = Color(rgb: 0x2B7BF0)
    var ink = Color.white

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.43, style: .continuous).fill(tint)
            /* `tint: .clear` (the v2 banner): a plain, bigger arrow with no tile. */
            Image(systemName: NavGlyph.symbol(maneuver))
                .font(.system(size: size * (tint == .clear ? 0.78 : 0.56), weight: .heavy))
                .foregroundStyle(ink)
            if maneuver.kind == .roundabout, let e = maneuver.exit {
                Text(SaryFormat.number(e))
                    .font(.system(size: size * 0.22, weight: .black))
                    .foregroundStyle(tint == .clear ? Color.black : tint)
                    .padding(3)
                    .background(Circle().fill(Color.white))
                    .offset(x: size * 0.3, y: size * 0.3)
            }
        }
        .frame(width: size, height: size)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }
}

/// The guidance HUD's rules (v2, «وضوح Google»: less text, bigger). Pure, unit-tested in `NavigationTests`.
enum NavHUD {
    /// «ثم …» shows only when the turn after this one comes this soon after it.
    static let thenWithinM = 400.0

    static func showsThen(_ step: NavStep, next: NavStep?) -> Bool {
        guard next != nil, step.maneuver.kind != .arrive else { return false }
        return step.distanceM < thenWithinM
    }

    /// «٣٫٣ كم» → («٣٫٣», «كم»): the number big, the unit small.
    static func distanceParts(_ meters: Double) -> (value: String, unit: String) {
        let s = SaryFormat.distance(meters: meters)
        guard let i = s.lastIndex(of: " ") else { return (s, "") }
        return (String(s[..<i]), String(s[s.index(after: i)...]))
    }

    /// The banner's one big line: the road («طريق مكة المكرمة»); with no name, the action
    /// («انعطف يمينًا»); at the end, the destination.
    static func title(_ step: NavStep, targetName: String?) -> String {
        if step.maneuver.kind == .arrive {
            if let n = targetName, !n.isEmpty { return NavText.arabicDigitsOnly(n) }
            return "وجهتك"
        }
        if let n = step.roadName, !n.isEmpty { return NavText.arabicDigitsOnly(n) }
        if let n = step.signText, !n.isEmpty { return NavText.arabicDigitsOnly(n) }
        return NavText.action(step.maneuver)
    }

    /// Over the posted limit (rounded km/h above it).
    static func overLimit(kmh: Double?, limit: Int?) -> Bool {
        guard let k = kmh, let l = limit, l > 0 else { return false }
        return Int(k.rounded()) > l
    }

    /// «١٩ كم · ١٢:٥٦ ص» under the time left.
    static func tripLine(meters: Double?, eta: Date?) -> String {
        [meters.map { SaryFormat.distance(meters: $0) }, eta.map { NavText.clock($0) }].compactMap { $0 }.joined(separator: " · ")
    }

    /// «مشاركة الوصول»: plain text the person sends themselves (no link, no tracking).
    static func shareText(target: String?, eta: Date?, seconds: Double?) -> String {
        var s = "في الطريق" + (target.map { $0.isEmpty ? "" : " إلى \(NavText.arabicDigitsOnly($0))" } ?? "")
        if let eta { s += "، أوصل تقريبًا \(NavText.clock(eta))" }
        if let seconds { s += " (بعد \(NavText.remaining(seconds: seconds)))" }
        return s + " · سَرى"
    }
}

/// Top banner (v2): a big arrow with the distance under it, the road on one big line beside them,
/// lanes near the turn, and «ثم …» only when the next turn is close. Time and distance left are in the
/// bottom bar now.
struct NavManeuverBanner: View {
    @ObservedObject var nav: NavSession
    @StateObject private var pip = NavPictureInPicture()
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let glyph: CGFloat = theme.drive ? 64 : 56
        VStack(spacing: 0) {
            if nav.rerouting {
                HStack(spacing: theme.space(.m)) {
                    ProgressView().tint(p.textPrimary).frame(width: glyph, height: glyph)
                    Text("نعيد حساب الطريق…").saryText(theme.drive ? .title2 : .headline).foregroundStyle(p.textPrimary)
                        .accessibilityIdentifier("nav.rerouting")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(theme.space(.m))
            } else if let step = nav.currentStep {
                let d = nav.progress?.distanceToManeuverM ?? step.distanceM
                let parts = NavHUD.distanceParts(d)
                HStack(alignment: .center, spacing: theme.space(.m)) {
                    /* The arrow and the distance: the two things read at a glance. */
                    VStack(spacing: 0) {
                        NavManeuverGlyph(maneuver: step.maneuver, size: glyph, tint: .clear, ink: p.accent)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(parts.value).font(.sary(theme.drive ? 30 : 26, .heavy)).foregroundStyle(p.textPrimary)
                            Text(parts.unit).font(.sary(theme.drive ? 16 : 14, .bold)).foregroundStyle(p.textSecondary)
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .fixedSize()
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("nav.distance")
                    }
                    .frame(minWidth: glyph + 8)
                    Text(NavHUD.title(step, targetName: nav.target?.name))
                        .font(.sary(theme.drive ? 30 : 26, .bold))
                        .foregroundStyle(p.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        /* VoiceOver hears the whole instruction («بعد ٣٫٣ كم انعطف يسارًا إلى …»). */
                        .accessibilityLabel(Text(NavText.banner(step, distanceM: d, targetName: nav.target?.name)))
                        .accessibilityIdentifier("nav.instruction")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                if !step.lanes.isEmpty, d < 1500 {
                    NavLanesView(lanes: step.lanes)
                        .padding(.horizontal, theme.space(.m))
                        .padding(.bottom, theme.space(.s))
                }
                if let next = nav.nextStep, NavHUD.showsThen(step, next: next) {
                    nextRow(next)
                }
            }
        }
        .navPanel(theme)
        .overlay(alignment: .topLeading) {
            Button { pip.start() } label: {
                Image(systemName: pip.active ? "pip.exit" : "pip.enter")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(p.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(p.sunken.opacity(0.85)))
            }
            .buttonStyle(SaryPressStyle())
            .disabled(!pip.supported)
            .accessibilityLabel(Text("نافذة الملاحة العائمة"))
            .accessibilityIdentifier("nav.pip")
            .padding(8)
        }
        .background(alignment: .bottomTrailing) {
            NavPiPLayerHost(displayLayer: pip.displayLayer)
                .frame(width: 2, height: 2)
                .opacity(0.01)
                .accessibilityHidden(true)
        }
        .onAppear { pip.update(NavPiPSnapshot.make(nav: nav), guiding: nav.phase == .guiding) }
        .onChange(of: NavPiPSnapshot.make(nav: nav)) { _, snapshot in
            pip.update(snapshot, guiding: nav.phase == .guiding)
        }
        .onChange(of: nav.phase) { _, phase in
            pip.update(NavPiPSnapshot.make(nav: nav), guiding: phase == .guiding)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nav.banner")
    }

    /// «ثم ↰ طريق العليا»: one small strip, only when that turn comes right after.
    private func nextRow(_ next: NavStep) -> some View {
        let p = theme.palette
        return HStack(spacing: theme.space(.s)) {
            Text("ثم").saryText(.callout, weight: .bold).foregroundStyle(p.textSecondary)
            NavManeuverGlyph(maneuver: next.maneuver, size: theme.drive ? 30 : 26, tint: .clear, ink: p.textPrimary)
            Text(NavHUD.title(next, targetName: nav.target?.name))
                .saryText(.callout, weight: .bold)
                .foregroundStyle(p.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(p.sunken.opacity(0.7))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("ثم \(NavText.instruction(next, targetName: nav.target?.name))"))
        .accessibilityIdentifier("nav.next")
    }
}

/// The header's bottom line, always while guiding: «توصل ٧:٤٢ م · باقي ١٨ د» on the right, «١٢٫٤ كم» on the left.
struct NavETARow: View {
    @ObservedObject var nav: NavSession
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let size: CGFloat = theme.drive ? 16 : 14
        if nav.etaDate != nil || nav.remainingMeters != nil {
            VStack(spacing: 0) {
                Rectangle().fill(p.separator).frame(height: 0.75).padding(.horizontal, 13)
                HStack(spacing: 4) {
                    if let eta = nav.etaDate {
                        Text("توصل \(NavText.clock(eta))").font(.sary(size, .bold)).foregroundStyle(p.liveText)
                            .accessibilityIdentifier("nav.eta")
                    }
                    if let s = nav.remainingSeconds {
                        Text("· باقي \(NavText.remaining(seconds: s))").font(.sary(size, .regular)).foregroundStyle(p.textSecondary)
                            .accessibilityIdentifier("nav.remainingTime")
                    }
                    Spacer(minLength: theme.space(.s))
                    if let m = nav.remainingMeters {
                        Text(SaryFormat.distance(meters: m)).font(.sary(size, .bold)).foregroundStyle(p.textPrimary)
                            .accessibilityIdentifier("nav.remainingDistance")
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(label))
            .accessibilityIdentifier("nav.banner.eta")
        }
    }

    private var label: String {
        [nav.target.map { "إلى \($0.name)" }, nav.etaDate.map { "توصل \(NavText.clock($0))" },
         nav.remainingSeconds.map { "باقي \(NavText.remaining(seconds: $0))" }, nav.remainingMeters.map { SaryFormat.distance(meters: $0) }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// Lanes as painted, left to right (a physical order: not mirrored).
struct NavLanesView: View {
    var lanes: [NavLane]
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        HStack(spacing: 4) {
            ForEach(Array(lanes.enumerated()), id: \.offset) { _, l in
                Image(systemName: NavGlyph.lane(l))
                    .font(.system(size: theme.drive ? 22 : 18, weight: .heavy))
                    .foregroundStyle(l.valid ? Color.white : p.textTertiary)
                    .frame(width: theme.drive ? 38 : 32, height: theme.drive ? 38 : 32)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(l.valid ? Color(rgb: 0x2B7BF0) : p.sunken))
                    .overlay { if l.preferred { RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.white, lineWidth: 2) } }
            }
        }
        .frame(maxWidth: .infinity)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement()
        .accessibilityLabel(Text("المسارات: \(SaryFormat.number(lanes.filter(\.valid).count)) من \(SaryFormat.number(lanes.count)) تؤدي لطريقك"))
        .accessibilityIdentifier("nav.lanes")
    }
}

/// The posted limit, as a road sign. Sits next to the speedometer («سرعة المركبة»).
struct NavSpeedLimitSign: View {
    var kmh: Int
    var size: CGFloat? = nil
    @Environment(\.sary) private var theme

    var body: some View {
        let s: CGFloat = size ?? (theme.drive ? 62 : 52)
        ZStack {
            Circle().fill(Color.white)
            Circle().stroke(Color(rgb: 0xD7262E), lineWidth: s * 0.11)
            Text(SaryFormat.number(kmh))
                .font(.system(size: s * 0.38, weight: .black))
                .foregroundStyle(Color.black)
                .minimumScaleFactor(0.6)
                .padding(s * 0.14)
        }
        .frame(width: s, height: s)
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .accessibilityElement()
        .accessibilityLabel(Text("حد السرعة \(SaryFormat.number(kmh)) كم/س"))
        .accessibilityIdentifier("nav.speedLimit")
    }
}

/// «آخر جزء بدون طريق»: a straight-line arrow, the distance and the bearing — nothing pretends to be a road.
struct NavOffRoadPanel: View {
    @ObservedObject var nav: NavSession
    /// Where the car (or the map) points, for the arrow.
    var reference: Double
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let leg = nav.offRoad
        let dist = nav.offRoadNow?.distanceM ?? leg?.distanceM ?? 0
        let bearing = nav.offRoadNow?.bearing ?? leg?.bearing ?? 0
        let arrow: CGFloat = theme.drive ? 64 : 56
        VStack(spacing: 0) {
            /* Lovable: «٣٠٠ م» big, «بدون طريق معبّد: اتجه مع السهم», the arrow in the orange tile. */
            HStack(spacing: theme.space(.m)) {
                ZStack {
                    RoundedRectangle(cornerRadius: arrow * 0.43, style: .continuous).fill(p.accent)
                    Image(systemName: "arrow.up")
                        .font(.system(size: arrow * 0.5, weight: .black))
                        .foregroundStyle(p.onAccent)
                        .rotationEffect(.degrees(NavOffRoad.arrowDegrees(bearing: bearing, reference: reference)))
                        .animation(theme.animation(.smooth), value: bearing)
                }
                .frame(width: arrow, height: arrow)
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(SaryFormat.distance(meters: dist))
                        .font(.sary(theme.drive ? 34 : 28, .heavy))
                        .foregroundStyle(p.textPrimary)
                        .accessibilityIdentifier("nav.offroad.distance")
                    Text(NavOffRoad.title(direct: nav.direct, fallback: nav.fallback))
                        .saryText(theme.drive ? .callout : .subhead)
                        .foregroundStyle(p.textSecondary)
                        .accessibilityIdentifier("nav.offroad.title")
                    Text(NavOffRoad.note(fallback: nav.fallback, bearing: bearing))
                        .saryText(.footnote)
                        .foregroundStyle(p.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("nav.offroad.note")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 13)
            .padding(.top, 13)
            .padding(.bottom, theme.space(.s))
            NavETARow(nav: nav)
        }
        .navPanel(theme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nav.offroad")
    }
}

/// «وصلت».
struct NavArrivalCard: View {
    @ObservedObject var nav: NavSession
    var end: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        HStack(spacing: theme.space(.m)) {
            ZStack {
                Circle().fill(p.live)
                Image(systemName: "flag.checkered").font(.system(size: theme.drive ? 34 : 26, weight: .heavy)).foregroundStyle(Color.white)
            }
            .frame(width: theme.drive ? 76 : 60, height: theme.drive ? 76 : 60)
            VStack(alignment: .leading, spacing: 2) {
                Text(nav.auto ? "وصلتوا" : "وصلت").saryText(theme.drive ? .title : .title2, weight: .heavy).foregroundStyle(p.textPrimary)
                    .accessibilityIdentifier("nav.arrived.title")
                Text(nav.target?.name ?? "وجهتك").saryText(.callout, weight: .bold).foregroundStyle(p.textSecondary).lineLimit(1)
                if let s = nav.startedAt, let a = nav.arrivedAt {
                    Text("مدة الرحلة \(NavText.remaining(seconds: a.timeIntervalSince(s)))").saryText(.footnote).foregroundStyle(p.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: end) { Text("إنهاء").saryText(theme.drive ? .body : .callout, weight: .bold) }
                .buttonStyle(.sary(.primary, width: .hug, compact: !theme.drive))
                .accessibilityIdentifier("nav.arrived.end")
        }
        .padding(theme.space(.m))
        .navPanel(theme, stroke: p.live)
        .sensoryFeedback(.success, trigger: nav.phase == .arrived) { was, now in now && !was }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nav.arrived")
    }
}

/// The bottom bar in the sheet's peek (v2): the time left big and coloured, «١٩ كم · ١٢:٥٦ ص» under it,
/// and a clear red «إنهاء». Drag the sheet up for «المسارات»، «مشاركة الوصول»، «الصوت» (`NavTripOptions`).
struct NavBottomBar: View {
    @ObservedObject var nav: NavSession
    var end: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        HStack(spacing: theme.space(.m)) {
            if nav.phase == .arrived {
                Text(nav.auto ? "وصلتوا إلى \(nav.target?.name ?? "وجهتكم")" : "وصلت إلى \(nav.target?.name ?? "وجهتك")").saryText(.headline).foregroundStyle(p.textPrimary).lineLimit(1)
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if let s = nav.remainingSeconds {
                        Text(NavText.remaining(seconds: s))
                            .font(.sary(theme.drive ? 34 : 30, .heavy))
                            .foregroundStyle(p.accent)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .accessibilityIdentifier("nav.remainingTime")
                    }
                    Text(NavHUD.tripLine(meters: nav.remainingMeters, eta: nav.etaDate))
                        .font(.sary(theme.drive ? 18 : 16, .medium))
                        .foregroundStyle(p.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .accessibilityIdentifier("nav.eta")
                    if let note = nav.target?.staleNote() {
                        Text(note).saryText(.caption, weight: .bold).foregroundStyle(p.warning).lineLimit(1)
                            .accessibilityIdentifier("nav.target.stale")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(label))
                .accessibilityIdentifier("nav.banner.eta")
                Spacer(minLength: 0)
                Button(action: end) {
                    /* The trip's guidance pauses on this phone only («استأنف» brings it back). */
                    Text(nav.auto ? "أوقف التوجيه" : "إنهاء")
                        .font(.sary(theme.drive ? 20 : 18, .heavy))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, theme.drive ? 30 : 26)
                        .frame(minHeight: theme.drive ? 60 : 52)
                        .background(Capsule().fill(p.emergency))
                }
                .buttonStyle(SaryPressStyle())
                .accessibilityIdentifier(nav.auto ? "nav.auto.pause" : "nav.end")
            }
        }
        .padding(.horizontal, theme.space(.l))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nav.bottomBar")
    }

    private var label: String {
        [nav.target.map { "إلى \($0.name)" }, nav.remainingSeconds.map { "باقي \(NavText.remaining(seconds: $0))" },
         nav.remainingMeters.map { SaryFormat.distance(meters: $0) }, nav.etaDate.map { "الوصول \(NavText.clock($0))" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// The guidance sheet pulled up: «المسارات»، «مشاركة الوصول»، «الصوت»، plus «الخطوات» and «نظرة عامة».
struct NavTripOptions: View {
    @ObservedObject var nav: NavSession
    /// «المسارات»: the route options again (nil for the trip's automatic guidance, which follows the plan).
    var routes: (() -> Void)?
    var steps: () -> Void
    var overview: () -> Void
    var overviewOn: Bool
    /// The map camera's mode (free / north / heading): VoiceOver value of «نظرة عامة».
    var cameraMode = ""
    @Environment(\.sary) private var theme

    var body: some View {
        let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        LazyVGrid(columns: cols, spacing: 10) {
            if let routes {
                tile("arrow.triangle.branch", "المسارات", id: "nav.opt.routes", action: routes)
            }
            ShareLink(item: NavHUD.shareText(target: nav.target?.name, eta: nav.etaDate, seconds: nav.remainingSeconds)) {
                tileLabel("square.and.arrow.up", "مشاركة الوصول", active: false)
            }
            .buttonStyle(SaryPressStyle())
            .accessibilityIdentifier("nav.opt.share")
            tile(nav.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", nav.muted ? "الصوت مكتوم" : "الصوت", id: "nav.opt.voice", active: nav.muted) {
                nav.muted.toggle()
            }
            if nav.phase == .guiding {
                tile("list.bullet", "الخطوات", id: "nav.stepsButton", action: steps)
            }
            tile("map.fill", overviewOn ? "رجّعني لسيارتي" : "نظرة عامة", id: "nav.overview", active: overviewOn, value: cameraMode, action: overview)
        }
        .padding(.horizontal, theme.space(.l))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nav.options.trip")
    }

    private func tile(_ symbol: String, _ title: String, id: String, active: Bool = false, value: String = "", action: @escaping () -> Void) -> some View {
        Button(action: action) { tileLabel(symbol, title, active: active) }
            .buttonStyle(SaryPressStyle())
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(value))
            .accessibilityAddTraits(active ? .isSelected : [])
            .accessibilityIdentifier(id)
    }

    private func tileLabel(_ symbol: String, _ title: String, active: Bool) -> some View {
        let p = theme.palette
        return VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
                .foregroundStyle(active ? p.onAccent : p.textPrimary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(active ? p.accent : p.sunken))
            Text(title).saryText(.footnote, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(p.sunken.opacity(0.5)))
    }
}

/// The speed while guiding (v2): my speed in a round bubble at the bottom-left, the posted limit
/// (Mapbox `maxspeed`) beside it when known; over the limit the bubble turns red.
struct NavSpeedCluster: View {
    var ui: SpeedometerUI
    var limit: Int?
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let kmh = ui.current.kmh.map { Int($0.rounded()) }
        let over = NavHUD.overLimit(kmh: ui.current.kmh, limit: limit) || ui.overLimit
        let d: CGFloat = theme.drive ? 72 : 64
        /* Physical order (not mirrored): my speed in the corner, the limit sign just right of it. */
        HStack(spacing: -6) {
            VStack(spacing: -2) {
                Text(kmh.map { SaryFormat.number($0) } ?? "—")
                    .font(.sary(d * 0.36, .heavy))
                    .foregroundStyle(over ? Color.white : p.textPrimary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("كم/س").font(.sary(11, .bold)).foregroundStyle(over ? Color.white.opacity(0.9) : p.textSecondary)
            }
            .frame(width: d, height: d)
            .background(Circle().fill(over ? p.emergency : p.chromeOpaque.opacity(0.92)))
            .overlay(Circle().stroke(over ? Color.white : p.separator, lineWidth: over ? 3 : 1))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(kmh.map { "السرعة \(SaryFormat.number($0)) كم/س" + (over ? "، فوق الحد" : "") } ?? "السرعة غير معروفة"))
            .accessibilityValue(Text(over ? "over" : "ok"))
            .accessibilityIdentifier("speedometer")
            if let limit {
                NavSpeedLimitSign(kmh: limit, size: d * 0.72)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .animation(theme.animation(.snappy), value: over)
    }
}

/// «الخطوات»: the remaining maneuvers.
struct NavStepsSheet: View {
    @ObservedObject var nav: NavSession
    var close: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let steps = nav.active?.steps ?? []
        let from = nav.progress?.stepIndex ?? 1
        NavigationStack {
            List {
                if let leg = nav.offRoad, nav.phase != .offRoad {
                    Label { Text(NavOffRoad.summary(leg)).saryText(.callout, weight: .bold) } icon: {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(Color(rgb: 0xC98A12))
                    }
                }
                ForEach(Array(steps.enumerated()).filter { $0.offset >= from }, id: \.offset) { i, s in
                    HStack(spacing: theme.space(.m)) {
                        NavManeuverGlyph(maneuver: s.maneuver, size: 40, tint: i == from ? Color(rgb: 0x2B7BF0) : p.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NavText.instruction(s, targetName: nav.target?.name)).saryText(.callout, weight: .bold).foregroundStyle(p.textPrimary)
                            let d = i == from ? (nav.progress?.distanceToManeuverM ?? 0) : steps[i - 1].distanceM
                            Text(NavText.distance(d)).saryNumber(.footnote).foregroundStyle(p.textSecondary)
                        }
                    }
                    .accessibilityIdentifier("nav.step")
                }
            }
            .listStyle(.plain)
            .navigationTitle("الخطوات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إغلاق", action: close).accessibilityIdentifier("nav.steps.close") }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("nav.steps")
    }
}

/// After «ابدأ الطلعة» (the leader only): guidance for everyone (highlighted) or only for me.
struct NavStartChoiceSheet: View {
    var target: String
    var forAll: () -> Void
    var onlyMe: () -> Void
    var later: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.space(.m)) {
            HStack(spacing: theme.space(.m)) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(rgb: 0x2B7BF0))
                    Image(systemName: "location.north.line.fill").font(.system(size: 24, weight: .heavy)).foregroundStyle(Color.white)
                }
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("التوجيه إلى \(target)").saryText(.title2, weight: .heavy).foregroundStyle(p.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("صوت وخطوات حتى توصلون").saryText(.footnote).foregroundStyle(p.textSecondary)
                }
            }
            Button(action: forAll) {
                SaryButtonLabel(title: "ابدأ التوجيه للكل", systemImage: "person.3.fill")
            }
            .buttonStyle(.saryPrimary)
            .accessibilityIdentifier("nav.choice.all")
            Text("يبدأ على جوال كل عضو تلقائيًا، ويقدر كل واحد يوقفه عنده بدون ما يأثر على الباقين.")
                .saryText(.footnote).foregroundStyle(p.textSecondary).fixedSize(horizontal: false, vertical: true)
            Button(action: onlyMe) {
                SaryButtonLabel(title: "لي فقط", systemImage: "person.fill")
            }
            .buttonStyle(.sary(.secondary))
            .accessibilityIdentifier("nav.choice.me")
            Button(action: later) {
                Text("لاحقًا").saryText(.callout, weight: .bold).foregroundStyle(p.textSecondary).frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(.top, theme.space(.xs))
            .accessibilityIdentifier("nav.choice.later")
        }
        .padding(theme.space(.l))
        .presentationDetents([.height(400)])
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nav.choice")
    }
}

/// The trip runs without guidance on this phone: one tap starts it, for this phone only.
struct GuidancePromptRow: View {
    var prompt: LiveOutingController.GuidancePrompt
    var leaderName: String
    var start: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        switch prompt {
        case .leaderStarted:
            Button(action: start) {
                HStack(spacing: theme.space(.s)) {
                    Image(systemName: "location.north.line.fill").font(.system(size: 16, weight: .heavy)).foregroundStyle(Color.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color(rgb: 0x2B7BF0)))
                    Text("\(leaderName) بدأ التوجيه").saryText(.callout, weight: .bold).foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    Text("ابدأ").saryText(.callout, weight: .heavy).foregroundStyle(theme.palette.onAccent)
                        .padding(.horizontal, theme.space(.m)).padding(.vertical, 6)
                        .background(Capsule().fill(theme.palette.accent))
                }
                .padding(theme.space(.s))
                .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .panel)
            }
            .buttonStyle(SaryPressStyle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("\(leaderName) بدأ التوجيه · ابدأ"))
            .accessibilityIdentifier("nav.auto.leaderBanner")
        case .resume, .start:
            Button(action: start) {
                SaryButtonLabel(title: prompt == .resume ? "استأنف التوجيه" : "ابدأ التوجيه", systemImage: "location.north.line.fill")
            }
            .buttonStyle(.sary(.secondary, width: .hug, compact: true))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(prompt == .resume ? "nav.auto.resume" : "nav.auto.start")
        }
    }
}
