import SwiftUI

/// The first screen: a map, the category chips floating over it, and ONE bottom sheet —
/// «وين رايحين؟» (mic + profile), the shortcuts (البيت · الشغل · المفضلة) and what is
/// happening now. Pulled up: every category, recent places and «طلعاتي».
/// The flow (after Hudhud's, not its look): search → pick → «ابدأ» → «مين معك؟» → the trip.
struct MapHomeScreen: View {
    var push: (HomeRoute) -> Void
    /// In-trip «وين رايحين؟» uses the same map, search, results and home sheet; picking
    /// a place sends it to the current outing instead of opening the new-outing flow.
    var destinationPicker: ((OutingDestination) -> Void)? = nil
    var autoFocusSearch = false
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var location: LocationSharer
    @Environment(\.sary) private var theme
    @Environment(AppearanceSettings.self) private var appearance

    @State private var expanded = false
    @State private var drag: CGFloat = 0
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var category: HomeCategory?
    @State private var results: [PlaceSearch.Place] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var job: Task<Void, Never>?
    /// A desert chip's places («دليل البر» or the rain/green search), nearest first.
    @State private var desertItems: [DesertCategoryItem] = []
    /// «قريبًا» (or a failure) for a desert chip with no places.
    @State private var desertNote: String?
    /// The desert result picked (its outline stays drawn under the place card).
    @State private var desertPicked: DesertCategoryItem?
    private let desertService: DesertCategoryService = DesertCategoryRouter()
    @State private var selected: SelectedPlace?
    @State private var camera: PlanCamera?
    @State private var cameraSeq = 1
    @State private var shortcuts = HomeShortcutStore.load()
    /// Choosing a place for «البيت» / «الشغل» (the next pick is saved there).
    @State private var assigning: HomeShortcut?
    @State private var recent = RecentPlaces.load()
    @State private var profileOpen = false
    @State private var startFor: StartTarget?
    @State private var creating = false
    @State private var joining = false
    @StateObject private var voice = VoiceSearch()
    /// Where I am before any trip (the live sharer only runs during one).
    @StateObject private var locator = OneShotLocator()
    @ObservedObject private var saved = SavedPlacesStore.shared

    struct SelectedPlace: Equatable {
        var destination: OutingDestination
        var subtitle: String?
        var icon: String
    }

    struct StartTarget: Identifiable {
        var destination: OutingDestination
        var id: String { "\(destination.lat),\(destination.lng)" }
    }

