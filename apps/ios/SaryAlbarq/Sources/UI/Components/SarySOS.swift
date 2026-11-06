import SwiftUI
import UIKit

// MARK: - SOS hold-to-fire

/// «طوارئ». Fires ONLY after a continuous 1 s hold: a ring fills around the
/// button, haptics escalate (light → medium → heavy), then a warning
/// notification haptic and `trigger()`. Releasing early cancels and the ring
/// drains back. VoiceOver: a custom action fires it (after the system's own
/// activation confirmation), since holding is hard with VoiceOver.
struct SarySOSButton: View {
    var state: MySOSUI
    var holdDuration: Double = 1
    var trigger: () -> Void = {}
    /// Diameter (default: the theme's big button).
    var size: CGFloat? = nil
    /// The calm live screen (Lovable): «SOS» in the disc instead of the icon + «طوارئ».
    var compactLabel = false

    @Environment(\.sary) private var theme
    @State private var holding = false
    @State private var progress: CGFloat = 0
    @State private var stage = 0
    @State private var fired = 0
    @State private var holdTask: Task<Void, Never>?

    var body: some View {
        let p = theme.palette
        let size = self.size ?? theme.bigButton
        let sending = state == .sending
        let active: Bool = { if case .active = state { return true }; return false }()

        ZStack {
            Circle().fill(p.emergency)
                .shadow(color: p.emergency.opacity(holding ? 0.55 : 0.3), radius: holding ? 14 : 8, y: 3)
            if sending {
                ProgressView().tint(p.onEmergency).controlSize(.regular)
            } else {
                if compactLabel && !active {
                    /* UX ٢١: «SOS» alone is English; «طوارئ» goes with it. */
                    VStack(spacing: 0) {
                        Text("SOS")
                            .font(.system(size: max(13, size * 0.24), weight: .heavy, design: .rounded))
                            .environment(\.layoutDirection, .leftToRight)
                        Text("طوارئ")
                            .font(.sary(max(9, size * 0.15), .heavy))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .dynamicTypeSize(...DynamicTypeSize.large)
                    }
                    .foregroundStyle(p.onEmergency)
                } else {
                VStack(spacing: 0) {
                    Image(systemName: active ? SaryIcon.checkCircle : SaryIcon.sos)
                        .font(.system(size: size * (active ? 0.3 : 0.36), weight: .heavy))
                    Text(active ? "أُرسلت" : "طوارئ")
                        .font(.sary(size * 0.17, .heavy))
                        .dynamicTypeSize(...DynamicTypeSize.large)
                }
                .foregroundStyle(p.onEmergency)
                }
            }
        }
        .frame(width: size, height: size)
        .overlay {
            Circle()
                .stroke(p.emergency.opacity(0.25), lineWidth: 5)
                .padding(-7)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(p.textPrimary, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(-7)
                .environment(\.layoutDirection, .leftToRight)
        }
        .scaleEffect(holding && !theme.reduceMotion ? 0.94 : 1)
        .animation(theme.animation(.snappy), value: holding)
        .contentShape(Circle().inset(by: -10))
        .onLongPressGesture(minimumDuration: holdDuration, maximumDistance: 40) {
            // completed
            finishHold(fire: true)
        } onPressingChanged: { pressing in
            pressing ? beginHold() : finishHold(fire: false)
        }
        .disabled(sending || active)
        .sensoryFeedback(trigger: stage) { _, new in
            switch new {
            case 1: return .impact(weight: .light, intensity: 0.7)
            case 2: return .impact(weight: .medium, intensity: 0.85)
            case 3: return .impact(weight: .heavy, intensity: 1)
            default: return nil
            }
        }
        .sensoryFeedback(.warning, trigger: fired)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(active ? "تم إرسال طوارئ" : (sending ? "جارٍ إرسال الطوارئ" : "طوارئ")))
        .accessibilityHint(Text("امسك الزر ثانية وحدة، وبعدها عندك ٣ ثوانٍ تتراجع قبل ما توصل الطوارئ لكل الربع"))
        .accessibilityAddTraits(.isButton)
        /* VoiceOver: the system already confirms a custom action, so this one sends at once. */
        .accessibilityAction(named: Text("أرسل طوارئ الآن")) { fired += 1; trigger() }
        .accessibilityIdentifier("outing-sos")
    }

