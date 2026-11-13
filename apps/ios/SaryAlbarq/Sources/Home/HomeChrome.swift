import SwiftUI

// Build 46 «الرئيسية» (docs/ui-build47-prompt.md §١), behind `NewUI.enabled`.
// Three SHARED components — the glass top pill, the map capsule and the bottom card — hosted by the legacy home
// map (`MapHomeScreen`). Built from existing parts only (palette, fonts, `saryGlass`, `SaryControlCluster`, the
// shared `map.layers` / `map.tilt` buttons). Temporary: the foundations PR will swap the local metrics below.

// MARK: - Pure rules (unit-tested)

enum HomeChromeRules {
    /// Below this screen height (iPhone SE is 667) the secondary rows hide.
    static let compactHeight: Double = 700

    static func isCompact(screenHeight: Double) -> Bool { screenHeight < compactHeight }

    /// «٢٤° صافي • ريح شرقية خفيفة»: from the model's current value. Nil when there is no reading (never a made-up one).
    static func weatherLine(_ h: WeatherHour?) -> String? {
        guard let h, h.temperatureC != nil else { return nil }
        var parts: [String] = []
        parts.append(WeatherFormat.temp(h.temperatureC) + " " + conditionWord(h))
        if let from = h.windFromDeg, let kmh = h.windKmh {
            parts.append("ريح \(WeatherRules.windName(from: from)) \(windWord(kmh))")
        }
        return parts.joined(separator: " • ")
    }

    /// «صحو» is said «صافي» on the home card.
    static func conditionWord(_ h: WeatherHour) -> String {
        let t = WeatherRules.displayCondition(h).text
        return (t == "صحو" || t == "صحو غالبًا") ? "صافي" : t
    }

    static func windWord(_ kmh: Double) -> String {
        if kmh < 20 { return "خفيفة" }
        if kmh < 35 { return "معتدلة" }
        return "قوية"
    }

    /// «المغرب ٥:١٢»: today's sunset at my position (computed on the phone, no network). The call to prayer comes a few
    /// minutes after the sun sets, so this is the sunset time under the label the person knows; nil after sunset.
    static func maghribLine(now: Date, lat: Double, lng: Double, timeZone: TimeZone = .current) -> String? {
        let s = PlaceBriefRules.sun(now: now, lat: lat, lng: lng)
        guard s.isDay, let set = s.sunset, set > now else { return nil }
        return "المغرب \(WeatherFormat.clock(set, timeZone: timeZone))"
    }

    /// The «آخر طلعة» row: the latest finished outing, from the history the app already holds.
    static func lastOuting(_ history: [OutingSummary], now: Date = Date()) -> HomeLastOuting? {
        let ended = history.filter { $0.status == .ended }
        let pick = ended.max { (ISODate.parse($0.ended_at) ?? .distantPast) < (ISODate.parse($1.ended_at) ?? .distantPast) } ?? history.first
        guard let o = pick else { return nil }
        var bits: [String] = []
        if let d = ISODate.parse(o.ended_at ?? o.started_at ?? o.created_at) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ar")
            f.dateFormat = "EEEE"
            bits.append(f.string(from: d))
        }
        bits.append(o.participantsLabel)
        return HomeLastOuting(id: o.id, title: o.name, detail: bits.joined(separator: " • "))
    }
}

struct HomeLastOuting: Equatable {
    var id: String
    var title: String
    var detail: String
}

enum HomeTile: String, CaseIterable, Identifiable {
    case camp, routes, weather, qibla
    var id: String { rawValue }
    var title: String {
        switch self {
        case .camp: return "كشتة"
        case .routes: return "دروب البر"
        case .weather: return "الطقس"
        case .qibla: return "القبلة"
        }
    }
    var icon: String {
        switch self {
        case .camp: return "tent.fill"
        case .routes: return "point.topleft.down.to.point.bottomright.curvepath"
        case .weather: return "cloud.sun.fill"
        case .qibla: return "location.north.line.fill"
        }
    }
}

// MARK: - Top pill

