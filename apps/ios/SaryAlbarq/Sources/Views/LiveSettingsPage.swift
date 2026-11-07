import SwiftUI

/// Lovable's «الإعدادات»: a full page pushed from the header's gear (not a sheet), no group bar,
/// five groups — الطلعة، الخريطة، الصوت واللاسلكي، الخصوصية، متقدم — of one-line rows that end
/// in ‹ or a green switch. Long explanations and segmented choices live on the pages behind ‹.
/// Every setting the old «المزيد» had is still here (or, for the trip's own buttons, in «الرحلة»).
struct LiveSettingsPage: View {
    @ObservedObject var controller: LiveOutingController
    var close: () -> Void
    @Environment(\.sary) private var theme
    @State private var path: [Page] = []
    @State private var confirmClear = false
    @ObservedObject private var convoy = ConvoyAlertPrefs.shared
    @AppStorage(VoiceAutoplay.key) private var voiceAutoplay = VoiceAutoplay.default
    /// «طريقة اللاسلكي»: «رسالة صوتية» (default) or «مباشر (تجريبي)».
    @AppStorage(PTTTalkMode.key) private var talkMode = PTTTalkMode.default
    /// «صوت التوجيه»: «صوت سرى» (default, the owner's recorded voice) or «صوت الجهاز».
    @AppStorage(NavVoiceChoice.key) private var navVoice = NavVoiceChoice.default
    @AppStorage(OutingSession.modeKey) private var shareMode: String = ShareMode.balanced.rawValue

    enum Page: Hashable {
        case sharing, defaultLayer, mapDirection, units, driving, trail, defaultChannel, talkMode, navVoice, volume, media, diagnostics
    }

    var body: some View {
        NavigationStack(path: $path) {
            SettingsList(header: header(title: "الإعدادات", back: close, id: "settings.back")) {
                group("الطلعة") {
                    /* One page for my location (was «مشاركة موقعي» + «من يشوف موقعي», two pages saying the same). */
                    row("موقعي ومن يشوفه", id: "settings.sharing") { path.append(.sharing) }
                    row("رقم جوالي", id: "settings.phone") { closeThen { controller.modal = .panel(.phone) } }
                    toggle("تنبيه لما أحد يتأخر", isOn: $convoy.settings.behindTailOn, id: "settings.lateAlert", last: true)
                }
                group("الخريطة") {
                    row("الطبقة الافتراضية", id: "settings.defaultLayer") { path.append(.defaultLayer) }
                    row("اتجاه الخريطة أثناء القيادة", id: "settings.mapDirection") { path.append(.mapDirection) }
                    row("وحدات المسافة", id: "settings.units") { path.append(.units) }
                    row("القيادة والعرض", id: "settings.driving") { path.append(.driving) }
                    row("مساري", id: "settings.trail", last: true) { path.append(.trail) }
                }
                group("الصوت واللاسلكي") {
                    row("التردد الافتراضي", id: "settings.defaultChannel") { path.append(.defaultChannel) }
                    row("طريقة اللاسلكي", id: "settings.talkMode") { path.append(.talkMode) }
                    row("صوت التوجيه", id: "settings.navVoice") { path.append(.navVoice) }
                    toggle("تشغيل تلقائي للرسائل الصوتية", isOn: $voiceAutoplay, id: "settings.voiceAutoplay")
                    row("مستوى الصوت", id: "settings.volume") { path.append(.volume) }
                    row("الإذاعة ويوتيوب", id: "settings.media", last: true) { path.append(.media) }
                }
                group("الخصوصية") {
                    row("مسح سجل الطلعات", id: "settings.clearHistory", last: true) { confirmClear = true }
                }
                group("متقدم") {
                    toggle("دقة GPS العالية", isOn: Binding(get: { shareMode == ShareMode.precise.rawValue },
                                                           set: { shareMode = ($0 ? ShareMode.precise : ShareMode.balanced).rawValue }), id: "settings.gpsPrecise")
                    row("الوضع بدون إنترنت", id: "settings-offline") { closeThen { controller.modal = .offlineMaps } }
                    row("تشخيص", id: "settings.diagnostics", last: true) { path.append(.diagnostics) }
                }
            }
            .navigationDestination(for: Page.self) { page($0) }
            .toolbar(.hidden, for: .navigationBar)
        }
        .confirmationDialog("تمسح سجل الطلعات؟", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("امسح", role: .destructive) {
                LocalTripHistory.clear(keeping: controller.session.id)
                controller.toast("انمسح سجل الطلعات من جوالك")
            }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("تنمسح مسارات وسرعات طلعاتك السابقة المحفوظة على هذا الجوال. الطلعة الحالية ما تنمسح.")
        }
        .accessibilityIdentifier("settings.page")
    }

