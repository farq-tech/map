import CoreLocation
import SwiftUI

/// The native 3-detent sheet: ONE summary line, then the tabs الرحلة / المجموعة /
/// المزيد (docs/IA-REDESIGN.md §2.4). Everything presented over the live screen (participant card,
/// note composer, stations, consent, rally label) is presented from here, because the sheet is
/// the top-most presentation. A friend's SOS is the exception: it has its own window
/// (`FriendSOSAlertHost`), so nothing presented here can hold it back.
struct LiveSheet: View {
    @ObservedObject var controller: LiveOutingController
    /// The live screen's presenter state for this render (`LiveOutingScreen` builds it once and
    /// hands it down), so the sheet and everything under it never run the presenter again.
    var ui: LiveOutingUIState
    @Environment(\.sary) private var theme
    @Environment(AppearanceSettings.self) private var appearance
    @EnvironmentObject private var model: AppModel
    /// An invite link opened during this trip, shown once the sheet on top (if any) is gone.
    @State private var invite: InviteToken?

    var body: some View {
        let actions = controller.actions
        VStack(spacing: theme.space(.s)) {
            if controller.nav.isActive {
                /* Navigating: the peek is the guidance bar (arrival time, what is left, «المزيد»,
                 * «غيّر الوجهة», «أوقف التوجيه»). */
                NavBottomBar(nav: controller.nav, end: controller.stopGuidanceTapped,
                             more: { controller.modal = .actions },
                             changeDestination: controller.navChangeDestination,
                             peek: ui.sheetDetent == .peek)
                if ui.sheetDetent != .peek, controller.nav.phase != .arrived {
                    /* Pulled up: «المسارات»، «مشاركة الوصول»، «الصوت»، «الخطوات»، «نظرة عامة» (and «غيّر الوجهة»
                     * when the compact bar has no room for it). */
                    NavTripOptions(nav: controller.nav, routes: controller.navCanShowRoutes ? { controller.navShowRoutes() } : nil,
                                   steps: { controller.modal = .navSteps },
                                   overview: { controller.navControlTapped("nav.overview") }, overviewOn: controller.nav.camera == .overview,
                                   cameraMode: controller.mapFollowMode.rawValue,
                                   changeDestination: controller.navChangeDestination)
                        .padding(.top, theme.space(.s))
                }
            } else {
                /* One line: the people (the trip's numbers are in the header above), then the key actions. */
                SarySheetSummary(participants: ui.participantsTab.participants, detent: ui.sheetDetent, ended: controller.tripEnded,
                                 expand: { actions.setSheetDetent(ui.sheetDetent == .peek ? .half : .peek) })
                if controller.showsQuickRow(drive: theme.drive) && !controller.exploreActive {
                    LiveQuickRow(controller: controller, hasRally: ui.participantsTab.rally != nil)
                }
            }
            if ui.sheetDetent != .peek {
                /* No tabs (UX simplification): the people, then whatever needs attention. The rest is
                 * one tap away in the quick row or «المزيد». docs/ux-simplify-inventory.md. */
                ScrollView {
                    VStack(spacing: theme.space(.m)) {
                        LiveSheetBody(controller: controller, ui: ui)
                    }
                    .padding(.horizontal, theme.space(.l))
                    .padding(.bottom, theme.space(.xl))
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(.top, theme.space(.s))
        .frame(maxWidth: 720, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SafetyPrompts(safety: controller.safety))
        .modifier(FeatureModals(controller: controller, features: controller.features))
        .background(MediaSheetHost(center: MediaCenters.of(controller)))
        .background(GroupAudioSheetHost(center: GroupAudioCenters.of(controller)))
        .sheet(item: $controller.modal) { m in
            modal(m)
                .saryAppearance(appearance)
        }
        .fullScreenCover(isPresented: Binding(get: { controller.settingsOpen }, set: { if !$0 { controller.closeSettings() } })) {
            SettingsPushHost { close in LiveSettingsPage(controller: controller, close: close) }
                .saryAppearance(appearance)
        }
        /* A friend's SOS is NOT presented from here (UI-AUDIT 0.1): with a sheet or the settings page
         * up, a second presentation from this view silently did not appear. It has its own window
         * (`FriendSOSAlertHost`, on the live screen). */
        .sheet(item: $invite, onDismiss: { if model.pendingInvite == invite?.id { model.pendingInvite = nil } }) { inv in
            InviteJoinSheet(token: inv.id).saryPresented(appearance)
        }
        .onReceive(model.$pendingInvite.removeDuplicates()) { t in
            guard let t, invite?.id != t else { if t == nil { invite = nil }; return }
            /* One sheet at a time: close whatever is up, then show the invite. */
            let busy = controller.modal != nil || controller.shareItem != nil
            controller.modal = nil
            controller.shareItem = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + (busy ? 0.6 : 0.05)) { if model.pendingInvite == t { invite = InviteToken(id: t) } }
        }
        .sheet(item: Binding(get: { controller.shareItem.map(ShareURL.init) }, set: { if $0 == nil { controller.shareItem = nil } })) { s in
            ShareSheet(items: [s.url]).presentationDetents([.medium, .large])
        }
        .confirmationDialog("أنت", isPresented: $controller.meMenuOpen, titleVisibility: .visible) {
            if !controller.tripEnded {
                Button("رسالة فوق سيارتي") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { controller.modal = .note } }
            }
            Button("انسخ أو شارك موقعي") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { controller.modal = .plan(.me) } }
            Button("إلغاء", role: .cancel) {}
        }
        .confirmationDialog("أنت في طلعة شغّالة", isPresented: Binding(get: { controller.confirm == .backWhileSharing }, set: { if !$0 && controller.confirm == .backWhileSharing { controller.confirm = nil } }), titleVisibility: .visible) {
            Button("ارجع للقائمة", action: controller.backToList)
            Button("غادر الطلعة", role: .destructive) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { controller.confirm = .leave } }
            Button("ابقَ في الطلعة", role: .cancel) {}
        } message: {
            Text("أصدقاء الطلعة يشوفون موقعك ما دمت فيها. الرجوع للقائمة لا يوقف المشاركة؛ تتوقف فقط إذا غادرت الطلعة أو انتهت.")
        }
        .confirmationDialog("تغادر الطلعة؟", isPresented: Binding(get: { controller.confirm == .leave }, set: { if !$0 && controller.confirm == .leave { controller.confirm = nil } }), titleVisibility: .visible) {
            Button("غادر الطلعة", role: .destructive, action: controller.leaveOuting)
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("تتوقف مشاركة موقعك فورًا وينمسح آخر موقع لك من الخادم. ترجع لها فقط بدعوة جديدة.")
        }
        .confirmationDialog("نغيّر الوجهة إلى \(controller.confirm?.retargetTarget?.name ?? "النقطة")؟",
                            isPresented: Binding(get: { controller.confirm?.retargetTarget != nil },
                                                 set: { if !$0, controller.confirm?.retargetTarget != nil { controller.confirm = nil } }),
                            titleVisibility: .visible, presenting: controller.confirm?.retargetTarget) { t in
            Button("غيّر") { controller.retarget(to: t) }
            Button("لا", role: .cancel) {}
        } message: { t in
            Text(t.staleNote().map { "\($0). التوجيه الحالي يتوقف." } ?? "التوجيه الحالي يتوقف.")
        }
        .alert("تنبيه", isPresented: Binding(get: { controller.session.errorText != nil }, set: { if !$0 { controller.session.errorText = nil } })) {
            Button("حسنًا", role: .cancel) {}
        } message: { Text(controller.session.errorText ?? "") }
    }

    @ViewBuilder
    private func modal(_ m: LiveModal) -> some View {
        switch m {
        case let .chat(w):
            ChatHomeView(chat: controller.chat, context: controller.chatContext, close: { controller.modal = nil }, path: w.map { [$0] } ?? [])
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        case .actions:
            LiveActionSheet(groups: LiveActionCatalog.groups(controller.actionState),
                            action: controller.performAction, close: { controller.modal = nil }, trip: tripRows)
                /* Lovable: two thirds of the screen (SOS and the header stay in view), scrolls; pull up for all. */
                .presentationDetents([.fraction(0.66), .large])
                .presentationDragIndicator(.visible)
        case let .participant(id):
            if let s = controller.participantCard(id) {
                ScrollView {
                    SaryParticipantCard(state: s, actions: controller.participantActions(id))
                    /* Build 10: their recent trail (as this phone saw it) can be followed too. */
                    if let f = controller.friendFollowSubject(id) {
                        Button {
                            controller.modal = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { controller.startFollow(f) }
                        } label: {
                            SaryButtonLabel(title: "اسلك مساره (\(SaryFormat.distance(meters: f.stats.distanceM)))", systemImage: FollowIcon.follow)
                        }
                        .buttonStyle(.sary(.secondary))
                        .padding(.horizontal)
                        .accessibilityIdentifier("participant.followTrail")
                    }
                }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .accessibilityIdentifier("participant-card")
            }
        case .note:
            NoteComposer(state: NoteComposerUIState(currentNote: ui.participantsTab.participants.first(where: \.isMe)?.note,
                                                   isSending: controller.session.busy.contains("note")),
                         actions: NoteComposerActions(
                            send: { t in Task { if await controller.session.sendNote(t) { controller.modal = nil; controller.toast("رسالتك فوق سيارتك ١٥ دقيقة") } } },
                            clearNote: { Task { if await controller.session.sendNote("") { controller.modal = nil } } },
                            cancel: { controller.modal = nil }))
                .presentationDetents([.medium, .large])
        case .stations:
            NearestStationsView(state: NearestStationsUIState(phase: controller.stations), actions: controller.stationActions)
                .presentationDetents([.medium, .large])
        case let .rallyLabel(p, moving):
            RallyLabelView(moving: moving, save: { controller.saveRally(p, label: $0) }, cancel: { controller.modal = nil })
                .presentationDetents([.medium])
        case .notify:
            NotifyExplainerSheet(done: { controller.modal = nil })
        case .offlineMaps:
            OfflineMapsView(back: { controller.modal = nil }, suggested: controller.offlineSuggestion, outingName: ui.outingName)
                .presentationDetents([.large])
        case .weather:
            WeatherSheet(weather: controller.weather, close: { controller.modal = nil },
                         changeDestination: controller.session.view?.iLead == true ? { controller.changeDestinationFromWeather() } : nil,
                         destinationNote: controller.planModel?.destinationLocalOnly == true ? LocalDestinationCopy.note : nil)
                .presentationDetents([.large])
        case .qibla:
            QiblaView(fallback: controller.location.lastFix.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) },
                      close: { controller.modal = nil })
                .presentationDetents([.large])
        case let .weatherAt(point):
            WeatherPointSheet(point: point, close: { controller.modal = nil })
                .presentationDetents([.medium, .large])
        case .trailAlways:
            TrailAlwaysExplainer(allow: controller.allowAlways, later: controller.laterAlways)
                .presentationDetents([.large])
                .interactiveDismissDisabled()
        case let .plan(m):
            LivePlanModalView(controller: controller, modal: m)
        case .shareAlways:
            ShareAlwaysExplainer(allow: controller.allowShareAlways, later: controller.laterShareAlways, afterJoin: controller.shareAlwaysAfterJoin)
                .presentationDetents([.large])
                .interactiveDismissDisabled()
        case .navPicker:
            NavTargetPicker(rows: controller.navPickerRows,
                            pick: { t in controller.modal = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { controller.navigate(to: t) } },
                            refused: { _ in },
                            close: { controller.modal = nil })
        case .navOptions:
            NavOptionsSheet(nav: controller.nav, start: controller.startNav, cancel: { controller.modal = nil },
                            openExternally: controller.openExternally)
        case .navStartChoice:
            NavStartChoiceSheet(target: controller.autoNavNextTarget?.name ?? controller.tripDestination?.name ?? "الوجهة",
                                forAll: controller.startGuidanceForAll, onlyMe: controller.startGuidanceForMe,
                                later: { controller.modal = nil })
        case .navSteps:
            NavStepsSheet(nav: controller.nav, close: { controller.modal = nil })
        case .whereTo:
            WhereToSheet(controller: controller)
        case .pttChannels:
            PTTChannelSheet(walkie: controller.session.walkie,
                            members: (controller.session.displayView?.orderedMembers ?? []).map { PTTChannelSheet.Person(id: $0.user_id, name: $0.display_name) },
                            me: controller.session.myUserId,
                            close: { controller.modal = nil })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        case .campSuggest:
            CampSuggestSheet(controller: controller)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        case let .campSite(id):
            CampSiteTappedSheet(controller: controller, siteId: id)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        case let .desertRoute(target, name, rain, weatherAvailable):
            DesertRouteSheet(controller: controller, target: target, name: name, rain: rain, weatherAvailable: weatherAvailable)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        case .layers:
            ExploreLayersSheet(controller: controller)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        case .places:
            PlacesAndTracksSheet(controller: controller, part: .places)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        case let .placeEdit(d):
            SavedPlaceEditSheet(draft: d, done: { controller.savePlace($0) }, cancel: { controller.modal = nil })
                .presentationDetents([.large])
        case .convoyAlerts:
            ConvoyAlertSettingsView(close: { controller.modal = nil })
                .presentationDetents([.large])
        case let .enjad(situation):
            EnjadSheet(input: controller.enjadInput(situation), online: controller.followOnline,
                       addPhone: { controller.modal = nil; controller.actions.participantsTab.addMyPhone() },
                       close: { controller.modal = nil })
                .presentationDetents([.large])
        case .tracks:
            PlacesAndTracksSheet(controller: controller, part: .tracks)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        case let .panel(p):
            LivePanelView(controller: controller, panel: p, close: { controller.modal = nil })
                .presentationDetents(p == .rally || p == .phone ? [.medium, .large] : [.large])
                .presentationDragIndicator(.visible)
        }
    }

    /// «المزيد» → «الطلعة»: pause / end for the leader, leave for everyone, the settings.
    private var tripRows: LiveTripRows {
        let s = ui.settingsTab
        let a = controller.actions.settingsTab
        let running = s.outingStatus != .ended
        return LiveTripRows(canPause: s.isLeader && running && s.outingStatus != .notStarted,
                            paused: s.outingStatus == .paused,
                            canEnd: s.isLeader && running,
                            canLeave: controller.session.closedReason == nil,
                            pauseOrResume: a.pauseOrResumeOuting, end: a.endOuting, leave: a.leaveOuting,
                            settings: { controller.openSettings() })
    }
}

