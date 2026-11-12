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
    /// Tile colour; nil = the palette's `navBlue`. `.clear` = no tile.
    var tint: Color? = nil
    /// Arrow colour; nil = the palette's `onNavBlue`.
    var ink: Color? = nil
    @Environment(\.sary) private var theme

    var body: some View {
        let tint = self.tint ?? theme.palette.navBlue
        let ink = self.ink ?? theme.palette.onNavBlue
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.43, style: .continuous).fill(tint)
            /* `tint: .clear` (the v2 banner): a plain, bigger arrow with no tile. */
            Image(systemName: NavGlyph.symbol(maneuver))
                .font(.system(size: size * (tint == .clear ? 0.78 : 0.56), weight: .heavy))
                .foregroundStyle(ink)
                /* A new maneuver swaps the arrow with the system's symbol replace (only inside an
                 * animated transaction: the banner's maneuver key; still everywhere else). */
                .contentTransition(.symbolEffect(.replace))
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

    /// The banner's big line (build 37, owner's report item 7: the direction and its distance are
    /// what is read at a glance): the action in words («انعطف يسارًا», «في الدوّار خذ المخرج الثاني»);
    /// at the end, the destination.
    static func headline(_ step: NavStep, targetName: String?) -> String {
        if step.maneuver.kind == .arrive { return title(step, targetName: targetName) }
        return NavText.action(step.maneuver)
    }

    /// The road (or sign) under the headline, smaller; nil when there is none or it would repeat it.
    static func road(_ step: NavStep) -> String? {
        guard step.maneuver.kind != .arrive else { return nil }
        let n = [step.roadName, step.signText].compactMap { $0 }.first { !$0.isEmpty }.map(NavText.arabicDigitsOnly)
        guard let n, n != NavText.action(step.maneuver) else { return nil }
        return n
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

/// Motion on the guidance surfaces (pure, unit-tested in `NavigationTests`). It explains a change
/// (a new maneuver, a new route) and stays calm while driving; nothing loops.
enum NavMotion {
    /// How far (pt) the banner's instruction travels as it swaps: a short nudge, not a full slide.
    static let swapDistance: CGFloat = 36

    /// Identity of the maneuver on the banner: changes with a new step or a new route. Without a
    /// progress yet the banner shows step 1 (`NavSession.currentStep`), so nil counts as 1 and the
    /// first progress on the same step does not swap the instruction again.
    static func stepKey(route: UUID?, stepIndex: Int?) -> String {
        "\(route?.uuidString ?? "-")#\(stepIndex ?? 1)"
    }

    /// Horizontal offset of the instruction swap. The next instruction comes in from the trailing
    /// side (the way reading goes on: the left in Arabic) and the old one leaves toward the
    /// leading side. `insertion`: where the new one starts; otherwise where the old one ends.
    static func swapOffset(insertion: Bool, rtl: Bool) -> CGFloat {
        let trailing: CGFloat = rtl ? -swapDistance : swapDistance
        return insertion ? trailing : -trailing
    }

    /// Reduce Motion: a crossfade, no travel.
    static func swapTravels(reduceMotion: Bool) -> Bool { !reduceMotion }

    /// A rolling text that mostly counts down (time and distance left) and has no single numeric
    /// value to give `SaryTransition.number`: digits roll down; a crossfade under Reduce Motion.
    static func countdownRoll(_ theme: SaryTheme) -> ContentTransition {
        theme.reduceMotion ? .opacity : .numericText(countsDown: true)
    }
}

/// The guidance bar's fit in the sheet's 70 pt peek and at 320 pt (pure, unit-tested in
/// `NavigationTests`). The full row (big numbers, «غيّر الوجهة», «المزيد», «أوقف التوجيه») is
/// tried first and the compact row (an icon-only stop circle) when it does not fit; on a narrow
/// window or at accessibility text sizes the compact row is used outright and «غيّر الوجهة»
/// moves to the pulled-up sheet (`NavTripOptions`).
enum NavBarLayout {
    /// The two big numbers follow Dynamic Type up to here: beyond it they outgrow the peek.
    static let numbersTypeCap: DynamicTypeSize = .xLarge

    /// The icon-only stop circle: the full pill's height.
    static func stopCircle(drive: Bool) -> CGFloat { drive ? 60 : 52 }

    static func forcesCompact(width: SaryWidthClass, typeSize: DynamicTypeSize) -> Bool {
        width == .narrow || typeSize.isAccessibilitySize
    }

    /// «غيّر الوجهة» is a tile in the pulled-up sheet when the bar has no room for it.
    static func changeDestinationInSheet(width: SaryWidthClass, typeSize: DynamicTypeSize) -> Bool {
        forcesCompact(width: width, typeSize: typeSize)
    }

    /// The stale-target note («آخر موقع معروف…») is a third line: only with the sheet raised.
    static func showsStaleNote(peek: Bool) -> Bool { !peek }
}

/// The live screen while guiding, owner-approved redesign («الطلعة وقت القيادة»): a big navBlue
/// maneuver card on top with «ثم …» as a chip under it, a compact «طوارئ» under the card, and ONE
/// bottom bar (time left big, the trip line and the destination, the surfaces or a progress bar,
/// then the friends, the walkie-talkie, «المزيد» and «أوقف التوجيه»). Pure, unit-tested in
/// `NavigationTests`. The previous layout stays reachable in DEBUG with `-SaryDriveV1`.
enum NavDriveLayout {
    /// The redesign is on (DEBUG `-SaryDriveV1`: the previous driving layout).
    static var v2: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-SaryDriveV1") { return false }
        #endif
        return true
    }

    /// What the bar's footer row holds, in reading order (right to left in Arabic).
    enum FooterItem: String, Equatable {
        case friends, talk, more, stop
    }

    /// The footer: «٣ معك» only with friends in the outing (never in a solo outing), the walkie-talkie
    /// only where the outing has one (`LiveScreenRules.GroupUI.walkieTalkie`), «المزيد» always, and
    /// «أوقف التوجيه» until arrival (then the arrival card has its own button).
    static func footer(friends: Bool, friendCount: Int, talk: Bool, arrived: Bool) -> [FooterItem] {
        var items: [FooterItem] = []
        if friends && friendCount > 0 { items.append(.friends) }
        if talk { items.append(.talk) }
        items.append(.more)
        if !arrived { items.append(.stop) }
        return items
    }

    /// The footer's controls: one height for all, never under 44 pt.
    static func footerControl(drive: Bool) -> CGFloat { drive ? 56 : 52 }

    /// «طوارئ» while the maneuver card is up: a compact fixed disc (still ≥ 44 pt); otherwise the
    /// sizes the live screen already used.
    static func sosSize(card: Bool, driving: Bool) -> CGFloat {
        card ? 48 : (driving ? 60 : 52)
    }

    /// The bar's peek: the numbers row, the surfaces strip (or the thin progress bar), the footer.
    static func peekHeight(drive: Bool, surfaces: Bool) -> CGFloat {
        let base: CGFloat = drive ? 164 : 150
        return base + (surfaces ? SheetDetentUI.surfacesExtra(drive: drive) : progressExtra)
    }

    /// The thin progress bar's row on an all-asphalt route.
    static let progressExtra: CGFloat = 12

    /// Share of the trip already driven (0…1), for the thin bar on a route without dirt.
    static func progress(totalM: Double?, remainingM: Double?) -> Double? {
        guard let t = totalM, t > 0, let r = remainingM else { return nil }
        return min(1, max(0, 1 - r / t))
    }

    /// «١٨ كم · وصول ٥:٤٢ م».
    static func tripLine(meters: Double?, eta: Date?) -> String {
        [meters.map { SaryFormat.distance(meters: $0) }, eta.map { "وصول \(NavText.clock($0))" }].compactMap { $0 }.joined(separator: " · ")
    }

    /// The time left split for the big number: («٢٥», «د»), («١ س ٥», «د»); under a minute the
    /// words whole («أقل من دقيقة», no unit).
    static func timeParts(seconds: Double) -> (value: String, unit: String) {
        let s = NavText.remaining(seconds: seconds)
        guard seconds >= 60, let i = s.lastIndex(of: " ") else { return (s, "") }
        return (String(s[..<i]), String(s[s.index(after: i)...]))
    }

    /// «٣ معك»: the friends in the outing with me.
    static func friendsLabel(_ count: Int) -> String { "\(SaryFormat.number(count)) معك" }
}

