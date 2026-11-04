import SwiftUI

/// The official source for warnings. We only link to it (never scrape it).
enum NCM {
    static let url = URL(string: "https://www.ncm.gov.sa/ar")!
    static let name = "المركز الوطني للأرصاد"
}

/// Wind arrow pointing where the wind blows TO, north-up. Rotation is an
/// absolute compass angle, so it is pinned left-to-right: RTL must not mirror it.
struct WindArrow: View {
    var degrees: Double?
    var size: CGFloat = 16
    var tint: Color

    var body: some View {
        Group {
            if let degrees {
                Image(systemName: "location.north.fill")
                    .font(.system(size: size * 0.8, weight: .bold))
                    .foregroundStyle(tint)
                    .rotationEffect(.degrees(degrees))
            } else {
                Image(systemName: "minus").font(.system(size: size * 0.6, weight: .bold)).foregroundStyle(tint.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }
}

/// Compact card for the live sheet and the outing details: now + next hours.
struct WeatherCardView: View {
    var ui: WeatherCardUI
    /// Show the next-hours strip.
    var showHours = true
    var tap: (() -> Void)?
    @Environment(\.sary) private var theme

    var body: some View {
        let content = VStack(alignment: .leading, spacing: theme.space(.m)) {
            header
            switch ui.phase {
            case .loading:
                HStack(spacing: theme.space(.s)) {
                    ProgressView()
                    Text("نجيب الطقس…").saryText(.subhead).foregroundStyle(theme.palette.textSecondary)
                }
            case .unavailable(let m):
                SaryBanner(text: m, tone: ui.offline ? .warning : .info, systemImage: ui.offline ? SaryIcon.offline : "cloud")
            case .ready:
                nowRow
                factsRow
                if showHours, !ui.hours.isEmpty { HoursStrip(hours: ui.hours) }
            }
            footer
        }
        .padding(theme.space(.l))
        .frame(maxWidth: .infinity, alignment: .leading)
        .sarySurface(radius: SaryRadius.l)
        if let tap {
            Button(action: tap) { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("weather.card")
                .accessibilityHint(Text("يفتح تفاصيل الطقس"))
        } else {
            content
        }
    }

    private var header: some View {
        HStack(spacing: theme.space(.s)) {
            Text(ui.title).saryText(.caption, weight: .bold).foregroundStyle(theme.palette.textSecondary).lineLimit(1)
            Spacer(minLength: 4)
            if tap != nil {
                Image(systemName: "chevron.backward").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.palette.textTertiary)
            }
        }
    }

    private var nowRow: some View {
        let p = theme.palette
        return HStack(alignment: .center, spacing: theme.space(.m)) {
            Image(systemName: ui.symbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: theme.drive ? 34 : 30))
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 0) {
                Text(ui.nowLabel).saryText(.caption, weight: .bold).foregroundStyle(ui.stale ? p.warningText : p.textSecondary)
                HStack(alignment: .firstTextBaseline, spacing: theme.space(.s)) {
                    Text(ui.temp).saryNumber(.title, weight: .heavy).foregroundStyle(p.textPrimary)
                    Text(ui.condition).saryText(.callout, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var factsRow: some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: theme.space(.s)) {
            if let w = ui.wind {
                HStack(spacing: theme.space(.s)) {
                    WindArrow(degrees: w.arrowDeg, size: 18, tint: w.level > 0 ? p.warningText : p.accentText)
                    Text([w.name, w.speed, w.gust].compactMap { $0 }.joined(separator: " · "))
                        .saryNumber(.subhead, weight: w.level > 0 ? .bold : .medium)
                        .foregroundStyle(w.level > 0 ? p.warningText : p.textPrimary)
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: theme.space(.s)) {
                Image(systemName: "sun.dust.fill").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle((ui.dust ?? .clear) >= .moderate ? p.warningText : p.textSecondary).frame(width: 18)
                Text(ui.dustText).saryText(.subhead, weight: (ui.dust ?? .clear) >= .moderate ? .bold : .medium)
                    .foregroundStyle((ui.dust ?? .clear) >= .moderate ? p.warningText : p.textPrimary)
                Text("· الرؤية \(ui.visibility)").saryNumber(.subhead).foregroundStyle(p.textSecondary).lineLimit(1)
            }
            HStack(spacing: theme.space(.s)) {
                Image(systemName: "cloud.rain.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(p.textSecondary).frame(width: 18)
                Text(ui.rainText).saryNumber(.subhead).foregroundStyle(p.textPrimary)
            }
        }
    }

    private var footer: some View {
        let p = theme.palette
        return HStack(spacing: theme.space(.xs)) {
            if ui.offline || ui.stale {
                Image(systemName: ui.offline ? SaryIcon.offline : "clock.badge.exclamationmark").font(.system(size: 11, weight: .bold))
            }
            Text(footerText).saryNumber(.caption, weight: ui.stale || ui.offline ? .bold : .regular).lineLimit(2)
        }
        .foregroundStyle(ui.stale || ui.offline ? p.warningText : p.textTertiary)
        .accessibilityIdentifier("weather.updated")
    }

    private var footerText: String {
        var parts: [String] = []
        if ui.offline { parts.append("تعذّر التحديث") }
        if !ui.updated.isEmpty { parts.append(ui.updated) }
        parts.append(OpenMeteo.attribution)
        return parts.joined(separator: " · ")
    }
}

/// Next hours, earliest at the reading start (right in RTL).
struct HoursStrip: View {
    var hours: [WeatherHourUI]
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: theme.space(.s)) {
                ForEach(hours) { h in
                    VStack(spacing: 4) {
                        Text(h.label).saryNumber(.micro, weight: .bold).foregroundStyle(p.textSecondary).lineLimit(1)
                        Image(systemName: h.symbol).symbolRenderingMode(.multicolor).font(.system(size: 18)).frame(height: 22)
                        Text(h.temp).saryNumber(.subhead, weight: .bold).foregroundStyle(p.textPrimary)
                        HStack(spacing: 2) {
                            WindArrow(degrees: h.arrowDeg, size: 11, tint: p.textSecondary)
                            Text(h.wind).saryNumber(.micro).foregroundStyle(p.textSecondary)
                        }
                        Text(h.rainChance ?? " ").saryNumber(.micro, weight: .bold).foregroundStyle(p.accentText)
                    }
                    .frame(minWidth: 52)
                    .padding(.vertical, theme.space(.s))
                    .background(RoundedRectangle(cornerRadius: SaryRadius.s, style: .continuous).fill(p.sunken))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// The weather card's lane variant (inside `SaryAlertCard`).
struct WeatherAlertLeading: View {
    var alert: WeatherAlertUI
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let severe = alert.kind == .flood || alert.level >= 2
        Image(systemName: Self.symbol(alert.kind))
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(severe ? p.emergencyText : p.warningText)
            .frame(width: 36, height: 36)
            .background(Circle().fill((severe ? p.emergency : p.warning).opacity(0.18)))
    }

    static func symbol(_ k: WeatherAlertKind) -> String {
        switch k {
        case .wind: return "wind"
        case .dust: return "sun.dust.fill"
        case .rain: return "cloud.rain.fill"
        case .flood: return "water.waves"
        }
    }
}

// MARK: - Full sheet

/// Everything: the outing area (48 h), the destination with the forecast at
/// arrival, the wadi estimate and its limits, the NCM link, the attribution.
struct WeatherSheet: View {
    @ObservedObject var weather: OutingWeather
    var close: () -> Void
    @Environment(\.sary) private var theme
    @State private var now = Date()
    @State private var pickDeparture = false

    var body: some View {
        let p = theme.palette
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space(.l)) {
                    WeatherCardView(ui: weather.areaCard(now: now, hours: 24))
                    if weather.destinationPoint != nil {
                        WeatherCardView(ui: weather.destinationCard(now: now, hours: 12))
                        if let a = weather.arrival(now: now) { arrivalCard(a) }
                    }
                    if weather.showsWadi { wadiSection }
                    officialSection
                    Text("نرسل لـOpen-Meteo إحداثيات تقريبية لمنطقة الطلعة (مقرّبة لنحو ١١ كم)\(weather.destinationPoint != nil ? "، وإحداثيات الوجهة كما حُددت" : ""). لا نرسل مواقع الأعضاء ولا اسمك أو حسابك.")
                        .saryText(.footnote).foregroundStyle(p.textTertiary).fixedSize(horizontal: false, vertical: true)
                    Link(destination: OpenMeteo.siteURL) {
                        Text("\(OpenMeteo.attribution) (CC BY 4.0) · نماذج توقعات، لا قراءات محطات")
                            .saryText(.footnote, weight: .bold).foregroundStyle(p.accentText)
                    }
                }
                .padding(theme.space(.l))
            }
            .background(p.elevated.ignoresSafeArea())
            .navigationTitle("الطقس")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("تم", action: close).accessibilityIdentifier("weather.close")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await weather.refresh(force: true); now = Date() } } label: {
                        if weather.area.refreshing { ProgressView() } else { Image(systemName: SaryIcon.retry) }
                    }
                    .accessibilityLabel(Text("حدّث"))
                }
            }
        }
        .task {
            await weather.refresh(force: false)
            now = Date()
        }
        .accessibilityIdentifier("weather.sheet")
    }

