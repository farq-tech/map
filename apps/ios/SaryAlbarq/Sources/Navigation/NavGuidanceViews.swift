import SwiftUI

/// Panels over the live map while navigating. Drive mode: opaque, bigger, readable in sun.
private extension View {
    func navPanel(_ theme: SaryTheme, stroke: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous)
        return self
            .background { if theme.drive { shape.fill(theme.palette.chromeOpaque) } }
            .saryGlass(shape, role: .panel)
            .overlay { if let stroke { shape.stroke(stroke, lineWidth: 3) } }
    }
}

/// The maneuver glyph in its blue tile. Never mirrored.
struct NavManeuverGlyph: View {
    var maneuver: NavManeuver
    var size: CGFloat
    var tint = Color(rgb: 0x2B7BF0)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(tint)
            Image(systemName: NavGlyph.symbol(maneuver))
                .font(.system(size: size * 0.56, weight: .heavy))
                .foregroundStyle(Color.white)
            if maneuver.kind == .roundabout, let e = maneuver.exit {
                Text(SaryFormat.number(e))
                    .font(.system(size: size * 0.22, weight: .black))
                    .foregroundStyle(tint)
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

/// Top banner: «بعد ٥٠٠ م» big, «انعطف يمينًا إلى طريق الملك فهد», lanes, then «ثم …».
struct NavManeuverBanner: View {
    @ObservedObject var nav: NavSession
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let glyph: CGFloat = theme.drive ? 76 : 60
        VStack(spacing: 0) {
            if nav.rerouting {
                HStack(spacing: theme.space(.m)) {
                    ProgressView().tint(p.textPrimary).frame(width: glyph, height: glyph)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("نعيد حساب الطريق…").saryText(theme.drive ? .title2 : .headline).foregroundStyle(p.textPrimary)
                            .accessibilityIdentifier("nav.rerouting")
                        Text("خرجت عن المسار، لحظات ونعطيك طريقًا جديدًا").saryText(.footnote).foregroundStyle(p.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(theme.space(.m))
            } else if let step = nav.currentStep {
                let d = nav.progress?.distanceToManeuverM ?? step.distanceM
                HStack(alignment: .center, spacing: theme.space(.m)) {
                    NavManeuverGlyph(maneuver: step.maneuver, size: glyph)
                    VStack(alignment: .leading, spacing: 2) {
                        if let inD = NavText.inDistance(d) {
                            Text(inD)
                                .saryNumber(theme.drive ? .display : .title, weight: .heavy)
                                .foregroundStyle(p.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .accessibilityIdentifier("nav.distance")
                        }
                        Text(NavText.instruction(step, targetName: nav.target?.name))
                            .saryText(theme.drive ? .title2 : .headline, weight: .bold)
                            .foregroundStyle(p.textPrimary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("nav.instruction")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(theme.space(.m))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(NavText.banner(step, distanceM: d, targetName: nav.target?.name)))
                if !step.lanes.isEmpty, d < 1500 {
                    NavLanesView(lanes: step.lanes)
                        .padding(.horizontal, theme.space(.m))
                        .padding(.bottom, theme.space(.s))
                }
                if let next = nav.nextStep, step.maneuver.kind != .arrive {
                    nextRow(next)
                }
                if nav.auto, let eta = nav.etaDate {
                    etaRow(eta)
                }
            }
        }
        .navPanel(theme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nav.banner")
    }

    /// The trip's guidance: where to and when, in the one header («إلى روضة الثمامة · الوصول ٤:٣٥ م · ١٨ كم»).
    private func etaRow(_ eta: Date) -> some View {
        let p = theme.palette
        let parts = [nav.target.map { "إلى \($0.name)" }, "الوصول \(NavText.clock(eta))", nav.remainingMeters.map { SaryFormat.distance(meters: $0) }]
        return HStack(spacing: theme.space(.s)) {
            Image(systemName: nav.target?.source == .tripStop ? "mappin.circle.fill" : "flag.checkered")
                .font(.system(size: 13, weight: .bold)).foregroundStyle(p.liveText)
            Text(parts.compactMap { $0 }.joined(separator: " · "))
                .saryNumber(theme.drive ? .callout : .footnote, weight: .bold)
                .foregroundStyle(p.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.space(.m))
        .padding(.bottom, theme.space(.s))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nav.banner.eta")
    }

    private func nextRow(_ next: NavStep) -> some View {
        let p = theme.palette
        return HStack(spacing: theme.space(.s)) {
            Text("ثم").saryText(.footnote, weight: .bold).foregroundStyle(p.textSecondary)
            NavManeuverGlyph(maneuver: next.maneuver, size: theme.drive ? 30 : 24, tint: p.textSecondary)
            Text(NavText.instruction(next, targetName: nav.target?.name))
                .saryText(.footnote, weight: .medium)
                .foregroundStyle(p.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.space(.m))
        .padding(.vertical, theme.space(.s))
        .background(p.sunken.opacity(theme.drive ? 1 : 0.6))
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: SaryRadius.l, bottomTrailingRadius: SaryRadius.l, style: .continuous))
        .accessibilityIdentifier("nav.next")
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
    @Environment(\.sary) private var theme

    var body: some View {
        let s: CGFloat = theme.drive ? 62 : 52
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
        let arrow: CGFloat = theme.drive ? 88 : 66
        HStack(spacing: theme.space(.m)) {
            ZStack {
                Circle().fill(Color(rgb: 0xF5B83D))
                Image(systemName: "arrow.up")
                    .font(.system(size: arrow * 0.5, weight: .black))
                    .foregroundStyle(Color(rgb: 0x16110B))
                    .rotationEffect(.degrees(NavOffRoad.arrowDegrees(bearing: bearing, reference: reference)))
                    .animation(theme.animation(.smooth), value: bearing)
            }
            .frame(width: arrow, height: arrow)
            .overlay(Circle().stroke(Color.white, lineWidth: 3))
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(NavOffRoad.title(direct: nav.direct, fallback: nav.fallback))
                    .saryText(theme.drive ? .title2 : .headline, weight: .bold)
                    .foregroundStyle(p.textPrimary)
                    .accessibilityIdentifier("nav.offroad.title")
                Text(SaryFormat.distance(meters: dist))
                    .saryNumber(theme.drive ? .display : .title, weight: .heavy)
                    .foregroundStyle(p.textPrimary)
                    .accessibilityIdentifier("nav.offroad.distance")
                Text(NavOffRoad.note(fallback: nav.fallback, bearing: bearing))
                    .saryText(theme.drive ? .callout : .footnote, weight: .medium)
                    .foregroundStyle(p.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("nav.offroad.note")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(theme.space(.m))
        .navPanel(theme, stroke: Color(rgb: 0xF5B83D))
        .accessibilityElement(children: .combine)
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

/// The bottom bar in the sheet's peek: «الوصول ٤:٣٥ م · ٢٣ د · ١٨ كم» and «إنهاء».
struct NavBottomBar: View {
    @ObservedObject var nav: NavSession
    var end: () -> Void
    /// «الخطوات» (moved here from the map in build 8, with the voice: the map keeps two buttons).
    var steps: (() -> Void)? = nil
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        HStack(spacing: theme.space(.m)) {
            if nav.phase == .arrived {
                Text(nav.auto ? "وصلتوا إلى \(nav.target?.name ?? "وجهتكم")" : "وصلت إلى \(nav.target?.name ?? "وجهتك")").saryText(.headline).foregroundStyle(p.textPrimary).lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if let eta = nav.etaDate, nav.phase == .guiding {
                        Text("الوصول \(NavText.clock(eta))")
                            .saryNumber(theme.drive ? .title2 : .headline, weight: .heavy)
                            .foregroundStyle(p.liveText)
                            .accessibilityIdentifier("nav.eta")
                    } else {
                        Text(nav.target?.name ?? "").saryText(.headline).foregroundStyle(p.textPrimary).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        if let s = nav.remainingSeconds, nav.phase == .guiding {
                            Text(NavText.remaining(seconds: s)).accessibilityIdentifier("nav.remainingTime")
                            Text("·")
                        }
                        if let m = nav.remainingMeters {
                            Text(SaryFormat.distance(meters: m)).accessibilityIdentifier("nav.remainingDistance")
                        }
                    }
                    .saryNumber(theme.drive ? .callout : .footnote, weight: .bold)
                    .foregroundStyle(p.textSecondary)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if nav.phase != .arrived {
                barIcon(nav.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: nav.muted ? "الصوت مكتوم" : "الصوت",
                        id: "nav.mute", active: nav.muted) { nav.muted.toggle() }
            }
            if nav.phase == .guiding, let steps {
                barIcon("list.bullet", label: "الخطوات", id: "nav.stepsButton", action: steps)
            }
            /* Arrived: «إنهاء» is on the arrival card; one is enough. */
            if nav.phase != .arrived {
                Button(action: end) {
                    /* The trip's guidance pauses on this phone only («استأنف» brings it back). */
                    Text(nav.auto ? "أوقف التوجيه" : "إنهاء").saryText(theme.drive ? .body : .callout, weight: .bold)
                }
                .buttonStyle(.sary(.destructive, width: .hug, compact: !theme.drive))
                .accessibilityIdentifier(nav.auto ? "nav.auto.pause" : "nav.end")
            }
        }
        .padding(.horizontal, theme.space(.l))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nav.bottomBar")
    }

    private func barIcon(_ symbol: String, label: String, id: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        let p = theme.palette
        let d: CGFloat = theme.drive ? 52 : 44
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: theme.drive ? 20 : 17, weight: .semibold))
                .foregroundStyle(active ? p.onAccent : p.textPrimary)
                .frame(width: d, height: d)
                .background(Circle().fill(active ? p.accent : p.sunken))
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier(id)
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
