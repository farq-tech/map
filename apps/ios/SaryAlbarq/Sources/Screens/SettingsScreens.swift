import PhotosUI
import SwiftUI
import UIKit
import UserNotifications

// MARK: - Profile («ملفي»)

struct ProfileView: View {
    var back: () -> Void
    var open: (HomeRoute) -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.sary) private var theme
    @State private var name = ""
    @State private var phone = ""
    @State private var item: PhotosPickerItem?
    @State private var photo: UIImage?
    @State private var photoChanged = false
    @State private var busy = false
    @State private var saved = false
    @State private var error: String?
    @State private var confirmSignOut = false

    var body: some View {
        let p = theme.palette
        let user = model.identity?.user
        let phoneOK = phone.trimmingCharacters(in: .whitespaces).isEmpty || SaryFormat.normalizeSaudiMobile(phone) != nil
        let dirty = name.trimmingCharacters(in: .whitespaces) != (user?.display_name ?? "") || phoneDirty || photoChanged
        SaryPage(title: "ملفي", back: back) {
            VStack(spacing: theme.space(.s)) {
                PhotosPicker(selection: $item, matching: .images) {
                    ZStack(alignment: .bottomTrailing) {
                        SaryAvatar(name: name.isEmpty ? "؟" : name, color: theme.accent.fill, photo: photo, size: 96)
                        Image(systemName: "camera.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(p.onAccent)
                            .frame(width: 32, height: 32).background(Circle().fill(p.accent))
                    }
                }
                .accessibilityLabel(Text("غيّر الصورة"))
                if photo != nil {
                    Button("إزالة الصورة") { photo = nil; photoChanged = true }
                        .buttonStyle(.sary(.plain, width: .hug, compact: true))
                }
            }
            .frame(maxWidth: .infinity)
            SaryTextField(title: "الاسم", placeholder: "اسمك كما يشوفه الربع", text: $name, id: "profile.name", maxLength: ServerRules.nameMax)
            SaryTextField(title: "رقم الجوال (اختياري)", placeholder: "05XXXXXXXX", text: $phone, id: "profile.phone", keyboard: .phonePad, maxLength: 14,
                          state: phoneOK ? .normal : .error("اكتب رقمًا سعوديًا يبدأ بـ ٠٥"),
                          help: "يظهر لأعضاء طلعاتك فقط (اتصال وواتساب). امسحه واحفظ لتحذفه من الخادم.")
            if let error { SaryInlineMessage(text: error, tone: .error) }
            if saved { SaryInlineMessage(text: "تم الحفظ", tone: .success) }
            Button { save() } label: { SaryButtonLabel(title: "احفظ", busy: busy) }
                .buttonStyle(.sary(.primary))
                .disabled(!dirty || !phoneOK || name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                .accessibilityIdentifier("profile.save")
            SarySection(title: "الحساب") {
                SaryNavRow(title: "رمز الاسترجاع", detail: model.recovery?.active == true ? "محفوظ" : "لم تحفظه بعد — احفظه قبل ما تغيّر جوالك",
                           systemImage: "key.fill", tint: model.recovery?.active == true ? nil : p.warning, id: "profile.recovery") { open(.recoveryCode) }
                SaryDivider()
                SaryNavRow(title: "الإعدادات", systemImage: SaryIcon.settings) { open(.settings) }
            }
            Button { confirmSignOut = true } label: { SaryButtonLabel(title: "تسجيل الخروج من هذا الجهاز", systemImage: "rectangle.portrait.and.arrow.right") }
                .buttonStyle(.sary(.plainDestructive))
                .accessibilityIdentifier("profile.signOut")
        }
        .onAppear(perform: fill)
        .task { await model.loadMe() }
        .onChange(of: item) { _, it in
            guard let it else { return }
            Task {
                if let d = try? await it.loadTransferable(type: Data.self), let img = UIImage(data: d) { photo = img; photoChanged = true }
            }
        }
        .saryDialog($confirmSignOut, systemImage: "rectangle.portrait.and.arrow.right", title: "تخرج من هذا الجهاز؟",
                    message: model.recovery?.active == true
                        ? "تتوقف أي مشاركة، وتُمسح هويتك من هذا الجهاز. ترجع برمز الاسترجاع."
                        : "ما حفظت رمز استرجاع: إذا خرجت لن تقدر ترجع لهذا الحساب وطلعاته.",
                    confirmTitle: "اخرج") {
            confirmSignOut = false
            Task { await model.signOut() }
        }
    }

    private var phoneDirty: Bool {
        let cur = model.identity?.user.phone ?? ""
        let typed = phone.trimmingCharacters(in: .whitespaces)
        return (ServerRules.normalizePhone(typed) ?? typed) != cur
    }

    private func fill() {
        let u = model.identity?.user
        name = u?.display_name ?? ""
        phone = u?.phone.map { SaryFormat.displayPhone($0.hasPrefix("+966") ? "0" + $0.dropFirst(4) : $0) } ?? ""
        photo = AvatarCodec.image(from: u?.avatar)
        photoChanged = false
    }

    private func save() {
        busy = true
        error = nil
        saved = false
        Task {
            var avatar: String?
            if photoChanged {
                if let photo {
                    guard let a = AvatarCodec.dataURL(from: photo) else { error = "تعذّر تجهيز الصورة."; busy = false; return }
                    avatar = a
                } else { avatar = "" }
            }
            let u = model.identity?.user
            let n = name.trimmingCharacters(in: .whitespaces)
            let ok = await model.updateProfile(name: n == u?.display_name ? nil : n, phone: phoneDirty ? phone : nil, avatar: avatar)
            busy = false
            if ok { saved = true; fill() } else { error = model.errorText; model.errorText = nil }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    var back: () -> Void
    var open: (HomeRoute) -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.sary) private var theme
    /// «قناة الطلعة» squelch / chirp / roger and the radio-voice filter (on by default).
    @AppStorage(PTTRadioSounds.enabledKey) private var radioSounds = true
    /// «صوت اللاسلكي»: how loud a friend's voice plays («عالي» by default).
    @AppStorage(PTTVoiceLevel.key) private var voiceLevel = PTTVoiceLevel.default
    /// «طريقة اللاسلكي»: «رسالة صوتية» (default) or «مباشر (تجريبي)».
    @AppStorage(PTTTalkMode.key) private var talkMode = PTTTalkMode.default

    var body: some View {
        /* Four clear sections (docs/IA-REDESIGN.md §2.7). */
        SaryPage(title: "الإعدادات", back: back) {
            SarySection(title: "الحساب") {
                SaryNavRow(title: "ملفي", detail: model.identity?.user.display_name, systemImage: "person.fill", id: "settings.profile") { open(.profile) }
                SaryDivider()
                SaryNavRow(title: "رمز الاسترجاع", detail: model.recovery?.active == true ? "محفوظ" : "لم تحفظه بعد",
                           systemImage: "key.fill", tint: model.recovery?.active == true ? nil : theme.palette.warning, id: "settings.recovery") { open(.recoveryCode) }
                SaryDivider()
                SaryNavRow(title: "التنبيهات", detail: pushDetail, systemImage: "bell.fill", id: "settings.notifications") { open(.notifications) }
                SaryDivider()
                SaryNavRow(title: "تنبيهات القافلة", detail: "الابتعاد عن الأمير، الوقوف المفاجئ، الانقطاع، التأخر", systemImage: "car.2.fill",
                           id: "settings.convoyAlerts") { open(.convoyAlerts) }
            }
            SarySection(title: "اللاسلكي", footer: "صوت «كشش» ونغمة قصيرة لما يبدأ الإرسال، ونغمة «حوّل» لما ينتهي، وصوت الربع بنبرة اللاسلكي. على شاشة القفل يشغّل iOS نغماته هو لإرسالك.") {
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    HStack(spacing: theme.space(.m)) {
                        SaryRowIcon(systemImage: "waveform")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("طريقة اللاسلكي").saryText(.body, weight: .medium).foregroundStyle(theme.palette.textPrimary)
                            Text(talkMode == .notes ? "اضغط وسجّل، ثم «أرسل»: توصل لكل اللي على ترددك ولو انقطع النت شوي"
                                                    : "امسك الزر وتكلم مباشرة · يحتاج شبكة قوية عند الكل")
                                .saryText(.footnote).foregroundStyle(theme.palette.textSecondary)
                        }
                    }
                    SarySegmented(options: PTTTalkMode.allCases, selection: $talkMode, label: { $0.label }, id: "settings.talkMode")
                }
                .padding(.vertical, theme.space(.xs))
                SaryDivider()
                SaryToggleRow(title: "أصوات اللاسلكي", subtitle: "كشش وتنبيه البدء والانتهاء", systemImage: "antenna.radiowaves.left.and.right",
                              isOn: $radioSounds, id: "settings.radioSounds")
                SaryDivider()
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    HStack(spacing: theme.space(.m)) {
                        SaryRowIcon(systemImage: "speaker.wave.3.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("صوت اللاسلكي").saryText(.body, weight: .medium).foregroundStyle(theme.palette.textPrimary)
                            Text("قوة صوت أصحابك من السماعة الخارجية").saryText(.footnote).foregroundStyle(theme.palette.textSecondary)
                        }
                    }
                    SarySegmented(options: PTTVoiceLevel.allCases, selection: $voiceLevel, label: { $0.label }, id: "settings.voiceLevel")
                }
                .padding(.vertical, theme.space(.xs))
            }
            IntroSettingsSection()
            SarySection(title: "الخصوصية والموقع") {
                SaryNavRow(title: "الخصوصية", detail: "ما يُشارك ومتى، البطارية، بياناتك", systemImage: "hand.raised.fill", id: "settings.privacy") { open(.privacy) }
                SaryDivider()
                SaryNavRow(title: "المحظورين", detail: "اللي حظرتهم من المحادثة والرسائل الصوتية", systemImage: "person.crop.circle.badge.xmark", id: "settings.blocked") { open(.blocked) }
            }
            SarySection(title: "المظهر والقيادة") {
                SaryNavRow(title: "المظهر", detail: "الألوان، وضع القيادة والليل، حجم النص", systemImage: "paintbrush.fill", id: "settings.appearance") { open(.appearance) }
            }
            SarySection(title: "الخرائط والبيانات") {
                SaryNavRow(title: "الخرائط بلا إنترنت", detail: "احفظ منطقة الطلعة قبل ما تفقد التغطية", systemImage: "arrow.down.circle.fill", id: "settings.offline") { open(.offlineMaps) }
                SaryDivider()
                SaryNavRow(title: "متقدم", detail: "سجل المسار، مزوّد المسارات", systemImage: "wrench.and.screwdriver.fill", id: "settings.advanced") { open(.advanced) }
            }
            VisualEffectsSection()
            SarySection {
                SaryNavRow(title: "حول سَرى البارق", systemImage: "info.circle.fill", id: "settings.about") { open(.about) }
            }
        }
    }

    private var pushDetail: String {
        switch model.push.state {
        case .registered: return "مفعّلة"
        case .off: return "متوقفة"
        case .denied: return "مرفوضة في إعدادات iOS"
        case .notAsked: return "لم تُفعّل بعد"
        case .serverNotReady: return "داخل التطبيق فقط حاليًا"
        case .waitingForToken: return "نجهّزها…"
        case .failed: return "تعذّر التفعيل"
        }
    }
}