    private func arrivalCard(_ a: WeatherArrivalUI) -> some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: theme.space(.s)) {
            HStack {
                Label(a.etaText, systemImage: "flag.checkered").saryNumber(.headline, weight: .bold).foregroundStyle(p.textPrimary)
                Spacer()
            }
            Text(a.basis).saryNumber(.footnote).foregroundStyle(p.textSecondary)
            if let h = a.hour {
                HStack(spacing: theme.space(.m)) {
                    Image(systemName: h.symbol).symbolRenderingMode(.multicolor).font(.system(size: 26))
                    Text(h.temp).saryNumber(.title2, weight: .heavy).foregroundStyle(p.textPrimary)
                    Text(a.condition ?? "").saryNumber(.subhead, weight: .medium).foregroundStyle(p.textPrimary).fixedSize(horizontal: false, vertical: true)
                }
            } else if let c = a.condition {
                Text(c).saryText(.subhead).foregroundStyle(p.textSecondary)
            }
            HStack(spacing: theme.space(.s)) {
                Text("الانطلاق").saryText(.subhead, weight: .bold).foregroundStyle(p.textSecondary)
                Spacer()
                if pickDeparture {
                    DatePicker("", selection: Binding(get: { weather.departure ?? Date() }, set: { weather.departure = $0 }),
                               in: Date()...Date().addingTimeInterval(47 * 3600), displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                    Button("الآن") { weather.departure = nil; pickDeparture = false }.saryText(.subhead, weight: .bold)
                } else {
                    Button(weather.departure.map { WeatherFormat.clock($0) } ?? "الآن · غيّر") { pickDeparture = true }
                        .saryText(.subhead, weight: .bold)
                        .accessibilityIdentifier("weather.departure")
                }
            }
        }
        .padding(theme.space(.l))
        .sarySurface(radius: SaryRadius.l)
    }

    private var wadiSection: some View {
        let p = theme.palette
        return SarySection(title: "السيول والأودية") {
            VStack(alignment: .leading, spacing: theme.space(.s)) {
                Label(weather.wadiStatus, systemImage: "water.waves").saryNumber(.subhead, weight: .bold).foregroundStyle(p.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("تقدير، تابع تحذيرات \(NCM.name). نبحث في مجاري الأودية والسيول المرسومة على خريطة Mapbox (من OpenStreetMap) داخل ما حمّلته الخريطة حولكم، ونقيس بُعدها عن أعضاء الطلعة ونقطة التجمع والوجهة والمسار. كثير من الأودية غير مرسوم، والسيل قد يأتي من مطر بعيد في أعلى الوادي لا تظهره توقعات منطقتكم. لا تعتبر غياب التنبيه أمانًا.")
                    .saryText(.footnote).foregroundStyle(p.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, theme.space(.s))
        }
    }

    private var officialSection: some View {
        Link(destination: NCM.url) {
            SaryButtonLabel(title: "التحذيرات الرسمية: \(NCM.name)", systemImage: "exclamationmark.shield.fill")
        }
        .buttonStyle(.sary(.secondary))
        .accessibilityIdentifier("weather.ncm")
    }
}

/// «الطقس هنا»: the forecast for any point the person picked or searched.
struct WeatherPointSheet: View {
    var point: OutingDestination
    var close: () -> Void
    @StateObject private var store = WeatherStore()
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space(.l)) {
                    WeatherCardView(ui: WeatherPresenter.card(title: point.name.isEmpty ? "الطقس هنا" : "الطقس في \(point.name)", report: store.report,
                                                              refreshing: store.refreshing, failed: store.lastFailed, now: Date(), hours: 24))
                    Link(destination: NCM.url) { SaryButtonLabel(title: "التحذيرات الرسمية: \(NCM.name)", systemImage: "exclamationmark.shield.fill") }
                        .buttonStyle(.sary(.secondary))
                    Text("نرسل لـOpen-Meteo إحداثيات هذه النقطة فقط، بلا اسمك أو حسابك أو موقعك.")
                        .saryText(.footnote).foregroundStyle(p.textTertiary)
                }
                .padding(theme.space(.l))
            }
            .background(p.elevated.ignoresSafeArea())
            .navigationTitle("الطقس هنا")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("تم", action: close) } }
        }
        .task { await store.update(WeatherArea(point: point.lat, lng: point.lng)) }
    }
}