/// Top banner (v2): a big arrow with the distance under it, the road on one big line beside them,
/// lanes near the turn, and «ثم …» only when the next turn is close. Time and distance left are in the
/// bottom bar now.
struct NavManeuverBanner: View {
    @ObservedObject var nav: NavSession
    /// The per-surface km strip under the maneuver; off where the guidance bar lists the surfaces in order.
    var showsSurfaceStrip = true
    /// The live screen's maneuver card (`NavDriveLayout`): navBlue, the distance big, «ثم …» as a chip
    /// under it. Off (the default): the classic dark banner, as on «اتجه» from the home map.
    var card = false
    @StateObject private var pip = NavPictureInPicture()
    @Environment(\.sary) private var theme
    @Environment(\.layoutDirection) private var layoutDirection

    /// The instruction's swap: a short nudge in from the trailing side, out toward the leading side
    /// (`NavMotion.swapOffset`), with a fade; a plain crossfade with Reduce Motion.
    private var instructionSwap: AnyTransition {
        guard NavMotion.swapTravels(reduceMotion: theme.reduceMotion) else { return .opacity }
        let rtl = layoutDirection == .rightToLeft
        return .asymmetric(insertion: .offset(x: NavMotion.swapOffset(insertion: true, rtl: rtl)).combined(with: .opacity),
                           removal: .offset(x: NavMotion.swapOffset(insertion: false, rtl: rtl)).combined(with: .opacity))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(.s)) {
            if card {
                cardPanel
                cardChips
            } else {
                classicPanel
            }
        }
        /* A reroute gets one soft tap (silent in drive mode by `SaryHaptics.allows`; the voice says it). */
        .saryHaptic(.confirm, trigger: nav.rerouting) { was, now in now && !was }
        .background(alignment: .bottomTrailing) {
            NavPiPLayerHost(displayLayer: pip.displayLayer)
                .frame(width: 160, height: 90)
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
        .alert("تعذر فتح النافذة العائمة", isPresented: Binding(
            get: { pip.startError != nil },
            set: { if !$0 { pip.startError = nil } }
        )) {
            Button("حسنًا", role: .cancel) { pip.startError = nil }
        } message: {
            Text(pip.startError ?? "")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nav.banner")
    }

    /// «نافذة الملاحة العائمة»: a 40 pt circle in a 44 pt touch area.
    private func pipButton(ink: Color, fill: Color) -> some View {
        Button { pip.start() } label: {
            Image(systemName: pip.active ? "pip.exit" : "pip.enter")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(ink)
                .frame(width: 40, height: 40)
                .background(Circle().fill(fill))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(SaryPressStyle())
        .disabled(!pip.supported)
        .accessibilityLabel(Text("نافذة الملاحة العائمة"))
        .accessibilityValue(Text(pip.active ? "مفتوحة" : "مغلقة"))
        .accessibilityIdentifier("nav.pip")
    }

    // MARK: the maneuver card (`NavDriveLayout`)

    /// The navBlue card: the arrow in its tile, the distance big, the instruction bold under it (two
    /// lines at most, never shrunk: UI-AUDIT 0.6; a long road name ends in «…»).
    private var cardPanel: some View {
        let p = theme.palette
        let tile: CGFloat = theme.drive ? 76 : 68
        return Group {
            if nav.rerouting {
                HStack(spacing: theme.space(.m)) {
                    ProgressView().tint(p.onNavBlue).frame(width: tile, height: tile)
                    Text("نعيد حساب الطريق…").saryText(.title2, weight: .heavy).foregroundStyle(p.onNavBlue)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("nav.rerouting")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(theme.space(.m))
                .transition(.opacity)
            } else if let step = nav.currentStep {
                let d = nav.maneuverDistanceM ?? step.distanceM
                let parts = NavHUD.distanceParts(d)
                let key = NavMotion.stepKey(route: nav.active?.geometryRevision, stepIndex: nav.shownProgress?.stepIndex)
                HStack(alignment: .top, spacing: theme.space(.m)) {
                    NavManeuverGlyph(maneuver: step.maneuver, size: tile * 0.78, tint: .clear, ink: p.onNavBlue)
                        .frame(width: tile, height: tile)
                        .background(RoundedRectangle(cornerRadius: tile * 0.3, style: .continuous).fill(p.onNavBlue.opacity(0.16)))
                    ZStack(alignment: .leading) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(parts.value).saryNumber(.display, weight: .heavy)
                                    .contentTransition(SaryTransition.number(d, theme))
                                    .animation(theme.animation(.snappy), value: parts.value)
                                Text(parts.unit).saryText(.title2, weight: .bold)
                            }
                            .foregroundStyle(p.onNavBlue)
                            .lineLimit(1)
                            .fixedSize()
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("nav.distance")
                            Text(NavText.instruction(step, targetName: nav.target?.name))
                                .saryText(.title2, weight: .heavy)
                                .foregroundStyle(p.onNavBlue)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Text(NavText.banner(step, distanceM: d, targetName: nav.target?.name)))
                                .accessibilityIdentifier("nav.instruction")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(key)
                        .transition(instructionSwap)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    pipButton(ink: p.onNavBlue, fill: p.onNavBlue.opacity(0.16))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .animation(theme.animation(theme.drive ? .snappy : .smooth), value: key)
                .transition(.opacity)
            }
        }
        /* The two lines and the big number follow Dynamic Type only this far (never shrunk). */
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .animation(theme.animation(.smooth), value: nav.rerouting)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { RoundedRectangle(cornerRadius: 22, style: .continuous).fill(p.navBlue) }
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }

    /// Under the card, each its own small chip: the lanes near the turn and «ثم …» when the next turn
    /// is close; the per-surface km strip when the bar does not list the surfaces.
    @ViewBuilder
    private var cardChips: some View {
        let p = theme.palette
        if !nav.rerouting, let step = nav.currentStep {
            let d = nav.maneuverDistanceM ?? step.distanceM
            let lanes = !step.lanes.isEmpty && d < 1500
            let next = nav.nextStep.flatMap { NavHUD.showsThen(step, next: $0) ? $0 : nil }
            if lanes || next != nil {
                HStack(spacing: theme.space(.s)) {
                    if let next { thenChip(next) }
                    if lanes {
                        NavLanesView(lanes: step.lanes)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .navPanel(theme)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        if showsSurfaceStrip, !nav.rerouting, let km = nav.remainingSurfaces {
            NavSurfaceKmStrip(km: km, labels: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(p.chromeOpaque.opacity(0.92)))
        }
    }

    /// «ثم ↰ يسار»: a small navBlue chip under the card (one line, not shrunk).
    private func thenChip(_ next: NavStep) -> some View {
        let p = theme.palette
        return HStack(spacing: 6) {
            Text("ثم").saryText(.callout, weight: .bold)
            NavManeuverGlyph(maneuver: next.maneuver, size: theme.drive ? 28 : 24, tint: .clear, ink: p.onNavBlue)
            Text(NavHUD.headline(next, targetName: nav.target?.name)).saryText(.callout, weight: .heavy)
                .lineLimit(1)
        }
        .foregroundStyle(p.onNavBlue)
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .background(Capsule().fill(p.navBlue))
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("ثم \(NavText.instruction(next, targetName: nav.target?.name))"))
        .accessibilityIdentifier("nav.next")
    }

    // MARK: the classic banner

    /// The previous banner (`-SaryDriveV1`, and «اتجه» from the home map): a dark panel with the arrow
    /// and the distance, the direction in words and «ثم …» inside it.
    private var classicPanel: some View {
        let p = theme.palette
        let glyph: CGFloat = theme.drive ? 64 : 56
        return VStack(spacing: 0) {
            if nav.rerouting {
                HStack(spacing: theme.space(.m)) {
                    ProgressView().tint(p.textPrimary).frame(width: glyph, height: glyph)
                    Text("نعيد حساب الطريق…").saryText(theme.drive ? .title2 : .headline).foregroundStyle(p.textPrimary)
                        .accessibilityIdentifier("nav.rerouting")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(theme.space(.m))
                .transition(.opacity)
            } else if let step = nav.currentStep {
                let d = nav.maneuverDistanceM ?? step.distanceM
                let parts = NavHUD.distanceParts(d)
                let key = NavMotion.stepKey(route: nav.active?.geometryRevision, stepIndex: nav.shownProgress?.stepIndex)
                HStack(alignment: .center, spacing: theme.space(.m)) {
                    /* The arrow and the distance: the two things read at a glance (bigger in build 37). */
                    VStack(spacing: 0) {
                        NavManeuverGlyph(maneuver: step.maneuver, size: glyph, tint: .clear, ink: p.accentText)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(parts.value).font(.sary(theme.drive ? 38 : 32, .heavy)).foregroundStyle(p.textPrimary)
                                .monospacedDigit()
                                /* Rolls on the progress updates that already change it (about 1 Hz). */
                                .contentTransition(SaryTransition.number(d, theme))
                                .animation(theme.animation(.snappy), value: parts.value)
                            Text(parts.unit).font(.sary(theme.drive ? 18 : 15, .bold)).foregroundStyle(p.textSecondary)
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .fixedSize()
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("nav.distance")
                    }
                    .frame(minWidth: glyph + 8)
                    /* The direction in words, big; the road under it, smaller (one line). A new maneuver
                     * swaps it (`instructionSwap`); the ZStack keeps the old and new one in one place
                     * while they cross. */
                    ZStack(alignment: .leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NavHUD.headline(step, targetName: nav.target?.name))
                            .font(.sary(theme.drive ? 28 : 24, .heavy))
                            .foregroundStyle(p.textPrimary)
                            /* Two lines, barely shrinking: wraps instead of turning unreadable at a glance. */
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                            .fixedSize(horizontal: false, vertical: true)
                        if let road = NavHUD.road(step) {
                            Text(road)
                                .font(.sary(theme.drive ? 20 : 17, .bold))
                                .foregroundStyle(p.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    /* VoiceOver hears the whole instruction («بعد ٣٫٣ كم انعطف يسارًا إلى …»). */
                    .accessibilityLabel(Text(NavText.banner(step, distanceM: d, targetName: nav.target?.name)))
                    .accessibilityIdentifier("nav.instruction")
                    .id(key)
                    .transition(instructionSwap)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                /* One animated transaction per new maneuver: the words swap, the arrow's symbol is
                 * replaced. Quicker while driving. */
                .animation(theme.animation(theme.drive ? .snappy : .smooth), value: key)
                .transition(.opacity)
                if !step.lanes.isEmpty, d < 1500 {
                    NavLanesView(lanes: step.lanes)
                        .padding(.horizontal, theme.space(.m))
                        .padding(.bottom, theme.space(.s))
                }
                if let next = nav.nextStep, NavHUD.showsThen(step, next: next) {
                    nextRow(next)
                }
            }
            /* Asphalt / dirt / off-road km still ahead, in the map's colours (only when dirt or off-road is left). */
            if showsSurfaceStrip, !nav.rerouting, let km = nav.remainingSurfaces {
                NavSurfaceKmStrip(km: km, labels: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(p.sunken.opacity(0.7))
            }
        }
        /* «نعيد حساب الطريق…» and back: a crossfade, so the reroute reads as one change. */
        .animation(theme.animation(.smooth), value: nav.rerouting)
        .navPanel(theme)
        .overlay(alignment: .topLeading) {
            /* 40 pt circle, 44 pt touch area (same circle position as before). */
            pipButton(ink: p.textPrimary, fill: p.sunken.opacity(0.85))
                .padding(6)
        }
    }

    /// «ثم ↰ طريق العليا»: one small strip, only when that turn comes right after.
    private func nextRow(_ next: NavStep) -> some View {
        let p = theme.palette
        return HStack(spacing: theme.space(.s)) {
            Text("ثم").saryText(.callout, weight: .bold).foregroundStyle(p.textSecondary)
            NavManeuverGlyph(maneuver: next.maneuver, size: theme.drive ? 30 : 26, tint: .clear, ink: p.textPrimary)
            /* The following maneuver in a few words (its direction), one line: no second road name. */
            Text(NavHUD.headline(next, targetName: nav.target?.name))
                .saryText(.callout, weight: .bold)
                .foregroundStyle(p.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
              VStack(spacing: 0) {
                Rectangle().fill(p.separator).frame(height: 0.75).padding(.horizontal, 13)
                HStack(spacing: 4) {
                    if let eta = nav.etaDate {
                        let clock = NavText.clock(eta)
                        Text("توصل \(clock)").font(.sary(size, .bold)).foregroundStyle(p.liveText)
                            .contentTransition(theme.reduceMotion ? .opacity : .numericText())
                            .animation(theme.animation(.snappy), value: clock)
                            .accessibilityIdentifier("nav.eta")
                    }
                    if let s = nav.remainingSeconds {
                        let left = NavText.remaining(seconds: s)
                        Text("· باقي \(left)").font(.sary(size, .regular)).foregroundStyle(p.textSecondary)
                            .contentTransition(SaryTransition.number(s, theme))
                            .animation(theme.animation(.snappy), value: left)
                            .accessibilityIdentifier("nav.remainingTime")
                    }
                    Spacer(minLength: theme.space(.s))
                    if let m = nav.remainingMeters {
                        let far = SaryFormat.distance(meters: m)
                        Text(far).font(.sary(size, .bold)).foregroundStyle(p.textPrimary)
                            .contentTransition(SaryTransition.number(m, theme))
                            .animation(theme.animation(.snappy), value: far)
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
                /* Asphalt / dirt / off-road km still ahead (not on a route without dirt or surface data). */
                if let km = nav.remainingSurfaces {
                    NavSurfaceKmStrip(km: km)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 13)
                        .padding(.bottom, 8)
                }
            }
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
                    .foregroundStyle(l.valid ? p.onNavBlue : p.textTertiary)
                    .frame(width: theme.drive ? 38 : 32, height: theme.drive ? 38 : 32)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(l.valid ? p.navBlue : p.sunken))
                    .overlay { if l.preferred { RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(p.onNavBlue, lineWidth: 2) } }
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
            /* Lovable: «٣٠٠ م» big, «مافي طريق مزفلت: كمّل مع السهم», the arrow in the orange tile. */
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
    /// The one-shot arrival moment: up on appear, then settles (never loops).
    @State private var celebrate = false
    /// Bumped once on appear for the success haptic (the card only exists once arrived, so a
    /// trigger on `phase == .arrived` never saw a change).
    @State private var arrivedTap = 0

    var body: some View {
        let p = theme.palette
        HStack(spacing: theme.space(.m)) {
            ZStack {
                Circle().fill(p.live)
                Image(systemName: "flag.checkered").font(.system(size: theme.drive ? 34 : 26, weight: .heavy)).foregroundStyle(Color.white)
            }
            .frame(width: theme.drive ? 76 : 60, height: theme.drive ? 76 : 60)
            .scaleEffect(celebrate ? 1.12 : 1)
            .shadow(color: p.live.opacity(celebrate ? 0.75 : 0), radius: celebrate ? 14 : 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(nav.auto ? "وصلتوا" : "وصلت").saryText(theme.drive ? .title : .title2, weight: .heavy).foregroundStyle(p.textPrimary)
                    .accessibilityIdentifier("nav.arrived.title")
                Text(nav.target?.name ?? "وجهتك").saryText(.callout, weight: .bold).foregroundStyle(p.textSecondary).lineLimit(1)
                if let s = nav.startedAt, let a = nav.arrivedAt {
                    Text("مدة المشوار \(NavText.remaining(seconds: a.timeIntervalSince(s)))").saryText(.footnote).foregroundStyle(p.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            /* Arrival already ended the guidance: this only closes the card (build 36 labelled it
             * «أوقف التوجيه», one word for two different things). */
            Button(action: end) { Text(SaryCopy.arrivedDone).saryText(theme.drive ? .body : .callout, weight: .bold) }
                .buttonStyle(.sary(.primary, width: .hug, compact: !theme.drive))
                .accessibilityIdentifier("nav.arrived.end")
        }
        .padding(theme.space(.m))
        .navPanel(theme, stroke: p.live)
        /* A soft green glow around the card for the same moment. */
        .shadow(color: p.live.opacity(celebrate ? 0.45 : 0), radius: celebrate ? 18 : 0)
        .scaleEffect(celebrate ? 1.02 : 1)
        .onAppear {
            /* «وصلت»: the arrival haptic (silent in drive mode by `SaryHaptics.allows`). */
            arrivedTap += 1
            guard !theme.reduceMotion else { return }
            withAnimation(theme.animation(.celebrate)) { celebrate = true } completion: {
                withAnimation(theme.animation(.smooth)) { celebrate = false }
            }
        }
        .saryHaptic(.arrival, trigger: arrivedTap)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nav.arrived")
    }
}

/// The bottom bar in the sheet's peek (v2): the time left big and coloured, «١٩ كم · ١٢:٥٦ ص» under it,
/// and a clear red «أوقف التوجيه». Drag the sheet up for «المسارات»، «مشاركة الوصول»، «الصوت» (`NavTripOptions`).
/// It fits the 70 pt peek and a 320 pt window (`NavBarLayout`): the numbers are capped at xLarge,
/// the stale note waits for the sheet raised, and a compact row replaces the full one when it
/// does not fit.
struct NavBottomBar: View {
    @ObservedObject var nav: NavSession
    var end: () -> Void
    /// «المزيد» while guiding (UI-AUDIT م3: the actions no longer vanish once the car moves).
    var more: (() -> Void)? = nil
    /// «غيّر الوجهة» without stopping the guidance first.
    var changeDestination: (() -> Void)? = nil
    /// The bar is the sheet's 70 pt peek (the live screen): no room for a third line.
    var peek = false
    /// The route's surfaces in driving order under the numbers (`NavSurfaceAheadStrip`); the live screen's
    /// peek is taller for it (`LiveSheetShape.surfaces`).
    var surfaces = false
    /// The live screen's one bar while guiding (`NavDriveLayout`): the time left big, the trip line and
    /// the destination, the surfaces (or a thin progress bar), then the footer row. Off (the default):
    /// the classic row, as on «اتجه» from the home map. «غيّر الوجهة» is in the raised sheet then.
    var v2 = false
    /// v2 footer: «٣ معك» with the friends' avatars (nil in a solo outing).
    var friends: AnyView? = nil
    /// v2 footer: the walkie-talkie (nil where the outing has none).
    var talk: AnyView? = nil
    @Environment(\.sary) private var theme
    @Environment(\.saryWidthClass) private var widthClass
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if v2 { v2Body } else { classicBody }
    }

    // MARK: v2 (`NavDriveLayout`)

    private var v2Body: some View {
        let arrived = nav.phase == .arrived
        let items = NavDriveLayout.footer(friends: friends != nil, friendCount: friends == nil ? 0 : 1, talk: talk != nil, arrived: arrived)
        return VStack(alignment: .leading, spacing: 8) {
            if arrived {
                HStack(spacing: theme.space(.m)) {
                    Text(nav.auto ? "وصلتوا إلى \(nav.target?.name ?? "وجهتكم")" : "وصلت إلى \(nav.target?.name ?? "وجهتك")")
                        .saryText(.headline).foregroundStyle(theme.palette.textPrimary).lineLimit(1)
                    Spacer(minLength: 0)
                }
            } else {
                v2Numbers
                if surfaces, let ahead = nav.surfaceAhead {
                    NavSurfaceAheadStrip(ui: ahead)
                } else if let done = NavDriveLayout.progress(totalM: nav.active?.distanceM, remainingM: nav.remainingMeters) {
                    progressBar(done)
                }
            }
            HStack(spacing: theme.space(.s)) {
                if items.contains(.friends), let friends { friends }
                Spacer(minLength: 0)
                if items.contains(.talk), let talk { talk }
                if items.contains(.more), let more { morePill(more) }
                if items.contains(.stop) { stopButton(compact: true) }
            }
            .dynamicTypeSize(...NavBarLayout.numbersTypeCap)
        }
        .padding(.horizontal, theme.space(.l))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nav.bottomBar")
    }

    /// «١٨ كم · وصول ٥:٤٢ م» and the destination on the right, the time left big on the left.
    private var v2Numbers: some View {
        let p = theme.palette
        let trip = NavDriveLayout.tripLine(meters: nav.remainingMeters, eta: nav.etaDate)
        let time = nav.remainingSeconds.map { NavDriveLayout.timeParts(seconds: $0) }
        return HStack(alignment: .center, spacing: theme.space(.m)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(trip)
                    .saryNumber(.headline, weight: .bold)
                    .foregroundStyle(p.textPrimary)
                    .lineLimit(1)
                    .contentTransition(NavMotion.countdownRoll(theme))
                    .animation(theme.animation(.snappy), value: trip)
                    .accessibilityIdentifier("nav.eta")
                if let name = nav.target?.name, !name.isEmpty {
                    Text(NavText.arabicDigitsOnly(name))
                        .saryText(.subhead, weight: .medium)
                        .foregroundStyle(p.textSecondary)
                        .lineLimit(1)
                }
                if NavBarLayout.showsStaleNote(peek: peek), let note = nav.target?.staleNote() {
                    Text(note).saryText(.caption, weight: .bold).foregroundStyle(p.warningText).lineLimit(1)
                        .accessibilityIdentifier("nav.target.stale")
                }
            }
            Spacer(minLength: theme.space(.s))
            if let time {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(time.value)
                        .saryNumber(.display, weight: .heavy)
                        .contentTransition(SaryTransition.number(nav.remainingSeconds ?? 0, theme))
                        .animation(theme.animation(.snappy), value: time.value)
                    if !time.unit.isEmpty {
                        Text(time.unit).saryText(.title2, weight: .bold)
                    }
                }
                .foregroundStyle(p.liveText)
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("nav.remainingTime")
            }
        }
        .dynamicTypeSize(...NavBarLayout.numbersTypeCap)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier("nav.banner.eta")
    }

    /// The trip so far on an all-asphalt route: a thin bar, the driven part in the live colour.
    private func progressBar(_ done: Double) -> some View {
        let p = theme.palette
        return GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(p.sunken)
                Capsule().fill(p.liveText).frame(width: g.size.width * CGFloat(done))
            }
        }
        .frame(height: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("قطعت \(SaryFormat.number(Int((done * 100).rounded())))٪ من الطريق"))
        .accessibilityIdentifier("nav.progress")
    }

    /// «المزيد»: the existing actions entry, a capsule with its word (UI-AUDIT م3).
    private func morePill(_ action: @escaping () -> Void) -> some View {
        let p = theme.palette
        return Button(action: action) {
            Text("المزيد")
                .saryText(.headline, weight: .heavy)
                .foregroundStyle(p.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(minHeight: NavDriveLayout.footerControl(drive: theme.drive))
                .background(Capsule().fill(p.sunken))
                .contentShape(Capsule())
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityLabel(Text("المزيد"))
        .accessibilityIdentifier("nav.more")
    }

    // MARK: classic

    private var classicBody: some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 6) {
        Group {
            if nav.phase == .arrived {
                HStack(spacing: theme.space(.m)) {
                    Text(nav.auto ? "وصلتوا إلى \(nav.target?.name ?? "وجهتكم")" : "وصلت إلى \(nav.target?.name ?? "وجهتك")").saryText(.headline).foregroundStyle(p.textPrimary).lineLimit(1)
                    Spacer(minLength: 0)
                }
            } else if NavBarLayout.forcesCompact(width: widthClass, typeSize: typeSize) {
                /* 320 pt or accessibility text: the compact row outright; «غيّر الوجهة» is in the raised sheet. */
                row(compact: true, change: false)
            } else {
                /* The full row when its natural width fits, else the compact one (still with «غيّر الوجهة»). */
                ViewThatFits(in: .horizontal) {
                    row(compact: false, change: true)
                    row(compact: true, change: true)
                }
            }
        }
        /* «زفلت ١٢ كم ← ترابي ٢ كم ← بر مفتوح ٤ كم»: only on a route with dirt or off-road in it. */
        if surfaces, nav.phase != .arrived, let ahead = nav.surfaceAhead {
            NavSurfaceAheadStrip(ui: ahead)
        }
        }
        .padding(.horizontal, theme.space(.l))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nav.bottomBar")
    }

    private func row(compact: Bool, change: Bool) -> some View {
        HStack(spacing: theme.space(.m)) {
            numbers
            Spacer(minLength: 0)
            if change, let changeDestination {
                barIcon("arrow.triangle.swap", label: "غيّر الوجهة", id: "nav.changeDestination", action: changeDestination)
            }
            if let more {
                barIcon("ellipsis", label: "المزيد", id: "nav.more", action: more)
            }
            stopButton(compact: compact)
        }
    }

    /// The time left, big, and «١٩ كم · ١٢:٥٦ ص» under it (both roll as they change).
    private var numbers: some View {
        let p = theme.palette
        let left = nav.remainingSeconds.map { NavText.remaining(seconds: $0) }
        let trip = NavHUD.tripLine(meters: nav.remainingMeters, eta: nav.etaDate)
        return VStack(alignment: .leading, spacing: 0) {
            if let left {
                Text(left)
                    .font(.sary(theme.drive ? 34 : 30, .heavy))
                    .foregroundStyle(p.accentText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .dynamicTypeSize(...NavBarLayout.numbersTypeCap)
                    .contentTransition(SaryTransition.number(nav.remainingSeconds ?? 0, theme))
                    .animation(theme.animation(.snappy), value: left)
                    .accessibilityIdentifier("nav.remainingTime")
            }
            Text(trip)
                .font(.sary(theme.drive ? 18 : 16, .medium))
                .foregroundStyle(p.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .dynamicTypeSize(...NavBarLayout.numbersTypeCap)
                .contentTransition(NavMotion.countdownRoll(theme))
                .animation(theme.animation(.snappy), value: trip)
                .accessibilityIdentifier("nav.eta")
            if NavBarLayout.showsStaleNote(peek: peek), let note = nav.target?.staleNote() {
                Text(note).saryText(.caption, weight: .bold).foregroundStyle(p.warningText).lineLimit(1)
                    .accessibilityIdentifier("nav.target.stale")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier("nav.banner.eta")
    }

    /// «أوقف التوجيه»: the red pill, or (compact) a red stop circle with the same name and identifier.
    @ViewBuilder
    private func stopButton(compact: Bool) -> some View {
        let p = theme.palette
        /* The trip's guidance pauses on this phone only («استأنف» brings it back). One verb for
         * both (the word dictionary): «أوقف التوجيه». */
        let id = nav.auto ? "nav.auto.pause" : "nav.end"
        if compact {
            let side = NavBarLayout.stopCircle(drive: theme.drive)
            Button(action: end) {
                Image(systemName: "stop.fill")
                    .font(.system(size: theme.drive ? 22 : 20, weight: .heavy))
                    .foregroundStyle(p.onEmergency)
                    .frame(width: side, height: side)
                    .background(Circle().fill(p.emergency))
                    .contentShape(Circle())
            }
            .buttonStyle(SaryPressStyle())
            .accessibilityLabel(Text("إنهاء الرحلة"))
            .accessibilityIdentifier(id)
        } else {
            Button(action: end) {
                Text("إنهاء الرحلة")
                    .font(.sary(theme.drive ? 20 : 18, .heavy))
                    .foregroundStyle(p.onEmergency)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, theme.drive ? 30 : 26)
                    .frame(minHeight: theme.drive ? 60 : 52)
                    .background(Capsule().fill(p.emergency))
            }
            .buttonStyle(SaryPressStyle())
            .accessibilityIdentifier(id)
        }
    }

    /// A round 48 pt (56 in drive mode) secondary button of the guidance bar.
    private func barIcon(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        let p = theme.palette
        let side: CGFloat = theme.drive ? 56 : 48
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: theme.drive ? 20 : 18, weight: .bold))
                .foregroundStyle(p.textPrimary)
                .frame(width: side, height: side)
                .background(Circle().fill(p.sunken))
                .contentShape(Circle())
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(id)
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
    /// «غيّر الوجهة»: a tile here only when the compact guidance bar has no room for it (`NavBarLayout`).
    var changeDestination: (() -> Void)? = nil
    /// «غيّر الوجهة» is a tile here whatever the width: the v2 guidance bar has no room for it (`NavDriveLayout`).
    var changeInSheet = false
    @Environment(\.sary) private var theme
    @Environment(\.saryWidthClass) private var widthClass
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        LazyVGrid(columns: cols, spacing: 10) {
            if let changeDestination, changeInSheet || NavBarLayout.changeDestinationInSheet(width: widthClass, typeSize: typeSize) {
                tile("arrow.triangle.swap", "غيّر الوجهة", id: "nav.changeDestination", action: changeDestination)
            }
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
                    .foregroundStyle(over ? p.onEmergency : p.textPrimary)
                    .contentTransition(SaryTransition.number(Double(kmh ?? 0), theme))
                    /* Rolls on the speed readings that already arrive (no extra updates). */
                    .animation(theme.animation(.snappy), value: kmh)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("كم/س").font(.sary(11, .bold)).foregroundStyle(over ? p.onEmergency.opacity(0.9) : p.textSecondary)
            }
            .frame(width: d, height: d)
            .background(Circle().fill(over ? p.emergency : p.chromeOpaque.opacity(0.92)))
            .overlay(Circle().stroke(over ? p.onEmergency : p.separator, lineWidth: over ? 3 : 1))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(kmh.map { "السرعة \(SaryFormat.number($0)) كم/س" + (over ? "، فوق الحد" : "") } ?? "السرعة غير معروفة"))
            .accessibilityValue(Text(over ? "فوق الحد" : "ضمن الحد"))
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
        let from = nav.shownProgress?.stepIndex ?? 1
        NavigationStack {
            List {
                if let leg = nav.offRoad, nav.phase != .offRoad {
                    Label { Text(NavOffRoad.summary(leg)).saryText(.callout, weight: .bold) } icon: {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(Color(rgb: 0xC98A12))
                    }
                }
                ForEach(Array(steps.enumerated()).filter { $0.offset >= from }, id: \.offset) { i, s in
                    HStack(spacing: theme.space(.m)) {
                        NavManeuverGlyph(maneuver: s.maneuver, size: 40, tint: i == from ? p.navBlue : p.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NavText.instruction(s, targetName: nav.target?.name)).saryText(.callout, weight: .bold).foregroundStyle(p.textPrimary)
                            let d = i == from ? (nav.maneuverDistanceM ?? 0) : steps[i - 1].distanceM
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
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.navBlue)
                    Image(systemName: "location.north.line.fill").font(.system(size: 24, weight: .heavy)).foregroundStyle(p.onNavBlue)
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
                    Image(systemName: "location.north.line.fill").font(.system(size: 16, weight: .heavy)).foregroundStyle(theme.palette.onNavBlue)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(theme.palette.navBlue))
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

extension NavSession {
    /// The km still ahead per surface (`NavSurfaceKm.remaining`), only when dirt / off-road is left on the way.
    var remainingSurfaces: NavSurfaceKm? {
        guard let r = active, !r.surfaceRuns.isEmpty, let p = shownProgress else { return nil }
        let done = max(0, r.distanceM - p.distanceRemainingM)
        let k = NavSurfaceKm.remaining(r.surfaceRuns, from: done, cum: NavRouteMetrics.tables(r).surfaceCum, routeM: p.distanceRemainingM)
        return k.showsSplit ? k : nil
    }

    /// The route's surfaces in driving order and the metres already driven (`NavSurfaceAhead`), only when
    /// the route has dirt or off-road in it (nil when all asphalt or without surface data).
    var surfaceAhead: NavSurfaceAheadUI? {
        guard let r = active, !r.surfaceRuns.isEmpty else { return nil }
        let spans = NavSurfaceAhead.spans(NavSurfaceAhead.pieces(r.surfaceRuns, cum: NavRouteMetrics.tables(r).surfaceCum))
        guard NavSurfaceAhead.shows(spans) else { return nil }
        let done = shownProgress.map { max(0, r.distanceM - $0.distanceRemainingM) } ?? 0
        return NavSurfaceAheadUI(spans: spans, doneM: min(done, spans.last?.endM ?? 0))
    }
}

/// What `NavSurfaceAheadStrip` draws.
struct NavSurfaceAheadUI: Equatable {
    var spans: [NavSurfaceSpan]
    var doneM: Double
    var totalM: Double { spans.last?.endM ?? 0 }
    var remaining: [NavSurfaceSpan] { NavSurfaceAhead.remaining(spans, done: doneM) }
}

/// In the guidance bar (owner's request «كم زفلت وبعدها كم بري»): a thin bar of the route's surfaces in
/// driving order, in the map's colours, the part already driven greyed; under it what is left, in order:
/// «زفلت ١٢ كم ← ترابي ٢ كم ← بر مفتوح ٤ كم». Follows the reading direction (the start on the right).
struct NavSurfaceAheadStrip: View {
    var ui: NavSurfaceAheadUI
    @Environment(\.sary) private var theme

    /// The map's surface colours (`NavMapDrawer.SurfaceStyle`, as `NavSurfaceSwatch`).
    static func color(_ k: NavSurfaceKind) -> Color {
        switch k {
        case .paved: return Color(rgb: SaryPalette.navBlueDay)
        case .unpaved: return Color(rgb: NavMapDrawer.SurfaceStyle.dirtRGB)
        case .terrain: return Color(rgb: NavMapDrawer.SurfaceStyle.terrainRGB)
        case .rough: return Color(rgb: NavMapDrawer.SurfaceStyle.roughRGB)
        case .unknown, .gridSnap: return Color(rgb: NavMapDrawer.SurfaceStyle.unknownRGB)
        }
    }

    var body: some View {
        let p = theme.palette
        let left = ui.remaining
        VStack(alignment: .leading, spacing: 4) {
            bar
            HStack(spacing: 6) {
                ForEach(Array(left.prefix(NavSurfaceAhead.maxListed).enumerated()), id: \.offset) { i, s in
                    if i > 0 {
                        Text("←").saryText(.caption, weight: .bold).foregroundStyle(p.textTertiary)
                    }
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Self.color(s.kind)).frame(width: 8, height: 8)
                        Text(NavSurfaceAhead.label(s.kind)).saryText(.caption, weight: .medium).foregroundStyle(p.textSecondary)
                        Text(SaryFormat.distance(meters: s.meters)).saryNumber(.caption, weight: .bold).foregroundStyle(p.textPrimary)
                    }
                }
                if left.count > NavSurfaceAhead.maxListed {
                    Text("← +").saryText(.caption, weight: .bold).foregroundStyle(p.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .dynamicTypeSize(...NavBarLayout.numbersTypeCap)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(NavSurfaceAhead.accessibility(left)))
        .accessibilityIdentifier("nav.surfaceAhead")
    }

    private var bar: some View {
        let p = theme.palette
        let total = max(1, ui.totalM)
        let gap: CGFloat = 2
        return GeometryReader { g in
            let room = max(0, g.size.width - gap * CGFloat(max(0, ui.spans.count - 1)))
            HStack(spacing: gap) {
                ForEach(Array(ui.spans.enumerated()), id: \.offset) { _, s in
                    let w = room * CGFloat(s.meters / total)
                    let driven = s.meters > 0 ? min(1, max(0, (ui.doneM - s.startM) / s.meters)) : 0
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Self.color(s.kind))
                        Rectangle().fill(p.stale).frame(width: w * CGFloat(driven))
                    }
                    .frame(width: w, height: 5)
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}