private struct ShareURL: Identifiable { let url: URL; var id: String { url.absoluteString } }

extension IncomingSOSUI: @retroactive Hashable {
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - The quick row

/// The sheet's key actions while stopped, right under the summary line (UI-AUDIT م3, four):
/// «البر» (camp sites, desert routes, the Qibla, the weather), the chat, the rally point and
/// «المزيد» (everything else). No accent here: the state's one primary is the CTA over the map.
struct LiveQuickRow: View {
    @ObservedObject var controller: LiveOutingController
    /// A rally point is set (the sheet's presenter state says it; no presenter pass here).
    var hasRally: Bool
    @Environment(\.sary) private var theme

    var body: some View {
        let s = controller.actionState
        HStack(alignment: .top, spacing: 4) {
            ForEach(Array(LiveScreenRules.quickRow(chat: s.chat).enumerated()), id: \.element) { index, id in
                Group {
                switch id {
                case "desert": desertMenu
                case "chat":
                    item("المحادثة", icon: "bubble.left.and.bubble.right.fill", id: "sheet.chat", badge: controller.chat.totalUnread) {
                        controller.performAction("chat")
                    }
                case "rally":
                    item("التجمع", icon: SaryIcon.rally, id: "sheet.rally", active: hasRally) {
                        controller.performAction("rally")
                    }
                default:
                    item("المزيد", icon: "ellipsis", id: "outing-actions", badge: controller.safety.myStuck != nil ? 1 : 0) {
                        controller.modal = .actions
                    }
                }
                }
                /* The row arrives (trip started, guidance ended): the actions in turn, once. */
                .liveStaggerIn(index)
            }
        }
        .padding(.horizontal, theme.space(.m))
        /* Captions of round buttons in the fixed-height peek (`SheetDetentUI.peekHeight`), not body
         * text: uncapped they grew taller than the peek and were cut off at accessibility sizes. */
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sheet.quickRow")
    }