    /// The page's top: back on the right, the title, and SOS (small, never hidden, over nothing) on the left.
    private func header(title: String, back: @escaping () -> Void, id: String) -> some View {
        HStack(spacing: 10) {
            Button(action: back) {
                Image(systemName: SaryIcon.back).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .frame(width: 44, height: 44).background(Circle().fill(theme.palette.sunken))
            }
            .buttonStyle(SaryPressStyle())
            .accessibilityLabel(Text("رجوع"))
            .accessibilityIdentifier(id)
            Text(title).font(.sary(20, .bold)).foregroundStyle(theme.palette.textPrimary).accessibilityAddTraits(.isHeader)
            Spacer()
            if !controller.tripEnded {
                SarySOSButton(state: controller.ui.sos.mine, trigger: controller.actions.sos.trigger, size: 44, compactLabel: true)
                    .padding(6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: pages

    @ViewBuilder
    private func page(_ p: Page) -> some View {
        switch p {
        case .sharing:
            WhoSeesPage(controller: controller, header: header(title: "موقعي ومن يشوفه", back: { path.removeLast() }, id: "settings.sub.back"))
        case .defaultLayer:
            sub("الطبقة الافتراضية", footer: "الطبقة اللي يبدأ بها «الاستكشاف». خريطة الطلعة نفسها تبقى صور الأقمار الصناعية (هي اللي تنحفظ بلا إنترنت).") {
                ForEach(Array([MapLayer.satellite, .topo, .standard].enumerated()), id: \.element) { i, l in
                    choice(l.label, on: controller.mapLayer == l, id: "settings.layer.\(l.rawValue)", last: i == 2) { controller.mapLayer = l }
                }
            }
        case .mapDirection:
            sub("اتجاه الخريطة أثناء القيادة", footer: "إذا حرّكت الخريطة وأنت ماشي أكثر من ١٠ كم/س، ترجع «باتجاهي» بعد ١٠ ثوانٍ بدون لمس. «ابدأ التوجيه تلقائيًا»: إذا بدأت الطلعة يوجّهك صوتًا للمحطة التالية ثم الوجهة، على جوالك فقط. «شكل الشاشة»: أثناء القيادة تبقى الخريطة وأزرار قليلة كبيرة، وإذا وقفت تظهر التفاصيل؛ «تلقائي» يختار من سرعتك والملاحة.") {
                toggle("رجّعني للتوجيه تلقائيًا", isOn: Binding(get: { FollowCameraPrefs.snapshot().autoRecenter },
                                                              set: { FollowCameraPrefs.setAuto($0); controller.objectWillChange.send() }), id: "settings-autorecenter")
                toggle("ابدأ التوجيه تلقائيًا مع الرحلة", isOn: Binding(get: { controller.autoNavEnabled }, set: { controller.setAutoNavEnabled($0) }), id: "settings-autonav")
                segmentRow("شكل الشاشة") {
                    SarySegmented(options: LiveContextOverride.allCases, selection: $controller.contextOverride, label: { $0.label }, id: "settings-context")
                }
            }
        case .units:
            sub("وحدات المسافة", footer: "تنطبق على كل المسافات في التطبيق: الأعضاء، الوجهة، الملاحة، المسار.") {
                choice("كيلومتر", on: !DistanceUnits.miles, id: "settings.units.km") { DistanceUnits.miles = false; controller.objectWillChange.send() }
                choice("ميل", on: DistanceUnits.miles, id: "settings.units.mi", last: true) { DistanceUnits.miles = true; controller.objectWillChange.send() }
            }
        case .driving:
            DrivingPage(controller: controller, header: header(title: "القيادة والعرض", back: { path.removeLast() }, id: "settings.sub.back"))
        case .trail:
            SettingsList(header: header(title: "مساري", back: { path.removeLast() }, id: "settings.sub.back")) {
                TrailSettingsSection(controller: controller, card: controller.trailCard)
            }
        case .defaultChannel:
            sub("التردد الافتراضي", footer: "التردد اللي تنضم له أول ما تبدأ طلعة جديدة. تقدر تغيّره في أي وقت من «تردد ١» تحت زر اللاسلكي.") {
                ForEach(Array(PTTChannels.publicIds.enumerated()), id: \.element) { i, c in
                    choice(PTTChannels.publicName(c), on: PTTChannels.preferredDefault == c, id: "settings.channel.\(c)", last: i == PTTChannels.publicIds.count - 1) {
                        PTTChannels.preferredDefault = c
                        controller.objectWillChange.send()
                    }
                }
            }
        case .talkMode:
            sub("طريقة اللاسلكي", footer: "«رسالة صوتية»: اضغط وسجّل (لين دقيقة)، ثم «أرسل». توصل لكل اللي على ترددك وتشتغل عندهم لحالها، ولو انقطع النت شوي توصل أول ما يرجع. «بث مباشر»: امسك الزر وتكلم على الهواء، ويحتاج شبكة قوية عند الكل.") {
                ForEach(Array(PTTTalkMode.allCases.enumerated()), id: \.element) { i, m in
                    choice(m.label, on: talkMode == m, id: "settings.talkMode.\(m.rawValue)", last: i == PTTTalkMode.allCases.count - 1) {
                        talkMode = m
                        controller.objectWillChange.send()
                    }
                }
            }
        case .navVoice:
            sub("صوت التوجيه", footer: "«صوت سرى»: التوجيه بصوت مسجّل باللهجة النجدية، ويشتغل بدون إنترنت. ما يقول أسماء الشوارع والأماكن، تشوفها مكتوبة في لوحة التوجيه. «صوت الجهاز»: صوت الجوال العربي، ويقول الأسماء.") {
                ForEach(Array(NavVoiceChoice.allCases.enumerated()), id: \.element) { i, v in
                    choice(v.label, on: navVoice == v, id: "settings.navVoice.\(v.rawValue)", last: i == NavVoiceChoice.allCases.count - 1) {
                        navVoice = v
                        controller.objectWillChange.send()
                    }
                }
            }
        case .volume:
            VolumePage(controller: controller, header: header(title: "مستوى الصوت", back: { path.removeLast() }, id: "settings.sub.back"))
        case .media:
            sub("الإذاعة ويوتيوب", footer: "«إذاعة الطلعة» للكل، والشاشة مقفلة، وعلى سماعات السيارة. «يوتيوب» والتطبيق مفتوح فقط (شرط يوتيوب).") {
                row("إذاعة الطلعة", id: "radio.entry") { closeThen { GroupAudioCenters.of(controller).open() } }
                row("يوتيوب", id: "media.entry", last: true) { closeThen { MediaCenters.of(controller).open() } }
            }
        case .diagnostics:
            sub("تشخيص", footer: "حالة «قناة الطلعة» الآن، و«سجل القناة» تشاركه مع اللي يصلّح المشكلة.") {
                GpsDevGate(location: controller.location) { PTTLinkRow(line: controller.ui.settingsTab.pttLink) }
            }
        }
    }

    private func closeThen(_ f: @escaping () -> Void) {
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: f)
    }

    private func sub<C: View>(_ title: String, footer: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        SettingsList(header: header(title: title, back: { path.removeLast() }, id: "settings.sub.back")) {
            SettingsGroup(title: nil, footer: footer) { content() }
        }
    }

    // MARK: rows (Lovable: one line, ‹ or a green switch; no icons)

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        SettingsGroup(title: title, footer: nil, content: content)
    }

    private func row(_ title: String, id: String, last: Bool = false, action: @escaping () -> Void) -> some View {
        SettingsRow(title: title, last: last) {
            Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.palette.textSecondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(id)
    }

    private func toggle(_ title: String, isOn: Binding<Bool>, id: String, last: Bool = false) -> some View {
        SettingsRow(title: title, last: last) {
            Toggle("", isOn: isOn).labelsHidden().tint(theme.palette.live)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    private func choice(_ title: String, on: Bool, id: String, last: Bool = false, action: @escaping () -> Void) -> some View {
        SettingsRow(title: title, last: last) {
            if on { Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(theme.palette.live) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(id)
    }

    private func infoRow(_ title: String, id: String) -> some View {
        SettingsRow(title: title, last: true) { EmptyView() }.accessibilityIdentifier(id)
    }

    private func segmentRow<C: View>(_ title: String, @ViewBuilder _ control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.sary(14, .regular)).foregroundStyle(theme.palette.textPrimary)
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - building blocks

/// The page: its header, then the groups, scrolling.
struct SettingsList<Header: View, Content: View>: View {
    var header: Header
    @ViewBuilder var content: Content
    @Environment(\.sary) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { content }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
            }
        }
        .background(theme.palette.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .environment(\.saryToggleTint, theme.palette.live)
    }
}

/// A Lovable group: a small bold title, rows on one rounded card, an optional footer.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content
    @Environment(\.sary) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.sary(12, .bold)).foregroundStyle(theme.palette.textSecondary)
                    .padding(.horizontal, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.palette.surface))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if let footer {
                Text(footer).font(.sary(12, .regular)).foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// One line: the title on the right, the accessory (‹, a switch, a tick) on the left.
struct SettingsRow<Accessory: View>: View {
    var title: String
    var last = false
    @ViewBuilder var accessory: Accessory
    @Environment(\.sary) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title).font(.sary(14, .regular)).foregroundStyle(theme.palette.textPrimary).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                accessory
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 43)
            if !last { Rectangle().fill(theme.palette.separator).frame(height: 0.5).padding(.leading, 16) }
        }
    }
}

private struct DrivingPage<H: View>: View {
    @ObservedObject var controller: LiveOutingController
    var header: H
    @Environment(\.sary) private var theme

