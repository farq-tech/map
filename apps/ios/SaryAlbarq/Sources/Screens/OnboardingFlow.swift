import CoreLocation
import PhotosUI
import SwiftUI

// MARK: - Splash

/// The brand beat between the system launch screen (same background colour)
/// and the first page: the app mark and its name. Never a wait.
struct SplashView: View {
    @Environment(\.sary) private var theme
    @State private var shown = false

    var body: some View {
        let p = theme.palette
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            /* The mark sits exactly where the launch screen drew it (centre, 112 pt): no jump. */
            SaryMark(size: 112)
                .overlay(alignment: .top) {
                    VStack(spacing: theme.space(.s)) {
                        Text("سَرى البارق")
                            .font(.sary(34, .heavy))
                            .foregroundStyle(Color(rgb: 0xF4EFE6))
                        Text("طلعات البر مع الربع")
                            .saryText(.callout)
                            .foregroundStyle(Color(rgb: 0xB9AE9C))
                    }
                    .fixedSize()
                    .offset(y: 112 + theme.space(.l))
                    .opacity(shown ? 1 : 0)
                }
        }
        .onAppear { withAnimation(theme.animation(.smooth)) { shown = true } }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("splash")
        .environment(\.colorScheme, .dark)
        .tint(p.accent)
    }
}

/// The app mark drawn in code (same motif as the app icon): a dune ridge under a
/// headlight beam and a forward arrow, in the Dark Sand palette.
struct SaryMark: View {
    var size: CGFloat
    var body: some View {
        Canvas { ctx, s in
            SaryMarkDrawing.draw(in: ctx, size: s)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: size * 0.08, y: size * 0.04)
        .accessibilityHidden(true)
    }
}