    var body: some View {
        GeometryReader { g in
            let screen = g.size.height + g.safeAreaInsets.top + g.safeAreaInsets.bottom
            let sheetH = sheetHeight(screen: screen)
            ZStack(alignment: .bottom) {
                PlanMapView(route: [], destination: selected?.destination, camera: camera, theme: theme, showsUser: true,
                            onLongPress: { p in pick(.init(destination: OutingDestination(name: "نقطة على الخريطة", lat: p.lat, lng: p.lng),
                                                           subtitle: CoordinateShare.displayDecimal(p), icon: "mappin")) },
                            desert: desertOverlay,
                            onDesertTap: { id in if let it = desertItems.first(where: { $0.id == id }) { pickDesert(it) } })
                    .ignoresSafeArea()
                    .accessibilityIdentifier("home.map")
                VStack(spacing: theme.space(.s)) {
                    if selected == nil { categoryChips }
                    HStack {
                        Spacer()
                        locateButton
                    }
                    .padding(.horizontal, theme.space(.l))
                    Spacer()
                }
                .padding(.top, theme.space(.s))
                .padding(.bottom, sheetH)
                sheet(height: sheetH)
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .onAppear {
            recent = RecentPlaces.load()
            shortcuts = HomeShortcutStore.load()
            locator.request()
            if camera == nil { recenter(zoom: 12) }
            if autoFocusSearch {
                setExpanded(true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { searchFocused = true }
            }
        }
        .onChange(of: locator.fix) { old, fix in if old == nil, fix != nil, selected == nil { recenter(zoom: 12) } }
        .onChange(of: voice.text) { _, t in if !t.isEmpty { query = t } }
        .onChange(of: query) { _, q in schedule(q) }
        .sheet(isPresented: $profileOpen) {
            ProfileSheet(open: { r in
                profileOpen = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { push(r) }
            })
            .saryPresented(appearance)
        }
        .sheet(item: $startFor) { t in
            CreateOutingWizard(quick: t.destination).saryPresented(appearance)
        }
        .sheet(isPresented: $creating) { CreateOutingWizard().saryPresented(appearance) }
        .sheet(isPresented: $joining) { JoinByLinkSheet().saryPresented(appearance) }
    }

    // MARK: map chrome

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: theme.space(.s)) {
                ForEach(HomeCategory.all) { c in chip(c) }
            }
            .padding(.horizontal, theme.space(.l))
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("home.categories")
    }

    private func chip(_ c: HomeCategory) -> some View {
        let p = theme.palette
        let on = category == c
        return Button { runCategory(c) } label: {
            HStack(spacing: 6) {
                Image(systemName: c.systemImage).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(on ? p.onAccent : (c.desert ? p.warningText : p.accentText))
                Text(c.label).font(.sary(14, .bold)).foregroundStyle(on ? p.onAccent : p.textPrimary)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Capsule().fill(on ? p.accent : p.elevated))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityIdentifier("home.category.\(c.id)")
    }

    private var locateButton: some View {
        Button { recenter(zoom: 14) } label: {
            Image(systemName: "location.fill").font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.palette.accentText)
                .frame(width: 46, height: 46)
                .background(Circle().fill(theme.palette.elevated))
                .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityLabel(Text("موقعي"))
        .accessibilityIdentifier("home.locate")
    }

    // MARK: the sheet

    private func sheetHeight(screen: CGFloat) -> CGFloat {
        let base: CGFloat
        if selected != nil {
            base = 200
        } else if expanded {
            base = CGFloat(HomeSheetRules.expandedHeight(screen: Double(screen)))
        } else {
            base = CGFloat(HomeSheetRules.collapsedHeight) + (activeOuting == nil ? 0 : 78)
        }
        return min(min(screen - 60, 760), max(160, base - drag))
    }

    private func sheet(height: CGFloat) -> some View {
        let p = theme.palette
        let shape = UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26, style: .continuous)
        return VStack(spacing: 0) {
            Capsule().fill(p.textTertiary.opacity(0.6)).frame(width: 40, height: 5)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
                .onTapGesture { setExpanded(!expanded) }
                /* The sheet itself contains a vertical ScrollView. Keep its pan gesture out of
                 * that scroll view so dragging the categories/recent places cannot collapse the
                 * sheet or pan the map; only the dedicated handle resizes it. */
                .gesture(DragGesture(minimumDistance: 12)
                    .onChanged { v in drag = v.translation.height }
                    .onEnded { v in
                        let next = HomeSheetRules.settle(expanded: expanded, translation: Double(v.translation.height),
                                                         velocity: Double(v.predictedEndTranslation.height - v.translation.height))
                        drag = 0
                        setExpanded(next)
                    })
                .accessibilityElement()
                .accessibilityLabel(Text(expanded ? "صغّر" : "اسحب للأعلى للتصنيفات"))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { setExpanded(!expanded) }
                .accessibilityIdentifier("home.sheet.handle")
            if let s = selected {
                placeCard(s)
            } else {
                searchBar
                ScrollView {
                    VStack(alignment: .leading, spacing: theme.space(.l)) {
                        if showingResults {
                            resultsList
                        } else {
                            if let a = assigning { assignBanner(a) }
                            shortcutsRow
                            if let live = activeOuting { activeCard(live) }
                            if !model.online { SaryOfflineStrip() }
                            if expanded { expandedContent }
                        }
                    }
                    .padding(.horizontal, theme.space(.l))
                    .padding(.top, theme.space(.m))
                    .padding(.bottom, 40)
                }
                .scrollDisabled(!expanded && !showingResults)
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("home.sheet.content")
            }
        }
        .frame(height: height, alignment: .top)
        .frame(maxWidth: 560)
        .background(shape.fill(p.background).shadow(color: .black.opacity(0.18), radius: 12, y: -2))
        .clipShape(shape)
        .frame(maxWidth: .infinity, alignment: .bottom)
        .animation(theme.animation(.smooth), value: expanded)
        .animation(theme.animation(.smooth), value: selected)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(expanded ? "home.sheet.expanded" : "home.sheet")
    }

    private var showingResults: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var searchBar: some View {
        let p = theme.palette
        let me = model.identity?.user
        return HStack(spacing: theme.space(.s)) {
            HStack(spacing: theme.space(.s)) {
                Image(systemName: "magnifyingglass").foregroundStyle(p.textSecondary)
                TextField("", text: $query, prompt: Text(assigning.map { "ابحث عن \($0.label)" } ?? "وين رايحين؟ ابحث هنا").foregroundStyle(p.textTertiary))
                    .font(.sary(16, .medium))
                    .foregroundStyle(p.textPrimary)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit { schedule(query, now: true) }
                    .accessibilityIdentifier("home.search")
                if !query.isEmpty {
                    Button { clearSearch() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(p.textTertiary)
                    }
                    .accessibilityLabel(Text("امسح"))
                    .accessibilityIdentifier("home.search.clear")
                }
                Button { voice.toggle() } label: {
                    Image(systemName: voice.isListening ? "waveform" : "mic.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(voice.isListening ? p.onAccent : p.accentText)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(voice.isListening ? p.accent : Color.clear))
                        .symbolEffect(.variableColor, isActive: voice.isListening && !theme.reduceMotion)
                }
                .buttonStyle(SaryPressStyle())
                .accessibilityLabel(Text(voice.isListening ? "أوقف الاستماع" : "ابحث بصوتك"))
                .accessibilityIdentifier("home.mic")
            }
            .padding(.leading, theme.space(.m))
            .padding(.trailing, 6)
            .frame(height: 50)
            .background(Capsule().fill(p.sunken))
            Button { profileOpen = true } label: {
                SaryAvatar(name: me?.display_name ?? "؟", color: theme.accent.fill, photo: AvatarCodec.image(from: me?.avatar), size: 44)
            }
            .buttonStyle(SaryPressStyle())
            .accessibilityLabel(Text("ملفي"))
            .accessibilityIdentifier("home.profile")
        }
        .padding(.horizontal, theme.space(.l))
        .onChange(of: searchFocused) { _, f in if f { setExpanded(true) } }
        .overlay(alignment: .bottom) {
            if voice.state == .denied || voice.state == .unavailable {
                Text(voice.state == .denied ? "اسمح للمايك والتعرّف على الكلام من الإعدادات" : "البحث بالصوت غير متاح الآن")
                    .saryText(.caption).foregroundStyle(p.warningText)
                    .offset(y: 18)
            }
        }
    }

    private var shortcutsRow: some View {
        HStack(spacing: theme.space(.s)) {
            ForEach(HomeShortcut.allCases) { s in
                shortcutButton(title: s.label, detail: shortcuts[s] == nil ? "أضف" : nil, icon: s.systemImage, id: "home.shortcut.\(s.rawValue)") {
                    if let d = shortcuts[s] { pick(.init(destination: d, subtitle: s.label, icon: s.systemImage)) } else { beginAssign(s) }
                }
            }
            shortcutButton(title: "المفضلة", detail: saved.places.isEmpty ? nil : SaryFormat.number(saved.places.count), icon: "star.fill", id: "home.shortcut.favorites") {
                push(.favorites)
            }
        }
    }

    private func shortcutButton(title: String, detail: String?, icon: String, id: String, run: @escaping () -> Void) -> some View {
        let p = theme.palette
        return Button(action: run) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.accentText)
                    .frame(width: 28, height: 28).background(Circle().fill(p.accent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.sary(14, .bold)).foregroundStyle(p.textPrimary).lineLimit(1).minimumScaleFactor(0.75)
                    if let detail { Text(detail).font(.sary(11, .regular)).foregroundStyle(p.textSecondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(p.elevated))
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityIdentifier(id)
    }

    private func activeCard(_ o: OutingSummary) -> some View {
        let p = theme.palette
        return Button { model.open(o.id) } label: {
            HStack(spacing: theme.space(.m)) {
                Image(systemName: "car.2.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(p.liveText)
                    .frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.live.opacity(0.16)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.name).font(.sary(15, .bold)).foregroundStyle(p.textPrimary).lineLimit(1)
                    Text("طلعتك جارية · \(o.participantsLabel)").font(.sary(12, .regular)).foregroundStyle(p.textSecondary)
                }
                Spacer(minLength: 0)
                Text("افتح الخريطة").font(.sary(13, .bold)).foregroundStyle(p.onAccent)
                    .padding(.horizontal, 12).frame(height: 34).background(Capsule().fill(p.accent))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(p.elevated))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(p.live.opacity(0.45), lineWidth: 1.5))
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityIdentifier("home.active")
    }

    @ViewBuilder
    private var expandedContent: some View {
        section("تصنيفات") { categoryGrid(HomeCategory.city) }
        section("البر") { categoryGrid(HomeCategory.desertOnes) }
        if !recent.isEmpty {
            section("أماكن سابقة") {
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.offset) { i, d in
                        if i > 0 { SaryDivider() }
                        placeRow(icon: "clock.arrow.circlepath", title: d.name, detail: nil, point: LngLat(lng: d.lng, lat: d.lat), id: "home.recent") {
                            pick(.init(destination: d, subtitle: nil, icon: "clock.arrow.circlepath"))
                        }
                    }
                }
                .padding(.horizontal, theme.space(.m))
                .sarySurface(radius: SaryRadius.m)
            }
        }
        myOutings
    }

