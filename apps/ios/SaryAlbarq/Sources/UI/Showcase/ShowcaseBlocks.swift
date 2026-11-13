#if DEBUG
import SwiftUI

struct ShowcaseBlocks: View {
    var section: ShowcaseSection
    var lab: ShowcaseLab

    var body: some View {
        switch section {
        case .tokens: TokensBlocks()
        case .buttons: ButtonsBlocks()
        case .controls: ControlsBlocks()
        case .status: StatusBlocks()
        case .alerts: AlertsBlocks()
        case .sos: SOSBlocks()
        case .ptt: PTTBlocks()
        case .sheet: SheetBlocks()
        case .participants: ParticipantsBlocks()
        case .rally: RallyBlocks()
        case .overlays: OverlaysBlocks()
        case .states: StatesBlocks()
        case .inputs: InputsBlocks()
        case .dialogs: DialogsBlocks()
        case .appearance: SaryAppearancePanel(settings: lab.settings)
        case .stage: EmptyView()
        }
    }
}

// MARK: - Tokens

private struct TokensBlocks: View {
    @Environment(\.sary) private var theme
    @State private var tick = 0

    var body: some View {
        let p = theme.palette
        ShowcaseBlock(index: 0, title: "الألوان", note: "محلولة للوضع الحالي — لا قيم ثابتة داخل المكوّنات") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                swatch("الخلفية", p.background)
                swatch("الورقة", p.elevated)
                swatch("البطاقة", p.surface)
                swatch("الحقل", p.sunken)
                swatch("نص أساسي", p.textPrimary)
                swatch("نص ثانوي", p.textSecondary)
                swatch("التمييز", p.accent)
                swatch("طوارئ", p.emergency)
                swatch("مباشر", p.live)
                swatch("تنبيه", p.warning)
                swatch("قديم", p.stale)
                swatch("واجهة معتمة", p.chromeOpaque)
            }
        }
        ShowcaseBlock(index: 1, title: "ألوان السيارات", note: "بترتيب الانضمام — مطابقة للويب") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 12) {
                ForEach(Array(SaryCarColors.palette.enumerated()), id: \.offset) { i, c in
                    VStack(spacing: 4) {
                        SaryAvatar(name: SaryFormat.number(i + 1), color: c, size: 40)
                        Text(SaryCarColors.names[i]).saryText(.caption, weight: .medium).foregroundStyle(p.textSecondary)
                        Text(String(format: "#%06X", c)).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.textTertiary)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
            }
        }
        ShowcaseBlock(index: 2, title: "الخطوط", note: "تجوال مع حجم النص الديناميكي") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(SaryTextStyle.allCases, id: \.self) { s in
                    HStack(alignment: .firstTextBaseline) {
                        Text("طلعة البر ١٢٣").saryText(s).foregroundStyle(p.textPrimary)
                        Spacer()
                        Text("\(s.label) \(Int(s.size))").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.textTertiary)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
            }
            .padding(theme.space(.l))
            .sarySurface(radius: SaryRadius.m)
        }
        ShowcaseBlock(index: 3, title: "أرقام ثابتة العرض", note: "المسافات والمؤقتات لا تهتز أثناء التحديث") {
            let values = [111, 888, 1_404, 9_999, 61_000]
            let v = values[tick % values.count]
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(SaryFormat.distance(meters: Double(v))).saryNumber(.title).foregroundStyle(p.textPrimary)
                    Spacer()
                    Text("saryNumber").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.liveText)
                }
                HStack {
                    Text(SaryFormat.distance(meters: Double(v))).saryText(.title).foregroundStyle(p.textSecondary)
                    Spacer()
                    Text("Huwiya (متغير)").font(.system(size: 11)).foregroundStyle(p.emergencyText)
                }
                Text(SaryFormat.clock(seconds: tick * 7 % 600)).saryNumber(.headline).foregroundStyle(p.textPrimary)
            }
            .padding(theme.space(.l))
            .sarySurface(radius: SaryRadius.m)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    tick += 1
                }
            }
        }
        ShowcaseBlock(index: 4, title: "المسافات والزوايا والظلال") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(SarySpace.allCases, id: \.self) { s in
                    HStack {
                        Text("\(Int(theme.space(s)))").saryNumber(.caption).foregroundStyle(p.textTertiary).frame(width: 28)
                        Capsule().fill(p.accent).frame(width: theme.space(s) * 4, height: 8)
                    }
                }
                HStack(spacing: 12) {
                    ForEach([SaryRadius.xs, SaryRadius.s, SaryRadius.m, SaryRadius.l, SaryRadius.xl], id: \.self) { r in
                        RoundedRectangle(cornerRadius: r, style: .continuous).fill(p.surface)
                            .frame(width: 52, height: 52)
                            .overlay(Text("\(Int(r))").saryNumber(.caption).foregroundStyle(p.textSecondary))
                    }
                }
                HStack(spacing: 16) {
                    ForEach(SaryShadow.allCases, id: \.self) { s in
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.surface)
                            .frame(width: 60, height: 44).saryShadow(s, theme)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        ShowcaseBlock(index: 5, title: "الزجاج فوق الخريطة", note: theme.usesLiquidGlass ? "Liquid Glass (iOS 26+)" : "البديل: مادة + لون + خط رفيع") {
            ShowcaseMapStrip(height: 150) {
                HStack(spacing: 10) {
                    ForEach(SaryGlassIntensity.allCases) { g in
                        Text(g.label)
                            .saryText(.callout, weight: .bold)
                            .foregroundStyle(p.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous), role: .control)
                            .environment(\.sary, glassTheme(g))
                    }
                }
            }
        }
        ShowcaseBlock(index: 6, title: "الرموز") {
            let icons = [SaryIcon.locate, SaryIcon.fitGroup, SaryIcon.note, SaryIcon.nearest, SaryIcon.sos, SaryIcon.mic,
                         SaryIcon.rally, SaryIcon.connection, SaryIcon.gpsOff, SaryIcon.offline, SaryIcon.pause, SaryIcon.phone,
                         SaryIcon.directions, SaryIcon.drive, SaryIcon.night, SaryIcon.back]
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 8)], spacing: 8) {
                ForEach(icons, id: \.self) { i in
                    Image(systemName: i).font(.system(size: 20, weight: .semibold)).foregroundStyle(p.textPrimary)
                        .frame(width: 48, height: 48).sarySurface(radius: SaryRadius.s)
                }
            }
        }
    }

    private func glassTheme(_ g: SaryGlassIntensity) -> SaryTheme {
        var t = theme
        t.glass = g
        return t
    }

    private func swatch(_ name: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c).frame(height: 44)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.palette.stroke, lineWidth: 1))
            Text(name).saryText(.caption, weight: .medium).foregroundStyle(theme.palette.textSecondary)
        }
    }
}

