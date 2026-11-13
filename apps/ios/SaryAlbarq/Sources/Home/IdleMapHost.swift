import SwiftUI

/// EM1 (docs/EXPLORE-MERGE.md): the navigation map as the first screen, with no trip. Behind `OneMapFlag`.
/// The map host is `LiveOutingScreen` itself (no new map); what carries it is a local idle session that is
/// never `AppModel.session`, with exploration's capabilities always on and the home content in its sheet.
struct IdleMapHost: View {
    @StateObject private var controller: LiveOutingController
    private let session: OutingSession
    @EnvironmentObject private var model: AppModel

    init(user: PublicUser, model: AppModel, appearance: AppearanceSettings) {
        let s = OutingSession.idleMap(me: user, location: model.location)
        session = s
        _controller = StateObject(wrappedValue: {
            let c = LiveOutingController(session: s, location: model.location, appearance: appearance,
                                         featuresBackend: model.featuresBackend(for: s.id))
            c.idleHome = true
            c.exploreActive = true
            c.planModel = model.plans.model(s.id)
            c.idleNavigate = { [weak model] d in model?.openSolo(to: d) }
            return c
        }())
    }

    var body: some View {
        LiveOutingScreen(controller: controller)
            .task { await model.refresh() }
            .onAppear {
                model.idleMapShown = true
                MapTiltModel.shared.idleHome = true
                session.open()
                /* The navigation map's 3D look, centred on me (R02); the «٣د / ٢د» button changes it (no touch tilt). */
                /* The remembered «٣د / ٢د» choice of this map (3D at 40° until the person flattens it). */
                let pitch = MapTiltModel.shared.pitch(.idle)
                #if DEBUG
                /* `-SaryHiResCam lat,lng,zoom` puts the camera on a test spot itself: the idle map must not race it. */
                if ProcessInfo.processInfo.arguments.contains("-SaryHiResCam") { return }
                #endif
                Task { @MainActor in
                    /* Wait for the first fix (up to 10 s): the opening zoom depends on where I am (open land / a city). */
                    for _ in 0..<20 where model.location.lastFix == nil { try? await Task.sleep(nanoseconds: 500_000_000) }
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if let f = model.location.lastFix {
                        controller.ask(.idleOpen(zoom: IdleMapRules.openingZoom(lat: f.lat, lng: f.lng), pitch: pitch))
                    } else {
                        controller.ask(.tilt(pitch))
                    }
                }
            }
            .onDisappear {
                model.idleMapShown = false
                MapTiltModel.shared.idleHome = false
                session.close()
            }
    }
}

/// The idle sheet's content (the home content over the navigation map): the profile, the search, the category chips,
/// «طلعاتي», «طلعة جديدة» and «انضم برابط». The map's own buttons are in the side column (`IdleSideRules`).
struct IdleSheetContent: View {
    @ObservedObject var controller: LiveOutingController
    var detent: SheetDetentUI
    @EnvironmentObject private var model: AppModel
    @Environment(\.sary) private var theme
    @Environment(AppearanceSettings.self) private var appearance
    @State private var searchQuery: String?
    @State private var creating = false
    @State private var joining = false
    @State private var toolsOpen = false
    @State private var profileOpen = false

    @StateObject private var voice = VoiceSearch()