    var body: some View {
        let s = controller.ui.settingsTab
        let a = controller.actions.settingsTab
        SettingsList(header: header) {
            SettingsGroup(title: "وضع القيادة", footer: "خط وأزرار أكبر، تتقرأ من بعيد وأنت تسوق.") {
                SarySegmented(options: TriModeUI.allCases, selection: Binding(get: { s.driveMode }, set: { a.setDriveMode($0) }), label: { $0.label }, id: "settings-drive")
                    .padding(10)
            }
            SettingsGroup(title: "الوضع الليلي", footer: nil) {
                SarySegmented(options: TriModeUI.allCases, selection: Binding(get: { s.nightMode }, set: { a.setNightMode($0) }), label: { $0.label }, id: "settings-night")
                    .padding(10)
            }
            SpeedSettingsSection()
            DrivingRealismSection()
            VisualEffectsSection()
        }
    }
}

private struct VolumePage<H: View>: View {
    @ObservedObject var controller: LiveOutingController
    var header: H
    @AppStorage(PTTRadioSounds.enabledKey) private var radioSounds = true
    @AppStorage(PTTVoiceLevel.key) private var voiceLevel = PTTVoiceLevel.default

    var body: some View {
        let s = controller.ui.settingsTab
        let a = controller.actions.settingsTab
        SettingsList(header: header) {
            SettingsGroup(title: "صوت اللاسلكي", footer: "قوة صوت العيال من السماعة الخارجية.") {
                SarySegmented(options: PTTVoiceLevel.allCases, selection: $voiceLevel, label: { $0.label }, id: "settings.voiceLevel")
                    .padding(10)
            }
            SettingsGroup(title: nil, footer: "«أصوات اللاسلكي»: «كشش» ونغمة البدء والانتهاء. «اكتم القناة»: ما تسمع أحد ولا يصحّي جوالك.") {
                SettingsRow(title: "أصوات اللاسلكي") { Toggle("", isOn: $radioSounds).labelsHidden() }
                    .accessibilityElement(children: .combine).accessibilityIdentifier("settings.radioSounds")
                SettingsRow(title: "اكتم القناة", last: true) {
                    Toggle("", isOn: Binding(get: { s.pttMuted }, set: { a.setPTTMuted($0) })).labelsHidden()
                }
                .accessibilityElement(children: .combine).accessibilityIdentifier("settings-ptt-mute")
            }
        }
        .tint(Color.green)
    }
}

private struct WhoSeesPage<H: View>: View {
    @ObservedObject var controller: LiveOutingController
    var header: H