// MARK: - Buttons

private struct ButtonsBlocks: View {
    @Environment(\.sary) private var theme
    @State private var busy = false

    var body: some View {
        ShowcaseBlock(index: 0, title: "الأنواع") {
            VStack(spacing: 10) {
                Button {} label: { SaryButtonLabel(title: "ابدأ الطلعة", systemImage: "play.fill") }.buttonStyle(.saryPrimary)
                Button {} label: { SaryButtonLabel(title: "شارك رابط الدعوة", systemImage: SaryIcon.share) }.buttonStyle(.sarySecondary)
                Button {} label: { SaryButtonLabel(title: "أنهِ الطلعة للجميع", systemImage: "stop.fill") }.buttonStyle(.saryDestructive)
                Button("لاحقًا") {}.buttonStyle(.saryPlain)
                Button("غادر الطلعة") {}.buttonStyle(.sary(.plainDestructive))
            }
        }
        ShowcaseBlock(index: 1, title: "الحالات", note: "عادي • معطل • جارٍ التحميل (بلا قفز في العرض)") {
            VStack(spacing: 10) {
                Button {} label: { SaryButtonLabel(title: "انضم", systemImage: "person.badge.plus") }
                    .buttonStyle(.saryPrimary).disabled(true)
                Button { busy.toggle() } label: {
                    SaryButtonLabel(title: "انضم للطلعة", systemImage: "person.badge.plus", busy: busy, busyTitle: "جارٍ الانضمام…")
                }
                .buttonStyle(.saryPrimary)
                .accessibilityIdentifier("outing-join-submit")
                Button {} label: { SaryButtonLabel(title: "حفظ", busy: true, busyTitle: "جارٍ الحفظ…") }.buttonStyle(.sarySecondary)
            }
        }
        ShowcaseBlock(index: 2, title: "مدمجة") {
            HStack(spacing: 8) {
                Button {} label: { SaryButtonLabel(title: "اتجه", systemImage: SaryIcon.directions) }.buttonStyle(.sary(.primary, width: .hug, compact: true))
                Button {} label: { SaryButtonLabel(title: "أظهرها", systemImage: SaryIcon.showOnMap) }.buttonStyle(.sary(.secondary, width: .hug, compact: true))
                Button("إزالة") {}.buttonStyle(.sary(.destructive, width: .hug, compact: true))
            }
        }
        ShowcaseBlock(index: 3, title: "فوق الخريطة", note: "زجاج في ٢٦، مادة في ١٧–٢٥، معتم في القيادة") {
            ShowcaseMapStrip(height: 140) {
                HStack(spacing: 10) {
                    Button {} label: { SaryButtonLabel(title: "إعادة التوسيط", systemImage: SaryIcon.locate) }.buttonStyle(.sary(.glass))
                    Button {} label: { SaryButtonLabel(title: "انضم", systemImage: "plus") }.buttonStyle(.sary(.primary, width: .hug))
                }
            }
        }
        ShowcaseBlock(index: 4, title: "أزرار دائرية") {
            HStack(spacing: 12) {
                SaryIconButton(systemImage: SaryIcon.close, label: "إغلاق", id: "sheet-close") {}
                SaryIconButton(systemImage: SaryIcon.share, label: "مشاركة") {}
                SaryIconButton(systemImage: SaryIcon.check, label: "خلاص", tinted: true) {}
            }
        }
    }
}