    /// «البر» (UI-AUDIT م6): what makes Sary Albarq different, one tap away instead of six.
    private var desertMenu: some View {
        Menu {
            Button { controller.performAction("camp") } label: { Label("اقترح لي مكان كشتة", systemImage: "tent.fill") }
                .accessibilityIdentifier("desert.camp")
            Button { controller.performAction("desertRoute") } label: { Label("دروب البر", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                .accessibilityIdentifier("desert.routes")
            Button { controller.performAction("qibla") } label: { Label("القبلة", systemImage: "location.north.circle") }
                .accessibilityIdentifier("desert.qibla")
            Button { controller.performAction("weather") } label: { Label("الطقس", systemImage: "sun.max") }
                .accessibilityIdentifier("desert.weather")
        } label: {
            itemLabel("البر", icon: "tent.2.fill")
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("البر"))
        .accessibilityHint(Text("الكشتة، دروب البر، القبلة، الطقس"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("sheet.desert")
    }

    /// The menu's label: the same circle and caption as `item` (no badge, never active).
    private func itemLabel(_ title: String, icon: String) -> some View {
        let p = theme.palette
        let size: CGFloat = theme.drive ? 54 : 46
        return VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: theme.drive ? 20 : 17, weight: .semibold))
                .foregroundStyle(p.accentText)
                .frame(width: size, height: size)
                .background(Circle().fill(p.sunken))
            Text(title).font(.sary(11, .bold)).foregroundStyle(p.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private func item(_ title: String, icon: String, id: String, accent: Bool = false, active: Bool = false, disabled: Bool = false,
                      badge: Int = 0, hint: String? = nil, run: @escaping () -> Void) -> some View {
        let p = theme.palette
        let size: CGFloat = theme.drive ? 54 : 46
        return Button(action: run) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: theme.drive ? 20 : 17, weight: .semibold))
                    .foregroundStyle(accent || active ? p.onAccent : p.accentText)
                    .frame(width: size, height: size)
                    .background(Circle().fill(accent ? p.accent : active ? p.accent.opacity(0.85) : p.sunken))
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text(SaryFormat.number(badge)).saryNumber(.micro, weight: .heavy).foregroundStyle(p.onEmergency)
                                .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                                .background(Capsule().fill(p.emergency))
                                .saryBadgeOutset(trailing: 4, top: 2)
                        }
                    }
                Text(title).font(.sary(11, .bold)).foregroundStyle(p.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .opacity(disabled ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(SaryPressStyle())
        .disabled(disabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(badge > 0 ? "\(title)، \(SaryFormat.number(badge))" : title))
        .accessibilityHint(Text(hint ?? ""))
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(id)
    }
}

// MARK: - The raised sheet

/// Pulled up: only what needs attention (the trip not started yet / paused / ended, iOS
/// location off), the people, the invite, the convoy and shared points when there are any.
private struct LiveSheetBody: View {
    @ObservedObject var controller: LiveOutingController
    var ui: LiveOutingUIState
    @ObservedObject private var features: OutingFeaturesModel
    @Environment(\.sary) private var theme

    init(controller: LiveOutingController, ui: LiveOutingUIState) {
        self.controller = controller
        self.ui = ui
        features = controller.features
    }

    private var arrivedOrOver: Bool {
        if controller.tripEnded { return true }
        if case .arrived = controller.tripPanel.phase { return true }
        return false
    }

    /// UI-AUDIT م3: the trip card is the «الوجهة والخطة» panel's (the header opens it); the sheet
    /// keeps it only after the end, for «طلعة الرجعة» (the summary is the end card's «اعرض الملخص»).
    private var shouldShowTripCard: Bool {
        controller.showsTripStrip && controller.tripEnded
    }

    var body: some View {
        let actions = controller.actions
        Group {
            TripStatusCallout(controller: controller, ui: ui)
            if shouldShowTripCard {
                TripCard(ui: controller.tripPanel, actions: controller.tripActions)
            }
            VStack(spacing: 0) {
                let list = ui.participantsTab.participants
                ForEach(list) { p in
                    SaryParticipantRow(participant: p, now: ui.now) { actions.participantsTab.openParticipant(p.id) }
                        .accessibilityIdentifier("participant-row")
                    if p.id != list.last?.id { SaryDivider().padding(.leading, 60) }
                }
                if ui.status != .ended, controller.session.closedReason == nil {
                    SaryDivider()
                    Button { controller.modal = .panel(.invite) } label: {
                        HStack(spacing: theme.space(.m)) {
                            SaryRowIcon(systemImage: "person.badge.plus", color: theme.palette.accent)
                            Text("ادعُ أصدقاءك").saryText(.body, weight: .bold).foregroundStyle(theme.palette.accentText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, theme.space(.m))
                        .frame(minHeight: theme.minTarget + 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SaryRowPressStyle())
                    .accessibilityIdentifier("sheet.invite")
                }
            }
            .padding(.vertical, theme.space(.xs))
            /* The people re-order (nearest first, who went quiet) in place: the rows keep their ids. */
            .animation(theme.animation(LiveMotion.reorder(drive: theme.drive)), value: ui.participantsTab.participants.map(\.id))
            .sarySurface(radius: SaryRadius.l)
            ConvoySection(controller: controller, features: features, participants: ui.participantsTab.participants)
            // Keep the section available for the first waypoint and show the honest
            // unavailable state when the server has not deployed its routes.
            if !features.waypoints.isEmpty || features.phase != .loading {
                WaypointsSection(controller: controller, features: features)
            }
        }
    }
}

/// The outing's state, only when it needs saying (an active trip that shares says nothing:
/// the dot in the header already does). The «دائمًا» hint at most once, closable.
private struct TripStatusCallout: View {
    @ObservedObject var controller: LiveOutingController
    var ui: LiveOutingUIState
    @Environment(\.sary) private var theme
    @AppStorage("sary.live.shareHint.dismissed.v1") private var hintDismissed = false

    var body: some View {
        if let r = controller.session.closedReason {
            SaryBanner(text: closedText(r), tone: .warning, systemImage: SaryIcon.warning)
        } else {
            switch ui.status {
            case .notStarted:
                /* UI-AUDIT م3: nothing here — «ابدأ الطلعة» (or the member's «ننتظر أمير الطلعة») is the
                 * one CTA over the map; the header says «ما بدأت الطلعة». The sheet is the people and
                 * «ادعُ أصدقاءك». */
                EmptyView()
            case .paused:
                SaryBanner(text: "الطلعة متوقفة مؤقتًا. لا أحد يشارك موقعه الآن.", tone: .warning, systemImage: SaryIcon.pause)
            case .ended:
                SaryBanner(text: "انتهت هذه الطلعة.", tone: .info)
            case .active:
                if controller.locationDenied {
                    ShareBackgroundHintRow(hint: .denied, openSettings: controller.openAppSettings)
                } else {
                    /* One quiet line (was a strip with «أخفِ موقعي» and «غادر الطلعة»: those are in the
                     * quick row and «المزيد» now). */
                    let hidden = controller.isLocationHidden
                    HStack(spacing: theme.space(.s)) {
                        Circle().fill(hidden ? theme.palette.textTertiary : ui.sharing == .sharing ? theme.palette.live : theme.palette.warning).frame(width: 8, height: 8)
                        Text(hidden ? HideText.hiddenStrip : ui.sharing == .sharing ? "موقعك مُشارَك مع الطلعة" : "جارٍ تحديد موقعك…")
                            .saryText(.footnote, weight: .bold)
                            .foregroundStyle(theme.palette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("live.sharing")
                    }
                    .padding(.horizontal, theme.space(.xs))
                }
                if !controller.locationDenied, let hint = controller.shareBackgroundHint, !hintDismissed {
                    HStack(spacing: 0) {
                        ShareBackgroundHintRow(hint: hint, openSettings: controller.openAppSettings)
                        Button { hintDismissed = true } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.palette.textTertiary)
                                .frame(width: theme.minTarget, height: theme.minTarget).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("أخفِ"))
                        .accessibilityIdentifier("live.shareHint.close")
                    }
                    .sarySurface(radius: SaryRadius.m)
                }
            }
        }
    }

    private func closedText(_ r: LiveCloseReason) -> String {
        switch r {
        case .outingEnded: return "انتهت هذه الطلعة."
        case .removed: return "أزالك أمير الطلعة منها."
        case .left: return "غادرت هذه الطلعة."
        case .notAMember: return "لست عضوًا في هذه الطلعة."
        case .unauthorized: return "انتهت جلستك على هذا الجهاز."
        case .replaced: return "فتحت الطلعة من جهاز آخر."
        }
    }
}

// MARK: - Panels («المزيد» and the quick row open these)

/// One focused part of the trip in its own sheet (what used to be stacked in the tabs).
struct LivePanelView: View {
    @ObservedObject var controller: LiveOutingController
    var panel: LivePanel
    var close: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let ui = controller.ui
        VStack(spacing: 0) {
            HStack {
                Text(panel.title).font(.sary(18, .bold)).foregroundStyle(p.textPrimary).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) {
                    Image(systemName: SaryIcon.close).font(.system(size: 14, weight: .bold)).foregroundStyle(p.textSecondary)
                        .frame(width: 36, height: 36).background(Circle().fill(p.sunken))
                        .frame(width: theme.minTarget, height: theme.minTarget).contentShape(Rectangle())
                }
                .buttonStyle(SaryPressStyle())
                .accessibilityLabel(Text("إغلاق"))
                .accessibilityIdentifier("panel.close")
            }
            .padding(.horizontal, theme.space(.l))
            .padding(.top, theme.space(.l))
            .padding(.bottom, theme.space(.s))
            ScrollView {
                VStack(spacing: theme.space(.m)) {
                    switch panel {
                    case .route: route(ui)
                    case .safety: SafetySection(safety: controller.safety, now: ui.now, outingActive: ui.status == .active)
                    case .rally:
                        SaryRallyCard(rally: ui.participantsTab.rally, canManage: controller.session.view?.iLead == true, actions: rallyActions)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("rally-card")
                    case .invite:
                        LivePersonalInvites(session: controller.session) { InviteTab(controller: controller, ui: ui) }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("invite-section")
                    case .phone: PhonePanel(controller: controller, done: close)
                    }
                }
                .padding(.horizontal, theme.space(.l))
                .padding(.bottom, theme.space(.xl))
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel.\(panel.rawValue)")
    }

    @ViewBuilder
    private func route(_ ui: LiveOutingUIState) -> some View {
        if controller.showsTripStrip, ui.status != .notStarted {
            TripCard(ui: controller.tripPanel, actions: controller.tripActions)
        }
        /* «سجل الطلعة»: the legs so far (and a quiet «غيّر الوجهة» while one is picked). */
        if ui.status != .notStarted, !controller.legs.timeline.isEmpty || controller.legPicked != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("سجل الطلعة").saryText(.footnote, weight: .bold).foregroundStyle(theme.palette.textSecondary)
                if !controller.legs.timeline.isEmpty { OutingLegTimeline(legs: controller.legs.timeline, now: ui.now) }
                if let d = controller.legPicked {
                    Button { controller.flowTapped(.changeDestination) } label: {
                        Label("الوجهة \(d.name) · غيّر", systemImage: "arrow.triangle.swap").saryText(.footnote, weight: .bold)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("flow.changeDestination")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sarySurface(radius: SaryRadius.m)
        }
        TripPlanCard(controller: controller)
    }

    /// The rally card's map actions close this sheet first (the map is where they happen).
    private var rallyActions: ParticipantsTabActions {
        var a = controller.actions.participantsTab
        let onMap: (@escaping () -> Void) -> () -> Void = { f in
            { [weak controller] in
                controller?.modal = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: f)
            }
        }
        a.rallyShow = onMap(a.rallyShow)
        a.rallyGo = onMap(a.rallyGo)
        a.rallyMove = onMap(a.rallyMove)
        a.rallyCreate = onMap(a.rallyCreate)
        return a
    }
}

/// «رقم جوالي»: shown to the members of my outings only (call / WhatsApp). Was a form in the trip tab.
private struct PhonePanel: View {
    @ObservedObject var controller: LiveOutingController
    var done: () -> Void
    @Environment(\.sary) private var theme
    @State private var phone = ""

    var body: some View {
        let a = controller.actions.settingsTab
        SarySection(title: nil, footer: "يظهر لأصدقائك في طلعاتك فقط، ليتصلوا بك أو يراسلوك واتساب. تقدر تغيّره من «ملفي» أيضًا.") {
            VStack(spacing: theme.space(.s)) {
                SaryTextField(title: "رقم الجوال", placeholder: "05XXXXXXXX", text: $phone, id: "settings-phone", keyboard: .phonePad, maxLength: 14)
                Button { a.saveMyPhone(phone.isEmpty ? nil : phone); done() } label: { SaryButtonLabel(title: "حفظ", systemImage: SaryIcon.check) }
                    .buttonStyle(.saryPrimary)
                    .disabled(!phone.isEmpty && SaryFormat.normalizeSaudiMobile(phone) == nil)
                    .accessibilityIdentifier("settings-phone-save")
            }
            .padding(theme.space(.m))
        }
        .onAppear { phone = controller.ui.settingsTab.myPhone ?? "" }
    }
}

/// «مساري» in the settings tab: recording, the screen-locked trail, friends' trails, clear.
struct TrailSettingsSection: View {
    @ObservedObject var controller: LiveOutingController
    var card: TrailCardUIState
    @Environment(\.sary) private var theme
    @State private var confirmClear = false

    var body: some View {
        let p = theme.palette
        SarySection(title: "مساري", footer: "مسارك محفوظ على جوالك وما نرسله للأصدقاء ولا لخوادمنا. مع «طابق مساري مع الطرق» تُرسل أجزاء منه لمزوّد الخرائط فقط لرسمه على الشوارع. يُمسح مع تسجيل الخروج أو حذف الحساب.") {
            SaryToggleRow(title: "سجّل مساري", subtitle: "لتشوف من وين جيت وترجع منه", systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill",
                          isOn: Binding(get: { card.recordingOn }, set: { controller.setTrailRecording($0) }), id: "trail.record")
            SaryDivider()
            SaryToggleRow(title: "سجّل مساري والشاشة مقفلة", subtitle: backgroundSubtitle, systemImage: "lock.fill",
                          isOn: Binding(get: { card.backgroundOn }, set: { controller.setBackgroundTrail($0) }), id: "trail.background")
                .disabled(!card.recordingOn)
            if card.recordingOn && card.backgroundOn && !card.backgroundAllowed {
                VStack(alignment: .leading, spacing: theme.space(.xs)) {
                    Text("إذن الموقع مقفل، فما نقدر نسجّل والشاشة مقفلة. الإعدادات ← سَرى البارق ← الموقع ← «دائمًا» أو «أثناء الاستخدام».")
                        .saryText(.caption).foregroundStyle(p.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("افتح الإعدادات", action: controller.openAppSettings)
                        .buttonStyle(.sary(.secondary, width: .hug, compact: true))
                        .accessibilityIdentifier("trail.openSettings")
                }
                .padding(.bottom, theme.space(.s))
            }
            SaryDivider()
            SaryToggleRow(title: "طابق مساري مع الطرق", subtitle: "يرسمه على الشوارع اللي مشيت فيها · في البر يبقى مثل ما سجّله الجوال", systemImage: "road.lanes",
                          isOn: Binding(get: { card.matchOn }, set: { controller.setTrailMatching($0) }), id: "trail.match")
                .disabled(!card.recordingOn)
            SaryDivider()
            SaryToggleRow(title: "أظهر مسارات الأصدقاء", subtitle: "آخر ٣٠ دقيقة، من مواقعهم اللي وصلتك الآن", systemImage: SaryIcon.fitGroup,
                          isOn: Binding(get: { controller.showFriendTrails }, set: { controller.showFriendTrails = $0 }), id: "trail.friends")
            /* Moved from the trip tab: the recording's accuracy and the GPS warnings, where the recording is set. */
            if let h = card.health {
                SaryDivider()
                VStack(alignment: .leading, spacing: theme.space(.xs)) {
                    Text(h.line).saryNumber(.caption).foregroundStyle(p.textSecondary)
                        .accessibilityIdentifier("trail.health")
                    ForEach(h.warnings, id: \.self) { w in
                        Text(w).saryText(.caption).foregroundStyle(p.warningText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if h.preciseOff {
                        Button("فعّل الموقع الدقيق", action: controller.openAppSettings)
                            .buttonStyle(.sary(.secondary, width: .hug, compact: true))
                            .accessibilityIdentifier("trail.precise")
                    }
                    if card.gapCount > 0 {
                        Text("الخط المتقطع جزء ما وصلتنا فيه أي نقطة موقع لأكثر من دقيقة؛ نرسمه على الشارع إذا عرفناه، وإلا مستقيمًا.")
                            .saryText(.caption).foregroundStyle(p.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, theme.space(.s))
            }
            SaryDivider()
            Button { confirmClear = true } label: {
                HStack(spacing: theme.space(.m)) {
                    SaryRowIcon(systemImage: "trash", color: p.emergency)
                    Text("امسح مساري لهذه الطلعة").saryText(.body, weight: .bold).foregroundStyle(p.emergency)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: theme.minTarget + 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(card.pointCount == 0)
            .accessibilityIdentifier("trail.clear")
        }
        .confirmationDialog("امسح مسارك؟", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("امسح مساري", role: .destructive, action: controller.clearTrail)
            Button("إلغاء", role: .cancel) {}
        } message: { Text("ينمسح مسارك لهذه الطلعة من جوالك، وما تقدر ترجعه. «طريق الرجعة» يبدأ من جديد.") }
    }

    private var backgroundSubtitle: String {
        if !card.backgroundOn { return "متوقف: يُسجَّل والتطبيق مفتوح فقط" }
        if !card.backgroundAllowed { return "يحتاج إذن الموقع من iOS" }
        return card.recordingInBackground ? "يُسجَّل الآن والشاشة مقفلة" : "على جوالك فقط · يستهلك بطارية أكثر"
    }
}

/// Before iOS asks for «دائمًا»: what it is for, honestly.
struct TrailAlwaysExplainer: View {
    var allow: () -> Void
    var later: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(.l)) {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space(.l)) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill").font(.system(size: 48)).foregroundStyle(theme.palette.accent)
                    Text("سجّل مسارك حتى والشاشة مقفلة").saryText(.title2).foregroundStyle(theme.palette.textPrimary)
                    Text("عشان «طريق الرجعة» يرجّعك من نفس الطريق اللي دخلت منه، حتى لو قفلت الشاشة وأنت تسوق.")
                        .saryText(.body).foregroundStyle(theme.palette.textSecondary)
                    bullet("iphone", "المسار يبقى على جوالك فقط. ما نرسله لأحد، ولا حتى للخادم.")
                    bullet("person.2.fill", "نفس الإذن يخلّي مشاركة موقعك مع أصدقاء الطلعة تستمر والشاشة مقفلة.")
                    bullet("location.fill", "يظهر مؤشر الموقع الأزرق أعلى الشاشة وقت التسجيل.")
                    bullet("battery.50percent", "يستهلك بطارية أكثر. يتوقف لحاله إذا انتهت الطلعة أو غادرتها، وتقدر توقفه من الإعدادات.")
                    Text("بيسألك iOS: اختر «تغيير إلى السماح دائمًا».")
                        .saryText(.footnote, weight: .bold).foregroundStyle(theme.palette.textPrimary)
                }
            }
            Button(action: allow) { SaryButtonLabel(title: "تمام، اسمح دائمًا", systemImage: SaryIcon.check) }
                .buttonStyle(.saryPrimary)
                .accessibilityIdentifier("trail.always.allow")
            Button("لاحقًا، والتطبيق مفتوح فقط", action: later).buttonStyle(.saryPlain)
                .accessibilityIdentifier("trail.always.later")
        }
        .padding(theme.space(.l))
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: theme.space(.m)) {
            Image(systemName: icon).foregroundStyle(theme.palette.accentText).frame(width: 24)
            Text(text).saryText(.body).foregroundStyle(theme.palette.textPrimary)
        }
    }
}

/// The persistent one-liner under «موقعك مُشارَك»: with «أثناء الاستخدام» it is a link to
/// Settings (choose «دائمًا»); with «دائمًا» a gentle note not to swipe the app away.
struct ShareBackgroundHintRow: View {
    var hint: ShareBackgroundHint
    var openSettings: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        if hint == .needsAlways || hint == .denied {
            Button(action: openSettings) { row(link: true) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("live.shareHint.settings")
                .accessibilityHint("يفتح إعدادات سَرى البارق")
        } else {
            row(link: false).accessibilityIdentifier("live.shareHint")
        }
    }

    private func row(link: Bool) -> some View {
        HStack(spacing: theme.space(.s)) {
            Image(systemName: hint.systemImage).foregroundStyle(link ? theme.palette.warning : theme.palette.accentText).frame(width: 20)
            Text(hint.text).saryText(.footnote).foregroundStyle(theme.palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if link { Image(systemName: SaryIcon.disclosure).font(.footnote.weight(.bold)).foregroundStyle(theme.palette.textTertiary) }
        }
        .padding(.horizontal, theme.space(.m))
        .padding(.vertical, theme.space(.s))
        .contentShape(Rectangle())
    }
}

/// For someone who consented before sharing kept going off screen: say so, then ask iOS for «دائمًا».
struct ShareAlwaysExplainer: View {
    var allow: () -> Void
    var later: () -> Void
    /// Shown right after «انضم» (before anything stopped), not on the way back.
    var afterJoin = false
    @Environment(\.sary) private var theme

    static let afterJoinTitle = "خلّ الأصدقاء يشوفونك طول الطلعة"
    static let afterJoinBody = "عشان يوصل موقعك للأصدقاء من الحين لين تخلص الطلعة — حتى لو قفلت الجوال أو فتحت تطبيق ثاني أو كنت على CarPlay — اسمح بالموقع «دائمًا». ما نرسل موقعك إلا وأنت في طلعة، ويوقف أول ما تخلص أو تطلع منها."

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(.l)) {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space(.l)) {
                    Image(systemName: "lock.iphone").font(.system(size: 48)).foregroundStyle(theme.palette.accent)
                    Text(afterJoin ? Self.afterJoinTitle : "المشاركة تستمر والشاشة مقفلة").saryText(.title2).foregroundStyle(theme.palette.textPrimary)
                    Text(afterJoin ? Self.afterJoinBody : "لما طلعت من التطبيق توقف إرسال موقعك للأصدقاء. اسمح «دائمًا» عشان يشوفونك وأنت تسوق، حتى لو قفلت الشاشة أو فتحت تطبيقًا ثانيًا أو كنت على CarPlay.")
                        .saryText(.body).foregroundStyle(theme.palette.textSecondary)
                    ShareAlwaysBullets()
                    Text("بيسألك iOS: اختر «تغيير إلى السماح دائمًا».")
                        .saryText(.footnote, weight: .bold).foregroundStyle(theme.palette.textPrimary)
                }
            }
            Button(action: allow) { SaryButtonLabel(title: "تمام، اسمح دائمًا", systemImage: SaryIcon.check) }
                .buttonStyle(.saryPrimary)
                .accessibilityIdentifier("share.always.allow")
            Button("لاحقًا، والتطبيق مفتوح فقط", action: later).buttonStyle(.saryPlain)
                .accessibilityIdentifier("share.always.later")
        }
        .padding(theme.space(.l))
    }
}

/// The facts on the «دائمًا» explainer.
struct ShareAlwaysBullets: View {
    @Environment(\.sary) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(.l)) {
            bullet("lock.iphone", "تستمر المشاركة في الخلفية والشاشة مقفلة، حتى تغادر الطلعة أو تنتهي.")
            bullet("location.fill", "يظهر مؤشر الموقع الأزرق أعلى الشاشة ما دامت المشاركة شغالة.")
            bullet("gearshape.fill", "تحتاج إذن «دائمًا». إذا اخترت «أثناء الاستخدام» فقط، تتوقف المشاركة إذا قفلت الشاشة.")
            bullet("xmark.app", "لا تقفل التطبيق من قائمة التطبيقات أثناء الطلعة: iOS قد لا يعيد فتحه، فتتوقف المشاركة.")
            bullet("battery.50percent", "يستهلك بطارية أكثر؛ يخفف الدقة وأنت واقف، ويقل التكرار في وضع توفير الطاقة.")
        }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: theme.space(.m)) {
            Image(systemName: icon).foregroundStyle(theme.palette.accentText).frame(width: 24)
            Text(text).saryText(.body).foregroundStyle(theme.palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Invite tab

private struct InviteTab: View {
    @ObservedObject var controller: LiveOutingController
    var ui: LiveOutingUIState
    @Environment(\.sary) private var theme
    @State private var confirmRevoke = false
    @State private var copied = false

    var body: some View {
        let s = ui.inviteTab
        let actions = controller.actions.inviteTab
        VStack(spacing: theme.space(.m)) {
            if let link = s.link {
                SaryQRCode(text: link, size: theme.drive ? 200 : 170)
                    .accessibilityIdentifier("invite-qr")
                Text(link.replacingOccurrences(of: "https://", with: ""))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .environment(\.layoutDirection, .leftToRight)
                    .textSelection(.enabled)
                HStack(spacing: theme.space(.s)) {
                    Button {
                        actions.copyLink()
                        copied = true
                        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                    } label: { SaryButtonLabel(title: copied ? "نسخناه" : "نسخ", systemImage: copied ? SaryIcon.check : SaryIcon.copy) }
                        .buttonStyle(.sarySecondary)
                        .accessibilityIdentifier("invite-copy")
                    Button(action: actions.shareLink) { SaryButtonLabel(title: "مشاركة", systemImage: SaryIcon.share) }
                        .buttonStyle(.saryPrimary)
                        .accessibilityIdentifier("invite-share")
                }
                Text("الرابط يدخل أي شخص يفتحه إلى الطلعة. شاركه مع أصدقاءك فقط.")
                    .saryText(.footnote)
                    .foregroundStyle(theme.palette.textSecondary)
                    .multilineTextAlignment(.center)
            } else if s.canRevoke {
                SaryStateView(kind: .empty(title: "ما فيه رابط على هذا الجوال",
                                           message: "الخادم لا يحفظ الروابط. أنشئ رابطًا جديدًا، وأي رابط قديم يتوقف.", systemImage: "link"))
            } else {
                SaryStateView(kind: .empty(title: "اطلب الرابط من أمير الطلعة", message: "الرابط عند من أنشأه فقط.", systemImage: "link"))
            }
            if s.canRevoke {
                Button { if s.link == nil { actions.revokeLink() } else { confirmRevoke = true } } label: {
                    SaryButtonLabel(title: s.link == nil ? "أنشئ رابطًا" : "إلغاء الرابط وإنشاء جديد", systemImage: "arrow.triangle.2.circlepath",
                                    busy: s.isRevoking, busyTitle: "جارٍ الإنشاء…")
                }
                .buttonStyle(.sary(s.link == nil ? .primary : .plainDestructive))
                .disabled(s.isRevoking)
                .accessibilityIdentifier("invite-revoke")
            }
        }
        .padding(theme.space(.l))
        .sarySurface(radius: SaryRadius.l)
        .confirmationDialog("رابط جديد؟", isPresented: $confirmRevoke, titleVisibility: .visible) {
            Button("ألغِ القديم وأنشئ جديدًا", role: .destructive, action: actions.revokeLink)
            Button("إلغاء", role: .cancel) {}
        } message: { Text("الرابط القديم يتوقف فورًا، ومن انضم يبقى في الطلعة.") }
    }
}

// MARK: - Note composer («رسالة»)

struct NoteComposer: View {
    var state: NoteComposerUIState
    var actions: NoteComposerActions
    @Environment(\.sary) private var theme
    @State private var text = ""

    var body: some View {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: theme.space(.m)) {
            Text("رسالة فوق سيارتك").saryText(.title2).foregroundStyle(theme.palette.textPrimary)
            Text("يشوفها الأصدقاء فوق سيارتك ١٥ دقيقة.").saryText(.footnote).foregroundStyle(theme.palette.textSecondary)
            SaryTextField(title: "الرسالة", placeholder: "مثل: بوقف عند المحطة", text: $text, id: "note-input", maxLength: state.maxLength)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: theme.space(.s)) {
                    ForEach(state.presets, id: \.self) { p in
                        Button(p) { text = p }.buttonStyle(.sary(.secondary, width: .hug, compact: true))
                    }
                }
            }
            if let e = state.errorMessage { SaryInlineMessage(text: e, tone: .error) }
            Button { actions.send(clean) } label: { SaryButtonLabel(title: "أرسل", systemImage: SaryIcon.send, busy: state.isSending, busyTitle: "جارٍ الإرسال…") }
                .buttonStyle(.saryPrimary)
                .disabled(clean.isEmpty || clean.count > state.maxLength || state.isSending)
                .accessibilityIdentifier("note-send")
            if let cur = state.currentNote {
                Button(role: .destructive, action: actions.clearNote) { SaryButtonLabel(title: "احذف رسالتي «\(cur)»", systemImage: "trash") }
                    .buttonStyle(.sary(.plainDestructive))
            }
            Button("إلغاء", action: actions.cancel).buttonStyle(.saryPlain)
        }
        .padding(theme.space(.l))
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Nearest stations

struct NearestStationsView: View {
    var state: NearestStationsUIState
    var actions: NearestStationsActions
    @Environment(\.sary) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(.m)) {
            HStack {
                Text("أقرب محطة").saryText(.title2).foregroundStyle(theme.palette.textPrimary)
                Spacer()
                SaryIconButton(systemImage: SaryIcon.close, label: "إغلاق", action: actions.close)
            }
            switch state.phase {
            case .loading:
                SaryStateView(kind: .loading("جارٍ البحث عن أقرب محطة…"))
            case .empty:
                SaryStateView(kind: .empty(title: "ما فيه محطة مسجّلة قريبة", message: "لا نخمّن مكانها.", systemImage: SaryIcon.nearest))
            case let .error(msg):
                SaryStateView(kind: .error(title: "تعذّر التحميل", message: msg), actionTitle: "حاول مرة ثانية", action: actions.retry)
            case let .loaded(rows):
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { s in
                            SaryStationRow(station: s, go: { actions.go(s.id) }, show: { actions.show(s.id) })
                            if s.id != rows.last?.id { SaryDivider() }
                        }
                    }
                    .padding(.horizontal, theme.space(.l))
                    .sarySurface(radius: SaryRadius.l)
                }
            }
            /* ODbL: the attribution must stay readable (secondary, also at night). */
            Text("© OpenStreetMap contributors · ODbL").saryText(.micro).foregroundStyle(theme.palette.textSecondary)
                .environment(\.layoutDirection, .leftToRight)
        }
        .padding(theme.space(.l))
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier("stations")
    }
}