    var body: some View {
        content
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("idle.sheet")
        .sheet(isPresented: Binding(get: { searchQuery != nil }, set: { if !$0 { searchQuery = nil } })) {
            LiveSearchSheet(near: controller.location.lastFix.map { LngLat(lng: $0.lng, lat: $0.lat) },
                            initialQuery: searchQuery ?? "",
                            pick: { d in searchQuery = nil; controller.idlePickPlace(d) },
                            close: { searchQuery = nil })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .saryAppearance(appearance)
        }
        .sheet(isPresented: $toolsOpen) {
            HomeDesertToolsMenu(me: controller.location.lastFix.map { LngLat(lng: $0.lng, lat: $0.lat) },
                                open: { tool in
                                    toolsOpen = false
                                    let action: String?
                                    switch tool {
                                    case .weather: action = "weather"
                                    case .qibla: action = "qibla"
                                    case .camp: action = "camp"
                                    default: action = nil
                                    }
                                    if let action { DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { controller.performAction(action) } }
                                },
                                close: { toolsOpen = false },
                                search: {
                                    toolsOpen = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { searchQuery = "" }
                                })
                .presentationDetents([.medium, .large])
                .saryPresented(appearance)
        }
        .sheet(isPresented: $creating) { CreateOutingWizard().saryPresented(appearance) }
        .sheet(isPresented: $joining) { JoinByLinkSheet().saryPresented(appearance) }
        .fullScreenCover(isPresented: $profileOpen) { IdleProfileFlow(pick: { d in
            profileOpen = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { controller.idlePickPlace(d) }
        }).saryPresented(appearance) }
        /* Queued: shown once no other sheet of the idle map is up (`IdleMapRules.idlePresentsNotifyExplainer`). */
        .sheet(isPresented: Binding(
            get: {
                IdleMapRules.idlePresentsNotifyExplainer(
                    offer: model.offerNotifications, pendingInvite: model.pendingInvite != nil,
                    idleSheetOpen: searchQuery != nil || toolsOpen || creating || joining || profileOpen || controller.idleMoreOpen,
                    liveModalOpen: controller.modal != nil)
            },
            set: { if !$0 { model.offerNotifications = false } })) {
            NotifyExplainerSheet(done: { model.offerNotifications = false }).saryPresented(appearance)
        }
        .confirmationDialog("المزيد", isPresented: $controller.idleMoreOpen, titleVisibility: .visible) {
            let compact = IdleSideRules.isCompact(screenHeight: Double(UIScreen.main.bounds.height))
            ForEach(IdleSideRules.moreActions(compact: compact), id: \.rawValue) { a in
                Button(Self.title(a)) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        switch a {
                        case .places: controller.modal = .places
                        case .drone: controller.idleDrone()
                        case .realistic: controller.performAction("realistic")
                        }
                    }
                }
            }
            Button("إلغاء", role: .cancel) {}
        }
    }


    @ViewBuilder
    private var content: some View {
        if NewUI.enabled { newContent } else { legacyContent }
    }

    /// The new Home on the one map (`NewUI.enabled`, behind the one-map switch): the same shared pieces as the home map's card
    /// (`HomeTopPill`, `HomeCardContent`); the map's own buttons (layers, 2D/3D, locate) are the side column's, unchanged.
    private var newContent: some View {
        let me = model.identity?.user
        let screenH = Double(UIScreen.main.bounds.height)
        let fix = controller.location.lastFix
        return VStack(spacing: theme.space(.s)) {
            HomeTopPill(avatarName: me?.display_name ?? "؟", avatarPhoto: AvatarCodec.image(from: me?.avatar),
                        listening: voice.isListening,
                        onSearch: { searchQuery = "" },
                        onMic: { voice.toggle() },
                        onProfile: { profileOpen = true })
                .padding(.horizontal, theme.space(.l))
            if detent != .peek {
                ScrollView {
                    VStack(spacing: theme.space(.s)) {
                    HomeCardContent(weather: nil,
                                    maghrib: fix.flatMap { HomeChromeRules.maghribLine(now: Date(), lat: $0.lat, lng: $0.lng) },
                                    last: HomeChromeRules.isCompact(screenHeight: screenH) ? nil : HomeChromeRules.lastOuting(model.history),
                                    weatherRow: true, lastRow: true,
                                    onStart: { creating = true },
                                    onTile: { openTile($0) },
                                    onLast: { if let o = HomeChromeRules.lastOuting(model.history) { model.open(o.id) } })
                    /* Nothing of the old idle sheet is lost: «البر» and the categories, my outings, «انضم برابط». */
                    categoryChips
                    VStack(spacing: theme.space(.s)) {
                        ForEach(IdleMapRules.visibleOutings(model.current)) { o in
                            OutingCard(o: o, open: { model.open(o.id) }, compact: true)
                        }
                        row("انضم برابط", "link", id: "idle.join", filled: false) { joining = true }
                    }
                    .padding(.horizontal, theme.space(.l))
                    .padding(.bottom, theme.space(.xl))
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .onChange(of: voice.text) { _, t in if !t.isEmpty { searchQuery = t } }
    }

    private func openTile(_ t: HomeTile) {
        switch t {
        case .camp: controller.performAction("camp")
        case .qibla: controller.performAction("qibla")
        case .weather: controller.performAction("weather")
        case .routes: toolsOpen = true
        }
    }

    private var legacyContent: some View {
        let p = theme.palette
        return VStack(spacing: theme.space(.s)) {
            HStack(spacing: theme.space(.s)) {
                Button { profileOpen = true } label: {
                    SaryAvatar(name: model.identity?.user.display_name ?? "؟", color: theme.accent.fill,
                               photo: AvatarCodec.image(from: model.identity?.user.avatar), size: 44)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("حسابي"))
                .accessibilityIdentifier("idle.profile")
                Button { searchQuery = "" } label: {
                    HStack(spacing: theme.space(.s)) {
                        Image(systemName: "magnifyingglass").foregroundStyle(p.textTertiary).accessibilityHidden(true)
                        Text("ابحث عن مكان أو إحداثية").saryText(.body).foregroundStyle(p.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, theme.space(.m))
                    .frame(minHeight: 48)
                    .background(Capsule().fill(p.sunken))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("idle.search")
            }
            .padding(.horizontal, theme.space(.l))
            categoryChips
            if detent != .peek {
                ScrollView {
                    VStack(spacing: theme.space(.s)) {
                        ForEach(IdleMapRules.visibleOutings(model.current)) { o in
                            OutingCard(o: o, open: { model.open(o.id) }, compact: true)
                        }
                        row("طلعة جديدة", "plus.circle.fill", id: "idle.new", filled: true) { creating = true }
                        row("انضم برابط", "link", id: "idle.join", filled: false) { joining = true }
                    }
                    .padding(.horizontal, theme.space(.l))
                    .padding(.bottom, theme.space(.xl))
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    static func title(_ a: IdleMoreAction) -> String {
        switch a {
        case .places: return "أماكني ومساراتي"
        case .drone: return "درون"
        case .realistic: return "الوضع الواقعي"
        }
    }

    /// «البر» first, then the everyday and desert categories: one row that scrolls (the home's order).
    private var categoryChips: some View {
        let p = theme.palette
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: theme.space(.s)) {
                Button { toolsOpen = true } label: {
                    chipLabel("sun.dust.fill", "البر", fg: p.onWarning, bg: p.warning, iconColor: p.onWarning)
                }
                .buttonStyle(SaryPressStyle())
                .accessibilityLabel(Text("البر: الطقس والقبلة والكشتة والدروب"))
                .accessibilityIdentifier("idle.tools.open")
                ForEach(HomeCategory.all) { c in
                    Button { searchQuery = c.query } label: {
                        chipLabel(c.systemImage, c.label, fg: p.textPrimary, bg: p.elevated, iconColor: c.desert ? p.warningText : p.accentText)
                    }
                    .buttonStyle(SaryPressStyle())
                    .accessibilityIdentifier("idle.category.\(c.id)")
                }
            }
            .padding(.horizontal, theme.space(.l))
        }
        .accessibilityIdentifier("idle.categories")
    }

    private func chipLabel(_ icon: String, _ title: String, fg: Color, bg: Color, iconColor: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(iconColor)
            Text(title).font(.sary(14, .bold)).foregroundStyle(fg)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(Capsule().fill(bg))
        /* 36 tall to the eye, 44 to the finger. */
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func row(_ title: String, _ icon: String, id: String, filled: Bool, run: @escaping () -> Void) -> some View {
        let p = theme.palette
        return Button(action: run) {
            Label(title, systemImage: icon)
                .saryText(.body, weight: .bold).foregroundStyle(p.accentText)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous).fill(filled ? p.accent.opacity(0.14) : p.sunken))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// «حسابي» from the idle map: the profile sheet with the home's pages behind it (favorites, activity, settings, help…).
struct IdleProfileFlow: View {
    /// A favourite chosen on the «مفضلتك» page: the host closes the flow and shows it on the map.
    var pick: (OutingDestination) -> Void = { _ in }
    @State private var path: [HomeRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ProfileSheet(open: { path.append($0) })
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: HomeRoute.self) { route in
                    HomeRouteDestination(route: route, path: $path, choosePlace: pick)
                        .navigationBarBackButtonHidden(true)
                }
        }
    }
}

/// «قرّب لصور أوضح»: high-res imagery is available and not drawn at this zoom. Tapping goes to where it starts.
struct IdleHiResHint: View {
    @ObservedObject var controller: LiveOutingController
    @ObservedObject var reading: ExploreReadingModel
    var ui: LiveOutingUIState
    @Environment(\.sary) private var theme

    var body: some View {
        if controller.idleShowsHiResHint(ui, reading: reading.reading), let r = reading.reading {
            Button { controller.ask(.zoom(IdleMapRules.hiResTargetZoom(lat: r.center.lat, lng: r.center.lng))) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "photo.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.palette.accentText)
                    Text("قرّب لصور أوضح").font(.sary(14, .bold)).foregroundStyle(theme.palette.textPrimary)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .saryGlass(Capsule(), role: .chrome, interactive: true)
                .contentShape(Capsule())
            }
            .buttonStyle(SaryPressStyle())
            .accessibilityIdentifier("idle.hires.hint")
            .accessibilityValue(Text(String(format: "z%.2f", r.zoom)))
            .accessibilityHint(Text("يقرّب الخريطة للمستوى اللي تبدأ فيه الصور عالية الوضوح"))
            .transition(.opacity)
        }
    }
}