// MARK: - Map controls

private struct ControlsBlocks: View {
    @Environment(\.sary) private var theme
    @State private var axis: Axis = .vertical
    @State private var following = false
    @State private var labels = false

    var body: some View {
        let items = theme.drive
            ? Array(SaryMapControlItem.liveDefaults(following: following).prefix(2))
            : SaryMapControlItem.liveDefaults(following: following, unreadNotes: 2)
        ShowcaseBlock(index: 0, title: "مجموعة الأزرار", note: "عمود ⇄ صف — في ٢٦ تذوب الأقراص الزجاجية وتتشكل من جديد") {
            ShowcaseMapStrip(height: 300, alignment: axis == .vertical ? .leading : .bottom) {
                SaryControlCluster(items: items, axis: axis, showsLabels: labels) { id in
                    if id == "locate" { following.toggle() }
                }
            }
            HStack(spacing: 8) {
                Button { axis = axis == .vertical ? .horizontal : .vertical } label: {
                    SaryButtonLabel(title: axis == .vertical ? "حوّل لصف" : "حوّل لعمود", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.sary(.secondary, compact: true))
                .accessibilityIdentifier("showcase-morph")
                Button { labels.toggle() } label: { SaryButtonLabel(title: labels ? "بدون أسماء" : "مع الأسماء", systemImage: "textformat") }
                    .buttonStyle(.sary(.secondary, compact: true))
            }
        }
        ShowcaseBlock(index: 1, title: "زر منفرد", note: "عادي • مفعّل (يتبع موقعي) • مع شارة") {
            ShowcaseMapStrip(height: 120) {
                HStack(spacing: 16) {
                    SaryMapControlButton(item: .init(id: "a", systemImage: SaryIcon.locate, label: "موقعي", accessibilityID: "outing-locate")) {}
                    SaryMapControlButton(item: .init(id: "b", systemImage: SaryIcon.locateFollow, label: "موقعي", accessibilityID: "x1", isActive: true)) {}
                    SaryMapControlButton(item: .init(id: "c", systemImage: SaryIcon.note, label: "رسالة", accessibilityID: "x2", badge: 3)) {}
                    SaryMapControlButton(item: .init(id: "d", systemImage: SaryIcon.layers, label: "الطبقات", accessibilityID: "x3")) {}
                }
            }
        }
    }
}

// MARK: - Status capsule

private struct StatusBlocks: View {
    @State private var e1 = false
    @State private var e2 = false
    @State private var e3 = true
    @State private var e4 = false

