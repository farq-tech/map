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
            SaryTextField(title: "الاسم", placeholder: "اسمك كما يراه أصحابك", text: $name, id: "profile.name", maxLength: ServerRules.nameMax)
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

    var body: some View {
        SaryPage(title: "الإعدادات", back: back) {
            SarySection {
                SaryNavRow(title: "المظهر", detail: "الألوان، وضع القيادة والليل، حجم النص", systemImage: "paintbrush.fill", id: "settings.appearance") { open(.appearance) }
                SaryDivider()
                SaryNavRow(title: "الخصوصية", detail: "ما الذي يُشارك ومتى، البطارية، بياناتك", systemImage: "hand.raised.fill", id: "settings.privacy") { open(.privacy) }
                SaryDivider()
                SaryNavRow(title: "التنبيهات", detail: pushDetail, systemImage: "bell.fill", id: "settings.notifications") { open(.notifications) }
                SaryDivider()
                SaryNavRow(title: "الخرائط بلا إنترنت", detail: "احفظ منطقة الطلعة قبل ما تفقد التغطية", systemImage: "arrow.down.circle.fill", id: "settings.offline") { open(.offlineMaps) }
            }
            SarySection {
                SaryNavRow(title: "ملفي", detail: model.identity?.user.display_name, systemImage: "person.fill") { open(.profile) }
                SaryDivider()
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
                    fact("hand.tap.fill", "فقط بعد ما تضغط «شارك موقعي» داخل طلعة، وتوافق أول مرة على شاشة الموافقة.")
                    fact("iphone", "فقط والتطبيق مفتوح أمامك. إذا قفلت الشاشة أو خرجت يتوقف الإرسال، ولا يُرسل موقعك من الخلفية أبدًا.")
                    fact("point.topleft.down.to.point.bottomright.curvepath.fill", "«مساري» (طريقك في الطلعة) يُسجَّل على جوالك فقط، وبإذن «دائمًا» يستمر والشاشة مقفلة. لا يُرسل لأحد، ولا حتى للخادم، ويُمسح مع تسجيل الخروج أو حذف الحساب.")
                    fact("person.2.fill", "يراه أعضاء تلك الطلعة فقط، لا أحد غيرهم.")
                    fact("trash", "الخادم يحفظ آخر موقع فقط، ويحذفه إذا أوقفت المشاركة أو أُوقفت الطلعة أو انتهت.")
                }
                .padding(.vertical, theme.space(.s))
            }
            SarySection(title: "دقة المشاركة", footer: modeFooter) {
                SarySegmented(options: ShareMode.allCases, selection: Binding(get: { ShareMode(rawValue: mode) ?? .balanced }, set: { mode = $0.rawValue }),
                              label: { $0.label }, id: "privacy.mode")
                    .padding(.vertical, theme.space(.s))
            }
            SarySection(footer: "إذا فعّلته يرى أعضاء طلعتك نسبة بطارية جوالك وهل هو على الشاحن، ليعرفوا إذا قرب ينطفي. لا يُرسل شيء آخر.") {
                SaryToggleRow(title: "شارك نسبة البطارية", systemImage: "battery.75percent", isOn: $battery, id: "privacy.battery")
            }
            SarySection(title: "Mapbox", footer: "مكتبة الخرائط (Mapbox) ترسل افتراضيًا إحصاءات استخدام مجهولة لتحسين خرائطها. أوقفها هنا إن شئت؛ الخريطة تعمل مثل ما هي. هذا الخيار نفسه الموجود في زر «i» على الخريطة.") {
                SaryToggleRow(title: "ساهم في تحسين خرائط Mapbox", subtitle: "إحصاءات مجهولة يرسلها Mapbox", systemImage: "chart.bar.fill",
                              isOn: $mapboxTelemetry, id: "privacy.mapboxTelemetry")
            }
            SarySection(title: "ما الذي يُرسل للخادم", footer: "لا إعلانات، لا تتبع، ولا بيع بيانات.") {
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    fact("person.text.rectangle", "اسمك وصورتك (إن وضعتها) ورقمك (إن كتبته): يراها أعضاء طلعاتك.")
                    fact("location.fill", "موقعك أثناء المشاركة: آخر موقع فقط.")
                    fact(SaryIcon.note, "رسائلك القصيرة: ١٥ دقيقة ثم تختفي.")
                    fact(SaryIcon.mic, "مقاطع «اضغط وتكلم»: في ذاكرة الخادم ١٠ دقائق فقط.")
                    fact(SaryIcon.sos, "الطوارئ: مع آخر موقع حقيقي لك، وتنتهي خلال ساعة أو بـ«أنا بخير».")
                    fact("flag.checkered", "ملخص رحلتك: مجاميع فقط، ولا يُرسل إلا إذا اخترت «شارك ملخصي».")
                    fact("map", "الخرائط من Mapbox: تطلب صور الخريطة للمنطقة المعروضة، دون اسمك أو حسابك.")
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
                    fact("person.2.fill", "عضويتك في كل الطلعات. تخرج من الطلعات الجارية مثل «غادر الطلعة»: إذا كنت صاحبها تنتقل لمساعدك أو لأقدم عضو، وإذا ما بقي أحد تنتهي.")
                    fact("location.fill", "آخر موقع محفوظ لك، ورسائلك القصيرة، ونداء الطوارئ، ومقاطعك الصوتية.")
                    fact("flag.checkered", "ملخصات رحلاتك التي شاركتها.")
                    fact("bell.fill", "تنبيهات هذا الجهاز وأي جهاز آخر، ورمز الاسترجاع.")
                }
                .padding(.vertical, theme.space(.s))
            }
            SarySection(title: "يُمسح من هذا الجهاز") {
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    fact("key.fill", "هويتك المحفوظة، وموافقاتك على مشاركة الموقع، وسجل رحلاتك، وروابط الدعوة المحفوظة.")
                }
                .padding(.vertical, theme.space(.s))
            }
            SarySection(title: "يبقى") {
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    fact("arrow.down.circle.fill", "الخرائط التي نزّلتها بلا إنترنت: صور خرائط فقط، تبقى على جوالك وتحذفها من «الخرائط بلا إنترنت».")
                    fact("person.3.fill", "طلعات أصحابك وملخصاتهم تبقى لهم، ولا يظهر اسمك فيها بعد الآن.")
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
    @Environment(AppearanceSettings.self) private var appearance
    private var push: PushRegistrar { model.push }

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
            SarySection(title: "ما الذي يصلك") {
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    kind(SaryIcon.sos, p.emergency, "طوارئ", "تنبيه عاجل بصوت، حتى في وضع التركيز إذا سمحت بالتنبيهات العاجلة. يُستبدل بـ«أنا بخير» إذا انتهت.")
                    kind(SaryIcon.note, nil, "رسالة من المجموعة", "بهدوء، بدون صوت.")
                    kind(SaryIcon.mic, nil, "مقطع صوتي", "بهدوء، بدون صوت.")
                }
                .padding(.vertical, theme.space(.s))
            }
            Text("الضغط على أي تنبيه يفتح الطلعة نفسها. وأنت داخل الطلعة تظهر الرسائل والطوارئ على الخريطة مباشرة.")
                .saryText(.footnote).foregroundStyle(p.textTertiary)
        }
        .task { await push.refresh(signedIn: model.signedIn) }
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
    /// Hidden developer settings: always in DEBUG, after 7 taps on the version in Release.
    @AppStorage("sary.dev.unlocked") private var devUnlocked = false
    @AppStorage(NavProviderChoice.key) private var navProvider = NavProviderChoice.mapbox.rawValue
    @State private var versionTaps = 0

    private var showDev: Bool {
        #if DEBUG
        return true
        #else
        return devUnlocked
        #endif
    }

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
                    .onTapGesture {
                        versionTaps += 1
                        if versionTaps >= 7 { devUnlocked = true }
                    }
            }
            .frame(maxWidth: .infinity)
            if showDev {
                SarySection(title: "مزوّد المسارات", footer: "Mapbox هو الافتراضي. «فرق» يجرّب خادم الشركة (Valhalla) أولًا، و«تلقائي» يستخدمه فقط إذا كان مفعّلًا على الخادم؛ وإذا ما قدر يرد نرجع لـ Mapbox تلقائيًا.") {
                    SarySegmented(options: NavProviderChoice.allCases, selection: Binding(
                        get: { NavProviderChoice(rawValue: navProvider) ?? .mapbox },
                        set: { navProvider = $0.rawValue }), label: \.label, id: "dev.navProvider")
                }
            }
            SarySection(title: "مصادر") {
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    Text("الخرائط © Mapbox و© OpenStreetMap المساهمون. صور الأقمار © Maxar وغيرها عبر Mapbox.")
                    Text("محطات الوقود من OpenStreetMap (ODbL).")
                    Text("خط «تجوّل» (Tajawal) برخصة SIL Open Font License.")
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

/// Mapbox SDK telemetry. The SDK registers `MGLMapboxMetricsEnabled = true` and observes
/// the key (KVO), switching its events collection off/on at once. We leave its default.
enum MapboxTelemetry {
    static let key = "MGLMapboxMetricsEnabled"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}
