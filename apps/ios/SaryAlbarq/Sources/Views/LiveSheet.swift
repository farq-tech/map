import SwiftUI

/// The native 3-detent sheet: ONE summary line, then the tabs الرحلة / المجموعة /
/// المزيد (docs/IA-REDESIGN.md §2.4). Everything presented over the live screen (participant card,
/// note composer, stations, consent, rally label, a friend's SOS) is presented
/// from here, because the sheet is the top-most presentation.
struct LiveSheet: View {
    @ObservedObject var controller: LiveOutingController
    @Environment(\.sary) private var theme
    @Environment(AppearanceSettings.self) private var appearance
    @EnvironmentObject private var model: AppModel
    /// An invite link opened during this trip, shown once the sheet on top (if any) is gone.
    @State private var invite: InviteToken?

    var body: some View {
        let ui = controller.ui
        let actions = controller.actions
        VStack(spacing: theme.space(.s)) {
            if controller.nav.isActive {
                /* Navigating: the peek is the guidance bar (arrival time, what is left, voice, steps, «إنهاء»). */
                NavBottomBar(nav: controller.nav, end: controller.endNav, steps: { controller.modal = .navSteps },
                             overview: { controller.navControlTapped("nav.overview") }, overviewOn: controller.nav.camera == .overview,
                             cameraMode: controller.mapFollowMode.rawValue)
            } else {
                /* One line: the people. The trip's numbers are in the header above. */
                SarySheetSummary(participants: ui.participantsTab.participants, detent: ui.sheetDetent, ended: controller.tripEnded,
                                 expand: { actions.setSheetDetent(ui.sheetDetent == .peek ? .half : .peek) })
            }
            if ui.sheetDetent != .peek {
                HStack(spacing: theme.space(.s)) {
                    SaryTabBar(selection: Binding(get: { ui.selectedTab }, set: { actions.selectTab($0) }), groupBadge: controller.chat.totalUnread)
                    Button { controller.openSettings() } label: {
                        Image(systemName: "gearshape").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(theme.palette.textPrimary).frame(width: 40, height: 40)
                    }
                    .buttonStyle(SaryPressStyle())
                    .accessibilityLabel(Text("الإعدادات"))
                    .accessibilityIdentifier("sheet.settings")
                }
                .padding(.horizontal, theme.space(.l))
                ScrollView {
                    VStack(spacing: theme.space(.m)) {
                        switch ui.selectedTab {
                        case .trip: TripTab(controller: controller, ui: ui)
                        case .group: GroupTab(controller: controller, ui: ui)
                        case .more: TripTab(controller: controller, ui: ui)
                        case .map: MapTab(controller: controller)
                        }
                    }
                    .padding(.horizontal, theme.space(.l))
                    .padding(.bottom, theme.space(.xl))
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(.top, theme.space(.s))
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
        .fullScreenCover(item: Binding(get: { ui.sos.incoming.first { !$0.acknowledged } }, set: { _ in })) { a in
            SaryFriendSOSAlert(alert: a, now: Date(), show: { controller.showSOS(a.id) }, call: { actions.sos.call(a.id) })
                .saryAppearance(appearance)
                .accessibilityIdentifier("friend-sos-alert")
        }
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
            Text("أعضاء الطلعة يشوفون موقعك ما دمت فيها. الرجوع للقائمة لا يوقف المشاركة؛ تتوقف فقط إذا غادرت الطلعة أو انتهت.")
        }
        .confirmationDialog("تغادر الطلعة؟", isPresented: Binding(get: { controller.confirm == .leave }, set: { if !$0 && controller.confirm == .leave { controller.confirm = nil } }), titleVisibility: .visible) {
            Button("غادر الطلعة", role: .destructive, action: controller.leaveOuting)
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("تتوقف مشاركة موقعك فورًا ويُحذف آخر موقع لك من الخادم. ترجع لها فقط بدعوة جديدة.")
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
                            action: controller.performAction, close: { controller.modal = nil })
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
            NoteComposer(state: NoteComposerUIState(currentNote: controller.ui.participantsTab.participants.first(where: \.isMe)?.note,
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
            OfflineMapsView(back: { controller.modal = nil }, suggested: controller.offlineSuggestion, outingName: controller.ui.outingName)
                .presentationDetents([.large])
        case .weather:
            WeatherSheet(weather: controller.weather, close: { controller.modal = nil },
                         changeDestination: controller.session.view?.iLead == true ? { controller.changeDestinationFromWeather() } : nil,
                         destinationNote: controller.planModel?.destinationLocalOnly == true ? LocalDestinationCopy.note : nil)
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
            ShareAlwaysExplainer(allow: controller.allowShareAlways, later: controller.laterShareAlways)
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
        }
    }
}

private struct ShareURL: Identifiable { let url: URL; var id: String { url.absoluteString } }

extension IncomingSOSUI: @retroactive Hashable {
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - «الرحلة»

/// Where we are going and how it goes: my sharing, the trip, the destination and plan,
/// the weather there, safety (return timer, «غرّزت») and my trail.
private struct TripTab: View {
    @ObservedObject var controller: LiveOutingController
    var ui: LiveOutingUIState

    var body: some View {
        Group {
            ShareCallout(controller: controller, ui: ui)
            if controller.showsTripStrip, ui.status != .notStarted {
                TripCard(ui: controller.tripPanel, actions: controller.tripActions, confirmEnd: $controller.tripConfirmEnd)
            }
            /* «سجل الطلعة»: the legs so far (and a quiet «غيّر الوجهة» while one is picked). */
            if ui.status != .notStarted, !controller.legs.timeline.isEmpty || controller.legPicked != nil {
                VStack(alignment: .leading, spacing: 6) {
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
            TripRouteActions(controller: controller)
            if ui.status != .ended {
                LiveWeatherCard(controller: controller, weather: controller.weather)
                SafetySection(safety: controller.safety, now: ui.now, outingActive: ui.status == .active)
            }
            TrailCard(controller: controller, card: controller.trailCard)
            /* From the old «المزيد» (Lovable's settings have none of these): the invite link, pause /
             * end / leave, and my number. */
            TripControls(controller: controller, ui: ui)
        }
    }
}

/// «اتبع الخطة» and the leader's «وجّه الكل» (moved here from «+», «تخفيف الزحمة» ١٣).
private struct TripRouteActions: View {
    @ObservedObject var controller: LiveOutingController
    @Environment(\.sary) private var theme

    var body: some View {
        let items = LiveActionCatalog.tripRouteActions(controller.actionState)
        if !items.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    Button { controller.performAction(item.id) } label: {
                        HStack(spacing: theme.space(.m)) {
                            SaryRowIcon(systemImage: item.systemImage, color: item.isActive ? theme.palette.accent : nil)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).saryText(.body, weight: .bold).foregroundStyle(theme.palette.textPrimary)
                                if let sub = item.subtitle {
                                    Text(sub).saryText(.footnote).foregroundStyle(theme.palette.textSecondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, theme.space(.m))
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SaryRowPressStyle())
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(item.isActive ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier(item.accessibilityID)
                    if i < items.count - 1 { SaryDivider().padding(.leading, 56) }
                }
            }
            .sarySurface(radius: SaryRadius.l)
        }
    }
}

// MARK: - «الخريطة»

/// Lovable's «الخريطة» tab: the layers (exploration), high-res imagery, the realistic view, offline maps
/// and the visual effects.
private struct MapTab: View {
    @ObservedObject var controller: LiveOutingController
    @Environment(\.sary) private var theme

    var body: some View {
        Group {
            SarySection(title: "الطبقة") {
                SaryNavRow(title: controller.mapLayer.label, detail: "قمر صناعي، طبوغرافي، عادي · في الاستكشاف",
                           systemImage: "square.3.layers.3d", id: "map.layers") {
                    controller.sheetDetent = .peek
                    controller.enterExplore()
                }
                .padding(.horizontal, theme.space(.m))
            }
            HiResLayerSection()
            SarySection(title: "الوضع الواقعي") {
                SaryNavRow(title: "الوضع الواقعي", detail: "شوف المكان مجسّم من فوق", systemImage: "mountain.2", id: "map.realistic") {
                    controller.sheetDetent = .peek
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { controller.realisticRequest += 1 }
                }
                .padding(.horizontal, theme.space(.m))
                SaryDivider()
                SaryNavRow(title: "الخرائط بلا إنترنت", detail: "احفظ منطقة الطلعة قبل ما تطلع من التغطية", systemImage: "arrow.down.circle.fill",
                           id: "map.offline") { controller.modal = .offlineMaps }
                    .padding(.horizontal, theme.space(.m))
            }
            VisualEffectsSection()
        }
    }
}

// MARK: - «المجموعة»

/// The people: who is where, the convoy, the rally point, shared points, and the invite.
private struct GroupTab: View {
    @ObservedObject var controller: LiveOutingController
    var ui: LiveOutingUIState
    @Environment(\.sary) private var theme

    var body: some View {
        let actions = controller.actions
        let v = controller.session.view
        Group {
            /* «المحادثات»: first in the Group tab (≤ 2 taps from anywhere: «المجموعة» → here, or «+» → المحادثات). */
            ChatEntryRow(chat: controller.chat) { controller.openChat() }
            VStack(spacing: 0) {
                let list = ui.participantsTab.participants
                ForEach(list) { p in
                    SaryParticipantRow(participant: p, now: ui.now) { actions.participantsTab.openParticipant(p.id) }
                        .accessibilityIdentifier("participant-row")
                    if p.id != list.last?.id { SaryDivider().padding(.leading, 60) }
                }
            }
            .padding(.vertical, theme.space(.xs))
            .sarySurface(radius: SaryRadius.l)
            ConvoySection(controller: controller, features: controller.features)
            if ui.status != .ended {
                SaryRallyCard(rally: ui.participantsTab.rally, canManage: v?.iLead == true, actions: actions.participantsTab)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("rally-card")
            }
            WaypointsSection(controller: controller, features: controller.features)
            VStack(alignment: .leading, spacing: theme.space(.s)) {
                Text("ادعُ ربعك").saryText(.footnote, weight: .bold).foregroundStyle(theme.palette.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                /* «دعوة شخصية»: one link per person; the open link only while the leader keeps it on. */
                LivePersonalInvites(session: controller.session) { InviteTab(controller: controller, ui: ui) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("invite-section")
        }
    }
}

/// The one clear call to action for my own sharing, and the outing's state.
private struct ShareCallout: View {
    @ObservedObject var controller: LiveOutingController
    var ui: LiveOutingUIState
    @Environment(\.sary) private var theme
    /// The «دائمًا» hint, closed once on this phone.
    @AppStorage("sary.live.shareHint.dismissed.v1") private var hintDismissed = false

    var body: some View {
        let v = controller.session.view
        if let r = controller.session.closedReason {
            SaryBanner(text: closedText(r), tone: .warning, systemImage: SaryIcon.warning)
        } else {
            switch ui.status {
            case .notStarted:
                /* An outing needs no destination (a leg does): «وين رايحين؟» comes after the start. */
                VStack(spacing: theme.space(.s)) {
                    SaryBanner(text: v?.iLead == true ? "الطلعة ما بدأت. ابدأها ويشارك الكل مواقعهم." : "بانتظار أمير الرحلة يبدأ الطلعة.", tone: .info)
                        .accessibilityIdentifier("live.notStarted")
                    if v?.iLead == true {
                        Button { controller.startOutingFlow() } label: { SaryButtonLabel(title: "ابدأ الطلعة", systemImage: SaryIcon.play) }
                            .buttonStyle(.saryPrimary)
                            .accessibilityIdentifier("live.start")
                    }
                }
            case .paused:
                SaryBanner(text: "الطلعة متوقفة مؤقتًا. لا أحد يشارك موقعه الآن.", tone: .warning, systemImage: SaryIcon.pause)
            case .ended:
                SaryBanner(text: "انتهت هذه الطلعة.", tone: .info)
            case .active:
                /* Build 14: sharing is automatic for every member of an active trip — no «شارك موقعي»
                 * and no «أوقف». The only way to stop is «غادر الطلعة», right here and in «المزيد». */
                if controller.locationDenied {
                    /* iOS location turned off after joining: still a member, the calm fix. */
                    ShareBackgroundHintRow(hint: .denied, openSettings: controller.openAppSettings)
                } else {
                    /* A thin strip (the owner's «زحمة» review): sharing state + the quiet way out. */
                    HStack(spacing: theme.space(.s)) {
                        Circle().fill(ui.sharing == .sharing ? theme.palette.live : theme.palette.warning).frame(width: 8, height: 8)
                        Text(ui.sharing == .sharing ? "موقعك مُشارَك مع الطلعة" : "جارٍ تحديد موقعك…")
                            .saryText(.footnote, weight: .bold)
                            .foregroundStyle(theme.palette.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("live.sharing")
                        Button { controller.confirm = .leave } label: {
                            Text("غادر الطلعة").saryText(.footnote, weight: .bold).foregroundStyle(theme.palette.textSecondary)
                                .frame(minHeight: 32).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("live.leave")
                    }
                    .padding(.horizontal, theme.space(.m))
                    .padding(.vertical, 6)
                    .background(Capsule().fill(theme.palette.sunken.opacity(0.6)))
                    /* «دائمًا»: once, small, closable (also in the settings). */
                    if let hint = controller.shareBackgroundHint, !hintDismissed {
                        HStack(spacing: 0) {
                            ShareBackgroundHintRow(hint: hint, openSettings: controller.openAppSettings)
                            Button { hintDismissed = true } label: {
                                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.palette.textTertiary)
                                    .frame(width: 36, height: 36).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("أخفِ"))
                            .accessibilityIdentifier("live.shareHint.close")
                        }
                    }
                }
            }
        }
    }

    private func closedText(_ r: LiveCloseReason) -> String {
        switch r {
        case .outingEnded: return "انتهت هذه الطلعة."
        case .removed: return "أزالك أمير الرحلة منها."
        case .left: return "غادرت هذه الطلعة."
        case .notAMember: return "لست عضوًا في هذه الطلعة."
        case .unauthorized: return "انتهت جلستك على هذا الجهاز."
        case .replaced: return "فتحت الطلعة من جهاز آخر."
        }
    }
}

// MARK: - «مساري»

/// My trail at a glance, with «طريق العودة» and the friends' trails switch.
private struct TrailCard: View {
    @ObservedObject var controller: LiveOutingController
    var card: TrailCardUIState
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.space(.s)) {
            HStack(spacing: theme.space(.m)) {
                SaryRowIcon(systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text("مساري").saryText(.headline, weight: .bold).foregroundStyle(p.textPrimary)
                    Text(summary).saryText(.footnote).foregroundStyle(p.textSecondary)
                        .accessibilityIdentifier("trail.summary")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                card.backTrackActive ? controller.stopBackTrack() : controller.startBackTrack()
            } label: {
                SaryButtonLabel(title: card.backTrackActive ? "أنهِ طريق الرجعة" : "طريق الرجعة", systemImage: SaryIcon.backTrack)
            }
            .buttonStyle(card.backTrackActive ? .sarySecondary : .saryPrimary)
            .disabled(card.pointCount < 2 && !card.backTrackActive)
            .accessibilityIdentifier("trail.backtrack")
            if let h = card.health {
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
            }
            if card.gapCount > 0 {
                Text("الخط المتقطع جزء ما وصلتنا فيه أي نقطة GPS لأكثر من دقيقة؛ نرسمه على الشارع إذا عرفناه، وإلا مستقيمًا.")
                    .saryText(.caption).foregroundStyle(p.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SaryDivider()
            SaryToggleRow(title: "أظهر مسارات العيال", subtitle: "آخر ٣٠ دقيقة، من مواقعهم اللي وصلتك الآن", systemImage: SaryIcon.fitGroup,
                          isOn: Binding(get: { controller.showFriendTrails }, set: { controller.showFriendTrails = $0 }), id: "trail.friends")
        }
        .padding(theme.space(.m))
        .sarySurface(radius: SaryRadius.l)
    }

    private var summary: String {
        guard card.recordingOn else { return "التسجيل متوقف من الإعدادات" }
        guard card.pointCount >= 2 else { return card.isRecording ? "يبدأ التسجيل أول ما تتحرك" : "يُسجَّل مسارك والطلعة شغالة" }
        var parts = ["سجّلنا \(SaryFormat.distance(meters: card.recordedMeters))"]
        if let d = card.startDistanceMeters { parts.append("البداية على بعد \(SaryFormat.distance(meters: d))") }
        return parts.joined(separator: " · ")
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
        SarySection(title: "مساري", footer: "مسارك محفوظ على جوالك ولا يُرسل للعيال ولا لخوادمنا. مع «طابق مساري مع الطرق» تُرسل أجزاء منه إلى Mapbox فقط لرسمه على الشوارع. يُمسح مع تسجيل الخروج أو حذف الحساب.") {
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
            SaryToggleRow(title: "طابق مساري مع الطرق", subtitle: "يرسمه على الشوارع اللي مشيت فيها (Mapbox) · في البر يبقى كما سجّله GPS", systemImage: "road.lanes",
                          isOn: Binding(get: { card.matchOn }, set: { controller.setTrailMatching($0) }), id: "trail.match")
                .disabled(!card.recordingOn)
            SaryDivider()
            SaryToggleRow(title: "أظهر مسارات العيال", systemImage: SaryIcon.fitGroup,
                          isOn: Binding(get: { controller.showFriendTrails }, set: { controller.showFriendTrails = $0 }), id: "trail.friends.settings")
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
        } message: { Text("يُحذف مسارك لهذه الطلعة من جوالك، وما تقدر ترجعه. «طريق الرجعة» يبدأ من جديد.") }
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
                    bullet("iphone", "المسار يبقى على جوالك فقط. لا يُرسل لأحد، ولا حتى للخادم.")
                    bullet("person.2.fill", "نفس الإذن يخلّي مشاركة موقعك مع أعضاء الطلعة تستمر والشاشة مقفلة.")
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
            if link { Image(systemName: "chevron.left").font(.footnote.weight(.bold)).foregroundStyle(theme.palette.textTertiary) }
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
    @Environment(\.sary) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(.l)) {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space(.l)) {
                    Image(systemName: "lock.iphone").font(.system(size: 48)).foregroundStyle(theme.palette.accent)
                    Text("المشاركة تستمر والشاشة مقفلة").saryText(.title2).foregroundStyle(theme.palette.textPrimary)
                    Text("لما طلعت من التطبيق توقف إرسال موقعك للعيال. اسمح «دائمًا» عشان يشوفونك وأنت تسوق، حتى لو قفلت الشاشة أو فتحت تطبيقًا ثانيًا أو كنت على CarPlay.")
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
                    } label: { SaryButtonLabel(title: copied ? "تم النسخ" : "نسخ", systemImage: copied ? SaryIcon.check : SaryIcon.copy) }
                        .buttonStyle(.sarySecondary)
                        .accessibilityIdentifier("invite-copy")
                    Button(action: actions.shareLink) { SaryButtonLabel(title: "مشاركة", systemImage: SaryIcon.share) }
                        .buttonStyle(.saryPrimary)
                        .accessibilityIdentifier("invite-share")
                }
                Text("الرابط يدخل أي شخص يفتحه إلى الطلعة. شاركه مع العيال فقط.")
                    .saryText(.footnote)
                    .foregroundStyle(theme.palette.textSecondary)
                    .multilineTextAlignment(.center)
            } else if s.canRevoke {
                SaryStateView(kind: .empty(title: "لا يوجد رابط على هذا الجهاز",
                                           message: "الخادم لا يحفظ الروابط. أنشئ رابطًا جديدًا، وأي رابط قديم يتوقف.", systemImage: "link"))
            } else {
                SaryStateView(kind: .empty(title: "اطلب الرابط من أمير الرحلة", message: "الرابط عند من أنشأه فقط.", systemImage: "link"))
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

// MARK: - Settings tab

private struct TripControls: View {
    @ObservedObject var controller: LiveOutingController
    var ui: LiveOutingUIState
    @Environment(\.sary) private var theme
    @State private var confirm: Kind?
    @State private var phone = ""

    enum Kind: Identifiable { case pause, end, leave; var id: Self { self } }

    var body: some View {
        let s = ui.settingsTab
        let a = controller.actions.settingsTab
        VStack(spacing: theme.space(.m)) {
            SarySection(title: "الطلعة") {
                if ui.participantsTab.myPhoneMissing {
                    Button(action: controller.actions.participantsTab.addMyPhone) {
                        SaryBanner(text: "ما أضفت رقمك · أضفه عشان يتصل بك العيال", tone: .info, systemImage: SaryIcon.phone)
                    }
                    .buttonStyle(.plain)
                    .padding(theme.space(.s))
                    SaryDivider()
                }
                if s.outingStatus != .ended {
                    actionRow("رابط الدعوة", icon: "link", id: "settings-invite") { controller.selectedTab = .group; controller.sheetDetent = .half }
                    SaryDivider()
                }
                if s.isLeader && s.outingStatus != .ended {
                    if s.outingStatus != .notStarted {
                        actionRow(s.outingStatus == .paused ? "استأنف الطلعة" : "أوقف مؤقتًا", icon: s.outingStatus == .paused ? SaryIcon.play : SaryIcon.pause, id: "settings-pause-outing") { confirm = .pause }
                        SaryDivider()
                    }
                    actionRow("أنهِ الطلعة", icon: "flag.checkered", destructive: true, id: "settings-end") { confirm = .end }
                    SaryDivider()
                }
                actionRow("غادر الطلعة", icon: "rectangle.portrait.and.arrow.right", destructive: true, id: "settings-leave") { confirm = .leave }
            }
            SarySection(title: "رقمي", footer: "يظهر لأعضاء طلعاتك فقط، ليتصلوا بك أو يراسلوك واتساب.") {
                VStack(spacing: theme.space(.s)) {
                    SaryTextField(title: "رقم الجوال", placeholder: "05XXXXXXXX", text: $phone, id: "settings-phone", keyboard: .phonePad, maxLength: 14)
                    Button { a.saveMyPhone(phone.isEmpty ? nil : phone) } label: { SaryButtonLabel(title: "حفظ", systemImage: SaryIcon.check) }
                        .buttonStyle(.saryPrimary)
                        .disabled(!phone.isEmpty && SaryFormat.normalizeSaudiMobile(phone) == nil)
                }
                .padding(theme.space(.m))
            }
            .onAppear { phone = s.myPhone ?? "" }
        }
        .confirmationDialog(title, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible, presenting: confirm) { k in
                switch k {
                case .pause: Button(s.outingStatus == .paused ? "استأنف" : "أوقف مؤقتًا", action: a.pauseOrResumeOuting)
                case .end: Button("أنهِ الطلعة للجميع", role: .destructive, action: a.endOuting)
                case .leave: Button("غادر", role: .destructive, action: a.leaveOuting)
                }
                Button("إلغاء", role: .cancel) {}
            } message: { k in
                switch k {
                case .pause: Text(s.outingStatus == .paused ? "يرجع الأعضاء يشاركون مواقعهم." : "تتوقف مشاركة المواقع عند الجميع وتُحذف المواقع حتى تستأنف.")
                case .end: Text("بتنتهي الطلعة عند الكل ويتوقف تتبع المواقع. ما تقدر ترجعها.")
                case .leave: Text("بيتوقف إرسال موقعك وتخرج من الطلعة.")
                }
            }
    }

    /// A numbered section of «المزيد» («١ الصوت والقناة»…).
    private func groupTitle(_ t: String, number: Int) -> some View {
        Text(t)
            .saryText(.headline, weight: .heavy)
            .foregroundStyle(theme.palette.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, theme.space(.s))
            .accessibilityAddTraits(.isHeader)
    }

    private func segmentTitle(_ t: String) -> some View {
        Text(t).saryText(.footnote, weight: .bold).foregroundStyle(theme.palette.textSecondary)
    }

    private var title: String {
        switch confirm {
        case .pause?: return ui.settingsTab.outingStatus == .paused ? "استئناف الطلعة؟" : "إيقاف الطلعة مؤقتًا؟"
        case .end?: return "أنهِ الطلعة؟"
        case .leave?: return "غادر الطلعة؟"
        case nil: return ""
        }
    }

    private func actionRow(_ title: String, icon: String, destructive: Bool = false, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: theme.space(.m)) {
                SaryRowIcon(systemImage: icon, color: destructive ? theme.palette.emergency : nil)
                Text(title).saryText(.body, weight: .bold)
                    .foregroundStyle(destructive ? theme.palette.emergency : theme.palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, theme.space(.m))
            .frame(minHeight: theme.minTarget + 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
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
            Text("يشوفها العيال فوق سيارتك ١٥ دقيقة.").saryText(.footnote).foregroundStyle(theme.palette.textSecondary)
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
                SaryStateView(kind: .empty(title: "لا توجد محطة مسجّلة قريبة", message: "لا نخمّن مكانها.", systemImage: SaryIcon.nearest))
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
            Text("© OpenStreetMap contributors · ODbL").saryText(.micro).foregroundStyle(theme.palette.textTertiary)
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
