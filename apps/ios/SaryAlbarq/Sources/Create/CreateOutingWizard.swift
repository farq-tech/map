import Combine
import SwiftUI
import UIKit

/// «طلعة جديدة» in three steps: ١ وين رايحين؟ → ٢ الجو هناك (يناسبنا الجو؟) → ٣ ادعُ ربعك.
/// The outing is created on the server only when the weather is approved; the
/// destination is saved with it (on this phone first if the server cannot take it yet).
struct CreateOutingWizard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var location: LocationSharer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sary) private var theme
    @State private var flow = CreateFlowState()
    @StateObject private var weather = WizardWeather()
    /// After creation: the destination reached the server, or stays on this phone for now.
    @State private var destinationLocalOnly = false
    var initialText = ""
    /// «ابدأ» on a place picked on the home map: no steps ١–٢, just «مين معك؟» (leaving now),
    /// then the same invite as step ٣ — or «لحالي» straight into the trip.
    var quick: OutingDestination? = nil
    /// «لحالي، ابدأ»: once the outing exists, open it and start (no invite step).
    @State private var solo = false

    private var title: String {
        if quick != nil, flow.step != .invite { return "مين معك؟" }
        return flow.step.title
    }

    var body: some View {
        SaryPage(title: title, back: flow.canGoBack && quick == nil ? { withAnimation(theme.animation(.smooth)) { flow.back() } } : nil,
                 close: { finish(start: false) }) {
            if quick == nil { progress }
            switch flow.step {
            case .destination:
                if quick != nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    DestinationStep(near: weather.origin.map { LngLat(lng: $0.lng, lat: $0.lat) }, initialText: initialText,
                                    choose: { d in withAnimation(theme.animation(.smooth)) { _ = flow.choose(d) } })
                }
            case .weather:
                if quick != nil {
                    CompanionsStep(flow: flow, weather: weather, online: model.online || model.isDemo,
                                   withFriends: { solo = false; approve() }, alone: { solo = true; approve() })
                } else {
                    WeatherStep(flow: $flow, weather: weather, online: model.online || model.isDemo, approve: approve)
                }
            case .invite:
                InviteStep(flow: flow, weather: weather, link: flow.outingId.flatMap(model.inviteURL), localOnly: destinationLocalOnly,
                           start: { finish(start: true) }, later: { finish(start: false) })
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(flow.creating)
        .onAppear {
            weather.myFix = location.lastFix.map { Geo.LatLng(lat: $0.lat, lng: $0.lng) }
            weather.locator.request()
            if let q = quick, flow.step == .destination {
                _ = flow.choose(q)
                flow.departure = Date()
                weather.setDestination(flow.destination)
            }
        }
        .onChange(of: flow.destination) { _, d in weather.setDestination(d) }
    }

    private var progress: some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: theme.space(.xs)) {
            HStack {
                Text("الخطوة \(flow.progressText)").saryNumber(.caption, weight: .bold).foregroundStyle(p.accentText)
                    .accessibilityIdentifier("create.progress")
                Spacer()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.sunken)
                    Capsule().fill(p.accent).frame(width: g.size.width * flow.progress)
                }
            }
            .frame(height: 6)
            .environment(\.layoutDirection, .rightToLeft)
            .accessibilityHidden(true)
        }
    }

    private func approve() {
        guard flow.approve(now: Date()) else { return }
        let name = flow.trimmedName
        let dest = flow.destination
        Task {
            guard let id = await model.createOuting(name: name, openNow: false) else {
                flow.createFailed(model.errorText ?? "تعذّر إنشاء الطلعة.")
                model.errorText = nil
                return
            }
            if let dest {
                RecentPlaces.add(dest)
                let plan = model.plans.model(id)
                if plan.planPhase == .loading { await plan.loadPlan() }
                _ = await plan.setDestination(dest)
                destinationLocalOnly = plan.destinationLocalOnly
            }
            withAnimation(theme.animation(.smooth)) { flow.created(id) }
            if solo { finish(start: true) }
        }
    }

    private func finish(start: Bool) {
        guard !flow.creating else { return }
        if let id = flow.outingId {
            /* The creator is in the outing: the statement on this step is the consent (share by default). */
            model.consentByJoining(id)
            if start { model.pendingStart = id }
            dismiss()
            if start {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    model.open(id)
                    model.startSharingAfterJoin(id)
                }
            } else {
                Task { await model.refresh() }
            }
        } else {
            dismiss()
        }
    }
}