    var body: some View {
        ShowcaseBlock(index: 0, title: "كل شيء سليم") {
            ShowcaseMapStrip(height: 96, alignment: .top) {
                SaryStatusCapsule(outingName: "طلعة الثمامة", status: .active, connection: .connected, sharing: .sharing, warnings: [], expanded: $e1)
            }
        }
        ShowcaseBlock(index: 1, title: "جارٍ الاتصال • موقع ضعيف") {
            ShowcaseMapStrip(height: 96, alignment: .top) {
                SaryStatusCapsule(outingName: "طلعة الثمامة", status: .active, connection: .connecting, sharing: .starting, warnings: [.weakGPS], expanded: $e2)
            }
        }
        ShowcaseBlock(index: 2, title: "بلا إنترنت • التنبيهات مفتوحة", note: "اضغط الشريط لفتح أو طي التنبيهات") {
            ShowcaseMapStrip(height: 300, alignment: .top) {
                SaryStatusCapsule(outingName: "طلعة نفود الدهناء الكبرى مع الشباب", status: .active, connection: .offline, sharing: .sharing,
                                  warnings: [.noInternet, .weakGPS, .keepScreenOn], expanded: $e3)
            }
        }
        ShowcaseBlock(index: 3, title: "الطلعة متوقفة • الموقع مقفل") {
            ShowcaseMapStrip(height: 96, alignment: .top) {
                SaryStatusCapsule(outingName: "كشتة العيد", status: .paused, connection: .connected, sharing: .paused, warnings: [.locationOff], expanded: $e4)
            }
        }
    }
}

// MARK: - Alerts

private struct AlertsBlocks: View {
    @State private var alerts = Mock.alerts
    @State private var expanded = false
    @State private var n = 0

    var body: some View {
        ShowcaseBlock(index: 0, title: "تحت الشريط، لا تغطيه", note: "الأحدث أولًا • أقصى ٣ • الباقي يتجمع") {
            ShowcaseMapStrip(height: 400, alignment: .top) {
                VStack(spacing: 10) {
                    SaryStatusCapsule(outingName: "طلعة الثمامة", status: .active, connection: .connected, sharing: .sharing, warnings: [], expanded: $expanded)
                    SaryAlertLane(alerts: alerts, dismiss: { id in alerts.removeAll { $0.id == id } })
                }
            }
            HStack(spacing: 8) {
                Button("أضف تنبيه") {
                    n += 1
                    alerts.insert(.init(id: "n\(n)", kind: .note(senderName: "نورة", senderColor: SaryCarColors.palette[2], text: "وصلت المحطة \(SaryFormat.number(n))")), at: 0)
                }
                .buttonStyle(.sary(.secondary, compact: true))
                Button("إعادة") { alerts = Mock.alerts }.buttonStyle(.sary(.secondary, compact: true))
            }
        }
        ShowcaseBlock(index: 1, title: "الصوت والإشعار القصير", note: "تشغيل • جارٍ التحميل • نص قصير") {
            ShowcaseMapStrip(height: 260, alignment: .top) {
                VStack(spacing: 10) {
                    SaryVoiceBanner(clip: Mock.voicePlaying)
                    SaryVoiceBanner(clip: Mock.voiceLoading)
                    SaryAlertCard(alert: .init(id: "t", kind: .toast("تم نسخ الرابط")))
                }
            }
        }
    }
}

// MARK: - SOS

private struct SOSBlocks: View {
    @Environment(\.sary) private var theme
    @State private var mine: MySOSUI = .none
    @State private var showFull = false

    var body: some View {
        ShowcaseBlock(index: 0, title: "اضغط مطولًا ثانية", note: "حلقة تمتلئ • اهتزاز يتصاعد • ثم إرسال") {
            ShowcaseMapStrip(height: 170) {
                HStack(spacing: 34) {
                    VStack(spacing: 8) {
                        SarySOSButton(state: mine) {
                            mine = .sending
                            Task {
                                try? await Task.sleep(nanoseconds: 1_400_000_000)
                                mine = .active(since: Date())
                            }
                        }
                        label("جرّبه")
                    }
                    VStack(spacing: 8) { SarySOSButton(state: .sending); label("يرسل") }
                    VStack(spacing: 8) { SarySOSButton(state: .active(since: Mock.ago(1))); label("أُرسل") }
                }
            }
            if mine != .none {
                Button("صفّر") { mine = .none }.buttonStyle(.sary(.secondary, compact: true))
            }
        }
        ShowcaseBlock(index: 1, title: "شريط طوارئي") {
            SaryMySOSStrip(since: Mock.ago(1), now: Mock.now)
        }
        ShowcaseBlock(index: 2, title: "طوارئ صديق: شريط ثابت") {
            SaryFriendSOSStrip(alert: { var a = Mock.sosIncoming; a.acknowledged = true; return a }(), now: Mock.now)
        }
        ShowcaseBlock(index: 3, title: "طوارئ صديق: ملء الشاشة") {
            SaryFriendSOSAlert(alert: Mock.sosIncoming, now: Mock.now)
                .frame(height: 640)
                .clipShape(RoundedRectangle(cornerRadius: SaryRadius.xl, style: .continuous))
            Button { showFull = true } label: { SaryButtonLabel(title: "اعرضه بملء الشاشة", systemImage: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.sary(.secondary))
                .fullScreenCover(isPresented: $showFull) {
                    SaryFriendSOSAlert(alert: Mock.sosIncoming, now: Mock.now, show: { showFull = false }, call: { showFull = false })
                        .saryTheme(theme)
                }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).saryText(.caption).foregroundStyle(theme.palette.textPrimary)
            .padding(.horizontal, 8).padding(.vertical, 2).saryGlass(Capsule())
    }
}

// MARK: - PTT

private struct PTTBlocks: View {
    @State private var state: PTTStateUI = .idle
    @State private var task: Task<Void, Never>?

