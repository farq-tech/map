import SwiftUI

/// «ابدأ الملاحة»: route options, the routes (alternatives are also on the map
/// with their time / distance), the honest off-road note, and «ابدأ».
struct NavOptionsSheet: View {
    @ObservedObject var nav: NavSession
    var start: () -> Void
    var cancel: () -> Void
    var openExternally: (ExternalNav.App) -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.space(.m)) {
            HStack(spacing: theme.space(.m)) {
                SaryRowIcon(systemImage: icon, color: Color(rgb: 0x2B7BF0))
                VStack(alignment: .leading, spacing: 2) {
                    Text("الملاحة إلى").saryText(.caption, weight: .bold).foregroundStyle(p.textSecondary)
                    Text(nav.target?.name ?? "").saryText(.title2).foregroundStyle(p.textPrimary).lineLimit(2)
                        .accessibilityIdentifier("nav.options.target")
                    if let note = nav.target?.staleNote() {
                        Label(note, systemImage: "clock.badge.exclamationmark").saryText(.footnote, weight: .bold).foregroundStyle(p.warning)
                            .accessibilityIdentifier("nav.options.stale")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: cancel) {
                    Image(systemName: SaryIcon.close).font(.system(size: 15, weight: .bold)).foregroundStyle(p.textSecondary)
                        .frame(width: 36, height: 36).background(Circle().fill(p.sunken))
                }
                .accessibilityLabel(Text("إغلاق"))
                .accessibilityIdentifier("nav.options.close")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: theme.space(.m)) {
                    VStack(spacing: 0) {
                        SaryToggleRow(title: "أسرع", subtitle: nav.options.fastest ? "حسب الزحام الآن" : "الأقصر مسافة", systemImage: "bolt.fill",
                                      isOn: binding(\.fastest), id: "nav.opt.fastest")
                        SaryDivider()
                        SaryToggleRow(title: "تجنّب الطرق الترابية", subtitle: nil, systemImage: "road.lanes",
                                      isOn: binding(\.avoidUnpaved), id: "nav.opt.unpaved")
                        /* No toll roads in Saudi Arabia: the «تجنّب الرسوم» toggle is not shown. */
                    }
                    .padding(.horizontal, theme.space(.m))
                    .sarySurface(radius: SaryRadius.m)

                    content
                }
            }
            .scrollBounceBehavior(.basedOnSize)

            Button(action: start) {
                SaryButtonLabel(title: nav.direct ? "ابدأ باتجاه مباشر" : "ابدأ الملاحة", systemImage: "location.north.line.fill", busy: nav.loading)
            }
            .buttonStyle(.saryPrimary)
            .disabled(nav.loading || (nav.routes.isEmpty && !nav.direct))
            .accessibilityIdentifier("nav.start")
        }
        .padding(theme.space(.l))
        .background(p.elevated.ignoresSafeArea())
        .presentationDetents([.fraction(0.52), .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.52)))
        .accessibilityIdentifier("nav.options")
    }

    private var icon: String {
        switch nav.target?.source {
        case .rally: return SaryIcon.rally
        case .member: return "person.fill"
        case .destination: return "flag.checkered"
        case .planRouteEnd: return "point.topleft.down.to.point.bottomright.curvepath"
        case .tripStop: return "mappin.circle.fill"
        case .lastKnown: return "clock.arrow.circlepath"
        default: return "mappin.and.ellipse"
        }
    }

    private func binding(_ k: WritableKeyPath<NavRouteOptions, Bool>) -> Binding<Bool> {
        Binding(get: { nav.options[keyPath: k] }, set: { v in
            nav.options[keyPath: k] = v
            nav.refetch()
        })
    }

    @ViewBuilder
    private var content: some View {
        let p = theme.palette
        if nav.loading && nav.routes.isEmpty {
            HStack(spacing: theme.space(.s)) {
                ProgressView()
                Text("نحسب الطريق…").saryText(.callout).foregroundStyle(p.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
            .accessibilityIdentifier("nav.loading")
        } else if let e = nav.error {
            SaryInlineMessage(text: e, tone: .error)
            ForEach(ExternalNav.App.allCases) { app in
                Button { openExternally(app) } label: { SaryButtonLabel(title: app.openTitle, systemImage: SaryIcon.directions) }
                    .buttonStyle(.sary(.secondary))
                    .accessibilityIdentifier("nav.open.\(app.rawValue)")
            }
        } else if nav.direct {
            SaryInlineMessage(text: "ما فيه طريق معروف يوصل لهذه النقطة. نعطيك اتجاهًا مباشرًا (خط مستقيم) ومسافته — ليس طريقًا، انتبه للتضاريس.", tone: .warning)
            if let leg = nav.offRoad { offRoadNote(leg, whole: true) }
        } else {
            VStack(spacing: theme.space(.s)) {
                ForEach(Array(nav.routes.enumerated()), id: \.element.id) { i, r in
                    routeRow(r, best: nav.routes[0], index: i)
                }
            }
            if let leg = nav.offRoad { offRoadNote(leg, whole: false) }
            if nav.options.avoidUnpaved, nav.selected?.hasUnpaved == true {
                SaryInlineMessage(text: "ما لقينا طريقًا بدون أجزاء ترابية؛ هذا أقرب ما يكون.", tone: .warning)
            }
        }
    }

    private func routeRow(_ r: NavRoute, best: NavRoute, index: Int) -> some View {
        let p = theme.palette
        let on = r.id == (nav.selectedId ?? nav.routes.first?.id)
        return Button { nav.select(r.id) } label: {
            HStack(spacing: theme.space(.m)) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(on ? Color(rgb: 0x2B7BF0) : p.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(NavText.remaining(seconds: r.durationS)).saryNumber(.headline, weight: .heavy).foregroundStyle(p.textPrimary)
                        Text("·").saryText(.callout).foregroundStyle(p.textTertiary)
                        Text(SaryFormat.distance(meters: r.distanceM)).saryNumber(.callout, weight: .bold).foregroundStyle(p.textSecondary)
                        if index > 0 {
                            Text(NavRouteChoice.delta(r, best: best)).saryNumber(.caption, weight: .bold).foregroundStyle(p.textSecondary)
                        }
                    }
                    HStack(spacing: 6) {
                        if index == 0 { tag(nav.options.fastest ? "الأسرع" : "الأقصر", p.liveText) }
                        if let v = r.via { Text("عبر \(NavText.arabicDigitsOnly(v))").saryText(.footnote).foregroundStyle(p.textSecondary).lineLimit(1) }
                        if r.hasUnpaved { tag("ترابي", p.warningText) }
                        if r.hasTolls { tag("رسوم", p.warningText) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(theme.space(.m))
            .sarySurface(radius: SaryRadius.m, fill: on ? Color(rgb: 0x2B7BF0).opacity(0.12) : p.surface)
            .overlay(RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous).stroke(on ? Color(rgb: 0x2B7BF0) : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(on ? "nav.route.selected" : "nav.route")
    }

    private func tag(_ t: String, _ c: Color) -> some View {
        Text(t).saryText(.micro, weight: .bold).foregroundStyle(c)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.14)))
    }

    private func offRoadNote(_ leg: NavOffRoadLeg, whole: Bool) -> some View {
        let p = theme.palette
        return HStack(alignment: .top, spacing: theme.space(.m)) {
            Image(systemName: "arrow.up")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(Color(rgb: 0x16110B))
                .rotationEffect(.degrees(leg.bearing))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color(rgb: 0xF5B83D)))
                .environment(\.layoutDirection, .leftToRight)
            VStack(alignment: .leading, spacing: 2) {
                Text(whole ? "اتجاه مباشر: \(SaryFormat.distance(meters: leg.distanceM)) باتجاه \(NavText.compassDefinite(leg.bearing))" : NavOffRoad.summary(leg))
                    .saryText(.callout, weight: .bold).foregroundStyle(p.textPrimary)
                    .accessibilityIdentifier("nav.offroad.note")
                Text(whole ? "الخط على الخريطة مستقيم ومتقطع: ليس طريقًا." : "الطريق ينتهي قبل النقطة. الباقي خط مستقيم (متقطع على الخريطة)، ليس طريقًا.")
                    .saryText(.footnote).foregroundStyle(p.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(theme.space(.m))
        .sarySurface(radius: SaryRadius.m, fill: Color(rgb: 0xF5B83D).opacity(0.14))
    }
}

/// Where to? Every target the outing has, members refused when their position is old.
struct NavTargetPicker: View {
    struct Row: Identifiable {
        var id: String
        var title: String
        var subtitle: String?
        var icon: String
        var color: Color?
        var result: Result<NavTarget, NavRefusal>
    }

    var rows: [Row]
    var pick: (NavTarget) -> Void
    var refused: (NavRefusal) -> Void
    var close: () -> Void
    @Environment(\.sary) private var theme
    @State private var message: String?

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.space(.m)) {
            HStack {
                Text("إلى أين؟").saryText(.title2).foregroundStyle(p.textPrimary)
                Spacer()
                Button("إغلاق", action: close).buttonStyle(.sary(.plain, width: .hug, compact: true))
                    .accessibilityIdentifier("nav.picker.close")
            }
            if let message {
                SaryInlineMessage(text: message, tone: .warning).accessibilityIdentifier("nav.picker.refusal")
            }
            ScrollView {
                VStack(spacing: theme.space(.s)) {
                    ForEach(rows) { r in
                        Button {
                            switch r.result {
                            case let .success(t): pick(t)
                            case let .failure(e):
                                message = e.message
                                refused(e)
                            }
                        } label: {
                            HStack(spacing: theme.space(.m)) {
                                SaryRowIcon(systemImage: r.icon, color: r.color)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.title).saryText(.headline).foregroundStyle(p.textPrimary)
                                    if let s = r.subtitle { Text(s).saryText(.footnote).foregroundStyle(p.textSecondary).lineLimit(2) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if case .failure = r.result {
                                    Image(systemName: "clock.badge.exclamationmark").foregroundStyle(p.warningText)
                                } else {
                                    Image(systemName: SaryIcon.back).foregroundStyle(p.textTertiary)
                                }
                            }
                            .padding(theme.space(.m))
                            .sarySurface(radius: SaryRadius.m)
                            .opacity({ if case .failure = r.result { return 0.6 } else { return 1 } }())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("nav.pick.\(r.id)")
                    }
                    SaryInlineMessage(text: "أو اضغط مطولًا على أي نقطة في الخريطة لتبدأ الملاحة إليها.", tone: .info)
                }
            }
        }
        .padding(theme.space(.l))
        .background(p.elevated.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("nav.picker")
    }
}
