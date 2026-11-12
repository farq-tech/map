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
                session.open()
                /* The navigation map's 3D look, centred on me (R02); the person can change it with two fingers. */
                let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
                let pitch = IdleMapRules.idlePitch(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermalHot: hot)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    controller.ask(.me)
                    controller.ask(.tilt(pitch))
                }
            }
            .onDisappear {
                model.idleMapShown = false
                session.close()
            }
    }
}

/// The idle sheet's content (the home content over the navigation map): search, «طلعاتي», «طلعة جديدة».
struct IdleSheetContent: View {
    @ObservedObject var controller: LiveOutingController
    var detent: SheetDetentUI
    @EnvironmentObject private var model: AppModel
    @Environment(\.sary) private var theme
    @Environment(AppearanceSettings.self) private var appearance
    @State private var searching = false
    @State private var creating = false

    var body: some View {
        let p = theme.palette
        VStack(spacing: theme.space(.s)) {
            Button { searching = true } label: {
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
            .padding(.horizontal, theme.space(.l))
            if detent == .peek, let first = IdleMapRules.visibleOutings(model.current, limit: 1).first {
                /* The taller idle peek shows the one outing that matters (the active one first). */
                OutingCard(o: first, open: { model.open(first.id) }, compact: true)
                    .padding(.horizontal, theme.space(.l))
            }
            if detent != .peek {
                ScrollView {
                    VStack(spacing: theme.space(.s)) {
                        ForEach(IdleMapRules.visibleOutings(model.current)) { o in
                            OutingCard(o: o, open: { model.open(o.id) }, compact: true)
                        }
                        Button { creating = true } label: {
                            Label("طلعة جديدة", systemImage: "plus.circle.fill")
                                .saryText(.body, weight: .bold).foregroundStyle(p.accentText)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous).fill(p.accent.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("idle.new")
                    }
                    .padding(.horizontal, theme.space(.l))
                    .padding(.bottom, theme.space(.xl))
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("idle.sheet")
        .sheet(isPresented: $searching) {
            LiveSearchSheet(near: controller.location.lastFix.map { LngLat(lng: $0.lng, lat: $0.lat) },
                            pick: { d in searching = false; controller.idlePickPlace(d) },
                            close: { searching = false })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .saryAppearance(appearance)
        }
        .sheet(isPresented: $creating) { CreateOutingWizard().saryPresented(appearance) }
    }
}