    private func beginHold() {
        guard !holding else { return }
        holding = true
        stage = 0
        withAnimation(.linear(duration: holdDuration)) { progress = 1 }
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            // Escalating ticks at 5 %, 40 % and 75 % of the hold.
            var last = 0.0
            for (i, mark) in [0.05, 0.4, 0.75].enumerated() {
                try? await Task.sleep(nanoseconds: UInt64((mark - last) * holdDuration * 1_000_000_000))
                if Task.isCancelled { return }
                last = mark
                stage = i + 1
            }
        }
    }

    private func finishHold(fire shouldFire: Bool) {
        holdTask?.cancel()
        holding = false
        if shouldFire {
            fire()
            withAnimation(theme.animation(.urgent)) { progress = 0 }
        } else {
            withAnimation(theme.animation(.smooth)) { progress = 0 }
        }
        stage = 0
    }

    /// UX ٢١: a held SOS does not go out at once — «نرسل طوارئ بعد ٣…» with a big «تراجع».
    private func fire() {
        fired += 1
        SOSCountdown.shared.begin(theme: theme, send: trigger)
    }
}

// MARK: - SOS countdown («تراجع»)

/// After the hold: 3 s, over everything (its own window, above the sheets and the SOS window),
/// with a 56 pt «تراجع» and «أرسل الآن». One countdown at a time; a second hold does nothing.
@MainActor
final class SOSCountdown: ObservableObject {
    static let shared = SOSCountdown()
    /// How long the «تراجع» window lasts.
    static let seconds = 3

    @Published private(set) var remaining: Int? = nil
    private var send: (() -> Void)?
    private var tick: Task<Void, Never>?
    private var window: UIWindow?

    var isRunning: Bool { remaining != nil }

    func begin(theme: SaryTheme, send: @escaping () -> Void) {
        guard remaining == nil else { return }
        self.send = send
        remaining = Self.seconds
        show(theme)
        UIAccessibility.post(notification: .announcement, argument: "نرسل طوارئ بعد ٣ ثوانٍ. تقدر تتراجع")
        tick = Task { @MainActor [weak self] in
            while let self, let r = self.remaining, r > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                self.remaining = r - 1
            }
            self?.sendNow()
        }
    }

    func cancel() {
        tick?.cancel()
        send = nil
        remaining = nil
        hide()
        UIAccessibility.post(notification: .announcement, argument: "تراجعت، ما أرسلنا شي")
    }

    func sendNow() {
        tick?.cancel()
        let s = send
        send = nil
        remaining = nil
        hide()
        s?()
    }

    private func show(_ theme: SaryTheme) {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.backgroundColor = .clear
        let host = UIHostingController(rootView: SOSCountdownView(center: self).environment(\.sary, theme))
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = false
        window = w
    }

    private func hide() {
        window?.isHidden = true
        window = nil
    }
}

struct SOSCountdownView: View {
    @ObservedObject var center: SOSCountdown
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: theme.space(.l)) {
                Text("نرسل طوارئ بعد")
                    .saryText(.title2, weight: .bold)
                    .foregroundStyle(p.onEmergency)
                Text(SaryFormat.number(center.remaining ?? 0))
                    .font(.system(size: 96, weight: .heavy, design: .rounded))
                    .foregroundStyle(p.onEmergency)
                    .contentTransition(.numericText(countsDown: true))
                    .accessibilityIdentifier("sos-countdown-seconds")
                Text("توصل لكل الربع مع موقعك")
                    .saryText(.callout, weight: .medium)
                    .foregroundStyle(p.onEmergency.opacity(0.9))
                Button(action: center.cancel) {
                    Text("تراجع")
                        .font(.sary(22, .heavy))
                        .foregroundStyle(p.emergency)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(SaryPressStyle())
                .accessibilityIdentifier("sos-countdown-cancel")
                .accessibilityHint(Text("يلغي الطوارئ قبل ما ترسل"))
                Button(action: center.sendNow) {
                    Text("أرسل الآن")
                        .font(.sary(17, .bold))
                        .foregroundStyle(p.onEmergency)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .overlay(Capsule().stroke(p.onEmergency.opacity(0.8), lineWidth: 2))
                }
                .buttonStyle(SaryPressStyle())
                .accessibilityIdentifier("sos-countdown-send")
            }
            .padding(theme.space(.xl))
            .frame(maxWidth: 360)
            .background(RoundedRectangle(cornerRadius: 32, style: .continuous).fill(p.emergency))
            .padding(theme.space(.l))
            .animation(theme.animation(.snappy), value: center.remaining)
        }
        .environment(\.layoutDirection, .rightToLeft)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sos-countdown")
    }
}

