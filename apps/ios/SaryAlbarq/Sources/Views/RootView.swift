import Combine
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var location: LocationSharer
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(\.sary) private var theme

    var body: some View {
        ZStack {
            if model.launching {
                SplashView().transition(.opacity)
            } else if let session = model.session {
                LiveOutingHost(session: session, model: model, appearance: appearance)
                    .id(session.id)
            } else if model.identityPending {
                /* Signed in, but the Keychain has not answered yet: never onboarding (it would make a second account). */
                SplashView().transition(.opacity)
            } else if let screen = model.debugScreen {
                DebugScreen(name: screen)
            } else if model.pendingInvite != nil && (model.identity == nil || needsOnboarding) {
                /* Arriving by an invite: no onboarding pages behind the join sheet (build 21) —
                 * the invite IS the onboarding. «إلغاء» there brings the usual first page back. */
                SplashView().transition(.opacity)
            } else if model.identity == nil || needsOnboarding {
                OnboardingFlow(start: model.identity == nil ? .intro : .locationExplainer)
                    .transition(.opacity)
                    .alert(model.accountNotice?.notice?.title ?? "", isPresented: Binding(get: { model.accountNotice?.notice != nil }, set: { if !$0 { model.accountNotice = nil } })) {
                        Button("حسنًا", role: .cancel) {}
                    } message: {
                        Text(model.accountNotice?.notice?.message ?? "")
                    }
            } else {
                HomeView()
                    .transition(.opacity)
                    .onAppear { if model.identity != nil && location.authorization != .notDetermined { OnboardingProgress.done = true } }
            }
        }
        .animation(theme.animation(.smooth), value: model.launching)
        /* During a trip the live sheet is always presented: the invite is shown from inside it
         * (`LiveSheet`), never from here, where a second sheet would silently not appear. */
        .sheet(item: Binding(get: { model.session == nil ? model.pendingInvite.map(InviteToken.init) : nil }, set: { model.pendingInvite = $0?.id })) { inv in
            InviteJoinSheet(token: inv.id).saryPresented(appearance)
        }
        .sheet(isPresented: Binding(get: { model.offerNotifications && model.session == nil && model.pendingInvite == nil },
                                    set: { if !$0 { model.offerNotifications = false } })) {
            NotifyExplainerSheet(done: { model.offerNotifications = false }).saryPresented(appearance)
        }
        .alert("تنبيه", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) {
            Button("حسنًا", role: .cancel) {}
        } message: {
            Text(model.errorText ?? "")
        }
    }

    /// Signed in, but the location explainer was never seen and iOS has not asked yet.
    private var needsOnboarding: Bool {
        model.identity != nil && !OnboardingProgress.done && location.authorization == .notDetermined && !model.isDemo
    }
}

extension LiveOutingHost {
    /// «ابدأ الطلعة» at the end of «طلعة جديدة»: once the outing has loaded, start it if it
    /// has not started yet (never in the demo, which has no server).
    fileprivate func startIfAsked() {
        guard model.pendingStart == controller.session.id, let v = controller.session.view else { return }
        /* The destination is saved with the outing; wait until the plan has it (never start without one). */
        guard controller.tripDestination != nil || v.status != .created else { return }
        model.pendingStart = nil
        if v.status == .created, !controller.session.isDemo { controller.startOuting() }
    }

    fileprivate func startPendingMapDestination() {
        guard let request = model.pendingMapDestination,
              request.outingId == controller.session.id,
              let outing = controller.session.displayView else { return }
        model.pendingMapDestination = nil
        guard outing.status == .active else {
            model.errorText = "الطلعة ليست نشطة الآن. افتح طلعة نشطة لاختيار وجهة."
            return
        }
        controller.startLegFromMap(request.destination)
    }
}

struct InviteToken: Identifiable { let id: String }

/// Owns the live screen's controller for as long as that outing is open.
struct LiveOutingHost: View {
    @StateObject private var controller: LiveOutingController

    init(session: OutingSession, model: AppModel, appearance: AppearanceSettings) {
        _controller = StateObject(wrappedValue: {
            let c = LiveOutingController(session: session, location: model.location, appearance: appearance, featuresBackend: model.featuresBackend)
            c.onExit = { [weak model] in model?.closeSession() }
            c.onBackToList = { [weak model] in model?.parkSession() }
            /* «تخطيط الطلعة»: the weather reads the plan's destination and route. */
            c.planModel = model.plans.model(session.id)
            c.setPush = { [weak model] on in
                guard let model else { return }
                Task { await model.push.setEnabled(on, signedIn: model.signedIn) }
            }
            c.pushExplained = { [weak model] in model?.push.explained ?? true }
            c.openSummary = { [weak model] in model?.showSummaryAfterClose(session.id) }
            c.startReturnTrip = { [weak model, weak c] in
                guard let model else { return }
                Task {
                    if await model.startReturnTrip(from: session.id) == nil, let e = model.errorText { c?.toast(e); model.errorText = nil }
                }
            }
            c.savePhone = { [weak model, weak c] phone in
                guard let model else { return }
                Task {
                    let ok = await model.updateProfile(name: model.identity?.user.display_name ?? "", phone: phone ?? "")
                    if ok { c?.toast("تم حفظ رقمك") }
                }
            }
            return c
        }())
    }

    @EnvironmentObject private var model: AppModel

    var body: some View {
        LiveOutingScreen(controller: controller)
            /* A new destination (or one kept on this phone) moves the weather chip at once. */
            .onReceive(model.plans.model(controller.session.id).$plan.map(\.destination).removeDuplicates()) { _ in
                /* onReceive may run as SwiftUI is reconciling this host. Keep the weather model
                 * and trip controller mutations out of that view-update transaction. */
                DispatchQueue.main.async {
                    controller.feedWeather(force: true)
                    controller.updateTrip()
                    startIfAsked()
                }
            }
            .onReceive(controller.session.objectWillChange) { _ in
                DispatchQueue.main.async {
                    startIfAsked()
                    startPendingMapDestination()
                }
            }
            .onAppear {
                DispatchQueue.main.async {
                    startIfAsked()
                    startPendingMapDestination()
                }
            }
            .onReceive(model.$offerNotifications) { offer in
                /* First join: notifications are NOT asked at join (build 14). Our explainer comes with
                 * the first alert worth sending in this trip (a friend's message, SOS, convoy alert). */
                guard offer else { return }
                model.offerNotifications = false
                controller.notifyOfferPending = true
            }
    }
}

extension View {
    /// Sheets and dialogs are new presentations and do not reliably inherit the
    /// root's layout direction, so every presented screen asks for RTL itself.
    func rtl() -> some View {
        environment(\.layoutDirection, .rightToLeft).environment(\.locale, Locale(identifier: "ar"))
    }
}