    private func categoryGrid(_ list: [HomeCategory]) -> some View {
        let p = theme.palette
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: theme.space(.s)), count: 4), spacing: theme.space(.s)) {
            ForEach(list) { c in
                Button { runCategory(c) } label: {
                    VStack(spacing: 6) {
                        Image(systemName: c.systemImage).font(.system(size: 20)).foregroundStyle(c.desert ? p.warningText : p.accentText)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill((c.desert ? p.warning : p.accent).opacity(0.14)))
                        Text(c.label).font(.sary(12, .medium)).foregroundStyle(p.textPrimary).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SaryPressStyle())
                .accessibilityIdentifier("home.grid.\(c.id)")
            }
        }
    }

    /// «طلعاتي»: the planned outings (a new one, by link), the others in progress, the latest ended.
    @ViewBuilder
    private var myOutings: some View {
        section("طلعاتي") {
            HStack(spacing: theme.space(.s)) {
                Button { creating = true } label: { SaryButtonLabel(title: "طلعة جديدة", systemImage: "plus") }
                    .buttonStyle(.sary(.secondary))
                    .accessibilityIdentifier("list.create")
                Button { joining = true } label: { SaryButtonLabel(title: "انضم برابط", systemImage: "link") }
                    .buttonStyle(.sary(.secondary))
                    .accessibilityIdentifier("list.join")
            }
            let others = sortedCurrent.filter { $0.id != activeOuting?.id }
            if !others.isEmpty {
                VStack(spacing: 0) {
                    ForEach(others) { o in
                        OutingCard(o: o, open: { model.open(o.id) }, details: { push(.details(o.id)) }, compact: true)
                        if o.id != others.last?.id { SaryDivider().padding(.leading, 56) }
                    }
                }
                .sarySurface(radius: SaryRadius.m)
                .accessibilityIdentifier("home.current")
            }
            if let last = model.history.first {
                OutingCard(o: last, open: { push(.summary(last.id)) }, details: nil, compact: true)
                    .sarySurface(radius: SaryRadius.m)
                    .accessibilityIdentifier("home.history")
                Button("كل نشاطك") { push(.history) }
                    .buttonStyle(.sary(.plain, compact: true))
                    .accessibilityIdentifier("home.allHistory")
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: theme.space(.s)) {
            Text(title).saryText(.footnote, weight: .bold).foregroundStyle(theme.palette.textSecondary)
                .accessibilityAddTraits(.isHeader)
            c()
        }
    }

    private func assignBanner(_ s: HomeShortcut) -> some View {
        HStack {
            SaryBanner(text: "ابحث عن \(s.label) أو اضغط مطوّلًا على الخريطة، واختره.", tone: .info, systemImage: s.systemImage)
            Button("إلغاء") { assigning = nil }.buttonStyle(.sary(.plain, width: .hug, compact: true))
        }
    }

    // MARK: results

    @ViewBuilder
    private var resultsList: some View {
        let p = theme.palette
        if let c = category {
            Text(c.desertSource == nil ? "\(c.label) قريبة منك" : HomeDesertRules.heading(c)).saryText(.headline, weight: .bold).foregroundStyle(p.textPrimary)
                .accessibilityIdentifier("home.results.heading")
        }
        if let c = category, c.desertSource != nil {
            desertResults
        } else if let parsed = CoordinateParser.parse(query) {
            placeRow(icon: "scope", title: CoordinateShare.displayDecimal(parsed.point), detail: CoordinateShare.displayDMS(parsed.point), point: parsed.point,
                     id: "home.result.coordinate") {
                pick(.init(destination: OutingDestination(name: "نقطة على الخريطة", lat: parsed.point.lat, lng: parsed.point.lng),
                           subtitle: CoordinateShare.displayDMS(parsed.point), icon: "scope"))
            }
        } else {
            if searching { SaryStateView(kind: .loading("نبحث…")) }
            if let searchError { SaryBanner(text: searchError, tone: .warning) }
            if !results.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { SaryDivider() }
                        placeRow(icon: r.icon, title: r.name, detail: r.subtitle, point: r.point, id: "home.result", meters: r.areaDistanceM) {
                            if let polygon = r.areaPolygon {
                                desertPicked = DesertCategoryItem(id: r.id, title: r.name, detail: r.subtitle, point: r.point,
                                                                 meters: r.areaDistanceM, systemImage: r.icon, polygon: polygon,
                                                                 approach: r.areaApproach)
                            } else {
                                desertPicked = nil
                            }
                            let target = r.areaApproach ?? r.point
                            pick(.init(destination: OutingDestination(name: String(r.name.prefix(TripPlan.destinationNameMax)), lat: target.lat, lng: target.lng),
                                       subtitle: r.subtitle, icon: r.icon))
                        }
                    }
                }
                .padding(.horizontal, theme.space(.m))
                .sarySurface(radius: SaryRadius.m)
            } else if !searching && searchError == nil && query.count >= 2 {
                Text("ما وجدنا مكانًا بهذا الاسم. جرّب اسمًا آخر، أو اضغط مطوّلًا على الخريطة.").saryText(.subhead).foregroundStyle(p.textSecondary)
            }
        }
    }

    /// A desert chip's list: nearest first, the distance to the edge for a sand sea.
    @ViewBuilder
    private var desertResults: some View {
        let p = theme.palette
        if searching { SaryStateView(kind: .loading("نجهّز الأماكن…")) }
        if let note = desertNote {
            SaryBanner(text: note, tone: .info, systemImage: "clock")
                .accessibilityIdentifier("home.desert.soon")
        }
        if !desertItems.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(desertItems.enumerated()), id: \.element.id) { i, it in
                    if i > 0 { SaryDivider() }
                    placeRow(icon: it.systemImage, title: "\(SaryFormat.number(i + 1)). \(it.title)", detail: it.detail, point: it.point,
                             id: "home.desert.result", meters: it.meters) { pickDesert(it) }
                }
            }
            .padding(.horizontal, theme.space(.m))
            .sarySurface(radius: SaryRadius.m)
            Text(HomeDesertRules.footnote(category)).saryText(.caption).foregroundStyle(p.textTertiary)
                .accessibilityIdentifier("home.desert.attribution")
        }
    }

    private var desertOverlay: DesertOverlay? {
        if let s = desertPicked, selected != nil { return DesertOverlay(items: [s], selected: s.id) }
        guard selected == nil, category?.desertSource != nil, !desertItems.isEmpty else { return nil }
        return DesertOverlay(items: Array(desertItems.prefix(HomeDesertRules.onMap)))
    }

    private func placeRow(icon: String, title: String, detail: String?, point: LngLat, id: String, meters: Double? = nil, run: @escaping () -> Void) -> some View {
        let p = theme.palette
        return Button(action: run) {
            HStack(spacing: theme.space(.m)) {
                SaryRowIcon(systemImage: icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).saryText(.body, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(1)
                    if let detail { Text(detail).saryNumber(.footnote).foregroundStyle(p.textSecondary).lineLimit(1) }
                }
                Spacer()
                if let m = meters ?? myPoint.map({ PlanGeo.meters($0, point) }) {
                    Text(m == 0 ? "هنا" : SaryFormat.distance(meters: m)).saryNumber(.footnote).foregroundStyle(p.textTertiary)
                }
            }
            .frame(minHeight: theme.minTarget + 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    // MARK: the picked place

    private func placeCard(_ s: SelectedPlace) -> some View {
        let p = theme.palette
        let d = s.destination
        let point = LngLat(lng: d.lng, lat: d.lat)
        let isSaved = saved.places.contains { PlanGeo.meters($0.position, point) < 30 }
        return VStack(alignment: .leading, spacing: theme.space(.m)) {
            HStack(alignment: .top, spacing: theme.space(.m)) {
                SaryRowIcon(systemImage: s.icon, color: p.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.name).saryText(.title2, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(2)
                        .accessibilityIdentifier("home.place.name")
                    HStack(spacing: 6) {
                        if let me = myPoint {
                            Text(SaryFormat.distance(meters: PlanGeo.meters(me, point))).saryNumber(.footnote, weight: .bold).foregroundStyle(p.textSecondary)
                        }
                        if let sub = s.subtitle { Text(sub).saryNumber(.footnote).foregroundStyle(p.textSecondary).lineLimit(1) }
                    }
                }
                Spacer(minLength: 0)
                Button { closePlace() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(p.textPrimary)
                        .frame(width: 34, height: 34).background(Circle().fill(p.sunken))
                }
                .buttonStyle(SaryPressStyle())
                .accessibilityLabel(Text("إغلاق"))
                .accessibilityIdentifier("home.place.close")
            }
            if let a = assigning {
                Button {
                    HomeShortcutStore.set(a, d)
                    shortcuts = HomeShortcutStore.load()
                    assigning = nil
                    closePlace()
                } label: { SaryButtonLabel(title: "احفظه كـ\(a.label)", systemImage: a.systemImage) }
                    .buttonStyle(.sary(.primary))
                    .accessibilityIdentifier("home.place.assign")
            } else {
                HStack(spacing: theme.space(.s)) {
                    Button { start(d) } label: { SaryButtonLabel(title: "ابدأ", systemImage: "location.north.fill") }
                        .buttonStyle(.sary(.primary))
                        .accessibilityIdentifier("home.place.start")
                    Button {
                        if !isSaved { saved.add(name: d.name, icon: .star, at: point) }
                    } label: { SaryButtonLabel(title: isSaved ? "محفوظ" : "احفظ", systemImage: isSaved ? "star.fill" : "star") }
                        .buttonStyle(.sary(.secondary, width: .hug))
                        .disabled(isSaved)
                        .accessibilityIdentifier("home.place.save")
                }
            }
        }
        .padding(.horizontal, theme.space(.l))
        .padding(.top, theme.space(.xs))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.place")
    }

    // MARK: actions

    private var myPoint: LngLat? {
        location.lastFix.map { LngLat(lng: $0.lng, lat: $0.lat) } ?? locator.fix.map { LngLat(lng: $0.lng, lat: $0.lat) }
    }

    private var activeOuting: OutingSummary? { sortedCurrent.first { $0.status == .active } }

    private var sortedCurrent: [OutingSummary] {
        let rank: [OutingStatus: Int] = [.active: 0, .paused: 1, .created: 2, .ended: 3]
        return model.current.sorted { (rank[$0.status] ?? 9) < (rank[$1.status] ?? 9) }
    }

    private func setExpanded(_ e: Bool) {
        withAnimation(theme.animation(.smooth)) { expanded = e }
        if !e { searchFocused = false }
    }

    private func recenter(zoom: Double) {
        let p = myPoint ?? PlanCamera.initial(route: [], destination: nil, picked: nil)
        cameraSeq += 1
        camera = PlanCamera(kind: .point(p, zoom: zoom), id: cameraSeq)
    }

    private func beginAssign(_ s: HomeShortcut) {
        assigning = s
        selected = nil
        setExpanded(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { searchFocused = true }
    }

    private func runCategory(_ c: HomeCategory) {
        if category == c { clearSearch(); return }
        category = c
        selected = nil
        desertPicked = nil
        desertItems = []
        desertNote = nil
        query = c.query
        setExpanded(true)
        schedule(c.query, now: true)
    }

    /// A desert chip: ask its service, list nearest first, fit the map on you and the first ones.
    private func runDesert(_ c: HomeCategory) {
        results = []
        searching = true
        let near = myPoint
        job = Task {
            let r = await desertService.search(c, near: near)
            guard !Task.isCancelled, category == c else { return }
            searching = false
            switch r {
            case let .places(items):
                desertItems = items
                desertNote = items.isEmpty ? "ما لقينا أماكن قريبة في دليل البر." : nil
                let pts = HomeDesertRules.fitPoints(items, me: near)
                if pts.count >= 2 { cameraSeq += 1; camera = PlanCamera(kind: .fit(pts), id: cameraSeq) }
            case let .comingSoon(text), let .failed(text):
                desertItems = []
                desertNote = text
            }
        }
    }

    private func pickDesert(_ it: DesertCategoryItem) {
        desertPicked = it
        let to = it.approach ?? it.point
        let sub = [it.detail, to != it.point ? "أقرب طرف منك" : nil].compactMap { $0 }.joined(separator: " · ")
        pick(.init(destination: OutingDestination(name: String(it.title.prefix(TripPlan.destinationNameMax)), lat: to.lat, lng: to.lng),
                   subtitle: sub.isEmpty ? nil : sub, icon: it.systemImage))
    }

    private func clearSearch() {
        job?.cancel()
        query = ""
        category = nil
        results = []
        searching = false
        searchError = nil
        desertItems = []
        desertNote = nil
        desertPicked = nil
    }

    private func pick(_ s: SelectedPlace) {
        if let destinationPicker {
            RecentPlaces.add(s.destination)
            recent = RecentPlaces.load()
            destinationPicker(s.destination)
            return
        }
        searchFocused = false
        selected = s
        expanded = false
        cameraSeq += 1
        camera = PlanCamera(kind: .point(LngLat(lng: s.destination.lng, lat: s.destination.lat), zoom: 14), id: cameraSeq)
    }

    private func closePlace() {
        selected = nil
        desertPicked = nil
    }

    /// «ابدأ» → «مين معك؟» (the quick «طلعة»: this place, leaving now).
    private func start(_ d: OutingDestination) {
        RecentPlaces.add(d)
        recent = RecentPlaces.load()
        startFor = StartTarget(destination: d)
    }

    private func schedule(_ q: String, now: Bool = false) {
        job?.cancel()
        searchError = nil
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if category != nil, t != category?.query { category = nil; desertItems = []; desertNote = nil }
        if let c = category, c.desertSource != nil { runDesert(c); return }
        guard t.count >= 2, CoordinateParser.parse(t) == nil else {
            results = []
            searching = false
            return
        }
        searching = true
        let near = myPoint
        job = Task {
            if !now { try? await Task.sleep(nanoseconds: 350_000_000) }
            guard !Task.isCancelled else { return }
            /* «دليل البر» first: a known desert name answers offline too. */
            let desert = HomeDesertRules.searchPlaces(DesertGazetteer.bundled, t, near: near)
            results = desert
            if HomeDesertRules.categoryKind(t) != nil {
                /* Category intent is entirely answered by the bundled gazetteer. Avoid waiting on
                 * geocoders or leaking a query that cannot improve these type-filtered results. */
                searching = false
                return
            }
            do {
                let r = try await PlaceSearch.search(t, near: near)
                guard !Task.isCancelled else { return }
                results = HomeDesertRules.merge(desert: desert, places: r)
            } catch let e as PlaceSearch.SearchError {
                results = desert
                if desert.isEmpty { searchError = e.arabic }
            } catch {
                results = desert
                if desert.isEmpty { searchError = PlaceSearch.SearchError.network.arabic }
            }
            searching = false
        }
    }
}