    var body: some View {
        ShowcaseBlock(index: 0, title: "الحالات") {
            ShowcaseMapStrip(height: 180) {
                HStack(spacing: 18) {
                    SaryPTTButton(state: .idle)
                    SaryPTTButton(state: .arming)
                    SaryPTTButton(state: .talking(seconds: 7, remaining: 53))
                    SaryPTTButton(state: .listening(name: "فهد", color: SaryCarColors.palette[1]))
                    SaryPTTButton(state: .muted)
                }
            }
        }
        ShowcaseBlock(index: 1, title: "جرّبه", note: "اضغط مع الاستمرار وتكلم • ارفع إصبعك لتتوقف") {
            ShowcaseMapStrip(height: 190) {
                SaryPTTButton(state: state, actions: .init(
                    pressBegan: {
                        task?.cancel()
                        state = .arming
                        task = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            var s = 0
                            while !Task.isCancelled {
                                state = .talking(seconds: s, remaining: max(0, 60 - s))
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                                s += 1
                            }
                        }
                    },
                    pressEnded: {
                        task?.cancel()
                        state = .idle
                    },
                    cancelled: { task?.cancel(); state = .idle }
                ))
            }
        }
    }
}

// MARK: - Sheet

private struct SheetBlocks: View {
    @Environment(\.sary) private var theme
    @State private var tab: LiveTabUI = .group

    var body: some View {
        ShowcaseBlock(index: 0, title: "مصغّرة", note: "سطر الملخص فقط — الخريطة تبقى قابلة للمس") {
            ShowcaseMapStrip(height: 150, alignment: .bottom) {
                SarySheetFrame(height: SheetDetentUI.peekHeight(drive: theme.drive)) {
                    SarySheetSummary(participants: Mock.three, detent: .peek)
                }
                .padding(-14)
            }
        }
        ShowcaseBlock(index: 1, title: "نصف") {
            ShowcaseMapStrip(height: 430, alignment: .bottom) {
                SarySheetFrame(height: 400) {
                    SheetBody(tab: $tab, detent: .half)
                }
                .padding(-14)
            }
        }
        ShowcaseBlock(index: 2, title: "كاملة", note: "الورقة الحقيقية تستخدم presentationDetents الأصلية — جرّبها في مسرح الخريطة") {
            ShowcaseMapStrip(height: 640, alignment: .bottom) {
                SarySheetFrame(height: 620) {
                    SheetBody(tab: $tab, detent: .full)
                }
                .padding(-14)
            }
        }
    }
}

/// Sheet content used by the showcase frames and the map stage's real sheet.
struct SheetBody: View {
    @Binding var tab: LiveTabUI
    var detent: SheetDetentUI
    var participants: [ParticipantUI] = Mock.all
    var expand: () -> Void = {}
    @Environment(\.sary) private var theme