struct AppearanceScreen: View {
    var back: () -> Void
    @Environment(AppearanceSettings.self) private var appearance
    var body: some View {
        SaryPage(title: "المظهر", back: back) {
            SaryAppearancePanel(settings: appearance)
            Button("ارجع للإعدادات الأصلية") { appearance.reset() }
                .buttonStyle(.sary(.plain))
        }
    }
}

// MARK: - Privacy

struct PrivacySettingsView: View {
    var back: () -> Void
    var open: (HomeRoute) -> Void = { _ in }
    @EnvironmentObject private var model: AppModel
    @Environment(\.sary) private var theme
    @AppStorage(OutingSession.modeKey) private var mode: String = ShareMode.balanced.rawValue
    @AppStorage(OutingSession.batteryKey) private var battery = false
    /// Mapbox's own opt-out (the SDK observes this key; default on = the SDK default).
    @AppStorage(MapboxTelemetry.key) private var mapboxTelemetry = true

    var body: some View {
        let p = theme.palette
        SaryPage(title: "الخصوصية", back: back) {
            SarySection(title: "متى يُشارك موقعي؟") {
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    fact("hand.tap.fill", "المشاركة تلقائية ما دمت عضوًا في طلعة شغّالة: بانضمامك لطلعة (أو إنشائك لها) يشوف أعضاؤها موقعك المباشر، بدون زر «شارك» أو «أوقف».")
                    fact("rectangle.portrait.and.arrow.right", "لإيقاف المشاركة غادر الطلعة. وتتوقف أيضًا إذا أزالك أمير الطلعة، أو أوقف الطلعة مؤقتًا، أو انتهت.")
                    fact("lock.iphone", "بإذن «دائمًا» تستمر المشاركة في الخلفية والشاشة مقفلة (ويظهر مؤشر الموقع الأزرق) حتى تغادر، أو يزيلك أمير الطلعة، أو تتوقف الطلعة أو تنتهي. لا نطلب «دائمًا» عند الانضمام؛ نعرضه لاحقًا إذا قفلت الشاشة أثناء الطلعة.")
                    fact("iphone", "بإذن «أثناء الاستخدام» فقط: تُرسل والتطبيق مفتوح أمامك، وتتوقف إذا قفلت الشاشة.")
                    fact("xmark.app", "إذا قفلت التطبيق من قائمة التطبيقات، قد لا يعيد iOS فتحه، فتتوقف المشاركة حتى تفتحه.")
                    fact("point.topleft.down.to.point.bottomright.curvepath.fill", "«مساري» (طريقك في الطلعة) يُسجَّل على جوالك فقط، ويستمر والشاشة مقفلة إذا فعّلت ذلك (مع مؤشر الموقع الأزرق). لا يُرسل للربع ولا لخوادمنا؛ تُطابق أجزاء منه مع الشوارع عبر Mapbox فقط. يُمسح مع تسجيل الخروج أو حذف الحساب.")
                    fact("person.wave.2.fill", "«انقطع الإرسال»: إذا كنت تشارك وتوقف وصول موقعك ١٠ دقائق، يخبر الخادم ربع الطلعة بذلك مع آخر موقع معروف لك.")
                    fact("person.2.fill", "يراه أعضاء تلك الطلعة فقط، لا أحد غيرهم.")
                    fact(SaryNearbyMark.icon, "إذا انقطع الإنترنت وأنت تشارك، يتبادل جوالك موقعك مباشرة مع جوالات ربع الطلعة القريبين (بلوتوث وواي فاي مباشر)، مشفّرًا ولا يقرؤه غيرهم، ويمرّر لهم آخر مواقع الباقين بعمرها الحقيقي. يتوقف مع توقف المشاركة، ولا يُرسل للخادم شيء مما يصل بهذه الطريقة.")
                    fact("trash", "الخادم يحفظ آخر موقع لك فقط (لا مسارك)، ويحذفه إذا غادرت الطلعة أو أزالك أمير الطلعة أو أُوقفت الطلعة أو انتهت، ولا يبقى أي موقع أكثر من ٢٤ ساعة.")
                }
                .padding(.vertical, theme.space(.s))
            }
            SarySection(title: "دقة المشاركة", footer: modeFooter) {
                SarySegmented(options: ShareMode.allCases, selection: Binding(get: { ShareMode(rawValue: mode) ?? .balanced }, set: { mode = $0.rawValue }),
                              label: { $0.label }, id: "privacy.mode")
                    .padding(.vertical, theme.space(.s))
            }
            SarySection(footer: "إذا فعّلته يشوف ربع طلعتك نسبة بطارية جوالك وهل هو على الشاحن، ليعرفوا إذا قرب ينطفي. لا يُرسل شيء آخر.") {
                SaryToggleRow(title: "شارك نسبة البطارية", systemImage: "battery.75percent", isOn: $battery, id: "privacy.battery")
            }
            SarySection(title: "Mapbox", footer: "مكتبة الخرائط (Mapbox) ترسل افتراضيًا إحصاءات استخدام مجهولة لتحسين خرائطها. أوقفها هنا إن شئت؛ الخريطة تعمل مثل ما هي. هذا الخيار نفسه الموجود في زر «i» على الخريطة.") {
                SaryToggleRow(title: "ساهم في تحسين خرائط Mapbox", subtitle: "إحصاءات مجهولة يرسلها Mapbox", systemImage: "chart.bar.fill",
                              isOn: $mapboxTelemetry, id: "privacy.mapboxTelemetry")
            }
            SarySection(title: "ما الذي يُرسل للخادم", footer: "لا إعلانات، لا تتبع، ولا بيع بيانات.") {
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    fact("person.text.rectangle", "اسمك وصورتك (إن وضعتها) ورقمك (إن كتبته): يراها أعضاء طلعاتك.")
                    fact("location.fill", "موقعك ما دمت في طلعة شغّالة: آخر موقع فقط.")
                    fact(SaryIcon.note, "رسائلك القصيرة: ١٥ دقيقة ثم تختفي.")
                    fact(SaryIcon.mic, "صوتك في «قناة الطلعة»: يمرّ عبر الخادم مباشرة لربع الطلعة وأنت ضاغط على الزر فقط، ولا يُسجَّل ولا يُحفظ في أي مكان.")
                    fact(SaryIcon.sos, "الطوارئ: مع آخر موقع حقيقي لك، وتنتهي خلال ساعة أو بـ«أنا بخير».")
                    fact("flag.checkered", "ملخص طلعتك: مجاميع فقط، ولا يُرسل إلا إذا اخترت «شارك ملخصي».")
                    fact("map", "الخرائط من Mapbox: تطلب صور الخريطة للمنطقة المعروضة، دون اسمك أو حسابك.")
                    fact(SaryIcon.directions, "«الملاحة»: نقطة البداية والوجهة تُرسل لـ Mapbox (أو لخادم الشركة إذا اخترته) لحساب الطريق فقط، دون اسمك أو حسابك. الصوت يُنطق على جوالك.")
                    fact("play.rectangle.fill", "«يوتيوب»: الفيديو يعمل بمشغّل YouTube الرسمي (تطبّق عليه سياسة Google). في «قناة الطلعة» يرى ربع الطلعة الفيديو الذي شغّلته؛ «قناتي» لك وحدك.")
                }
                .padding(.vertical, theme.space(.s))
            }
            SarySection(title: "الطقس (Open-Meteo)", footer: "خدمة طقس مفتوحة بلا حساب ولا مفتاح. التنبيهات تقدير؛ التحذيرات الرسمية من المركز الوطني للأرصاد.") {
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    fact("cloud.sun.fill", "منطقة الطلعة: نرسل إحداثيات تقريبية فقط، مقرّبة إلى ٠٫١° (نحو ١١ كم). لا نرسل أبدًا مواقع الأعضاء الحية.")
                    fact("flag.checkered", "الوجهة، أو نقطة تختارها لـ«الطقس هنا»: نرسل إحداثياتها كما حُددت، لأنها مكان اخترتموه لا موقع شخص.")
                    fact("person.crop.circle.badge.xmark", "لا يُرسل اسمك ولا حسابك ولا رقمك، ونحفظ آخر رد على جوالك ليعمل بلا إنترنت.")
                }
                .padding(.vertical, theme.space(.s))
            }
            SarySection(title: "حسابي", footer: "الخرائط التي نزّلتها بلا إنترنت تبقى على جوالك؛ تحذفها من «الخرائط بلا إنترنت».") {
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    Text("«احذف حسابي» يحذف حسابك من الخادم نهائيًا: اسمك وصورتك ورقمك، وعضويتك في كل الطلعات، ومواقعك ورسائلك وملخصاتك وتنبيهاتك. ثم يمسح هويتك من هذا الجهاز.")
                        .saryText(.subhead).foregroundStyle(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { open(.deleteAccount) } label: { SaryButtonLabel(title: "احذف حسابي", systemImage: "person.crop.circle.badge.xmark") }
                        .buttonStyle(.sary(.destructive))
                        .accessibilityIdentifier("privacy.deleteAccount")
                }
                .padding(.vertical, theme.space(.s))
            }
        }
    }

    private var modeFooter: String {
        switch ShareMode(rawValue: mode) ?? .balanced {
        case .precise: return "دقيق: كل ثانيتين تقريبًا وبأعلى دقة. الأفضل للقافلة، ويستهلك بطارية أكثر."
        case .balanced: return "متوازن: كل بضع ثوانٍ أو عند الحركة. يناسب أغلب الطلعات."
        case .saver: return "موفّر: أقل تكرارًا ودقة أقل قليلًا، لتطول البطارية."
        }
    }

    private func fact(_ icon: String, _ t: String) -> some View {
        HStack(alignment: .top, spacing: theme.space(.m)) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.palette.accentText).frame(width: 22)
            Text(t).saryText(.subhead).foregroundStyle(theme.palette.textPrimary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Delete account («احذف حسابي»)

/// App Store 5.1.1(v): delete the account from inside the app. Says exactly what goes and what
/// stays, asks the person to type «احذف», then calls DELETE /api/outings/me (see AppModel.deleteAccount).
struct DeleteAccountView: View {
    var back: () -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.sary) private var theme
    @State private var typed: String
    @State private var busy = false
    @State private var error: String?

    static let confirmWord = "احذف"

    init(back: @escaping () -> Void, typed: String = "") {
        self.back = back
        _typed = State(initialValue: typed)
    }

    private var confirmed: Bool { typed.trimmingCharacters(in: .whitespacesAndNewlines) == Self.confirmWord }

    var body: some View {
        let p = theme.palette
        SaryPage(title: "احذف حسابي", back: busy ? nil : back) {
            SaryInlineMessage(text: "الحذف نهائي ولا يمكن التراجع عنه، ورمز الاسترجاع لن يعمل بعده.", tone: .warning)
            SarySection(title: "يُحذف من الخادم") {
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    fact("person.text.rectangle", "اسمك وصورتك ورقم جوالك.")
                    fact("person.2.fill", "عضويتك في كل الطلعات. تخرج من الطلعات الجارية مثل «غادر الطلعة»: إذا كنت أمير الطلعة تنتقل الإمارة لنائبك أو لأقدم مشارك، وإذا ما بقي أحد تنتهي.")
                    fact("location.fill", "آخر موقع محفوظ لك، ورسائلك القصيرة، ونداء الطوارئ، ورمز «قناة الطلعة» الذي يوقظ جوالك.")
                    fact("flag.checkered", "ملخصات طلعاتك التي شاركتها.")
                    fact("bell.fill", "تنبيهات هذا الجهاز وأي جهاز آخر، ورمز الاسترجاع.")
                }
                .padding(.vertical, theme.space(.s))
            }
            SarySection(title: "يُمسح من هذا الجهاز") {
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    fact("key.fill", "هويتك المحفوظة، وموافقاتك على مشاركة الموقع، وسجل طلعاتك، وروابط الدعوة المحفوظة.")
                }
                .padding(.vertical, theme.space(.s))
            }
            SarySection(title: "يبقى") {
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    fact("arrow.down.circle.fill", "الخرائط التي نزّلتها بلا إنترنت: صور خرائط فقط، تبقى على جوالك وتحذفها من «الخرائط بلا إنترنت».")
                    fact("person.3.fill", "طلعات الربع وملخصاتهم تبقى لهم، ولا يظهر اسمك فيها بعد الآن.")
                    fact("paintbrush.fill", "إعدادات المظهر على هذا الجهاز.")
                }
                .padding(.vertical, theme.space(.s))
            }
            SaryTextField(title: "للتأكيد اكتب «\(Self.confirmWord)»", placeholder: Self.confirmWord, text: $typed, id: "deleteAccount.confirm",
                          maxLength: 12, disabled: busy)
            if let error { SaryInlineMessage(text: error, tone: .error).accessibilityIdentifier("deleteAccount.error") }
            Button { delete() } label: { SaryButtonLabel(title: "احذف حسابي نهائيًا", systemImage: "trash.fill", busy: busy) }
                .buttonStyle(.sary(.destructive))
                .disabled(!confirmed || busy)
                .accessibilityIdentifier("deleteAccount.submit")
            Button("تراجع") { back() }
                .buttonStyle(.sary(.plain))
                .disabled(busy)
        }
    }

    private func delete() {
        busy = true
        error = nil
        Task {
            let outcome = await model.deleteAccount()
            busy = false
            if case .failed(let m) = outcome { error = m + " لم يُحذف شيء." }
        }
    }

    private func fact(_ icon: String, _ t: String) -> some View {
        HStack(alignment: .top, spacing: theme.space(.m)) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.palette.accentText).frame(width: 22)
            Text(t).saryText(.subhead).foregroundStyle(theme.palette.textPrimary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension ShareMode {
    var label: String {
        switch self {
        case .precise: return "دقيق"
        case .balanced: return "متوازن"
        case .saver: return "موفّر"
        }
    }
}

// MARK: - Notifications

struct NotificationSettingsView: View {
    var back: () -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.sary) private var theme
    @State private var explaining = false
    /// «رسائل المحادثات» on the server (PUT /push/chat): the other members' pushes respect it.
    @State private var chatPush = true
    /// Shown only once the server answered (an older server has no chat: no toggle).
    @State private var chatPrefsLoaded = false
    @Environment(AppearanceSettings.self) private var appearance
    private var push: PushRegistrar { model.push }

    private func setChatPush(_ on: Bool) {
        let before = chatPush
        chatPush = on
        Task {
            do { chatPush = try await model.api.setChatPrefs(on).chat_push } catch { chatPush = before }
        }
    }

    var body: some View {
        let p = theme.palette
        SaryPage(title: "التنبيهات", back: back) {
            SarySection {
                SaryToggleRow(title: "التنبيهات", subtitle: "طوارئ ورسائل طلعاتك", systemImage: "bell.fill",
                              isOn: Binding(get: { push.enabled && push.state != .off }, set: { on in
                                  if on && !push.explained { explaining = true } else { Task { await push.setEnabled(on, signedIn: model.signedIn) } }
                              }), id: "notify.toggle")
            }
            stateCard
            if chatPrefsLoaded {
            SarySection(footer: "تقدر توقف تنبيهات المحادثات وحدها وتبقى تنبيهات الطوارئ.") {
                SaryToggleRow(title: "رسائل المحادثات", subtitle: "محادثة الطلعة والرسائل الخاصة", systemImage: "bubble.left.and.bubble.right.fill",
                              isOn: Binding(get: { chatPush }, set: { on in setChatPush(on) }), id: "notify.chat")
                    .disabled(!model.signedIn || model.isDemo)
            }
            }
            SarySection(title: "ما الذي يصلك") {
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    kind(SaryIcon.sos, p.emergency, "طوارئ", "تنبيه عاجل بصوت، حتى في وضع التركيز إذا سمحت بالتنبيهات العاجلة. يُستبدل بـ«أنا بخير» إذا انتهت.")
                    kind(SaryIcon.note, nil, "رسالة فوق السيارة", "بهدوء، بدون صوت.")
                    kind("bubble.left.and.bubble.right.fill", nil, "المحادثات", "تنبيه عادي بصوت لرسائل محادثة الطلعة والرسائل الخاصة، فقط إذا كنت خارج الطلعة أو الشاشة مقفلة. باسم المرسل كما يظهر في الطلعة.")
                    kind(SaryIcon.mic, nil, "قناة الطلعة", "صوت الربع مباشرة مثل اللاسلكي، حتى والشاشة مقفلة. تكتمها من إعدادات الطلعة.")
                }
                .padding(.vertical, theme.space(.s))
            }
            Text("الضغط على أي تنبيه يفتح الطلعة نفسها. وأنت داخل الطلعة تظهر الرسائل والطوارئ على الخريطة مباشرة.")
                .saryText(.footnote).foregroundStyle(p.textTertiary)
        }
        .task {
            await push.refresh(signedIn: model.signedIn)
            if model.signedIn, !model.isDemo, let p = try? await model.api.chatPrefs() { chatPush = p.chat_push; chatPrefsLoaded = true }
        }
        .sheet(isPresented: $explaining) {
            NotifyExplainerSheet(done: { explaining = false }).saryPresented(appearance)
        }
    }

    @ViewBuilder
    private var stateCard: some View {
        let (tone, text): (SaryTone, String) = {
            switch push.state {
            case .registered: return (.success, "مفعّلة: يصلك التنبيه حتى والتطبيق مغلق.")
            case .off: return (.info, "متوقفة. لن يصلك شيء والتطبيق مغلق.")
            case .notAsked: return (.info, "لم تُفعّل بعد. فعّلها ليصلك نداء الطوارئ والتطبيق مغلق.")
            case .denied: return (.warning, "رفضتها في إعدادات iOS. فعّلها من الإعدادات ← سَرى البارق ← الإشعارات.")
            case .waitingForToken: return (.info, "نجهّز التنبيهات مع Apple…")
            case .serverNotReady: return (.warning, "سمحت بالتنبيهات، لكن إرسالها والتطبيق مغلق لم يُفعّل على الخادم بعد. الآن تصلك داخل التطبيق فقط، وتشتغل تلقائيًا أول ما تُفعّل.")
            case .failed(let m): return (.error, m + " نعيد المحاولة عند فتح التطبيق.")
            }
        }()
        VStack(alignment: .leading, spacing: theme.space(.s)) {
            SaryInlineMessage(text: text, tone: tone)
                .accessibilityIdentifier("notify.state")
            if push.state == .denied {
                Button { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } } label: {
                    SaryButtonLabel(title: "افتح إعدادات iOS", systemImage: SaryIcon.settings)
                }
                .buttonStyle(.sary(.secondary))
            } else if push.state == .notAsked {
                Button { explaining = true } label: { SaryButtonLabel(title: "فعّل التنبيهات", systemImage: "bell.fill") }
                    .buttonStyle(.sary(.primary))
                    .accessibilityIdentifier("notify.enable")
            }
        }
        .padding(theme.space(.m))
        .sarySurface(radius: SaryRadius.m)
    }

    private func kind(_ icon: String, _ c: Color?, _ t: String, _ d: String) -> some View {
        HStack(alignment: .top, spacing: theme.space(.m)) {
            SaryRowIcon(systemImage: icon, color: c)
            VStack(alignment: .leading, spacing: 2) {
                Text(t).saryText(.body, weight: .bold).foregroundStyle(theme.palette.textPrimary)
                Text(d).saryText(.footnote).foregroundStyle(theme.palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - About

struct AboutView: View {
    var back: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        SaryPage(title: "حول سَرى البارق", back: back) {
            VStack(spacing: theme.space(.s)) {
                SaryMark(size: 88)
                Text("سَرى البارق").font(.sary(26, .heavy)).foregroundStyle(p.textPrimary)
                Text("الإصدار \(SaryFormat.digits(v).replacingOccurrences(of: "٫", with: ".")) (\(SaryFormat.digits(b)))").saryNumber(.subhead).foregroundStyle(p.textSecondary)
                    .accessibilityIdentifier("about.version")
            }
            .frame(maxWidth: .infinity)
            SarySection(title: "مصادر") {
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    Text("الخرائط © Mapbox و© OpenStreetMap المساهمون. صور الأقمار © Maxar وغيرها عبر Mapbox.")
                    Text("محطات الوقود من OpenStreetMap (ODbL).")
                    Text("خط «هوية» (ITF Huwiya Arabic).")
                    Text("مجسّم السيارة مبني على «Offroader SUV» (CC0).")
                    HiResLicenseNotice()
                    VoiceDenoiseLicenseNotice()
                    CampSitesAttributionNotice()
                    DesertGazetteerAttributionNotice()
                }
                .saryText(.subhead).foregroundStyle(p.textSecondary)
                .padding(.vertical, theme.space(.s))
            }
            Link(destination: URL(string: "https://www.mapbox.com/legal/tos")!) {
                SaryButtonLabel(title: "شروط Mapbox", systemImage: "doc.text")
            }
            .buttonStyle(.sary(.secondary))
        }
    }
}

/// «متقدم»: what used to hide behind taps on the version — the trail log export (GPX)
/// for the team, and the route provider.
struct AdvancedSettingsView: View {
    var back: () -> Void
    @Environment(\.sary) private var theme
    @State private var gpx: [(id: String, url: URL)] = []
    @AppStorage(NavProviderChoice.key) private var navProvider = NavProviderChoice.auto.rawValue

    var body: some View {
        let p = theme.palette
        SaryPage(title: "متقدم", back: back) {
            SarySection(title: "سجل المسار", footer: "سجل المسار من جوالك (نقاط الموقع الخام بدقتها، والمسار المنعّم، والمطابق مع الطرق) في ملف، لترسله لفريق سَرى البارق إذا طلبوه.") {
                if gpx.isEmpty {
                    Text("ما فيه مسار محفوظ على هذا الجوال.").saryText(.subhead).foregroundStyle(p.textSecondary)
                        .padding(.vertical, theme.space(.s))
                }
                ForEach(Array(gpx.enumerated()), id: \.offset) { n, item in
                    ShareLink(item: item.url) {
                        SaryButtonLabel(title: n == 0 ? "صدّر سجل المسار" : "صدّر سجل المسار · \(SaryFormat.number(n + 1))", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.sary(.secondary))
                    .accessibilityIdentifier("about.gpx.\(n)")
                }
            }
            SarySection(title: "مزوّد المسارات", footer: "«تلقائي» هو الافتراضي: مزوّد الخرائط بالزحام الحي في المدن والطرق المعبّدة (وقت وصول دقيق)، وخادمنا للبر والطرق اللي ما يغطيها أو إذا تعذّر. «فرق» يجرّب خادمنا أول دايم، والثالث ما يسأل خادمنا أبد.") {
                SarySegmented(options: NavProviderChoice.allCases, selection: Binding(
                    get: { NavProviderChoice(rawValue: navProvider) ?? .auto },
                    set: { navProvider = $0.rawValue }), label: \.label, id: "dev.navProvider")
            }
        }
        .onAppear { gpx = TrailGPX.outings().prefix(5).compactMap { id in TrailGPX.export(outingId: id).map { (id, $0) } } }
    }
}

/// Mapbox SDK telemetry. The SDK registers `MGLMapboxMetricsEnabled = true` and observes
/// the key (KVO), switching its events collection off/on at once. We leave its default.
enum MapboxTelemetry {
    static let key = "MGLMapboxMetricsEnabled"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

/// Settings → «المحظورين» (App Store 1.2): the people I blocked, each with «إلغاء الحظر».
/// Loads the server's list (`GET /me/blocks`); the phone's copy shows at once and offline.
struct BlockedUsersView: View {
    var back: () -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.sary) private var theme
    @State private var list: [BlockedUser] = BlockedUsers.load()
    @State private var busy: String?
    @State private var error: String?

    var body: some View {
        let p = theme.palette
        SaryPage(title: "المحظورين", subtitle: "ما تشوف رسائلهم ولا رسائلهم الصوتية، وما يقدرون يراسلونك على الخاص", back: back) {
            if let error { SaryInlineMessage(text: error, tone: .warning).accessibilityIdentifier("blocked.error") }
            SarySection(footer: "الطوارئ من أي أحد توصلك دايم، حتى لو حاظره. للسلامة.") {
                if list.isEmpty {
                    Text("ما حظرت أحد.").saryText(.subhead).foregroundStyle(p.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .accessibilityIdentifier("blocked.empty")
                }
                ForEach(Array(list.enumerated()), id: \.element.user_id) { i, b in
                    if i > 0 { SaryDivider() }
                    HStack(spacing: theme.space(.m)) {
                        SaryAvatar(name: b.display_name ?? "؟", color: 0x9AA5AD, size: 36)
                        Text(b.display_name ?? "عضو").saryText(.body, weight: .medium).foregroundStyle(p.textPrimary).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { Task { await unblock(b) } } label: {
                            Group {
                                if busy == b.user_id { ProgressView() } else { Text("إلغاء الحظر").saryText(.callout, weight: .bold) }
                            }
                            .foregroundStyle(p.accentText)
                            .padding(.horizontal, theme.space(.m))
                            .frame(minWidth: 44, minHeight: 44)
                            .background(Capsule().fill(p.sunken))
                        }
                        .buttonStyle(SaryPressStyle())
                        .disabled(busy != nil)
                        .accessibilityLabel(Text("إلغاء حظر \(b.display_name ?? "العضو")"))
                        .accessibilityIdentifier("blocked.unblock")
                    }
                    .padding(.vertical, theme.space(.xs))
                    .accessibilityIdentifier("blocked.row")
                }
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        guard !model.isDemo, let l = try? await model.api.listBlocks() else { return }
        list = l
        BlockedUsers.save(l)
    }

    private func unblock(_ b: BlockedUser) async {
        busy = b.user_id
        defer { busy = nil }
        do {
            if !model.isDemo { try await model.api.unblockUser(b.user_id) }
            BlockedUsers.remove(b.user_id)
            list.removeAll { $0.user_id == b.user_id }
            error = nil
        } catch {
            self.error = "ما قدرنا نلغي الحظر الحين. جرّب مرة ثانية."
        }
    }
}