enum SaryMarkDrawing {
    /// Shared by the in-app mark and the icon renderer (scripts/render-app-icon.swift mirrors it).
    static func draw(in ctx: GraphicsContext, size s: CGSize) {
        let w = s.width, h = s.height
        // Night sky
        ctx.fill(Path(CGRect(origin: .zero, size: s)), with: .linearGradient(
            Gradient(colors: [Color(rgb: 0x1A1612), Color(rgb: 0x2B2118)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
        // Headlight beam fanning up-left from the car
        var beam = Path()
        beam.move(to: CGPoint(x: w * 0.60, y: h * 0.60))
        beam.addLine(to: CGPoint(x: w * 0.02, y: h * 0.20))
        beam.addLine(to: CGPoint(x: w * 0.10, y: h * 0.48))
        beam.closeSubpath()
        ctx.fill(beam, with: .linearGradient(Gradient(colors: [Color(rgb: 0xF2C36B, opacity: 0.85), Color(rgb: 0xF2C36B, opacity: 0)]),
                                              startPoint: CGPoint(x: w * 0.6, y: h * 0.6), endPoint: CGPoint(x: w * 0.05, y: h * 0.3)))
        // Back dune
        var back = Path()
        back.move(to: CGPoint(x: 0, y: h * 0.70))
        back.addCurve(to: CGPoint(x: w, y: h * 0.58), control1: CGPoint(x: w * 0.35, y: h * 0.50), control2: CGPoint(x: w * 0.65, y: h * 0.72))
        back.addLine(to: CGPoint(x: w, y: h))
        back.addLine(to: CGPoint(x: 0, y: h))
        back.closeSubpath()
        ctx.fill(back, with: .color(Color(rgb: 0xB8661F)))
        // Front dune with a sharp ridge
        var front = Path()
        front.move(to: CGPoint(x: 0, y: h * 0.86))
        front.addCurve(to: CGPoint(x: w * 0.62, y: h * 0.66), control1: CGPoint(x: w * 0.25, y: h * 0.80), control2: CGPoint(x: w * 0.45, y: h * 0.66))
        front.addCurve(to: CGPoint(x: w, y: h * 0.80), control1: CGPoint(x: w * 0.78, y: h * 0.66), control2: CGPoint(x: w * 0.9, y: h * 0.74))
        front.addLine(to: CGPoint(x: w, y: h))
        front.addLine(to: CGPoint(x: 0, y: h))
        front.closeSubpath()
        ctx.fill(front, with: .linearGradient(Gradient(colors: [Color(rgb: 0xE8842C), Color(rgb: 0xC96F22)]),
                                               startPoint: CGPoint(x: w * 0.6, y: h * 0.66), endPoint: CGPoint(x: w * 0.6, y: h)))
        // Forward arrow (the car's heading) on the ridge
        var arrow = Path()
        let c = CGPoint(x: w * 0.62, y: h * 0.47)
        let r = w * 0.17
        arrow.move(to: CGPoint(x: c.x - r * 0.95, y: c.y + r * 0.55))
        arrow.addLine(to: CGPoint(x: c.x + r * 0.05, y: c.y - r * 0.95))
        arrow.addLine(to: CGPoint(x: c.x + r * 0.95, y: c.y + r * 0.55))
        arrow.addLine(to: CGPoint(x: c.x + r * 0.05, y: c.y + r * 0.12))
        arrow.closeSubpath()
        ctx.fill(arrow, with: .color(Color(rgb: 0xF4EFE6)))
        // Headlight
        ctx.fill(Path(ellipseIn: CGRect(x: w * 0.555, y: h * 0.555, width: w * 0.09, height: w * 0.09)), with: .color(Color(rgb: 0xFFE3A3)))
    }
}

// MARK: - Onboarding

/// First launch: the idea in one line → name (≤ 40), optional photo and Saudi
/// mobile → what location is used for, BEFORE the system prompt. «عندي حساب
/// سابق» restores an identity with a recovery code instead (no passwords).
struct OnboardingFlow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var location: LocationSharer
    @Environment(\.sary) private var theme
    @State private var step: OnboardingStepUI
    @State private var restoring = false

    init(start: OnboardingStepUI = .intro) { _step = State(initialValue: start) }

    var body: some View {
        ZStack {
            switch step {
            case .intro:
                IntroStep(start: { go(.profile) }, restore: { restoring = true })
                    .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
            case .profile:
                ProfileStep(back: { go(.intro) }, done: { go(.locationExplainer) })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .locationExplainer:
                LocationStep(allow: {
                    Task {
                        _ = await location.requestWhenInUse()
                        finish()
                    }
                }, skip: finish)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(theme.animation(.smooth), value: step)
        .background(theme.palette.background.ignoresSafeArea())
        .fullScreenCover(isPresented: $restoring) {
            RecoveryRestoreScreen(close: { restoring = false })
        }
    }

    private func go(_ s: OnboardingStepUI) { step = s }
    private func finish() { OnboardingProgress.done = true; model.objectWillChange.send() }
}

private struct IntroStep: View {
    var start: () -> Void
    var restore: () -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.sary) private var theme
    @State private var pasteMiss = false

    var body: some View {
        let p = theme.palette
        VStack(spacing: 0) {
            if model.deferredInviteHint {
                deferredInvite
                    .padding(.horizontal, theme.space(.l))
                    .padding(.top, theme.space(.l))
            }
            Spacer(minLength: theme.space(.xl))
            SaryMark(size: 120)
            Text("سَرى البارق")
                .font(.sary(36, .heavy))
                .foregroundStyle(p.textPrimary)
                .padding(.top, theme.space(.xl))
            Text("شوف الربع على الخريطة في الطلعة، وكل سيارة بلونها.")
                .saryText(.title2, weight: .medium)
                .foregroundStyle(p.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, theme.space(.s))
                .padding(.horizontal, theme.space(.xl))
                .accessibilityIdentifier("onboarding.idea")
            Spacer(minLength: theme.space(.xl))
            VStack(alignment: .leading, spacing: theme.space(.m)) {
                point("location.fill", "موقعك يُشارك فقط مع ربع الطلعة اللي تنضم لها، وما دامت شغّالة. تغادرها فتتوقف.")
                point("person.crop.circle.badge.checkmark", "بدون كلمة مرور: اسمك على هذا الجهاز، ورمز استرجاع إذا غيّرت جوالك.")
                point("sos", "طوارئ ونقطة تجمع ورسائل قصيرة للمجموعة.")
            }
            .padding(theme.space(.l))
            .sarySurface(radius: SaryRadius.l)
            .padding(.horizontal, theme.space(.l))
            Spacer(minLength: theme.space(.xl))
            VStack(spacing: theme.space(.s)) {
                /* Came from an invite: «لصق» in the card above is the one primary action; «ابدأ»
                 * steps back (the card stays on the home afterwards, the invite is not lost). */
                Button(action: start) { SaryButtonLabel(title: "ابدأ") }
                    .buttonStyle(.sary(model.deferredInviteHint ? .secondary : .primary))
                    .accessibilityIdentifier("onboarding.begin")
                Button("عندي حساب سابق", action: restore)
                    .buttonStyle(.sary(.plain))
                    .accessibilityIdentifier("onboarding.restore")
            }
            .padding(.horizontal, theme.space(.l))
            .padding(.bottom, theme.space(.l))
        }
    }

    /// Installed from an invite page (it copied the link): one tap on the system «لصق» and the
    /// invite opens — no name, no pages (build 21). The link is read only on that tap.
    private var deferredInvite: some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: theme.space(.s)) {
            Text("جاي من دعوة؟").saryText(.headline, weight: .bold).foregroundStyle(p.textPrimary)
                .accessibilityIdentifier("deferred.title")
            Text(pasteMiss ? "ما لقينا رابط دعوة في النسخ. افتح رابط الدعوة من جديد، أو اطلبه من أمير الطلعة."
                           : "اضغط «لصق» ونكمّل دعوتك على طول. لو بديت بدونها، تلقاها بعدين في الرئيسية.")
                .saryText(.callout).foregroundStyle(p.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            PasteButton(payloadType: String.self) { strings in
                Task { @MainActor in pasteMiss = !model.acceptPastedInvite(strings) }
            }
            .buttonBorderShape(.capsule)
            .tint(p.accent)
            .accessibilityIdentifier("deferred.paste")
        }
        .padding(theme.space(.l))
        .frame(maxWidth: .infinity, alignment: .leading)
        .sarySurface(radius: SaryRadius.l)
    }

    private func point(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: theme.space(.m)) {
            SaryRowIcon(systemImage: icon)
            Text(text).saryText(.callout).foregroundStyle(theme.palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Name, optional photo, optional Saudi mobile.
struct ProfileStep: View {
    var back: () -> Void
    var done: () -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.sary) private var theme
    @State private var name = ""
    @State private var phone = ""
    @State private var photo: UIImage?
    @State private var item: PhotosPickerItem?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let phoneOK = phone.trimmingCharacters(in: .whitespaces).isEmpty || SaryFormat.normalizeSaudiMobile(phone) != nil
        SaryPage(title: "عرّفنا عليك", subtitle: "يشوفه الربع في الطلعة فقط", back: back) {
            VStack(spacing: theme.space(.s)) {
                PhotosPicker(selection: $item, matching: .images) {
                    ZStack(alignment: .bottomTrailing) {
                        SaryAvatar(name: trimmed.isEmpty ? "؟" : trimmed, color: theme.accent.fill, photo: photo, size: 96)
                        Image(systemName: photo == nil ? "camera.fill" : "pencil")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.palette.onAccent)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(theme.palette.accent))
                    }
                }
                .accessibilityLabel(Text(photo == nil ? "أضف صورة (اختياري)" : "غيّر الصورة"))
                .accessibilityIdentifier("onboarding.photo")
                if photo != nil {
                    Button("إزالة الصورة") { photo = nil; item = nil }
                        .buttonStyle(.sary(.plain, width: .hug, compact: true))
                } else {
                    Text("الصورة اختيارية").saryText(.footnote).foregroundStyle(theme.palette.textTertiary)
                }
            }
            .frame(maxWidth: .infinity)
            SaryTextField(title: "اسمك", placeholder: "مثل: أبو فهد", text: $name, id: "onboarding.name", maxLength: ServerRules.nameMax,
                          help: "يظهر فوق سيارتك على الخريطة.")
            SaryTextField(title: "رقم الجوال (اختياري)", placeholder: "05XXXXXXXX", text: $phone, id: "onboarding.phone", keyboard: .phonePad, maxLength: 14,
                          state: phoneOK ? .normal : .error("اكتب رقمًا سعوديًا يبدأ بـ ٠٥"),
                          help: "يظهر لأعضاء طلعاتك فقط ليتصلوا بك أو يراسلوك واتساب. تقدر تحذفه متى شئت.")
                .environment(\.layoutDirection, .rightToLeft)
            if let error { SaryInlineMessage(text: error, tone: .error) }
            Button {
                submit(trimmed)
            } label: { SaryButtonLabel(title: "متابعة", busy: busy, busyTitle: "نحفظ…") }
                .buttonStyle(.sary(.primary))
                .disabled(trimmed.isEmpty || !phoneOK || busy)
                .accessibilityIdentifier("onboarding.start")
        }
        .onChange(of: item) { _, it in
            guard let it else { return }
            Task {
                if let d = try? await it.loadTransferable(type: Data.self), let img = UIImage(data: d) { photo = img }
            }
        }
    }

    private func submit(_ trimmed: String) {
        busy = true
        error = nil
        Task {
            let avatar = photo.flatMap(AvatarCodec.dataURL(from:))
            let ok = await model.createIdentity(name: trimmed, phone: phone, avatar: avatar)
            busy = false
            if ok { done() } else {
                error = model.errorText ?? "تعذّر الحفظ. أعد المحاولة."
                model.errorText = nil
            }
        }
    }
}

/// Before the system location prompt: two short lines (UI-AUDIT ١-هـ). «دائمًا» is not explained
/// here: it is asked in the trip, when it matters (the «دائمًا» explainer, `share.always.*`).
private struct LocationStep: View {
    var allow: () -> Void
    var skip: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(spacing: theme.space(.l)) {
            Spacer(minLength: theme.space(.l))
            Image(systemName: "location.circle.fill")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(p.accentText)
                .accessibilityHidden(true)
            Text("موقعك للطلعة بس")
                .saryText(.title, weight: .bold)
                .foregroundStyle(p.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("onboarding.location.title")
            VStack(alignment: .leading, spacing: theme.space(.m)) {
                line("map.fill", "يشوفك ربعك على الخريطة وتشوفهم، وقت الطلعة بس.")
                line("hand.raised.fill", "تطلع من الطلعة أو تخلص، يوقف. وبرّا الطلعات ما نتتبعك.")
            }
            .padding(theme.space(.l))
            .sarySurface(radius: SaryRadius.l)
            Text("بعدها يسألك iOS: اختر «السماح أثناء استخدام التطبيق».")
                .saryText(.footnote)
                .foregroundStyle(p.textSecondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: theme.space(.l))
            Button(action: allow) { SaryButtonLabel(title: "اسمح بالموقع", systemImage: SaryIcon.locate) }
                .buttonStyle(.sary(.primary))
                .accessibilityIdentifier("onboarding.allowLocation")
            Button("لاحقًا", action: skip)
                .buttonStyle(.sary(.plain))
                .accessibilityIdentifier("onboarding.skipLocation")
        }
        .padding(.horizontal, theme.space(.l))
        .padding(.bottom, theme.space(.l))
    }

    private func line(_ icon: String, _ t: String) -> some View {
        HStack(alignment: .top, spacing: theme.space(.m)) {
            SaryRowIcon(systemImage: icon)
            Text(t).saryText(.callout).foregroundStyle(theme.palette.textPrimary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