/// ONE glass pill (56 tall): search icon + «وين رايحين؟» + mic + the avatar circle with the first letter on Ember.
struct HomeTopPill: View {
    var avatarName: String
    var avatarPhoto: UIImage? = nil
    var listening = false
    var onSearch: () -> Void
    var onMic: () -> Void
    var onProfile: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        HStack(spacing: 4) {
            Button(action: onSearch) {
                HStack(spacing: theme.space(.s)) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(p.textSecondary)
                        .accessibilityHidden(true)
                    Text("وين رايحين؟")
                        .font(.sary(17, .medium))
                        .foregroundStyle(p.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .padding(.leading, theme.space(.m))
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("ابحث عن وجهة"))
            .accessibilityIdentifier("home.pill.search")
            Button(action: onMic) {
                Image(systemName: listening ? "waveform" : "mic.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(listening ? p.onAccent : p.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(listening ? p.accent : Color.clear))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SaryPressStyle())
            .accessibilityLabel(Text(listening ? "أوقف الاستماع" : "ابحث بصوتك"))
            .accessibilityIdentifier("home.pill.mic")
            Button(action: onProfile) {
                SaryAvatar(name: avatarName, color: theme.accent.fill, photo: avatarPhoto, size: 44)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(SaryPressStyle())
            .accessibilityLabel(Text("ملفي"))
            .accessibilityIdentifier("home.pill.profile")
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 56)
        .saryGlass(Capsule(), role: .chrome)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.pill")
    }
}

// MARK: - Map capsule

/// The small vertical glass capsule on the map: layers (`map.layers`), 2D/3D (`map.tilt`) and locate. The same shared
/// items and identifiers as every map; no Qibla button.
struct HomeMapCapsule: View {
    var locateID = "home.locate"
    var onLayers: () -> Void
    var onLocate: () -> Void
    @ObservedObject private var tilt = MapTiltModel.shared

    var body: some View {
        let on = tilt.is3D(.overview)
        SaryControlCluster(items: [
            .layers(),
            .cameraTilt(is3D: on, settledPitch: tilt.settledPitch),
            SaryMapControlItem(id: "locate", systemImage: SaryIcon.locate, label: "موقعي", accessibilityID: locateID),
        ], axis: .vertical) { id in
            switch id {
            case "layers": onLayers()
            case "tilt": tilt.toggle(.overview)
            default: onLocate()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.capsule")
    }
}

// MARK: - Bottom card

/// ONE bottom card with a grab handle: the weather / Maghrib line, the big primary «＋ ابدأ طلعة», the four tiles and the
/// «آخر طلعة» row. Secondary rows hide first when there is no room (`ViewThatFits`: last outing, then the weather line).
struct HomeBottomCard: View {
    var weather: String?
    var maghrib: String?
    var last: HomeLastOuting?
    var onHandle: () -> Void
    var onStart: () -> Void
    var onTile: (HomeTile) -> Void
    var onLast: () -> Void
    /// What the old home said in its collapsed sheet and must still say here: the running / upcoming outing, an invite, a failed
    /// list, the offline strip (nothing is lost in the redesign). Nil when there is none.
    var extra: AnyView? = nil
    /// The bottom safe area: inside the card (its fill runs to the screen edge).
    var bottomInset: CGFloat = 0
    @Environment(\.sary) private var theme
    @Environment(\.dynamicTypeSize) private var type

    var body: some View {
        let p = theme.palette
        let shape = UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
        VStack(spacing: 0) {
            handle
            ViewThatFits(in: .vertical) {
                content(weatherRow: true, lastRow: true)
                content(weatherRow: true, lastRow: false)
                content(weatherRow: false, lastRow: false)
                ScrollView { content(weatherRow: false, lastRow: false) }.scrollIndicators(.hidden)
            }
        }
        .padding(.bottom, bottomInset)
        .frame(maxWidth: 560)
        .background(shape.fill(p.background).shadow(color: p.shadow, radius: 14, y: -2))
        .overlay(shape.stroke(p.stroke, lineWidth: 0.5))
        .background(GeometryReader { r in Color.clear.preference(key: HomeCardHeightKey.self, value: r.size.height) })
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.card")
    }

    private var handle: some View {
        Button(action: onHandle) {
            Capsule().fill(theme.palette.textTertiary.opacity(0.6)).frame(width: 40, height: 5)
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .gesture(DragGesture(minimumDistance: 14).onEnded { v in if v.translation.height < -20 { onHandle() } })
        .accessibilityLabel(Text("اسحب للأعلى لطلعاتك"))
        .accessibilityIdentifier("home.card.handle")
    }

    @ViewBuilder
    private func content(weatherRow: Bool, lastRow: Bool) -> some View {
        HomeCardContent(weather: weather, maghrib: maghrib, last: last, weatherRow: weatherRow, lastRow: lastRow,
                        onStart: onStart, onTile: onTile, onLast: onLast, extra: extra)
    }
}

/// The card's body, shared by the home map's bottom card and the idle map's sheet (one component, two hosts):
/// the weather / Maghrib line, the big primary «＋ ابدأ طلعة», the four tiles and the «آخر طلعة» row.
struct HomeCardContent: View {
    var weather: String?
    var maghrib: String?
    var last: HomeLastOuting?
    var weatherRow = true
    var lastRow = true
    var onStart: () -> Void
    var onTile: (HomeTile) -> Void
    var onLast: () -> Void
    var extra: AnyView? = nil
    @Environment(\.sary) private var theme
    @Environment(\.dynamicTypeSize) private var type

    var body: some View {
        VStack(spacing: theme.space(.m)) {
            if let extra { extra }
            if weatherRow, weather != nil || maghrib != nil { infoRow }
            startButton
            tiles
            if lastRow, let last { lastButton(last) }
        }
        .padding(.horizontal, theme.space(.l))
        .padding(.bottom, theme.space(.m))
    }

    private var infoRow: some View {
        let p = theme.palette
        return HStack(spacing: theme.space(.s)) {
            if let weather {
                Text(weather).font(.sary(14, .medium)).foregroundStyle(p.textSecondary).lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityIdentifier("home.card.weather")
            }
            Spacer(minLength: 0)
            if let maghrib {
                Text(maghrib).font(.sary(14, .bold)).foregroundStyle(p.textPrimary).lineLimit(1)
                    .accessibilityIdentifier("home.card.maghrib")
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var startButton: some View {
        let p = theme.palette
        return Button(action: onStart) {
            Text("＋ ابدأ طلعة")
                .font(.sary(19, .bold))
                .foregroundStyle(p.onAccent)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 58)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(p.accent))
                .contentShape(Rectangle())
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityIdentifier("home.card.start")
    }

    @ViewBuilder
    private var tiles: some View {
        if type.isAccessibilitySize {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: theme.space(.s)) {
                ForEach(HomeTile.allCases) { t in tileButton(t, wide: true) }
            }
        } else {
            HStack(alignment: .top, spacing: 0) {
                ForEach(HomeTile.allCases) { t in tileButton(t, wide: false).frame(maxWidth: .infinity) }
            }
        }
    }

    private func tileButton(_ t: HomeTile, wide: Bool) -> some View {
        let p = theme.palette
        let face = RoundedRectangle(cornerRadius: 18, style: .continuous).fill(p.elevated)
            .frame(width: 56, height: 56)
            .overlay(Image(systemName: t.icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(p.accentText))
        return Button { onTile(t) } label: {
            Group {
                if wide {
                    HStack(spacing: theme.space(.s)) { face; label(t); Spacer(minLength: 0) }
                } else {
                    VStack(spacing: 6) { face; label(t) }
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityLabel(Text(t.title))
        .accessibilityIdentifier("home.tile.\(t.rawValue)")
    }

    private func label(_ t: HomeTile) -> some View {
        Text(t.title).font(.sary(12, .medium)).foregroundStyle(theme.palette.textPrimary)
            .lineLimit(1).minimumScaleFactor(0.7)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func lastButton(_ l: HomeLastOuting) -> some View {
        let p = theme.palette
        return Button(action: onLast) {
            HStack(spacing: theme.space(.m)) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 16, weight: .semibold)).foregroundStyle(p.accentText)
                    .frame(width: 40, height: 40).background(Circle().fill(p.accent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("آخر طلعة • \(l.title)").font(.sary(15, .bold)).foregroundStyle(p.textPrimary).lineLimit(1).minimumScaleFactor(0.8)
                    Text(l.detail).font(.sary(12, .regular)).foregroundStyle(p.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.textTertiary)
            }
            .padding(.horizontal, theme.space(.m))
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(p.elevated))
            .contentShape(Rectangle())
        }
        .buttonStyle(SaryPressStyle())
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityIdentifier("home.card.last")
    }
}

/// Reports the card's height so the host can lift the map's attribution above it.
struct HomeCardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// «٢٤٫٥٠٠٠٠، ٤٥٫٠٠٠٠٠ • الارتفاع ٦٠٠ م» under a picked spot's name: the elevation comes from the map's DEM tiles once they
/// have loaded (a few tries), else «الارتفاع غير متاح». Nothing is made up.
struct HomeElevationLine: View {
    var point: LngLat
    var showCoordinates: Bool
    @State private var elevation: String = "الارتفاع …"
    @Environment(\.sary) private var theme

    var body: some View {
        let coords = showCoordinates ? CoordinateShare.displayDecimal(point) + " • " : ""
        Text(coords + elevation)
            .saryNumber(.footnote)
            .foregroundStyle(theme.palette.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityIdentifier("home.place.elevation")
            .task(id: "\(point.lat),\(point.lng)") {
                elevation = "الارتفاع …"
                for _ in 0..<10 {
                    let t = MapTerrainProbe.sample(point)
                    if t.elevationM != nil { elevation = PlaceBriefRules.elevationText(t); return }
                    try? await Task.sleep(nanoseconds: 700_000_000)
                }
                elevation = PlaceBriefRules.elevationText(.unavailable)
            }
    }
}
