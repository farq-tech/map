import SwiftUI

/// The first screen: a map, the category chips floating over it, and ONE bottom sheet —
/// «وين رايحين؟» (mic + profile), the shortcuts (البيت · الشغل · المفضلة) and what is
/// happening now. Pulled up: every category, recent places and «طلعاتي».
/// The flow: search → pick → continue the active outing or create a new one when no outing is active.
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 100 at the default text size: the collapsed sheet grows with Dynamic Type.
    @ScaledMetric(relativeTo: .body) private var textScale100: CGFloat = 100

    @State private var expanded = false
    @State private var drag: CGFloat = 0
    /// The translation when the sheet drag was recognized (after its minimum distance).
    @State private var dragOrigin: Double?
    /// True while a sheet drag is live; resets by itself if the system cancels the gesture
    /// (then `onEnded` never runs — see the `onChange` that settles the sheet back).
    @GestureState private var sheetDragging = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var category: HomeCategory?
    @State private var results: [PlaceSearch.Place] = []
    /// «الأنسب · الأقرب · حسب النوع» above the results.
    @State private var resultOrder: PlaceSearch.ListOrder = .relevance
    @State private var searching = false
    @State private var searchError: String?
    @State private var job: Task<Void, Never>?
    /// A desert chip's places («دليل البر» or the rain/green search), nearest first.
    @State private var desertItems: [DesertCategoryItem] = []
    /// «قريبًا» (or a failure) for a desert chip with no places.
    @State private var desertNote: String?
    /// The desert result picked (its outline stays drawn under the place card).
    @State private var desertPicked: DesertCategoryItem?
    private let desertService: DesertCategoryService = DesertCategoryRouter.shared
    @State private var selected: SelectedPlace?
    @State private var selectedPointNameTask: Task<Void, Never>?
    @State private var camera: PlanCamera?
    @State private var cameraSeq = 1
    /* Loaded in onAppear: a @State initialiser runs on every re-init of this struct (each parent re-render). */
    @State private var shortcuts: [HomeShortcut: OutingDestination] = [:]
    /// Choosing a place for «البيت» / «الشغل» (the next pick is saved there).
    @State private var assigning: HomeShortcut?
    @State private var recent: [OutingDestination] = []
    @State private var profileOpen = false
    @State private var startFor: StartTarget?
    @State private var creating = false
    @State private var joining = false
    /// «البر» tools and their sheets, no outing needed (UI-AUDIT م6).
    @State private var tool: HomeTool?
    /// «اتجه» / «امشِ عليه»: full screen over the home.
    @State private var cover: HomeCover?
    /// «أضفها لطلعتك» is saving to the planned outing.
    @State private var adding = false
    /// Why «أضفها لطلعتك» did not go through (shown on the place card).
    @State private var placeNote: String?
    @State private var invitePasteMiss = false
    @StateObject private var voice = VoiceSearch()
    /// Where I am before any trip (the live sharer only runs during one).
    @StateObject private var locator = OneShotLocator()
    @ObservedObject private var saved = SavedPlacesStore.shared
    /// «دروب البر» opened from here: drawn on this map while its sheet is open.
    @ObservedObject private var desertRoutes = DesertRoutesHub.shared

    struct SelectedPlace: Equatable {
        var destination: OutingDestination
        var subtitle: String?
        var icon: String
        /// A desert place (a desert chip / «دليل البر» result, a pressed map point): «دروب البر» may apply.
        var desert = false
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
                PlanMapView(route: [], destination: selected?.destination, camera: camera, theme: theme, userLocation: myPoint,
                            onLongPress: { p in pick(.init(destination: OutingDestination(name: "نقطة على الخريطة", lat: p.lat, lng: p.lng),
                                                           subtitle: CoordinateShare.displayDecimal(p), icon: "mappin", desert: true)) },
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
                sheet(height: sheetH, screen: screen)
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
        .onReceive(NotificationCenter.default.publisher(for: .saryRecentPlacesChanged)) { _ in
            recent = RecentPlaces.load()
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
        .sheet(item: $tool) { t in
            HomeToolSheet(tool: t, me: myPoint, host: desertHost, open: openTool, close: { tool = nil })
                .saryPresented(appearance)
        }
        .onChange(of: tool?.id) { old, new in
            /* «دروب البر» closed (swiped down too): its lines leave the home map with it. */
            if old?.hasPrefix("routes:") == true, new?.hasPrefix("routes:") != true { DesertRoutesHub.shared.clear() }
        }
        .background {
            /* Its own host view: a full-screen cover next to the sheets above. */
            Color.clear.fullScreenCover(item: $cover) { c in
                switch c {
                case let .nav(t):
                    StandaloneNavScreen(target: t) { cover = nil }
                        .saryPresented(appearance)
                case let .follow(m):
                    TrackFollowScreen(model: m) { cover = nil }
                        .saryPresented(appearance)
                }
            }
        }
    }

    // MARK: map chrome

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: theme.space(.s)) {
                if destinationPicker == nil { desertToolsChip }
                ForEach(HomeCategory.all) { c in chip(c) }
            }
            .padding(.horizontal, theme.space(.l))
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
            /* The chip stays 36 tall; the touch area is 44. */
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityIdentifier("home.category.\(c.id)")
    }

    /// «البر»: the weather, the Qibla, «اقترح لي مكان كشتة» and «دروب البر» without an outing (م6).
    private var desertToolsChip: some View {
        let p = theme.palette
        return Button { tool = .menu } label: {
            HStack(spacing: 6) {
                Image(systemName: "sun.dust.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.onWarning)
                Text("البر").font(.sary(14, .bold)).foregroundStyle(p.onWarning)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(Capsule().fill(p.warning))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            /* Same as the category chips: 36 tall to the eye, 44 to the finger. */
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityLabel(Text("البر: الطقس والقبلة والكشتة والدروب"))
        .accessibilityIdentifier("home.tools.open")
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
        CGFloat(HomeSheetRules.frameHeight(screen: Double(screen), preferred: Double(baseHeight(screen: screen, expanded: expanded)),
                                           drag: Double(drag)))
    }

    /// The sheet's resting height (no finger on it), clamped like the frame.
    private func restingHeight(screen: CGFloat, expanded e: Bool) -> Double {
        HomeSheetRules.frameHeight(screen: Double(screen), preferred: Double(baseHeight(screen: screen, expanded: e)), drag: 0)
    }

    private func baseHeight(screen: CGFloat, expanded: Bool) -> CGFloat {
        let base: CGFloat
        if selected != nil {
            // The picked-point card has only its title, coordinates, and two actions.
            // 200pt left a large empty area below the buttons; keep enough room for
            // a two-line place name while letting the map remain visible. At accessibility
            // sizes, give the card room to grow; its content remains scrollable as a fallback.
            /* + the weather line and the second row of actions («اتجه» + the outing action). */
            base = dynamicTypeSize.isAccessibilitySize ? min(screen - 60, max(420, screen * 0.72)) : 232
        } else if expanded {
            base = CGFloat(HomeSheetRules.expandedHeight(screen: Double(screen)))
        } else {
            base = CGFloat(HomeSheetRules.collapsedHeight(card: stateCard, textScale: Double(textScale100 / 100)))
        }
        return base
    }

    private func sheet(height: CGFloat, screen: CGFloat) -> some View {
        let p = theme.palette
        let shape = UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26, style: .continuous)
        return VStack(spacing: 0) {
            Capsule().fill(p.textTertiary.opacity(0.6)).frame(width: 40, height: 5)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
                .onTapGesture { setExpanded(!expanded) }
                /* The raised sheet contains a vertical ScrollView: there only the handle resizes it,
                 * so scrolling «طلعاتي» / recent places never collapses the sheet. Collapsed (nothing
                 * scrolls), the whole sheet drags too (`collapsedDraggable` below). */
                .gesture(sheetDrag(screen: screen))
                .accessibilityElement()
                .accessibilityLabel(Text(expanded ? "صغّر" : "اسحب للأعلى لطلعاتك"))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { setExpanded(!expanded) }
                .accessibilityIdentifier("home.sheet.handle")
            if let s = selected {
                ScrollView {
                    placeCard(s)
                }
                .scrollIndicators(.hidden)
                /* The picked place rises into the sheet as the sheet takes its height. */
                .transition(SaryTransition.appear(theme))
                .accessibilityIdentifier("home.place.scroll")
            } else {
                VStack(spacing: 0) {
                    searchBar
                    ScrollView {
                        VStack(alignment: .leading, spacing: theme.space(.l)) {
                            if showingResults {
                                resultsList
                            } else {
                                if let a = assigning { assignBanner(a) }
                                shortcutsRow
                                stateCardView
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
                /* Collapsed nothing scrolls: drag the sheet up from anywhere on it, not only the handle. */
                .gesture(sheetDrag(screen: screen), including: collapsedDraggable ? .all : .subviews)
                .transition(.opacity)
            }
        }
        .frame(height: height, alignment: .top)
        .frame(maxWidth: 560)
        .background(shape.fill(p.background).shadow(color: .black.opacity(0.18), radius: 12, y: -2))
        .clipShape(shape)
        .frame(maxWidth: .infinity, alignment: .bottom)
        .animation(theme.animation(.smooth), value: expanded)
        .animation(theme.animation(.smooth), value: selected)
        /* The collapsed height follows the state card; results replace the home content. */
        .animation(theme.animation(.smooth), value: stateCard)
        .animation(theme.animation(.smooth), value: showingResults)
        .onChange(of: sheetDragging) { _, dragging in
            guard !dragging else { return }
            /* A cancelled drag (no `onEnded`): settle back instead of staying where the finger left it.
             * Next run loop, so a normal end (which clears `dragOrigin`) always goes first. */
            DispatchQueue.main.async {
                guard dragOrigin != nil else { return }
                dragOrigin = nil
                withAnimation(theme.animation(.smooth)) { drag = 0 }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(expanded ? "home.sheet.expanded" : "home.sheet")
    }

    private var showingResults: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Resizes the sheet: on the handle always, on the whole sheet while it is collapsed.
    /// Owner report (Build 36, «اهتزاز النافذة السفلية»): the gesture used the default `.local`
    /// coordinate space of a view that the drag itself moves (the sheet is bottom-anchored, so its
    /// top — and the handle — rise as it grows). Each frame the local translation came out short by
    /// the previous frame's growth, so the height alternated between "followed the finger" and
    /// "back near the start": the sheet shook and never tracked. `.global` translation is the
    /// finger's own movement on screen: 1:1.
    private func sheetDrag(screen: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($sheetDragging) { _, dragging, _ in dragging = true }
            .onChanged { v in
                /* Start from where the gesture was recognized (no 12 pt jump on the first frame). */
                let origin = dragOrigin ?? Double(v.translation.height)
                if dragOrigin == nil { dragOrigin = origin }
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { drag = CGFloat(HomeSheetRules.dragOffset(translation: Double(v.translation.height), origin: origin)) }
            }
            .onEnded { v in
                let origin = dragOrigin ?? 0
                dragOrigin = nil
                let next = HomeSheetRules.settle(expanded: expanded,
                                                 collapsedHeight: restingHeight(screen: screen, expanded: false),
                                                 expandedHeight: restingHeight(screen: screen, expanded: true),
                                                 predictedTranslation: HomeSheetRules.dragOffset(translation: Double(v.predictedEndTranslation.height),
                                                                                                origin: origin))
                /* One animated change: the finger's offset back to 0 AND the new rest height (a release
                 * that stays put used to drop `drag` without animation and jump back). */
                withAnimation(theme.animation(.smooth)) {
                    drag = 0
                    expanded = next
                }
                if !next { searchFocused = false }
            }
    }

    /// The collapsed sheet has no scrolling content, so its whole area may drag it (never raised:
    /// there the content scrolls and only the handle resizes).
    private var collapsedDraggable: Bool { !expanded && !showingResults && selected == nil }

    // MARK: the one state card

    /// What the collapsed sheet says now (`HomeStateCard`): none in the in-trip picker.
    private var stateCard: HomeStateCard {
        guard destinationPicker == nil else { return .none }
        return HomeStateCard.pick(current: model.current, phase: model.listPhase, inviteHint: model.deferredInviteHint)
    }

    /// The one state card cross-fades when what it says changes (start → upcoming → active…).
    private var stateCardView: some View {
        stateCardContent
            .transition(SaryTransition.appear(theme))
            .id(stateCardKind)
    }

    /// Which card (not its live details): a new kind swaps the card, new details update in place.
    private var stateCardKind: String {
        switch stateCard {
        case .active: return "active"
        case .upcoming: return "upcoming"
        case .invite: return "invite"
        case .start: return "start"
        case .failed: return "failed"
        case .none: return "none"
        }
    }

    @ViewBuilder
    private var stateCardContent: some View {
        switch stateCard {
        case let .active(id):
            if let o = model.current.first(where: { $0.id == id }) { activeCard(o) }
        case let .upcoming(id):
            if let o = model.current.first(where: { $0.id == id }) { upcomingCard(o) }
        case .invite:
            inviteCard
        case .start:
            if !expanded { startCard }
        case let .failed(message):
            if !expanded { failedCard(message) }
        case .none:
            EmptyView()
        }
    }

    /// «طلعتك القادمة»: planned or paused, one tap opens it.
    private func upcomingCard(_ o: OutingSummary) -> some View {
        let p = theme.palette
        let paused = o.status == .paused
        return Button { model.open(o.id) } label: {
            HStack(spacing: theme.space(.m)) {
                Image(systemName: paused ? "pause.circle.fill" : "calendar").font(.system(size: 16, weight: .semibold)).foregroundStyle(p.accentText)
                    .frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.accent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.name).font(.sary(15, .bold)).foregroundStyle(p.textPrimary).lineLimit(1)
                    let line = [paused ? "طلعتك القادمة · متوقفة" : "طلعتك القادمة", o.timeLabel(), o.participantsLabel].compactMap { $0 }.joined(separator: " · ")
                    Text(line)
                        .font(.sary(12, .regular)).foregroundStyle(p.textSecondary).lineLimit(1)
                        .contentTransition(theme.reduceMotion ? .opacity : .numericText())
                        .saryAnimation(.smooth, value: line)
                }
                Spacer(minLength: 0)
                Text("افتحها").font(.sary(13, .bold)).foregroundStyle(p.onAccent)
                    .padding(.horizontal, 12).frame(minHeight: 34).background(Capsule().fill(p.accent))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(p.elevated))
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityHint(Text("يفتح الطلعة على الخريطة"))
        .accessibilityIdentifier("home.upcoming")
    }

    /// First time, or nothing current: the two ways in.
    private var startCard: some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: theme.space(.s)) {
            Text("أنشئ طلعة وادعُ ربعك").saryText(.headline, weight: .bold).foregroundStyle(p.textPrimary)
            Text("ابحث عن وجهتك فوق، أو ابدأ من هنا.").saryText(.footnote).foregroundStyle(p.textSecondary)
            HStack(spacing: theme.space(.s)) {
                Button { creating = true } label: { SaryButtonLabel(title: "طلعة جديدة", systemImage: "plus") }
                    .buttonStyle(.sary(.primary))
                    .accessibilityIdentifier("home.start.create")
                Button { joining = true } label: { SaryButtonLabel(title: "انضم برابط", systemImage: "link") }
                    .buttonStyle(.sary(.secondary))
                    .accessibilityIdentifier("home.start.join")
            }
        }
        .padding(theme.space(.m))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(p.elevated))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.start")
    }

    /// The list did not load and there is nothing to show: say it, and try again.
    private func failedCard(_ message: String) -> some View {
        let p = theme.palette
        return HStack(spacing: theme.space(.m)) {
            Image(systemName: model.online ? "exclamationmark.triangle.fill" : SaryIcon.offline).font(.system(size: 16, weight: .semibold))
                .foregroundStyle(p.warningText)
                .frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.warning.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(HomeListCopy.failedTitle).font(.sary(15, .bold)).foregroundStyle(p.textPrimary).lineLimit(1)
                Text(HomeListCopy.failedDetail(message, online: model.online)).font(.sary(12, .regular)).foregroundStyle(p.textSecondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button { Task { await model.refresh() } } label: { SaryButtonLabel(title: "حاول مرة ثانية") }
                .buttonStyle(.sary(.secondary, width: .hug, compact: true))
                .accessibilityIdentifier("home.failed.retry")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(p.elevated))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.failed")
    }

    /// Installed from an invite page and the link never pasted: the invite stays here after
    /// onboarding. The system «لصق» reads the pasteboard only on that tap.
    private var inviteCard: some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: theme.space(.s)) {
            HStack {
                Text("جاي من دعوة؟").saryText(.headline, weight: .bold).foregroundStyle(p.textPrimary)
                Spacer(minLength: 0)
                Button("لاحقًا") { model.deferredInviteHint = false }
                    .buttonStyle(.sary(.plain, width: .hug, compact: true))
                    .accessibilityIdentifier("home.invite.later")
            }
            Text(invitePasteMiss ? "ما لقينا رابط دعوة في النسخ. افتح رابط الدعوة من جديد، أو اطلبه من أمير الطلعة."
                                 : "اضغط «لصق» ونكمّل دعوتك على طول.")
                .saryText(.footnote).foregroundStyle(p.textSecondary).fixedSize(horizontal: false, vertical: true)
            PasteButton(payloadType: String.self) { strings in
                Task { @MainActor in invitePasteMiss = !model.acceptPastedInvite(strings) }
            }
            .buttonBorderShape(.capsule)
            .tint(p.accent)
            .accessibilityIdentifier("home.invite.paste")
        }
        .padding(theme.space(.m))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(p.elevated))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.invite")
    }

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
                            /* Same glyph, 44 pt touch area (the capsule is 50 tall). */
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
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
                        /* 34 pt circle, 44 pt touch area (the capsule is 50 tall). */
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SaryPressStyle())
                .accessibilityLabel(Text(voice.isListening ? "أوقف الاستماع" : "ابحث بصوتك"))
                .accessibilityIdentifier("home.mic")
            }
            .padding(.leading, theme.space(.m))
            .padding(.trailing, 1)
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
                    if let detail { Text(detail).font(.sary(12, .regular)).foregroundStyle(p.textSecondary).lineLimit(1) }
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
                        /* Someone joins: the count rolls, the card stays. */
                        .contentTransition(theme.reduceMotion ? .opacity : .numericText())
                        .saryAnimation(.smooth, value: o.participantsLabel)
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
        /* No category grid here: the same chips are on the map, always one tap away (UI-AUDIT §٢). */
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
            /* The list did not load and nothing is kept: an error with «حاول مرة ثانية», never an empty list. */
            if case let .failed(message) = model.listPhase, model.current.isEmpty, model.history.isEmpty {
                SaryStateView(kind: model.online ? .error(title: HomeListCopy.failedTitle, message: HomeListCopy.failedDetail(message, online: true))
                                                 : .offline(message: HomeListCopy.failedDetail(message, online: false)),
                              actionTitle: "حاول مرة ثانية", actionID: "home.outings.retry") { Task { await model.refresh() } }
                    .sarySurface(radius: SaryRadius.m)
                    .accessibilityIdentifier("home.outings.failed")
            } else if model.listPhase == .loading, model.current.isEmpty, model.history.isEmpty {
                SaryStateView(kind: .loading("نجيب طلعاتك…"))
                    .accessibilityIdentifier("home.outings.loading")
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
                if results.count >= 3 { PlaceOrderPicker(order: $resultOrder, hasPosition: myPoint != nil) }
                let ordered = PlaceSearch.ordered(results, by: resultOrder, near: myPoint)
                VStack(spacing: 0) {
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { SaryDivider() }
                        /* Build 36 item 11: Arabic name first, the other language on its own small line, the distance bold. */
                        PlaceResultRow(icon: r.icon, name: r.name, secondaryName: r.secondaryName, detail: r.rowDetail,
                                       meters: r.meters(from: myPoint), id: "home.result") {
                            if let polygon = r.areaPolygon {
                                desertPicked = DesertCategoryItem(id: r.id, title: r.name, detail: r.subtitle, point: r.point,
                                                                 meters: r.areaDistanceM, systemImage: r.icon, polygon: polygon,
                                                                 approach: r.areaApproach)
                            } else {
                                desertPicked = nil
                            }
                            let target = r.areaApproach ?? r.point
                            pick(.init(destination: OutingDestination(name: String(r.name.prefix(TripPlan.destinationNameMax)), lat: target.lat, lng: target.lng),
                                       subtitle: r.subtitle, icon: r.icon, desert: r.id.hasPrefix("gazetteer:")))
                        }
                        .transition(SaryTransition.appear(theme))
                    }
                }
                .padding(.horizontal, theme.space(.m))
                .sarySurface(radius: SaryRadius.m)
                /* Results refine as you type: rows keep their place (stable ids), new ones fade in,
                   a new order slides them. */
                .saryAnimation(.snappy, value: ordered.map(\.id))
            } else if !searching && searchError == nil && query.count >= 2 {
                Text("ما لقينا مكان بهذا الاسم. جرّب اسم ثاني، أو اضغط مطوّلًا على الخريطة.").saryText(.subhead).foregroundStyle(p.textSecondary)
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
                        .transition(SaryTransition.appear(theme))
                }
            }
            .padding(.horizontal, theme.space(.m))
            .sarySurface(radius: SaryRadius.m)
            .saryAnimation(.snappy, value: desertItems.map(\.id))
            Text(HomeDesertRules.footnote(category)).saryText(.caption).foregroundStyle(p.textTertiary)
                .accessibilityIdentifier("home.desert.attribution")
        }
    }

    private var desertOverlay: DesertOverlay? {
        HomeDesertRules.overlay(desertPlaces, routes: desertRoutes.options, selected: desertRoutes.selected)
    }

    private var desertPlaces: DesertOverlay? {
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
                    Text(d.name).saryText(.title2, weight: .bold).foregroundStyle(p.textPrimary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                        .accessibilityIdentifier("home.place.name")
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 2) {
                            if let me = myPoint {
                                Text(SaryFormat.distance(meters: PlanGeo.meters(me, point))).saryNumber(.footnote, weight: .bold).foregroundStyle(p.textSecondary)
                            }
                            if let sub = s.subtitle { Text(sub).saryNumber(.footnote).foregroundStyle(p.textSecondary).lineLimit(2) }
                        }
                    } else {
                        HStack(spacing: 6) {
                            if let me = myPoint {
                                Text(SaryFormat.distance(meters: PlanGeo.meters(me, point))).saryNumber(.footnote, weight: .bold).foregroundStyle(p.textSecondary)
                            }
                            if let sub = s.subtitle { Text(sub).saryNumber(.footnote).foregroundStyle(p.textSecondary).lineLimit(1) }
                        }
                    }
                }
                Spacer(minLength: 0)
                SaryIconButton(systemImage: SaryIcon.close, label: "إغلاق", id: "home.place.close", visual: 34) { closePlace() }
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
                placeActions(s, isSaved: isSaved)
            }
        }
        .padding(.horizontal, theme.space(.l))
        .padding(.top, theme.space(.xs))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.place")
    }

    /// «اتجه», the outing action, the weather there, «دروب البر» and «احفظ».
    @ViewBuilder
    private func placeActions(_ s: SelectedPlace, isSaved: Bool) -> some View {
        let p = theme.palette
        let d = s.destination
        let point = LngLat(lng: d.lng, lat: d.lat)
        let action = placeAction
        let routes = HomeDesertTools.offersRoutes(desertPlace: s.desert, me: myPoint, target: point)
        /* «اتجه» first: guidance on this phone, no outing and no server (UI-AUDIT §٢). */
        let go = Button { directions(d) } label: { SaryButtonLabel(title: "اتجه", systemImage: SaryIcon.directions) }
            .buttonStyle(.sary(.primary))
            .accessibilityIdentifier("home.place.go")
        let outing = Button { start(d) } label: {
            SaryButtonLabel(title: action.title, systemImage: action.systemImage, busy: adding, busyTitle: "نضيفها…")
        }
            .buttonStyle(.sary(.secondary))
            .disabled(adding)
            .accessibilityIdentifier("home.place.start")
        let save = Button {
            if !isSaved { saved.add(name: d.name, icon: .star, at: point) }
        } label: { SaryButtonLabel(title: isSaved ? "محفوظ" : "احفظ", systemImage: isSaved ? "star.fill" : "star") }
            .buttonStyle(.sary(.plain, width: .hug, compact: true))
            .disabled(isSaved)
            .accessibilityIdentifier("home.place.save")
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: theme.space(.s)) {
                go
                outing
            }
        } else {
            HStack(spacing: theme.space(.s)) {
                go
                outing
            }
        }
        if let placeNote { SaryInlineMessage(text: placeNote, tone: .error) }
        HStack(spacing: theme.space(.s)) {
            /* The weather at the destination now (Open-Meteo, the point only); tap for 24 h. */
            Button { openTool(.weather(d)) } label: {
                HStack(spacing: 4) {
                    DestinationWeatherBadge(destination: d)
                    Text("الجو هناك").saryText(.caption, weight: .bold).foregroundStyle(p.textSecondary)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
                .background(Capsule().fill(p.sunken))
                /* 36 tall to the eye, 44 to the finger. */
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(SaryPressStyle())
            .accessibilityIdentifier("home.place.weather")
            if routes {
                Button { openTool(.routes(target: point, name: d.name, rain: false, weatherAvailable: false)) } label: {
                    SaryButtonLabel(title: "دروب البر", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                .buttonStyle(.sary(.plain, width: .hug, compact: true))
                .accessibilityIdentifier("home.place.routes")
            }
            Spacer(minLength: 0)
            save
        }
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
        selectedPointNameTask?.cancel()
        selectedPointNameTask = nil
        assigning = s
        selected = nil
        setExpanded(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { searchFocused = true }
    }

    private func runCategory(_ c: HomeCategory) {
        if category == c { clearSearch(); return }
        selectedPointNameTask?.cancel()
        selectedPointNameTask = nil
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
        let service = desertService
        job = Task {
            /* Edge distances to thousands of outlines: off the main thread, then the state on it. */
            let r = await Task.detached(priority: .userInitiated) { await service.search(c, near: near) }.value
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
                   subtitle: sub.isEmpty ? nil : sub, icon: it.systemImage, desert: true))
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
        selectedPointNameTask?.cancel()
        selectedPointNameTask = nil
        selected = s
        expanded = false
        cameraSeq += 1
        let point = LngLat(lng: s.destination.lng, lat: s.destination.lat)
        camera = PlanCamera(kind: .point(point, zoom: 14), id: cameraSeq)
        guard PlaceLabel.isGeneric(s.destination.name) else { return }
        selectedPointNameTask = Task {
            let name = await PlaceNameResolver.shared.name(for: point, within: 3)
            guard !Task.isCancelled, !PlaceLabel.isGeneric(name),
                  var current = selected,
                  PlaceLabel.isGeneric(current.destination.name),
                  PlanGeo.meters(LngLat(lng: current.destination.lng, lat: current.destination.lat), point) < 2 else { return }
            current.destination.name = name
            selected = current
        }
    }

    private func closePlace() {
        selectedPointNameTask?.cancel()
        selectedPointNameTask = nil
        selected = nil
        desertPicked = nil
        placeNote = nil
    }

    /// The picked place with the name resolved meanwhile (the card's `d` may be a step behind).
    private func resolved(_ d: OutingDestination) -> OutingDestination {
        selected.map(\.destination).flatMap { picked in
            let a = LngLat(lng: picked.lng, lat: picked.lat)
            let b = LngLat(lng: d.lng, lat: d.lat)
            return PlanGeo.meters(a, b) < 2 ? picked : nil
        } ?? d
    }

    /// The card's outing action (`HomePlaceAction`): the running outing takes the point; a planned /
    /// paused one I lead gets it in its plan; otherwise a new outing.
    private func start(_ d: OutingDestination) {
        selectedPointNameTask?.cancel()
        selectedPointNameTask = nil
        let destination = resolved(d)
        RecentPlaces.add(destination)
        recent = RecentPlaces.load()
        switch placeAction {
        case let .guideConvoy(id), let .personalLeg(id):
            DispatchQueue.main.async { model.open(id, mapDestination: destination) }
        case let .addToOuting(id):
            addToOuting(id, destination)
        case .create:
            startFor = StartTarget(destination: destination)
        }
    }

    private var placeAction: HomePlaceAction { HomePlaceAction.pick(current: model.current) }

    /// «أضفها لطلعتك»: the planned outing's destination, or its next stop; then its details.
    private func addToOuting(_ id: String, _ d: OutingDestination) {
        adding = true
        placeNote = nil
        Task {
            let plan = model.plans.model(id)
            if plan.planPhase == .loading { await plan.loadPlan() }
            let edit = HomePlanEdit.adding(d, to: plan.plan)
            let ok: Bool
            switch edit.outcome {
            case .destination: ok = await plan.setDestination(d)
            case .stop: ok = await plan.save(edit.plan)
            case .already, .full: ok = true
            }
            adding = false
            guard ok else {
                placeNote = plan.errorText ?? "ما قدرنا نضيفها لطلعتك. جرّب مرة ثانية."
                plan.errorText = nil
                return
            }
            if edit.outcome == .full {
                placeNote = HomePlanEdit.confirmation(.full, name: d.name)
                return
            }
            UINotificationFeedback.success()
            closePlace()
            push(.details(id))
        }
    }

    /// «اتجه»: our own turn-by-turn on this phone, no outing and no server (`StandaloneNavScreen`).
    private func directions(_ d: OutingDestination) {
        selectedPointNameTask?.cancel()
        selectedPointNameTask = nil
        let destination = resolved(d)
        RecentPlaces.add(destination)
        recent = RecentPlaces.load()
        guard case let .success(t) = NavTargets.point(LngLat(lng: destination.lng, lat: destination.lat), name: destination.name) else { return }
        cover = .nav(t)
    }

    /// One desert tool after another: the open sheet goes first (a sheet over a closing one is dropped).
    private func openTool(_ t: HomeTool) {
        guard tool != nil else { tool = t; return }
        tool = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { tool = t }
    }

    /// The desert tools' host on the home map: «اتجه» opens `StandaloneNavScreen`, «امشِ عليه»
    /// `TrackFollowScreen` — both on this phone only.
    private var desertHost: DesertToolsHost {
        DesertToolsHost(
            myPoint: { myPoint },
            close: { tool = nil },
            directions: { r in
                guard case let .success(t) = r else { return }
                tool = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { cover = .nav(t) }
            },
            openRoutes: { target, name, rain, weatherAvailable in
                openTool(.routes(target: target, name: name, rain: rain, weatherAvailable: weatherAvailable))
            },
            follow: { s in
                tool = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { cover = TrackFollowModel(s).map(HomeCover.follow) }
            },
            fitTrack: { pts in
                /* The routes are drawn on this map (`desertOverlay`): frame them above the half sheet. */
                let fit = HomeDesertRules.routesFit(pts)
                guard fit.count >= 2 else { return }
                cameraSeq += 1
                camera = PlanCamera(kind: .fit(fit), id: cameraSeq)
            })
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
            /* Matched off the main thread (thousands of names, edge distances), shown on it. */
            let (desert, desertOnly) = await Task.detached(priority: .userInitiated) {
                (HomeDesertRules.searchPlaces(DesertGazetteer.bundled, t, near: near), HomeDesertRules.categoryKind(t) != nil)
            }.value
            guard !Task.isCancelled else { return }
            results = desert
            if desertOnly {
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
