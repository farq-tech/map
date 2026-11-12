import SwiftUI

/// «وضع السيارة»: the live screen's chrome for a mirrored phone screen, wide and short. The map fills the
/// screen; ONE big maneuver card on the leading edge, the arrival bar under it, and big round controls
/// (at least 64 pt, text at least 20 pt) on the trailing edge. No bottom sheet: the dock stays presented
/// as a 1 pt invisible presenter (`SarySheetPresentation`) because every sheet and alert of the live
/// screen is presented from it, so nothing is lost; «إنهاء» is always on the screen.
struct CarModeLayer: View {
    @ObservedObject var controller: LiveOutingController
    @ObservedObject var nav: NavSession
    var ui: LiveOutingUIState
    var alerts: [LiveAlertUI]
    @Environment(\.sary) private var theme
    @ObservedObject private var tilt = MapTiltModel.shared

    /// One control of the trailing columns.
    private struct Control: Identifiable {
        var id: String
        var title: String
        var symbol: String
        var active = false
        var danger = false
        var forceLabel = false
        var action: () -> Void = {}
        /// Replaces the generic button (the walkie-talkie and «طوارئ» are components of their own).
        var custom: AnyView? = nil
    }

    var body: some View {
        GeometryReader { geo in
            let preview = CarMode.previewSize()
            let size = preview ?? geo.size
            let safe = preview == nil ? geo.safeAreaInsets : EdgeInsets()
            let items = controls()
            let layout = CarModeLayout.make(size: size, safe: safe, buttons: items.count)
            ZStack {
                Color.clear.allowsHitTesting(false)
                HStack(alignment: .top, spacing: 12) {
                    leadingColumn(layout)
                    Spacer(minLength: 0)
                        .allowsHitTesting(false)
                    controlColumns(items, layout)
                }
                .padding(.leading, safe.leading + 12)
                .padding(.trailing, safe.trailing + 12)
                .padding(.top, safe.top + 8)
                .padding(.bottom, safe.bottom + 8)
            }
            .frame(width: size.width, height: size.height)
            .overlay {
                if preview != nil {
                    Rectangle().stroke(Color.yellow.opacity(0.7), lineWidth: 2).allowsHitTesting(false)
                }
            }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityIdentifier("car.layer")
    }

    // MARK: leading column: the card, the alert, the arrival bar

    private func leadingColumn(_ l: CarModeLayout) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            card(l)
            if !alerts.isEmpty {
                SaryAlertLane(alerts: AlertQueue.ordered(alerts), limit: 1, tapped: controller.actions.alertTapped,
                              dismiss: controller.actions.dismissAlert, voice: controller.actions.voice, silent: controller.actions.silent)
            }
            Spacer(minLength: 0)
                .allowsHitTesting(false)
            if nav.isActive && !controller.tripEnded { arrivalBar(l) }
        }
        .frame(width: l.cardWidth)
    }

    @ViewBuilder
    private func card(_ l: CarModeLayout) -> some View {
        let p = theme.palette
        if controller.tripEnded {
            plainCard(l, title: SaryCopy.outingEnded, tint: p.elevated, ink: p.textPrimary)
        } else if nav.rerouting {
            plainCard(l, title: "نعيد حساب الطريق…", tint: p.navBlue, ink: p.onNavBlue)
                .accessibilityIdentifier("car.rerouting")
        } else if nav.phase == .arrived {
            plainCard(l, title: "وصلنا", tint: p.navBlue, ink: p.onNavBlue)
        } else if nav.phase == .offRoad {
            VStack(alignment: .leading, spacing: 6) {
                Text("ارجع لمسارك").font(.sary(l.instructionFont, .heavy))
                if let d = nav.offRoadNow?.distanceM {
                    Text(SaryFormat.distance(meters: d)).font(.sary(l.distanceFont * 0.6, .heavy))
                }
            }
            .foregroundStyle(p.onNavBlue)
            .cardChrome(tint: p.navBlue)
            .accessibilityIdentifier("car.offroad")
        } else if let step = nav.currentStep {
            let d = nav.maneuverDistanceM ?? step.distanceM
            let parts = NavHUD.distanceParts(d)
            HStack(alignment: .top, spacing: 14) {
                NavManeuverGlyph(maneuver: step.maneuver, size: l.distanceFont * 1.15, tint: .clear, ink: p.onNavBlue)
                    .frame(width: l.distanceFont * 1.15, height: l.distanceFont * 1.15)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(parts.value).font(.sary(l.distanceFont, .heavy))
                        Text(parts.unit).font(.sary(max(CarModeLayout.minFont, l.distanceFont * 0.4), .bold))
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityIdentifier("car.distance")
                    Text(NavText.instruction(step, targetName: nav.target?.name))
                        .font(.sary(l.instructionFont, .heavy))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("car.instruction")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(p.onNavBlue)
            .cardChrome(tint: p.navBlue)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("car.card")
        } else {
            /* No guidance: one big way in to «وين رايحين؟» (the sheet is not on the screen). */
            Button { controller.openNavPicker() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.system(size: l.instructionFont, weight: .bold))
                    Text("وين رايحين؟").font(.sary(l.instructionFont, .heavy))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(p.textPrimary)
                .cardChrome(tint: p.elevated)
            }
            .buttonStyle(SaryPressStyle())
            .accessibilityIdentifier("car.whereTo")
        }
    }

    private func plainCard(_ l: CarModeLayout, title: String, tint: Color, ink: Color) -> some View {
        HStack {
            Text(title).font(.sary(l.instructionFont, .heavy)).foregroundStyle(ink)
            Spacer(minLength: 0)
        }
        .cardChrome(tint: tint)
    }

    private func arrivalBar(_ l: CarModeLayout) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let name = nav.target?.name, !name.isEmpty {
                Text("إلى \(name)").font(.sary(max(CarModeLayout.minFont, l.barFont * 0.9), .medium)).lineLimit(1)
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            HStack(spacing: 8) {
                if let eta = nav.etaDate {
                    Text("توصل \(NavText.clock(eta))").accessibilityIdentifier("car.eta")
                }
                if let s = nav.remainingSeconds {
                    Text("· باقي \(NavText.remaining(seconds: s))").accessibilityIdentifier("car.remaining")
                }
                Spacer(minLength: 0)
                if let m = nav.remainingMeters {
                    Text(SaryFormat.distance(meters: m)).accessibilityIdentifier("car.remainingDistance")
                }
            }
            .font(.sary(l.barFont, .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black.opacity(0.82)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("car.bar")
    }

    // MARK: trailing columns: the controls

    private func controls() -> [Control] {
        var items: [Control] = []
        let guiding = nav.isActive
        let ended = controller.tripEnded
        let mode = CameraTiltRules.mode(heading: controller.mapFollowMode == .heading, idle: controller.idleHome)
        if !ended {
            items.append(Control(id: "car.layers", title: "الطبقات", symbol: "square.3.layers.3d",
                                 action: { controller.modal = .layers }))
            items.append(Control(id: "car.tilt", title: tilt.is3D(mode) ? "٣د" : "٢د", symbol: "view.3d",
                                 active: tilt.is3D(mode), action: { tilt.toggle(mode) }))
            if guiding {
                let overview = nav.camera == .overview
                items.append(Control(id: "car.camera", title: overview ? "تتبعني" : "نظرة عامة",
                                     symbol: overview ? "location.north.line.fill" : "map.fill",
                                     action: { overview ? controller.recenterCamera() : controller.navControlTapped("nav.overview") }))
                items.append(Control(id: "car.mute", title: nav.muted ? "الصوت" : "كتم", symbol: nav.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                     active: nav.muted, action: { nav.muted.toggle() }))
            } else {
                items.append(Control(id: "car.locate", title: "موقعي", symbol: "location.fill",
                                     action: { controller.actions.locateMe() }))
            }
            if controller.groupUI.walkieTalkie {
                items.append(Control(id: "car.ptt", title: "اضغط وتكلم", symbol: "mic.fill", custom: AnyView(
                    SaryPTTButton(state: ui.ptt, actions: controller.actions.ptt, showsCaption: false, level: controller.pttLevel,
                                  openChannels: { controller.modal = .pttChannels })
                        .accessibilityIdentifier("car.ptt"))))
            }
            items.append(Control(id: "car.sos", title: "طوارئ", symbol: "exclamationmark.triangle.fill", custom: AnyView(
                LovableSOS(state: ui.sos.mine, size: 64, trigger: controller.actions.sos.trigger,
                           countdown: controller.groupUI.serverSOS, caption: false)
                    .accessibilityIdentifier("car.sos"))))
            /* «إنهاء» is ALWAYS here: the one control that must never be lost (the dock-vanish bug of Build 46). */
            items.append(Control(id: "car.end", title: guiding ? "إنهاء الرحلة" : "إنهاء الطلعة", symbol: "stop.circle.fill",
                                 danger: true, forceLabel: true, action: { controller.openEndChoice() }))
        } else {
            items.append(Control(id: "car.summary", title: "الملخص", symbol: "doc.text.fill", forceLabel: true,
                                 action: { controller.openSummary() }))
            items.append(Control(id: "car.home", title: "الرئيسية", symbol: "house.fill", forceLabel: true,
                                 action: { controller.onExit() }))
        }
        items.append(Control(id: "car.exit", title: "الوضع العادي", symbol: "iphone", forceLabel: true,
                             action: { CarModeState.shared.set(false) }))
        return items
    }

    private func controlColumns(_ items: [Control], _ l: CarModeLayout) -> some View {
        let perColumn = max(1, Int((Double(items.count) / Double(l.columns)).rounded(.up)))
        let chunks = stride(from: 0, to: items.count, by: perColumn).map { Array(items[$0..<min($0 + perColumn, items.count)]) }
        return HStack(alignment: .top, spacing: l.gap) {
            ForEach(Array(chunks.enumerated()), id: \.offset) { _, column in
                VStack(spacing: l.gap) {
                    ForEach(column) { item in
                        if let custom = item.custom {
                            custom.frame(width: l.button, height: l.button)
                        } else {
                            button(item, l)
                        }
                    }
                }
            }
        }
    }

    private func button(_ c: Control, _ l: CarModeLayout) -> some View {
        let p = theme.palette
        let fill: Color = c.danger ? p.emergency : (c.active ? p.accent : Color.black.opacity(0.82))
        let ink: Color = c.danger ? p.onEmergency : (c.active ? p.onAccent : Color.white)
        let label = l.showsLabels || c.forceLabel
        return Button(action: c.action) {
            VStack(spacing: 2) {
                Image(systemName: c.symbol).font(.system(size: l.button * (label ? 0.34 : 0.42), weight: .bold))
                if label {
                    Text(c.title).font(.sary(l.labelFont * (c.forceLabel && !l.showsLabels ? 0.9 : 1), .bold))
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            .foregroundStyle(ink)
            .frame(width: l.button, height: l.button)
            .background(RoundedRectangle(cornerRadius: l.button * 0.28, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: l.button * 0.28, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityLabel(Text(c.title))
        .accessibilityIdentifier(c.id)
    }
}

private extension View {
    /// The maneuver card's padding and surface.
    func cardChrome(tint: Color) -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(tint))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
    }
}

// MARK: - the offer (a mirrored screen) and the dock's quiet presentation

/// «تبث الشاشة للسيارة؟»: shown once on the live screen while this screen is mirrored and the mode is off.
struct CarModeSuggestHost: View {
    @ObservedObject private var capture = CarModeCapture.shared
    @ObservedObject private var state = CarModeState.shared
    @Environment(\.sary) private var theme

    var body: some View {
        if capture.mirrored && !state.on && !capture.dismissed {
            HStack(spacing: 10) {
                Image(systemName: "car.fill")
                Text("تبث الشاشة للسيارة؟").font(.sary(16, .bold))
                Button("فعّل وضع السيارة") { state.set(true) }
                    .font(.sary(16, .heavy))
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .background(Capsule().fill(theme.palette.accent))
                    .foregroundStyle(theme.palette.onAccent)
                    .accessibilityIdentifier("car.suggest.on")
                Button("لاحقًا") { capture.dismissed = true }
                    .font(.sary(15, .medium)).frame(minHeight: 44)
                    .accessibilityIdentifier("car.suggest.later")
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .foregroundStyle(.white)
            .background(Capsule().fill(Color.black.opacity(0.85)))
            .padding(.top, 6)
            .transition(.opacity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("car.suggest")
        }
    }
}

/// The live dock in car mode: still presented (every sheet and alert of the live screen is presented from it),
/// but 1 pt high, clear and see-through to touches, and edge-attached in landscape.
struct CarModeSheet: ViewModifier {
    func body(content: Content) -> some View {
        content
            .presentationDetents([.height(1)], selection: .constant(PresentationDetent.height(1)))
            .presentationDragIndicator(.hidden)
            .presentationBackgroundInteraction(.enabled)
            .presentationBackground(.clear)
            .interactiveDismissDisabled()
            .background(CarModeSheetConfigurator())
    }
}

/// iPhone landscape (compact height) presents a sheet full screen unless it is edge-attached.
private struct CarModeSheetConfigurator: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ vc: Probe, context: Context) { vc.apply() }

    final class Probe: UIViewController {
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); apply() }
        override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); apply() }
        func apply() {
            var node: UIViewController? = self
            while let n = node {
                if let sheet = n.sheetPresentationController {
                    sheet.prefersEdgeAttachedInCompactHeight = true
                    sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
                    return
                }
                node = n.parent
            }
        }
    }
}