    var body: some View {
        VStack(spacing: theme.space(.s)) {
            SarySheetSummary(participants: participants, detent: detent, expand: expand)
            if detent != .peek {
                SaryTabBar(selection: $tab).padding(.horizontal, theme.space(.l))
                ScrollView {
                    VStack(spacing: theme.space(.m)) {
                        switch tab {
                        case .group:
                            SaryRallyCard(rally: Mock.rally, canManage: true)
                            VStack(spacing: 0) {
                                ForEach(participants) { p in
                                    SaryParticipantRow(participant: p, now: Mock.now)
                                    if p.id != participants.last?.id { SaryDivider().padding(.leading, 60) }
                                }
                            }
                            .padding(.vertical, theme.space(.xs))
                            .sarySurface(radius: SaryRadius.l)
                        case .trip:
                            SaryQRCode(text: "https://sary.sa/j/7H2KQ", size: 150)
                            Text("sary.sa/j/7H2KQ").font(.system(size: 15, weight: .semibold, design: .monospaced))
                                .foregroundStyle(theme.palette.textPrimary).environment(\.layoutDirection, .leftToRight)
                            HStack(spacing: 8) {
                                Button {} label: { SaryButtonLabel(title: "نسخ", systemImage: SaryIcon.copy) }.buttonStyle(.sarySecondary)
                                Button {} label: { SaryButtonLabel(title: "مشاركة", systemImage: SaryIcon.share) }.buttonStyle(.saryPrimary)
                            }
                        case .more, .map:
                            SarySection(title: "مشاركتي") {
                                SaryToggleRow(title: "أوقف مشاركة موقعي", systemImage: SaryIcon.pause, isOn: .constant(false))
                                SaryDivider()
                                SaryToggleRow(title: "شارك البطارية", systemImage: SaryIcon.battery(60), isOn: .constant(true))
                            }
                        }
                    }
                    .padding(.horizontal, theme.space(.l))
                    .padding(.bottom, theme.space(.xl))
                }
                .scrollDisabled(detent == .half && false)
            }
        }
    }
}

// MARK: - Participants

private struct ParticipantsBlocks: View {
    @Environment(\.sary) private var theme