/// The live sheet's card: the area now + next hours, and the destination line.
struct LiveWeatherCard: View {
    let controller: LiveOutingController
    @ObservedObject var weather: OutingWeather
    @Environment(\.sary) private var theme

    var body: some View {
        let now = Date()
        VStack(spacing: theme.space(.s)) {
            WeatherCardView(ui: weather.areaCard(now: now, hours: theme.drive ? 4 : 8), showHours: !theme.drive) { controller.modal = .weather }
            if weather.destinationPoint != nil {
                WeatherCardView(ui: weather.destinationCard(now: now, hours: 6), showHours: false) { controller.modal = .weather }
            }
        }
        .task { controller.feedWeather() }
    }
}

/// Outing details: the weather for the outing's area (rally point, else the
/// members' last positions, else my own fix — only its 0.1° cell is sent).
struct DetailsWeatherSection: View {
    let snapshot: OutingSnapshot
    var myFix: DeviceFix?
    @StateObject private var weather: OutingWeather
    @State private var open = false
    @Environment(AppearanceSettings.self) private var appearance

    init(snapshot: OutingSnapshot, myFix: DeviceFix?) {
        self.snapshot = snapshot
        self.myFix = myFix
        _weather = StateObject(wrappedValue: OutingWeather(outingId: snapshot.outing.id, tracksMap: false))
    }

    var body: some View {
        WeatherCardView(ui: weather.areaCard(now: Date())) { open = true }
            .task {
                var pts = snapshot.positions.map { Geo.LatLng(lat: $0.lat, lng: $0.lng) }
                if let r = snapshot.outing.rally { pts = [Geo.LatLng(lat: r.lat, lng: r.lng)] }
                #if DEBUG
                weather.setDestination(WeatherDemo.destination)
                #endif
                weather.setPositions(pts, me: pts.isEmpty ? myFix : nil)
                await weather.refresh(force: false)
            }
            .sheet(isPresented: $open) {
                WeatherSheet(weather: weather, close: { open = false })
                    .saryAppearance(appearance)
            }
    }
}