// MARK: - My SOS strip

/// Red strip after I sent SOS: «أرسلت طوارئ · قبل ١ د» + «أنا بخير».
struct SaryMySOSStrip: View {
    var since: Date
    var now: Date
    var imOK: () -> Void = {}
    /// False when the alert went out without a position (I was not sharing): say so, never imply a location.
    var withLocation = true
    /// «اطلب إنجاد» (nil: not offered).
    var enjad: (() -> Void)? = nil
    @Environment(\.sary) private var theme
    /// UX ٢١: stopping a sent SOS asks first (one slip must not call it off).
    @State private var confirmOK = false

    var body: some View {
        let p = theme.palette
        HStack(spacing: theme.space(.m)) {
            Image(systemName: SaryIcon.sos)
                .font(.system(size: 16, weight: .heavy))
                .symbolEffect(.pulse, isActive: !theme.reduceMotion)
            VStack(alignment: .leading, spacing: 0) {
                Text("أرسلت طوارئ").saryText(.headline)
                Text("\(withLocation ? "الكل يشوف موقعك" : "وصل التنبيه للكل · بدون موقع") · \(SaryFormat.elapsed(since: since, now: now))")
                    .saryText(.footnote, weight: .medium).opacity(0.9)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { confirmOK = true } label: {
                Text("أنا بخير").saryText(.callout, weight: .heavy)
                    .foregroundStyle(p.emergency)
                    .padding(.horizontal, theme.space(.l))
                    .frame(minHeight: theme.minTarget)
                    .background(Capsule().fill(Color.white))
            }
            .buttonStyle(SaryPressStyle())
            .accessibilityIdentifier("outing-sos-ok")
            .accessibilityHint(Text("يسألك قبل ما يوقف الطوارئ"))
            .confirmationDialog("نوقف الطوارئ؟", isPresented: $confirmOK, titleVisibility: .visible) {
                Button("إيه، أنا بخير", role: .destructive, action: imOK)
                    .accessibilityIdentifier("outing-sos-ok-confirm")
                Button("لا، خلها", role: .cancel) {}
            } message: {
                Text("يوصل للربع إنك بخير ويختفي تنبيهك عندهم.")
            }
            if let enjad {
                Button(action: enjad) {
                    Text("إنجاد").saryText(.callout, weight: .heavy)
                        .foregroundStyle(p.emergency)
                        .padding(.horizontal, theme.space(.m))
                        .frame(minHeight: theme.minTarget)
                        .background(Capsule().fill(Color.white.opacity(0.85)))
                }
                .buttonStyle(SaryPressStyle())
                .accessibilityLabel(Text("اطلب إنجاد (واتساب)"))
                .accessibilityIdentifier("sos-enjad")
            }
        }
        .foregroundStyle(p.onEmergency)
        .padding(.leading, theme.space(.l))
        .padding(.trailing, theme.space(.s))
        .padding(.vertical, theme.space(.s))
        .background(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous).fill(p.emergency))
        .saryShadow(.floating, theme)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Friend SOS

/// Persistent strip for an acknowledged friend SOS (stays until they clear it).
struct SaryFriendSOSStrip: View {
    var alert: IncomingSOSUI
    var now: Date
    var show: () -> Void = {}
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        HStack(spacing: theme.space(.m)) {
            SaryAvatar(name: alert.name, color: alert.color, size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text("طوارئ: \(alert.name)").saryText(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    if let d = alert.distanceMeters {
                        Text(SaryFormat.distance(meters: d)).saryNumber(.footnote)
                    }
                    Text(SaryFormat.elapsed(since: alert.since, now: now)).saryText(.footnote, weight: .medium)
                }
                .opacity(0.9)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let b = alert.bearingDegrees {
                SaryBearingArrow(degrees: b, color: p.onEmergency, size: 18)
            }
            Button(action: show) {
                Text("أظهره").saryText(.callout, weight: .heavy)
                    .foregroundStyle(p.emergency)
                    .padding(.horizontal, theme.space(.l))
                    .frame(minHeight: theme.minTarget)
                    .background(Capsule().fill(Color.white))
            }
            .buttonStyle(SaryPressStyle())
        }
        .foregroundStyle(p.onEmergency)
        .padding(.leading, theme.space(.m))
        .padding(.trailing, theme.space(.s))
        .padding(.vertical, theme.space(.s))
        .background(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous).fill(p.emergency))
        .saryShadow(.floating, theme)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("طوارئ من \(alert.name)"))
    }
}