    var body: some View {
        let s = controller.ui.settingsTab
        let a = controller.actions.settingsTab
        SettingsList(header: header) {
            SettingsGroup(title: nil, footer: "موقعك يُشارك تلقائيًا مع أعضاء هذي الطلعة فقط، لا أحد غيرهم، ما دمت فيها وهي شغّالة. بإذن «دائمًا» يستمر الإرسال والشاشة مقفلة؛ بإذن «أثناء الاستخدام» فقط يتوقف إذا قفلت الشاشة ويظهر للعيال «آخر موقع». الخادم يحفظ آخر موقع فقط ويحذفه إذا غادرت أو انتهت الطلعة. تطلع منها من «المزيد» ← «غادر الطلعة».") {
                SettingsRow(title: controller.session.isSharingNow ? "موقعك مُشارَك الآن" : "موقعك غير مُشارَك الآن") { EmptyView() }
                    .accessibilityIdentifier("settings.sharing.state")
                SettingsRow(title: "شارك البطارية") {
                    Toggle("", isOn: Binding(get: { s.batterySharingOn }, set: { a.setBatterySharing($0) })).labelsHidden()
                }
                .accessibilityElement(children: .combine).accessibilityIdentifier("settings-battery")
                SettingsRow(title: "الإشعارات: رسائل وطوارئ العيال", last: true) {
                    Toggle("", isOn: Binding(get: { s.notificationsOn }, set: { a.setNotifications($0) })).labelsHidden()
                }
                .accessibilityElement(children: .combine).accessibilityIdentifier("settings-notify")
            }
        }
        .tint(Color.green)
    }
}

// MARK: - the new settings, real and small

/// «وحدات المسافة»: kilometres (default) or miles, for every distance on screen.
enum DistanceUnits {
    static let key = "sary.units.miles.v1"
    static var miles: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// «تشغيل تلقائي للرسائل الصوتية»: a friend's voice message plays as it arrives.
/// «تشغيل تلقائي للرسائل الصوتية»: on by default. Off: a new «رسالة صوتية» waits on a card with a
/// play button instead of playing by itself (older builds' voice_clip banners follow it too).
enum VoiceAutoplay {
    static let key = "sary.voice.autoplay.v1"
    static let `default` = true
    static var on: Bool { isOn() }
    static func isOn(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: key) as? Bool ?? `default` }
}

/// «مسح سجل الطلعات»: the trails and speed logs this phone kept for past outings (the current one stays).
enum LocalTripHistory {
    static func clear(keeping current: String, defaults: UserDefaults = .standard, trailsDir: URL? = TrailStore.directory) {
        if let d = defaults.data(forKey: TripLogStore.key), var all = try? JSONDecoder().decode([String: TripLog].self, from: d) {
            all = all.filter { $0.key == current }
            if let e = try? JSONEncoder().encode(all) { defaults.set(e, forKey: TripLogStore.key) }
        }
        guard let dir = trailsDir, let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let keep = Set([TrailStore.fileName(current)])
        for f in files where !keep.contains(f) && !f.contains(current) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }
}