/// The destination forecast for step 2–3, and where we start from (for the arrival time).
@MainActor
final class WizardWeather: ObservableObject {
    let store = WeatherStore()
    let locator = OneShotLocator()
    @Published var myFix: Geo.LatLng?
    private(set) var destination: OutingDestination?
    private var bag = Set<AnyCancellable>()

    init() {
        locator.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.objectWillChange.send() } }.store(in: &bag)
        store.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.objectWillChange.send() } }.store(in: &bag)
    }

    /// Where the drive starts: my live fix, else the rough one-shot fix.
    var origin: Geo.LatLng? { myFix ?? locator.fix }

    func setDestination(_ d: OutingDestination?) {
        destination = d
        guard let d else { return }
        Task { await store.update(WeatherArea(point: d.lat, lng: d.lng)) }
    }

    func refresh() async {
        guard let d = destination else { return }
        await store.update(WeatherArea(point: d.lat, lng: d.lng), force: true)
    }

    /// Straight line ÷ the cautious off-road default (`ArrivalEstimate`); departure = the chosen time.
    func estimate(departure: Date) -> ArrivalEstimate.Result? {
        guard let d = destination, let from = origin else { return nil }
        return ArrivalEstimate.estimate(from: from, to: Geo.LatLng(lat: d.lat, lng: d.lng), recentKmh: nil, departure: departure)
    }

    /// The forecast line at arrival, for the invite («٢٤° رياح خفيفة»).
    func arrivalLine(departure: Date) -> String? {
        WeatherSummary.atArrival(store.report, eta: estimate(departure: departure)?.eta ?? departure)
    }
}

// MARK: - Step 1: وين رايحين؟

private struct DestinationStep: View {
    var near: LngLat?
    var initialText: String
    var choose: (OutingDestination) -> Void
    var search: (String, LngLat?) async throws -> [PlaceSearch.Place] = { q, near in try await PlaceSearch.search(q, near: near) }
    @Environment(\.sary) private var theme
    @State private var text = ""
    @State private var results: [PlaceSearch.Place] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var job: Task<Void, Never>?
    @State private var mapOpen = false
    @State private var recent = RecentPlaces.load()
    @Environment(AppearanceSettings.self) private var appearance

