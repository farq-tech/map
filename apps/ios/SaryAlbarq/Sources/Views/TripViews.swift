import SwiftUI

// «الرحلة» on the live screen: the strip in the sheet's peek row (minimal, larger in
// drive mode) and the full card at the top of «المشاركون» (stats, arrival, the end).

/// Start → destination, filled from the start side (right in RTL).
struct TripProgressBar: View {
    var fraction: Double
    var height: CGFloat = 6
    var done = false
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(p.sunken)
                Capsule().fill(done ? p.live : p.accent).frame(width: max(height, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .environment(\.layoutDirection, .rightToLeft)
        .accessibilityHidden(true)
    }
}

/// The peek row: «قطعنا ٦٢٪ · باقي ١٢ كم · نوصل ٤:٣٠ م» over the bar. Tapping expands the sheet.
struct TripPeekStrip: View {
    var ui: TripPanelUI
    var expand: () -> Void
    /// While navigating the guidance bar already says what is left: only the progress here.
    var minimal = false
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        Button(action: expand) {
            VStack(alignment: .leading, spacing: theme.drive ? 6 : 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: theme.drive ? 17 : 13, weight: .bold)).foregroundStyle(tint)
                    if theme.drive && !minimal, ui.phase == .underway {
                        /* Drive mode: the two numbers that matter, big. */
                        Text(ui.remainingLine ?? stale ?? "…").saryNumber(.title2, weight: .heavy).foregroundStyle(p.textPrimary)
                        if let e = ui.etaLine { Text("·").foregroundStyle(p.textTertiary); Text(e).saryNumber(.title2, weight: .heavy).foregroundStyle(p.liveText) }
                    } else {
                        Text(line).saryNumber(.callout, weight: .bold).foregroundStyle(p.textPrimary)
                    }
                    Spacer(minLength: 0)
                    if let pc = ui.percent, ui.phase == .underway {
                        Text(SaryFormat.percent(pc)).saryNumber(theme.drive ? .headline : .footnote, weight: .heavy).foregroundStyle(p.accentText)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                if showsBar {
                    TripProgressBar(fraction: Double(ui.percent ?? 0) / 100, height: theme.drive ? 8 : 5, done: isArrived)
                }
            }
            .padding(.horizontal, theme.space(.l))
            .frame(maxWidth: .infinity, minHeight: theme.drive ? 52 : 38, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibility))
        .accessibilityHint(Text("اضغط لعرض الرحلة"))
        .accessibilityIdentifier("trip.peek")
    }

    private var isArrived: Bool { if case .arrived = ui.phase { return true }; return false }
    private var showsBar: Bool { ui.phase == .underway || isArrived }
    private var stale: String? { ui.myFixStaleSince.map { SaryFormat.lastUpdate(since: $0, now: Date()) } }

    private var icon: String {
        switch ui.phase {
        case .needsDestination: return "flag.slash"
        case .arrived: return "flag.checkered"
        case .ended: return "checkmark.seal.fill"
        default: return "flag.checkered"
        }
    }

    private var tint: Color {
        switch ui.phase {
        case .needsDestination: return theme.palette.warningText
        case .arrived, .ended: return theme.palette.liveText
        default: return theme.palette.accentText
        }
    }

    private var line: String {
        switch ui.phase {
        case let .needsDestination(canSet): return canSet ? "حدّد الوجهة قبل ما تبدأ" : "بانتظار الوجهة"
        case .notStarted: return "إلى \(ui.destinationName) · لم تبدأ"
        case .waitingFix: return "بدأت الرحلة · ننتظر موقعك"
        case .arrived: return "وصلت \(ui.destinationName) 🎉"
        case .ended: return "انتهت الرحلة"
        case .underway:
            if minimal { return ui.progressLine ?? "إلى \(ui.destinationName)" }
            if let s = stale { return [ui.progressLine, s].compactMap { $0 }.joined(separator: " · ") }
            return [ui.progressLine, ui.remainingLine, ui.etaLine].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private var accessibility: String {
        "الرحلة: " + line
    }
}

/// The full trip card at the top of «المشاركون».
struct TripCard: View {
    var ui: TripPanelUI
    var actions: TripPanelActions
    @Binding var confirmEnd: Bool
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.space(.m)) {
            header
            switch ui.phase {
            case let .needsDestination(canSet):
                Text(canSet ? "كل طلعة رحلة لها بداية ونهاية. حدّد وين رايحين، وتبدأ الرحلة لما تبدأ الطلعة."
                            : "أمير الرحلة ما حدّد الوجهة بعد. أول ما يحددها تبدأ الرحلة.")
                    .saryText(.subhead).foregroundStyle(p.textSecondary).fixedSize(horizontal: false, vertical: true)
                if canSet {
                    Button(action: actions.setDestination) { SaryButtonLabel(title: "حدّد الوجهة", systemImage: "flag.checkered") }
                        .buttonStyle(.saryPrimary)
                        .accessibilityIdentifier("trip.setDestination")
                }
            case .notStarted:
                Text("تبدأ الرحلة لكل واحد من أول موقع يوصل بعد بداية الطلعة.").saryText(.subhead).foregroundStyle(p.textSecondary)
            case .waitingFix:
                Text("بدأت الطلعة. أول موقع مباشر يوصلنا منك يصير نقطة البداية.").saryText(.subhead).foregroundStyle(p.textSecondary)
            case .underway:
                underway
            case .arrived:
                arrived
            case .ended:
                ended
            }
            if ui.canEnd {
                Button { confirmEnd = true } label: { SaryButtonLabel(title: "أنهِ الطلعة", systemImage: "house.fill") }
                    .buttonStyle(.sarySecondary)
                    .accessibilityIdentifier("trip.end")
            }
        }
        .padding(theme.space(.m))
        .sarySurface(radius: SaryRadius.l)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trip.card")
        .confirmationDialog("تنهي الرحلة للجميع؟", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("أنهِ الطلعة للجميع", role: .destructive, action: actions.endTrip)
            Button("ليس الآن", role: .cancel) {}
        } message: {
            Text(ui.everyoneArrived ? "وصل الجميع. تنتهي الطلعة ويتوقف إرسال المواقع، وتقدرون تشوفون ملخص الطلعة."
                                    : "ما وصل الجميع بعد. تنتهي الطلعة للجميع ويتوقف إرسال المواقع.")
        }
    }

    private var header: some View {
        let p = theme.palette
        return HStack(spacing: theme.space(.m)) {
            SaryRowIcon(systemImage: headerIcon, color: headerColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).saryText(.headline, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(2)
                if let s = subtitle { Text(s).saryNumber(.footnote).foregroundStyle(p.textSecondary).lineLimit(2) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if ui.phase == .underway, let pc = ui.percent {
                Text(SaryFormat.percent(pc)).saryNumber(theme.drive ? .display : .title, weight: .heavy).foregroundStyle(p.accentText)
                    .accessibilityIdentifier("trip.percent")
            }
        }
    }

    private var headerIcon: String {
        switch ui.phase {
        case .needsDestination: return "flag.slash"
        case .ended: return "checkmark.seal.fill"
        default: return "flag.checkered"
        }
    }

    private var headerColor: Color {
        switch ui.phase {
        case .needsDestination: return theme.palette.warning
        case .arrived, .ended: return theme.palette.live
        default: return theme.palette.accent
        }
    }

    private var title: String {
        switch ui.phase {
        case .needsDestination: return "ما فيه وجهة"
        case .arrived: return "وصلت 🎉"
        case .ended: return "انتهت الرحلة"
        default: return ui.isReturnTrip ? "طريق الرجعة إلى \(ui.destinationName)" : "الرحلة إلى \(ui.destinationName)"
        }
    }

    private var subtitle: String? {
        switch ui.phase {
        case .underway:
            if let s = ui.myFixStaleSince { return SaryFormat.lastUpdate(since: s, now: Date()) + " · ما نحسب الباقي من موقع قديم" }
            return ui.progressLine
        case let .arrived(at, manual): return "\(ui.destinationName) · \(NavText.clock(at))" + (manual ? " · «وصلنا»" : "")
        case .ended: return ui.destinationName
        default: return nil
        }
    }

    // MARK: underway

    @ViewBuilder
    private var underway: some View {
        TripProgressBar(fraction: Double(ui.percent ?? 0) / 100, height: theme.drive ? 10 : 8)
        if theme.drive {
            /* Drive mode: large and minimal. */
            HStack(spacing: theme.space(.s)) {
                stat("باقي", ui.myFixStaleSince == nil ? ui.remainingMeters.map { SaryFormat.distance(meters: $0) } ?? "—" : "—", note: ui.remainingApprox ? "تقريبي" : nil, big: true)
                stat("نوصل", ui.eta.map { NavText.clock($0) } ?? "—", note: ui.etaEstimated ? "تقديري" : nil, big: true)
            }
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: theme.space(.s)), GridItem(.flexible(), spacing: theme.space(.s)), GridItem(.flexible(), spacing: theme.space(.s))],
                      spacing: theme.space(.s)) {
                stat("قطعنا", ui.drivenMeters >= 50 ? SaryFormat.distance(meters: ui.drivenMeters) : "—", id: "trip.driven")
                stat("باقي", ui.myFixStaleSince == nil ? ui.remainingMeters.map { SaryFormat.distance(meters: $0) } ?? "—" : "—",
                     note: ui.myFixStaleSince != nil ? "آخر موقع قديم" : (ui.remainingApprox ? "تقريبي" : sourceNote), id: "trip.remaining")
                stat("نوصل", ui.myFixStaleSince == nil ? ui.eta.map { NavText.clock($0) } ?? "—" : "—", note: ui.etaEstimated ? "تقديري" : "الملاحة", id: "trip.eta")
                stat("المدة", ui.elapsedSeconds.map { SaryFormat.duration(seconds: $0) } ?? "—", id: "trip.elapsed")
                stat("حركة", ui.movingSeconds.map { SaryFormat.duration(seconds: $0) } ?? "—", note: ui.stoppedSeconds.map { "وقوف \(SaryFormat.duration(seconds: $0))" })
                stat("متوسط السرعة", ui.avgMovingKmh.map { SaryFormat.speed(kmh: $0) } ?? "—", note: ui.maxKmh.map { "أعلى \(SaryFormat.speed(kmh: $0))" })
            }
        }
        if let a = ui.arrivalLine {
            Label(a, systemImage: "flag.2.crossed").saryText(.footnote, weight: .bold).foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let g = ui.groupStartMeters, g > 200, !theme.drive {
            Text("نقطة انطلاق المجموعة على بعد \(SaryFormat.distance(meters: g))").saryNumber(.caption).foregroundStyle(theme.palette.textTertiary)
        }
        HStack(spacing: theme.space(.s)) {
            if ui.isReturnTrip {
                Button(action: actions.followOldTrail) { SaryButtonLabel(title: "على مساري", systemImage: SaryIcon.backTrack) }
                    .buttonStyle(.sarySecondary)
                    .accessibilityIdentifier("trip.followTrail")
            }
            Button(action: actions.markArrived) { SaryButtonLabel(title: "وصلنا", systemImage: "flag.checkered") }
                .buttonStyle(.sarySecondary)
                .accessibilityIdentifier("trip.arrived")
        }
    }

    private var sourceNote: String? {
        switch ui.remainingSource {
        case .navigation?: return "على طريق الملاحة"
        case .plannedRoute?: return "على المسار المخطط"
        default: return nil
        }
    }

    // MARK: arrived

    @ViewBuilder
    private var arrived: some View {
        let p = theme.palette
        TripProgressBar(fraction: 1, height: 8, done: true)
        /* Only real numbers (the owner's review: «قطعنا ٠ م» next to «المدة ١٨ د» says nothing). */
        if ui.drivenMeters >= 50 || (ui.elapsedSeconds ?? 0) >= 60 {
            HStack(spacing: theme.space(.s)) {
                if ui.drivenMeters >= 50 { stat("قطعنا", SaryFormat.distance(meters: ui.drivenMeters)) }
                if let e = ui.elapsedSeconds, e >= 60 { stat("المدة", SaryFormat.duration(seconds: e)) }
            }
        }
        if let a = ui.arrivalLine {
            Label(a, systemImage: "flag.2.crossed").saryText(.subhead, weight: .bold).foregroundStyle(p.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("trip.arrivalOrder")
        }
        if ui.canEnd {
            if ui.everyoneArrived {
                Text("وصل الجميع. إذا خلصت الطلعة، أنهِها ليتوقف إرسال المواقع ويظهر الملخص.").saryText(.footnote).foregroundStyle(p.textSecondary)
            }
        } else {
            Text("أمير الرحلة ينهي الرحلة لما يوصل الجميع.").saryText(.footnote).foregroundStyle(p.textSecondary)
        }
    }

    // MARK: ended

    @ViewBuilder
    private var ended: some View {
        Button(action: actions.openSummary) { SaryButtonLabel(title: "ملخص الطلعة", systemImage: "chart.bar.doc.horizontal") }
            .buttonStyle(.saryPrimary)
            .accessibilityIdentifier("trip.summary")
        Button(action: actions.returnTrip) { SaryButtonLabel(title: "طريق الرجعة", systemImage: SaryIcon.backTrack) }
            .buttonStyle(.sarySecondary)
            .accessibilityIdentifier("trip.return")
        Text("«طريق الرجعة» رحلة جديدة من هنا إلى نقطة بدايتك، على مسارك أو بالملاحة. وبدون نت نرجّعك على مسارك من جوالك.").saryText(.footnote).foregroundStyle(theme.palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func stat(_ k: String, _ v: String, note: String? = nil, big: Bool = false, id: String? = nil) -> some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 2) {
            Text(k).saryText(.caption).foregroundStyle(p.textSecondary).lineLimit(1)
            Text(v).saryNumber(big ? .title : .headline, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(1).minimumScaleFactor(0.6)
            if let note { Text(note).saryText(.micro).foregroundStyle(p.textTertiary).lineLimit(1).minimumScaleFactor(0.8) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.space(.s))
        .background(RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous).fill(p.sunken))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id ?? "trip.stat")
    }
}