// MARK: - Rally label

private struct RallyLabelView: View {
    var moving: Bool
    var save: (String) -> Void
    var cancel: () -> Void
    @Environment(\.sary) private var theme
    @State private var label = ""

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(.m)) {
            Text(moving ? "نقل نقطة التجمع" : "نقطة تجمع جديدة").saryText(.title2).foregroundStyle(theme.palette.textPrimary)
            SaryTextField(title: "اسم النقطة (اختياري)", placeholder: "مثل: عند الطعس الكبير", text: $label, id: "rally-label", maxLength: 40)
            Button { save(label) } label: { SaryButtonLabel(title: moving ? "انقلها هنا" : "حددها هنا", systemImage: SaryIcon.rally) }
                .buttonStyle(.saryPrimary)
                .accessibilityIdentifier("rally-save")
            Button("إلغاء", action: cancel).buttonStyle(.saryPlain)
        }
        .padding(theme.space(.l))
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - «قناة الطلعة» diagnostics

/// The live link in one line, and «سجل القناة» to share with whoever is fixing it.
struct PTTLinkRow: View {
    var line: String
    @Environment(\.sary) private var theme
    @State private var file: URL?

    var body: some View {
        HStack(spacing: theme.space(.m)) {
            SaryRowIcon(systemImage: "antenna.radiowaves.left.and.right")
            Text(line)
                .saryText(.footnote)
                .foregroundStyle(theme.palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("settings-ptt-link")
            Button {
                file = PTTDiagnosticsLog.shared.exportFile()
            } label: {
                Label("سجل القناة", systemImage: "square.and.arrow.up")
                    .saryText(.footnote, weight: .medium)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("settings-ptt-log")
        }
        .padding(.horizontal, theme.space(.m))
        .padding(.vertical, theme.space(.s))
        .sheet(item: Binding(get: { file.map(ShareFile.init) }, set: { file = $0?.url })) { f in
            ShareSheet(items: [f.url])
        }
    }

    struct ShareFile: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }
}

/// Lovable's settings slide in like a pushed page (the cover itself appears without animation) and
/// slide back out before it closes.
struct SettingsPushHost<Page: View>: View {
    @ViewBuilder var page: (_ close: @escaping () -> Void) -> Page
    @State private var shown = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sary) private var theme

    var body: some View {
        GeometryReader { g in
            page { close() }
                .offset(x: shown ? 0 : -g.size.width)
                .onAppear { withAnimation(theme.animation(.smooth)) { shown = true } }
        }
        .background(Color.clear)
        .presentationBackground(.clear)
    }

    private func close() {
        withAnimation(theme.animation(.smooth)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { dismiss() }
        }
    }
}