    var body: some View {
        let p = theme.palette
        let parsed = CoordinateParser.parse(text)
        Text("اختر الوجهة أولًا، ونوريك جوّها وقت وصولكم قبل ما ترسل الدعوة.")
            .saryText(.subhead).foregroundStyle(p.textSecondary).fixedSize(horizontal: false, vertical: true)
        SaryTextField(title: "ابحث أو أدخل إحداثية", placeholder: "اسم مكان أو ٢٤٫٧١٣٦، ٤٦٫٦٧٥٣", text: $text, id: "create.dest.field",
                      help: "يقبل: اسم مكان، عشري، درجات ودقائق وثوانٍ (مثل 24°42'49\"N)، روابط Google أو Apple Maps، و Plus Code.")
            .onChange(of: text) { _, v in schedule(v) }
        if let parsed {
            SarySection(title: "إحداثية") {
                row(icon: "scope", title: CoordinateShare.displayDecimal(parsed.point), detail: CoordinateShare.displayDMS(parsed.point), number: true,
                    id: "create.dest.coordinate") {
                    choose(OutingDestination(name: "نقطة على الخريطة", lat: parsed.point.lat, lng: parsed.point.lng))
                }
            }
            if parsed.outsideRegion {
                SaryBanner(text: "هذه الإحداثية خارج السعودية وما حولها. تأكد من ترتيب خط العرض والطول.", tone: .warning)
            }
            if parsed.swapped {
                SaryBanner(text: "قرأناها «طول، عرض» لأن الرقم الأول لا يصلح خط عرض.", tone: .info, systemImage: "arrow.left.arrow.right")
            }
        } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
            if searching { SaryStateView(kind: .loading("نبحث…")) }
            if let searchError { SaryBanner(text: searchError, tone: .warning) }
            if !results.isEmpty {
                SarySection(title: "أماكن") {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { SaryDivider() }
                        row(icon: r.icon, title: r.name, detail: r.subtitle, trailing: near.map { SaryFormat.distance(meters: PlanGeo.meters($0, r.point)) },
                            id: "create.dest.result") {
                            choose(OutingDestination(name: String(r.name.prefix(TripPlan.destinationNameMax)), lat: r.point.lat, lng: r.point.lng))
                        }
                    }
                }
            } else if !searching && searchError == nil && text.count >= 2 {
                Text("ما وجدنا مكانًا بهذا الاسم. جرّب اسمًا آخر أو أدخل إحداثية.").saryText(.subhead).foregroundStyle(p.textSecondary)
            }
        }
        Button { mapOpen = true } label: { SaryButtonLabel(title: "اختر من الخريطة", systemImage: "map") }
            .buttonStyle(.sary(.secondary))
            .accessibilityIdentifier("create.dest.map")
        if !recent.isEmpty, text.isEmpty {
            SarySection(title: "أماكن سابقة") {
                ForEach(Array(recent.enumerated()), id: \.offset) { i, d in
                    if i > 0 { SaryDivider() }
                    row(icon: "clock.arrow.circlepath", title: d.name, detail: CoordinateShare.displayDecimal(LngLat(lng: d.lng, lat: d.lat)), number: false,
                        trailing: near.map { SaryFormat.distance(meters: PlanGeo.meters($0, LngLat(lng: d.lng, lat: d.lat))) }, id: "create.dest.recent") {
                        choose(d)
                    }
                }
            }
        }
        /* No «بدون وجهة»: every outing is a trip with a start and an end. */
        Label("كل طلعة رحلة لها بداية ونهاية، فالوجهة مطلوبة.", systemImage: "flag.checkered")
            .saryText(.footnote).foregroundStyle(p.textTertiary).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("create.dest.required")
        .onAppear { if text.isEmpty, !initialText.isEmpty { text = initialText } }
        .fullScreenCover(isPresented: $mapOpen) {
            MapPointPicker(start: near, close: { mapOpen = false }) { pt in
                mapOpen = false
                choose(OutingDestination(name: "نقطة على الخريطة", lat: pt.lat, lng: pt.lng))
            }
            .saryAppearance(appearance)
            .rtl()
        }
    }

    private func row(icon: String, title: String, detail: String?, number: Bool = false, trailing: String? = nil, id: String, run: @escaping () -> Void) -> some View {
        let p = theme.palette
        return Button(action: run) {
            HStack(spacing: theme.space(.m)) {
                SaryRowIcon(systemImage: icon)
                VStack(alignment: .leading, spacing: 2) {
                    if number {
                        Text(title).saryNumber(.body, weight: .bold).foregroundStyle(p.textPrimary)
                    } else {
                        Text(title).saryText(.body, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(1)
                    }
                    if let detail { Text(detail).saryNumber(.footnote).foregroundStyle(p.textSecondary).lineLimit(1) }
                }
                Spacer()
                if let trailing { Text(trailing).saryNumber(.footnote).foregroundStyle(p.textTertiary) }
                Image(systemName: SaryIcon.disclosure).foregroundStyle(p.textTertiary)
            }
            .frame(minHeight: theme.minTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func schedule(_ q: String) {
        job?.cancel()
        searchError = nil
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, CoordinateParser.parse(t) == nil else {
            results = []
            searching = false
            return
        }
        searching = true
        job = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            do {
                let r = try await search(t, near)
                guard !Task.isCancelled else { return }
                results = r
            } catch let e as PlaceSearch.SearchError {
                results = []
                searchError = e.arabic
            } catch {
                results = []
                searchError = PlaceSearch.SearchError.network.arabic
            }
            searching = false
        }
    }
}

/// «اختر من الخريطة»: full screen, a fixed pin in the centre and the live coordinate.
struct MapPointPicker: View {
    var start: LngLat?
    var close: () -> Void
    var pick: (LngLat) -> Void
    @Environment(\.sary) private var theme
    @State private var center: LngLat?

    var body: some View {
        let p = theme.palette
        let first = start ?? PlanCamera.initial(route: [], destination: nil, picked: nil)
        ZStack {
            PlanMapView(route: [], camera: PlanCamera(kind: .point(first, zoom: start == nil ? 9 : 11), id: 1), theme: theme,
                        onCenter: { center = $0 })
                .ignoresSafeArea()
            /* The pin's tip sits exactly on the map's centre. */
            Image(systemName: "mappin")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(p.emergency)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                .offset(y: -20)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Circle().fill(p.emergency).frame(width: 6, height: 6).allowsHitTesting(false).accessibilityHidden(true)
            VStack(spacing: theme.space(.s)) {
                HStack {
                    Text("حرّك الخريطة لين يصير الدبوس على الوجهة").saryText(.callout, weight: .bold).foregroundStyle(p.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("إلغاء", action: close)
                        .buttonStyle(.sary(.secondary, width: .hug, compact: true))
                        .accessibilityIdentifier("create.map.cancel")
                }
                .padding(theme.space(.m))
                .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .control)
                Spacer()
                VStack(spacing: theme.space(.s)) {
                    let c = center ?? first
                    Text(CoordinateShare.displayDecimal(c)).saryNumber(.headline, weight: .bold).foregroundStyle(p.textPrimary)
                        .accessibilityIdentifier("create.map.readout")
                    Text(CoordinateShare.displayDMS(c)).saryNumber(.footnote).foregroundStyle(p.textSecondary)
                    Button { pick(center ?? first) } label: { SaryButtonLabel(title: "هنا الوجهة", systemImage: "flag.checkered") }
                        .buttonStyle(.sary(.primary))
                        .accessibilityIdentifier("create.map.confirm")
                }
                .padding(theme.space(.l))
                .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .control)
            }
            .padding(theme.space(.m))
        }
    }
}

// MARK: - Quick start: «مين معك؟»

/// After «ابدأ» on a place: who comes along. Inviting is optional — «لحالي» starts at once.
private struct CompanionsStep: View {
    var flow: CreateFlowState
    @ObservedObject var weather: WizardWeather
    var online: Bool
    var withFriends: () -> Void
    var alone: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        if let d = flow.destination {
            HStack(spacing: theme.space(.m)) {
                SaryRowIcon(systemImage: "flag.checkered", color: p.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.name).saryText(.headline).foregroundStyle(p.textPrimary).lineLimit(2)
                    let est = weather.estimate(departure: Date())
                    Text([est.map { SaryFormat.distance(meters: $0.distanceM) }, weather.arrivalLine(departure: Date()).map { "الجو وقت وصولكم \($0)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .saryNumber(.footnote).foregroundStyle(p.textSecondary).lineLimit(2)
                }
                Spacer()
            }
            .padding(theme.space(.m))
            .sarySurface(radius: SaryRadius.m)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("start.destination")
        }
        Text("تبي أحد معك؟ أرسل لهم الدعوة في واتساب، ويشوفون موقعك وتشوفهم طول الطريق. أو امشِ لحالك.")
            .saryText(.subhead).foregroundStyle(p.textSecondary).fixedSize(horizontal: false, vertical: true)
        if let e = flow.error { SaryInlineMessage(text: e, tone: .error) }
        if !online { SaryOfflineStrip(text: "بلا إنترنت — نبدأ أول ما يرجع الاتصال.") }
        Button(action: withFriends) {
            SaryButtonLabel(title: "ادعُ ربعك", systemImage: "person.2.fill", busy: flow.creating, busyTitle: "نجهّز الطلعة…")
        }
        .buttonStyle(.sary(.primary))
        .disabled(flow.creating || !online)
        .accessibilityIdentifier("start.withFriends")
        Button(action: alone) { SaryButtonLabel(title: "لحالي، ابدأ الآن", systemImage: SaryIcon.play) }
            .buttonStyle(.sary(.secondary))
            .disabled(flow.creating || !online)
            .accessibilityIdentifier("start.solo")
        Label(ShareMemory.joinStatement, systemImage: "location.fill")
            .saryText(.footnote, weight: .medium).foregroundStyle(p.textSecondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Step 2: الجو هناك

private struct WeatherStep: View {
    @Binding var flow: CreateFlowState
    @ObservedObject var weather: WizardWeather
    var online: Bool
    var approve: () -> Void
    @Environment(\.sary) private var theme
    @State private var now = Date()
    @FocusState private var timeFocused: Bool
    @State private var highlightTime = false

    var body: some View {
        let p = theme.palette
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: theme.space(.l)) {
                destinationRow
                SaryTextField(title: "اسم الطلعة · اختياري", placeholder: "اسم مقترح من الوجهة", text: $flow.name, id: "create.name", maxLength: ServerRules.outingNameMax,
                              state: flow.error == CreateFlowState.Issue.nameEmpty.arabic ? .error(CreateFlowState.Issue.nameEmpty.arabic) : .normal,
                              disabled: flow.creating,
                              help: "نقترح اسمًا من وجهتك تلقائيًا؛ تقدر تعدّله.")
                departureRow.id("departure")
                if let d = flow.destination {
                    weatherCards(d)
                }
                Text("يناسبنا الجو؟").saryText(.title2, weight: .bold).foregroundStyle(p.textPrimary).accessibilityAddTraits(.isHeader)
                if let e = flow.error, e != CreateFlowState.Issue.nameEmpty.arabic { SaryInlineMessage(text: e, tone: .error) }
                if !online { SaryOfflineStrip(text: "بلا إنترنت — ننشئ الطلعة أول ما يرجع الاتصال.") }
                Button(action: approve) {
                    SaryButtonLabel(title: "يناسبنا الجو، كمّل", systemImage: "checkmark", busy: flow.creating, busyTitle: "ننشئ الطلعة…")
                }
                .buttonStyle(.sary(.primary))
                .disabled(flow.creating || !online || flow.destination == nil)
                .accessibilityIdentifier("create.approve")
                HStack(spacing: theme.space(.s)) {
                    Button {
                        withAnimation(theme.animation(.smooth)) { proxy.scrollTo("departure", anchor: .center) }
                        highlightTime = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { highlightTime = false }
                    } label: { SaryButtonLabel(title: "غيّر الوقت", systemImage: "clock") }
                        .buttonStyle(.sary(.secondary))
                        .accessibilityIdentifier("create.changeTime")
                    Button { withAnimation(theme.animation(.smooth)) { flow.back() } } label: { SaryButtonLabel(title: "غيّر المكان", systemImage: "mappin.and.ellipse") }
                        .buttonStyle(.sary(.secondary))
                        .accessibilityIdentifier("create.changePlace")
                }
                .disabled(flow.creating)
            }
        }
        .task(id: flow.destination?.lat) { now = Date() }
        .onChange(of: flow.name) { _, _ in if flow.error == CreateFlowState.Issue.nameEmpty.arabic { flow.error = nil } }
    }

    @ViewBuilder
    private var destinationRow: some View {
        let p = theme.palette
        if let d = flow.destination {
            HStack(spacing: theme.space(.m)) {
                SaryRowIcon(systemImage: "flag.checkered", color: p.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.name).saryText(.headline).foregroundStyle(p.textPrimary).lineLimit(1)
                    Text(CoordinateShare.displayDecimal(LngLat(lng: d.lng, lat: d.lat))).saryNumber(.footnote).foregroundStyle(p.textSecondary)
                }
                Spacer()
            }
            .padding(theme.space(.m))
            .sarySurface(radius: SaryRadius.m)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("create.destination")
        }
    }

    private var departureRow: some View {
        let p = theme.palette
        return HStack(spacing: theme.space(.s)) {
            Label("الانطلاق", systemImage: "car.fill").saryText(.subhead, weight: .bold).foregroundStyle(p.textSecondary)
            Spacer()
            DatePicker("", selection: $flow.departure, in: Date().addingTimeInterval(-60)...Date().addingTimeInterval(CreateFlowState.maxAheadS),
                       displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .environment(\.locale, Locale(identifier: "ar@numbers=arab"))
                .accessibilityIdentifier("create.departure")
        }
        .padding(theme.space(.m))
        .sarySurface(radius: SaryRadius.m)
        .overlay {
            RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous).stroke(p.accent, lineWidth: highlightTime ? 2.5 : 0)
        }
        .animation(theme.animation(.smooth), value: highlightTime)
    }

    @ViewBuilder
    private func weatherCards(_ d: OutingDestination) -> some View {
        let p = theme.palette
        let s = weather.store
        let card = WeatherPresenter.card(title: "الجو في \(d.name) الآن", report: s.report, refreshing: s.refreshing, failed: s.lastFailed, now: now, hours: 24)
        WeatherCardView(ui: card)
            .accessibilityIdentifier("create.weather.now")
        arrivalCard(d)
        let alerts = s.report.map { WeatherAlerts.evaluate($0, now: now, wadi: nil, forDestination: true) } ?? []
        ForEach(alerts) { a in
            let severe = a.kind == .flood || a.level >= 2
            HStack(alignment: .top, spacing: theme.space(.m)) {
                WeatherAlertLeading(alert: a)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.title).saryText(.headline).foregroundStyle(severe ? p.emergencyText : p.warningText)
                    Text(a.detail).saryNumber(.footnote).foregroundStyle(p.textPrimary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(theme.space(.m))
            .background(RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous).fill((severe ? p.emergency : p.warning).opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous).stroke(severe ? p.emergency : p.warning, lineWidth: 1))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("create.weather.alert")
        }
        VStack(alignment: .leading, spacing: theme.space(.s)) {
            Label("السيول والأودية", systemImage: "water.waves").saryText(.subhead, weight: .bold).foregroundStyle(p.textPrimary)
            Text("لو بتنزلون قرب وادٍ: السيل قد يأتي من مطر بعيد في أعلى الوادي لا تظهره توقعات الوجهة. لا تخيّموا في بطن الوادي، وتابعوا تحذيرات \(NCM.name). غياب التنبيه هنا لا يعني الأمان.")
                .saryText(.footnote).foregroundStyle(p.textSecondary).fixedSize(horizontal: false, vertical: true)
            Link(destination: NCM.url) {
                Text("التحذيرات الرسمية: \(NCM.name)").saryText(.footnote, weight: .bold).foregroundStyle(p.accentText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.space(.m))
        .sarySurface(radius: SaryRadius.m)
        .accessibilityIdentifier("create.weather.wadi")
    }

    private func arrivalCard(_ d: OutingDestination) -> some View {
        let p = theme.palette
        let est = weather.estimate(departure: flow.departure)
        let report = weather.store.report
        let eta = est?.eta ?? flow.departure
        let hour = report.flatMap { WeatherRules.hour(containing: eta, in: $0) }
        return VStack(alignment: .leading, spacing: theme.space(.s)) {
            Label(est.map { "وقت وصولكم المتوقع \(WeatherFormat.clock($0.eta))" } ?? "وقت الانطلاق \(WeatherFormat.clock(flow.departure))", systemImage: "flag.checkered")
                .saryNumber(.headline, weight: .bold).foregroundStyle(p.textPrimary)
            Text(est.map { "\(SaryFormat.distance(meters: $0.distanceM)) بخط مستقيم · بافتراض \(WeatherFormat.speed($0.speedKmh)) · تقديري" }
                 ?? "ما نعرف موقعك، فنعرض الجو وقت الانطلاق.")
                .saryNumber(.footnote).foregroundStyle(p.textSecondary).fixedSize(horizontal: false, vertical: true)
            if let h = hour {
                HStack(spacing: theme.space(.m)) {
                    Image(systemName: WeatherRules.displayCondition(h).symbol).symbolRenderingMode(.multicolor).font(.system(size: 26))
                    Text(WeatherFormat.temp(h.temperatureC)).saryNumber(.title2, weight: .heavy).foregroundStyle(p.textPrimary)
                    Text(WeatherSummary.line(h, withTemp: false)).saryNumber(.subhead, weight: .medium).foregroundStyle(p.textPrimary).fixedSize(horizontal: false, vertical: true)
                }
            } else if report != nil {
                Text("وقت الوصول بعد نهاية التوقعات المتاحة (٤٨ ساعة). نحدّثها لكم قبلها.").saryText(.subhead).foregroundStyle(p.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(theme.space(.l))
        .frame(maxWidth: .infinity, alignment: .leading)
        .sarySurface(radius: SaryRadius.l)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("create.weather.arrival")
    }
}

// MARK: - Step 3: ادعُ ربعك

private struct InviteStep: View {
    var flow: CreateFlowState
    @ObservedObject var weather: WizardWeather
    var link: URL?
    var localOnly: Bool
    var start: () -> Void
    var later: () -> Void
    @Environment(\.sary) private var theme
    @Environment(\.openURL) private var openURL
    @State private var sharing = false
    @State private var copied = false

    var body: some View {
        let p = theme.palette
        let message = link.map {
            InviteMessage.text(outingName: flow.trimmedName, destination: flow.destination, arrivalWeather: flow.destination == nil ? nil : weather.arrivalLine(departure: flow.departure),
                               departure: flow.departure, link: $0)
        }
        HStack(spacing: theme.space(.s)) {
            Image(systemName: SaryIcon.checkCircle).foregroundStyle(p.liveText)
            Text(link == nil ? "أنشأنا «\(flow.trimmedName)». ادعُ ربعك واحدًا واحدًا." : "أنشأنا «\(flow.trimmedName)». أرسل الدعوة لربعك.").saryText(.callout, weight: .bold).foregroundStyle(p.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("create.created")
        if localOnly, flow.destination != nil {
            SaryBanner(text: LocalDestinationCopy.note + " الوجهة مكتوبة في رسالة الدعوة.", tone: .info, systemImage: "iphone")
                .accessibilityIdentifier("create.destinationLocal")
        }
        if let link, let message {
            VStack(spacing: theme.space(.m)) {
                SaryQRCode(text: link.absoluteString, size: 170)
                    .accessibilityIdentifier("create.qr")
                Text(link.absoluteString).saryText(.caption).foregroundStyle(p.textSecondary).lineLimit(1).truncationMode(.middle)
                    .environment(\.layoutDirection, .leftToRight)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
            .padding(theme.space(.l))
            .sarySurface(radius: SaryRadius.l)
            Button { if let u = InviteMessage.whatsAppURL(message) { openURL(u) } } label: {
                SaryButtonLabel(title: "أرسل في واتساب", systemImage: "message.fill")
            }
            .buttonStyle(.sary(.primary))
            .accessibilityIdentifier("create.whatsapp")
            HStack(spacing: theme.space(.s)) {
                Button { sharing = true } label: { SaryButtonLabel(title: "مشاركة", systemImage: SaryIcon.share) }
                    .buttonStyle(.sary(.secondary))
                    .accessibilityIdentifier("create.share")
                Button {
                    UIPasteboard.general.string = message
                    copied = true
                } label: { SaryButtonLabel(title: copied ? "نُسخت" : "انسخ الرسالة", systemImage: copied ? SaryIcon.check : SaryIcon.copy) }
                    .buttonStyle(.sary(.secondary))
                    .accessibilityIdentifier("create.copy")
            }
            SarySection(title: "نص الدعوة") {
                Text(message).saryText(.footnote).foregroundStyle(p.textPrimary).fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, theme.space(.s))
                    .accessibilityIdentifier("create.message")
            }
            .sheet(isPresented: $sharing) { ShareSheet(items: [message]).presentationDetents([.medium, .large]) }
        } else if let id = flow.outingId {
            /* «دعوة شخصية» (build 12+): no open link — invite each person by name. */
            WizardPersonalInvites(outingId: id, outingName: flow.trimmedName)
        } else {
            SaryBanner(text: "ما عندنا رابط الدعوة على هذا الجوال. افتح الطلعة وأنشئ رابطًا جديدًا من «الدعوة».", tone: .warning)
        }
        /* Said right above the buttons: finishing here is the creator's consent (shares by default). */
        Label(ShareMemory.joinStatement, systemImage: "location.fill")
            .saryText(.footnote, weight: .medium).foregroundStyle(p.textSecondary).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("create.shareStatement")
        Button(action: start) { SaryButtonLabel(title: "ابدأ الطلعة", systemImage: SaryIcon.play) }
            .buttonStyle(.sary(.primary))
            .accessibilityIdentifier("create.start")
        Button("لاحقًا", action: later)
            .buttonStyle(.sary(.plain))
            .accessibilityIdentifier("create.later")
        Text("«ابدأ الطلعة» تفتح الخريطة وتبدأ الطلعة للجميع.")
            .saryText(.footnote).foregroundStyle(p.textTertiary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Step ٣ for a personal-only trip: the same per-person invites as the live trip.
private struct WizardPersonalInvites: View {
    @EnvironmentObject private var model: AppModel
    var outingId: String
    var outingName: String

    var body: some View {
        Inner(model: PersonalInvitesModel(outingId: outingId, outingName: outingName, api: model.isDemo ? nil : model.api,
                                          isDemo: model.isDemo, initial: model.isDemo ? [] : nil, openLinks: false))
    }

    private struct Inner: View {
        @StateObject var model: PersonalInvitesModel
        init(model: @autoclosure @escaping () -> PersonalInvitesModel) { _model = StateObject(wrappedValue: model()) }
        var body: some View { PersonalInvitesSection(model: model, canLead: true) }
    }
}