/// Full-screen alert for a friend's SOS. Always opaque red (no glass), large
/// type, the two actions that matter. Repeating haptic on appear.
struct SaryFriendSOSAlert: View {
    var alert: IncomingSOSUI
    var now: Date
    var show: () -> Void = {}
    var call: () -> Void = {}

    @Environment(\.sary) private var theme
    @State private var pulse = false
    @State private var buzz = 0

    var body: some View {
        let p = theme.palette
        ZStack {
            LinearGradient(colors: [Color(rgb: theme.night ? 0x7A2216 : 0xC23A25), Color(rgb: theme.night ? 0x3E120B : 0x8E2414)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: theme.space(.xl)) {
                Spacer(minLength: 0)
                ZStack {
                    Circle().stroke(Color.white.opacity(0.25), lineWidth: 2)
                        .frame(width: 190, height: 190)
                        .scaleEffect(pulse ? 1.12 : 0.92)
                        .opacity(pulse ? 0 : 1)
                    Circle().fill(Color.white.opacity(0.1)).frame(width: 150, height: 150)
                    SaryAvatar(name: alert.name, color: alert.color, size: 104)
                }
                .accessibilityHidden(true)
                VStack(spacing: theme.space(.s)) {
                    Label("طوارئ", systemImage: SaryIcon.sos)
                        .saryText(.headline)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                    Text(alert.name)
                        .saryText(.display)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    Text("يحتاج مساعدة · \(SaryFormat.elapsed(since: alert.since, now: now))")
                        .saryText(.title2, weight: .medium)
                        .opacity(0.92)
                }
                .multilineTextAlignment(.center)

                if alert.distanceMeters != nil || alert.bearingDegrees != nil {
                    HStack(spacing: theme.space(.m)) {
                        if let b = alert.bearingDegrees {
                            SaryBearingArrow(degrees: b, color: .white, size: 34)
                        }
                        if let d = alert.distanceMeters {
                            Text(SaryFormat.distance(meters: d)).saryNumber(.title)
                        }
                    }
                    .padding(.horizontal, theme.space(.xl))
                    .padding(.vertical, theme.space(.m))
                    .background(Capsule().fill(Color.black.opacity(0.18)))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text([alert.distanceMeters.map { "على بعد \(SaryFormat.distance(meters: $0))" },
                                              alert.bearingDegrees.map { SaryFormat.relativeDirection($0) }]
                        .compactMap { $0 }.joined(separator: "، ")))
                }
                Spacer(minLength: 0)
                VStack(spacing: theme.space(.m)) {
                    Button(action: show) {
                        Label("أظهره على الخريطة", systemImage: SaryIcon.showOnMap)
                            .saryText(.headline)
                            .foregroundStyle(p.emergency)
                            .frame(maxWidth: .infinity, minHeight: max(theme.buttonHeight, 58))
                            .background(RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous).fill(Color.white))
                    }
                    .buttonStyle(SaryPressStyle())
                    .accessibilityIdentifier("sos-alert-show")
                    if alert.hasPhone {
                        Button(action: call) {
                            Label("اتصل به", systemImage: SaryIcon.phone)
                                .saryText(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: max(theme.buttonHeight, 58))
                                .background(RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous).fill(Color.black.opacity(0.22)))
                                .overlay(RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous).stroke(Color.white.opacity(0.5), lineWidth: 1))
                        }
                        .buttonStyle(SaryPressStyle())
                        .accessibilityIdentifier("sos-alert-call")
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, theme.space(.xxl))
            .padding(.vertical, theme.space(.xl))
        }
        .onAppear {
            buzz += 1
            guard !theme.reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
        .sensoryFeedback(.error, trigger: buzz)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}
