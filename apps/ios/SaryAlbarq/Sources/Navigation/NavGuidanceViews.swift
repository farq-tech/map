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
            Image(systemName: NavGlyph.symbol(maneuver))
                .font(.system(size: size * 0.56, weight: .heavy))
                .foregroundStyle(ink)
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
        let glyph: CGFloat = theme.drive ? 64 : 56
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
                /* Lovable: the manoeuvre in an orange tile at the right, the distance big, the instruction under it. */
                HStack(alignment: .center, spacing: theme.space(.m)) {
                    NavManeuverGlyph(maneuver: step.maneuver, size: glyph, tint: p.accent, ink: p.onAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SaryFormat.distance(meters: d))
                            .font(.sary(theme.drive ? 34 : 28, .heavy))
                            .foregroundStyle(p.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .accessibilityIdentifier("nav.distance")
                        Text(NavText.instruction(step, targetName: nav.target?.name))
                            .saryText(theme.drive ? .callout : .subhead)
                            .foregroundStyle(p.textSecondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("nav.instruction")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 13)
                .padding(.top, 13)
                .padding(.bottom, theme.space(.s))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(NavText.banner(step, distanceM: d, targetName: nav.target?.name)))
                if !step.lanes.isEmpty, d < 1500 {
                    NavLanesView(lanes: step.lanes)
                        .padding(.horizontal, theme.space(.m))
                        .padding(.bottom, theme.space(.s))
                }
                if let next = nav.nextStep, step.maneuver.kind != .arrive {
                    /* «ثم …»: ours (not in Lovable), one small line — the next turn is safety information. */
                    nextRow(next)
                }
                NavETARow(nav: nav)
            }
        }
        .navPanel(theme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nav.banner")
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
        .padding(.bottom, theme.space(.s))
        .accessibilityIdentifier("nav.next")
    }
}

/// The header's bottom line (Lovable): «١٨ د · وصول ٧:٤٢ م» on the right, «باقي ١٢٫٤ كم» on the left.
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
                    if let s = nav.remainingSeconds {
                        Text(NavText.remaining(seconds: s)).font(.sary(size, .bold)).foregroundStyle(p.liveText)
                            .accessibilityIdentifier("nav.remainingTime")
                    }
                    if let eta = nav.etaDate {
                        Text("· وصول \(NavText.clock(eta))").font(.sary(size, .regular)).foregroundStyle(p.textSecondary)
                            .accessibilityIdentifier("nav.eta")
                    }
                    Spacer(minLength: theme.space(.s))
                    if let m = nav.remainingMeters {
                        Text("باقي").font(.sary(size, .regular)).foregroundStyle(p.textSecondary)
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
        [nav.target.map { "إلى \($0.name)" }, nav.remainingSeconds.map { NavText.remaining(seconds: $0) },
         nav.etaDate.map { "الوصول \(NavText.clock($0))" }, nav.remainingMeters.map { "باقي \(SaryFormat.distance(meters: $0))" }]
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

/// The bottom bar in the sheet's peek: «الوصول ٤:٣٥ م · ٢٣ د · ١٨ كم» and «إنهاء».
struct NavBottomBar: View {
    @ObservedObject var nav: NavSession
    var end: () -> Void
    /// «الخطوات» (moved here from the map in build 8, with the voice: the map keeps two buttons).
    var steps: (() -> Void)? = nil
    /// «نظرة عامة» (moved here from the map's side in «تخفيف الزحمة» ١: no side column while driving).
    var overview: (() -> Void)? = nil
    var overviewOn = false
    /// The map camera's mode (free / north / heading): VoiceOver value of «نظرة عامة».
    var cameraMode = ""
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        HStack(spacing: theme.space(.m)) {
            if nav.phase == .arrived {
                Text(nav.auto ? "وصلتوا إلى \(nav.target?.name ?? "وجهتكم")" : "وصلت إلى \(nav.target?.name ?? "وجهتك")").saryText(.headline).foregroundStyle(p.textPrimary).lineLimit(1)
            } else {
                /* Arrival time and what is left are in the header now (Lovable); here: where to. */
                VStack(alignment: .leading, spacing: 0) {
                    Text("إلى").saryText(.caption, weight: .bold).foregroundStyle(p.textSecondary)
                    Text(nav.target?.name ?? "").saryText(.headline).foregroundStyle(p.textPrimary).lineLimit(1)
                    if let note = nav.target?.staleNote() {
                        Text(note).saryText(.caption, weight: .bold).foregroundStyle(p.warning).lineLimit(1)
                            .accessibilityIdentifier("nav.target.stale")
                    }
                }
            }
            Spacer(minLength: 0)
            if nav.phase != .arrived {
                barIcon(nav.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: nav.muted ? "الصوت مكتوم" : "الصوت",
                        id: "nav.mute", active: nav.muted) { nav.muted.toggle() }
            }
            if nav.phase != .arrived, let overview {
                barIcon("map.fill", label: overviewOn ? "رجّعني لسيارتي" : "نظرة عامة", id: "nav.overview", active: overviewOn, value: cameraMode, action: overview)
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

    private func barIcon(_ symbol: String, label: String, id: String, active: Bool = false, value: String = "", action: @escaping () -> Void) -> some View {
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
        .accessibilityValue(Text(value))
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