    var body: some View {
        ShowcaseBlock(index: 0, title: "صفوف المشاركين", note: "مباشر • قديم (رمادي، حلقة متقطعة، قبل ٤ د) • متوقف (رمز إيقاف)") {
            VStack(spacing: 0) {
                ForEach(Mock.all) { p in
                    SaryParticipantRow(participant: p, now: Mock.now)
                    if p.id != Mock.all.last?.id { SaryDivider().padding(.leading, 60) }
                }
            }
            .padding(.vertical, theme.space(.xs))
            .sarySurface(radius: SaryRadius.l)
        }
        ShowcaseBlock(index: 1, title: "الصور الرمزية والحضور") {
            HStack(spacing: 16) {
                VStack { SaryAvatar(name: "فهد", color: SaryCarColors.palette[1], size: 48); SaryPresenceBadge(presence: .live, now: Mock.now) }
                VStack { SaryAvatar(name: "سعد", color: SaryCarColors.palette[3], presence: .stale(since: Mock.ago(4)), size: 48); SaryPresenceBadge(presence: .stale(since: Mock.ago(4)), now: Mock.now) }
                VStack { SaryAvatar(name: "ريم", color: SaryCarColors.palette[4], presence: .paused, size: 48); SaryPresenceBadge(presence: .paused, now: Mock.now) }
            }
            .frame(maxWidth: .infinity)
        }
        ShowcaseBlock(index: 2, title: "اتجاه لا ينعكس مع العربية", note: "السهم يشير للاتجاه الحقيقي: ٠° أمام، ٩٠° يمين") {
            HStack(spacing: 18) {
                ForEach([0.0, 45, 90, 180, 270], id: \.self) { d in
                    VStack(spacing: 4) {
                        SaryBearingArrow(degrees: d, color: theme.palette.accentText, size: 22)
                        Text("\(SaryFormat.number(Int(d)))°").saryNumber(.caption).foregroundStyle(theme.palette.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        ShowcaseBlock(index: 3, title: "بطاقة المشارك") {
            SaryParticipantCard(state: .init(participant: Mock.fahad, now: Mock.now, canManage: true))
                .sarySurface(radius: SaryRadius.xl)
            SaryParticipantCard(state: .init(participant: Mock.saad, now: Mock.now, canManage: false))
                .sarySurface(radius: SaryRadius.xl)
        }
    }
}

// MARK: - Rally & stations

private struct RallyBlocks: View {
    @Environment(\.sary) private var theme
    var body: some View {
        ShowcaseBlock(index: 0, title: "نقطة التجمع") {
            SaryRallyCard(rally: Mock.rally, canManage: true)
            SaryRallyCard(rally: Mock.rallyDone, canManage: false)
        }
        ShowcaseBlock(index: 1, title: "بلا نقطة تجمع", note: "أمير الطلعة • عضو") {
            SaryRallyCard(rally: nil, canManage: true)
            SaryRallyCard(rally: nil, canManage: false)
        }
        ShowcaseBlock(index: 2, title: "أقرب المحطات") {
            VStack(spacing: 0) {
                ForEach(Mock.stations) { s in
                    SaryStationRow(station: s)
                    if s.id != Mock.stations.last?.id { SaryDivider() }
                }
            }
            .padding(.horizontal, theme.space(.l))
            .sarySurface(radius: SaryRadius.l)
        }
    }
}

// MARK: - Overlays

private struct OverlaysBlocks: View {
    @Environment(\.sary) private var theme
    var body: some View {
        ShowcaseBlock(index: 0, title: "الأسماء والسيارات", note: "أنت • مباشر • قديم • متوقف") {
            ShowcaseMapStrip(height: 230) {
                HStack(alignment: .bottom, spacing: 20) {
                    marker(Mock.me, heading: 20)
                    marker(Mock.fahad, heading: -30, note: true)
                    marker(Mock.saad, heading: 100)
                    marker(Mock.reem, heading: 200)
                }
            }
        }
        ShowcaseBlock(index: 1, title: "أسهم الحافة", note: "تدور نحو الصديق خارج الشاشة") {
            ShowcaseMapStrip(height: 210) {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        SaryEdgeArrowChip(chip: .init(name: "نورة", color: SaryCarColors.palette[2], distanceMeters: 2_400, bearingDegrees: -40, isStale: false))
                        SaryEdgeArrowChip(chip: .init(name: "فهد", color: SaryCarColors.palette[1], distanceMeters: 900, bearingDegrees: 70, isStale: false))
                    }
                    HStack(spacing: 12) {
                        SaryEdgeArrowChip(chip: .init(name: "سعد", color: SaryCarColors.palette[3], distanceMeters: 6_100, bearingDegrees: 160, isStale: true))
                        SaryEdgeArrowChip(chip: .init(name: "مشعل", color: SaryCarColors.palette[9], distanceMeters: 15_000, bearingDegrees: 250, isStale: false))
                    }
                }
            }
        }
        ShowcaseBlock(index: 2, title: "علم التجمع والفقاعة") {
            ShowcaseMapStrip(height: 170) {
                HStack(spacing: 40) {
                    SaryRallyFlag(marker: .init(label: "نقطة التجمع"))
                    SaryRallyFlag(marker: .init(label: nil))
                    SaryNoteBubble(bubble: .init(text: "اصبروا لي عند المحطة الجاية، بنعبّي بنزين", color: SaryCarColors.palette[2]))
                }
            }
        }
        ShowcaseBlock(index: 3, title: "وضع النقاط") {
            ShowcaseMapStrip(height: 150) {
                HStack(spacing: 28) {
                    marker(Mock.me, heading: 0)
                    marker(Mock.noura, heading: 0)
                    marker(Mock.saad, heading: 0)
                }
                .environment(\.sary, { var t = theme; t.participantMarker = .dots; return t }())
            }
        }
    }

    private func marker(_ p: ParticipantUI, heading: Double, note: Bool = false) -> some View {
        VStack(spacing: 4) {
            if note, let n = p.note { SaryNoteBubble(bubble: .init(text: n, color: p.color)) }
            SaryNameChip(chip: .init(name: p.name, color: p.color, isMe: p.isMe, presence: p.presence, hasVoice: p.hasVoice, now: Mock.now))
            SaryCarMarker(color: p.color, heading: heading, presence: p.presence, isMe: p.isMe)
        }
    }
}

// MARK: - States

private struct StatesBlocks: View {
    var body: some View {
        ShowcaseBlock(index: 0, title: "تحميل") {
            VStack(spacing: 0) { SarySkeletonRow(); SarySkeletonRow(); SarySkeletonRow() }.sarySurface(radius: SaryRadius.l)
            SaryStateView(kind: .loading("جارٍ البحث عن أقرب محطة…")).sarySurface(radius: SaryRadius.l)
        }
        ShowcaseBlock(index: 1, title: "فارغ") {
            SaryStateView(kind: .empty(title: "ما فيه طلعات بعد", message: "أنشئ طلعة وادعُ أصدقاءك برابط", systemImage: "car.2"),
                          actionTitle: "طلعة جديدة").sarySurface(radius: SaryRadius.l)
        }
        ShowcaseBlock(index: 2, title: "خطأ") {
            SaryStateView(kind: .error(title: "تعذّر التحميل", message: "تأكد من الاتصال وحاول مرة ثانية"), actionTitle: "حاول مرة ثانية")
                .sarySurface(radius: SaryRadius.l)
        }
        ShowcaseBlock(index: 3, title: "بلا إنترنت") {
            SaryStateView(kind: .offline(message: nil)).sarySurface(radius: SaryRadius.l)
            SaryBanner(text: "بلا إنترنت • نرسل موقعك أول ما يرجع الاتصال", tone: .warning, systemImage: SaryIcon.offline)
            SaryBanner(text: "انتهت صلاحية الرابط", tone: .error)
            SaryBanner(text: "تم حفظ المنطقة للاستخدام بلا إنترنت", tone: .success, systemImage: SaryIcon.checkCircle)
        }
    }
}

// MARK: - Inputs

private struct InputsBlocks: View {
    @State private var name = "طلعة الثمامة"
    @State private var empty = ""
    @State private var phone = "0551234"
    @State private var code = "K7Q2-9XPA"
    @State private var t1 = true
    @State private var t2 = false
    @State private var mode: SaryTriMode = .auto
    @State private var size: SaryButtonSize = .regular

    var body: some View {
        ShowcaseBlock(index: 0, title: "حقول النص") {
            VStack(spacing: 16) {
                SaryTextField(title: "اسم الطلعة", placeholder: "مثل: طلعة الثمامة", text: $name, id: "outing-name-input", maxLength: 40)
                SaryTextField(title: "اسمك", placeholder: "كيف يشوفك الأصدقاء", text: $empty, id: "name-empty", help: "يظهر فوق سيارتك")
                SaryTextField(title: "رقم الجوال", placeholder: "05XXXXXXXX", text: $phone, id: "phone", keyboard: .phonePad,
                              state: .error("الرقم ناقص • اكتب ١٠ أرقام تبدأ بـ ٠٥"))
                SaryTextField(title: "رمز الاسترجاع", placeholder: "XXXX-XXXX", text: $code, id: "recovery", state: .success("الرمز صحيح"))
                SaryTextField(title: "معطّل", placeholder: "—", text: .constant("لا يمكن التعديل"), id: "disabled", disabled: true)
            }
        }
        ShowcaseBlock(index: 1, title: "مفاتيح") {
            SarySection {
                SaryToggleRow(title: "الإشعارات", subtitle: "رسائل وطوارئ الأصدقاء", systemImage: "bell.fill", isOn: $t1)
                SaryDivider()
                SaryToggleRow(title: "أوقف مشاركة موقعي", systemImage: SaryIcon.pause, isOn: $t2)
            }
        }
        ShowcaseBlock(index: 2, title: "اختيار متعدد") {
            SarySegmented(options: SaryTriMode.allCases, selection: $mode, label: { $0.label })
            SarySegmented(options: SaryButtonSize.allCases, selection: $size, label: { $0.label })
        }
    }
}

// MARK: - Dialogs

private struct DialogsBlocks: View {
    @Environment(\.sary) private var theme
    @State private var confirm = false
    @State private var alert = false

    var body: some View {
        ShowcaseBlock(index: 0, title: "تأكيد خطِر") {
            ZStack {
                theme.palette.scrim
                SaryDialog(systemImage: "flag.checkered", title: "أنهِ الطلعة؟",
                           message: "بتنتهي الطلعة عند الكل ويتوقف تتبع المواقع. ما تقدر ترجعها.",
                           confirmTitle: "أنهِ الطلعة للجميع")
                    .padding(theme.space(.l))
            }
            .clipShape(RoundedRectangle(cornerRadius: SaryRadius.xl, style: .continuous))
        }
        ShowcaseBlock(index: 1, title: "تأكيد عادي") {
            SaryDialog(systemImage: "arrow.triangle.2.circlepath", title: "رابط جديد؟", message: "الرابط القديم بيتوقف، والمنضمين يبقون.",
                       confirmTitle: "أنشئ رابطًا جديدًا", confirmKind: .primary, busy: false)
        }
        ShowcaseBlock(index: 2, title: "أنظمة iOS", note: "للأسئلة البسيطة نستخدم النوافذ الأصلية") {
            HStack(spacing: 8) {
                Button("قائمة تأكيد") { confirm = true }.buttonStyle(.sary(.secondary, compact: true))
                Button("تنبيه") { alert = true }.buttonStyle(.sary(.secondary, compact: true))
            }
            .confirmationDialog("غادر الطلعة؟", isPresented: $confirm, titleVisibility: .visible) {
                Button("غادر", role: .destructive) {}
                Button("إلغاء", role: .cancel) {}
            } message: { Text("بيتوقف إرسال موقعك للأصدقاء") }
            .alert("تعذّر الإرسال", isPresented: $alert) {
                Button("حسنًا", role: .cancel) {}
            } message: { Text("تأكد من الاتصال وحاول مرة ثانية") }
        }
    }
}
#endif
