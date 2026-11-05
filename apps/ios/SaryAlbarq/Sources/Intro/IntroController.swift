import CallKit
import Combine
import SwiftUI
import UIKit

/// Runs the launch's intro once per process (cold launch only): decides the mode from
/// `IntroPolicy`, plays it, and gets out of the way on a tap or as soon as the launch
/// turns out to be "for something" (a link, a notification, PushToTalk…).
@MainActor
final class IntroController: ObservableObject {
    static let shared = IntroController()

    let mode: IntroMode
    let skip: IntroSkip?
    let sound: Bool
    let reduceMotion: Bool
    /// Overlay on screen (the launch frame or the intro).
    @Published private(set) var visible: Bool
    /// When the animation's t = 0 was (after the short grace window), nil before.
    @Published private(set) var startedAt: Date?
    /// DEBUG `-SaryIntroFreeze <seconds>`: hold one frame (stills for the docs).
    let freeze: Double?

    /// A deep link / notification arrived before the controller existed.
    private static var earlySignal = false
    private var appReady = false
    private var dismissing = false
    private let audio = IntroAudio()
    private var observers: [NSObjectProtocol] = []

    /// The first frame is the launch screen; wait this long for a link or a notification
    /// that a cold launch delivers just after the first frame, before the show (and its music) starts.
    static let grace: TimeInterval = 0.3

    private init() {
        let args = ProcessInfo.processInfo.arguments
        let env = ProcessInfo.processInfo.environment
        #if DEBUG
        if args.contains("-resetState") { for k in IntroPolicy.keys { UserDefaults.standard.removeObject(forKey: k) } }
        /* `-SaryIntroForget`: as if never shown (UI tests of the 6 h rule's other side). */
        if args.contains("-SaryIntroForget") { UserDefaults.standard.removeObject(forKey: IntroPolicy.lastShownKey) }
        func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        freeze = arg("-SaryIntroFreeze").flatMap(Double.init)
        let automation = IntroPolicy.isAutomation(args, environment: env)
        #else
        freeze = nil
        let automation = env["XCTestConfigurationFilePath"] != nil
        #endif
        let model = AppBoot.model
        let trip = model.session != nil || (model.identity.map { ShareMemory.activeShare(user: $0.user.id) != nil } ?? false)
        let facts = IntroFacts(enabled: IntroPolicy.enabled(), lastShown: IntroPolicy.lastShown(), now: Date(),
                               foregroundLaunch: UIApplication.shared.applicationState != .background,
                               openedForSomething: Self.earlySignal || model.pendingInvite != nil,
                               activeTrip: trip, carPlay: CarPlayHub.active, automation: automation)
        skip = IntroPolicy.skipReason(facts)
        mode = IntroPolicy.mode(facts)
        let callLive = CXCallObserver().calls.contains { !$0.hasEnded }
        sound = IntroPolicy.playsSound(mode: mode, soundOn: IntroPolicy.soundOn()) && !callLive
        reduceMotion = UIAccessibility.isReduceMotionEnabled
        visible = mode != .none
        observers.append(NotificationCenter.default.addObserver(forName: .saryOpenOuting, object: nil, queue: .main) { _ in
            Task { @MainActor in IntroController.shared.interrupt() }
        })
    }

    /// The overlay appeared (first frame = launch screen).
    func begin() {
        guard visible, startedAt == nil, !dismissing else { return }
        switch mode {
        case .none: visible = false
        case .still:
            /* At most ~1 s of the night frame, less if the app is ready sooner. */
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.dismiss(fade: 0.4) }
            if appReady { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.dismiss(fade: 0.4) } }
        case .full:
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.grace) { [weak self] in self?.start() }
        }
    }

    private func start() {
        guard visible, !dismissing, startedAt == nil else { return }
        startedAt = Date()
        /* A DEBUG held frame (stills, UI tests) is not a showing. */
        if freeze == nil { IntroPolicy.markShown() }
        if sound { audio.play() }
        guard freeze == nil else { return }
        let length = reduceMotion ? 2.6 : IntroScene.T.fadeOut
        DispatchQueue.main.asyncAfter(deadline: .now() + length) { [weak self] in self?.finish() }
    }

    /// Seconds into the animation at `date`.
    func time(at date: Date) -> Double {
        if let freeze { return freeze }
        guard let s = startedAt else { return 0 }
        return max(0, date.timeIntervalSince(s))
    }

    /// The app behind is ready (the boot splash is done).
    func ready() {
        appReady = true
        if mode == .still, visible { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.dismiss(fade: 0.4) } }
    }

    /// Natural end: crossfade into the app; the music's tail rings out on its own.
    private func finish() {
        dismiss(fade: 0.6)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.audio.fadeOut(0.4) }
    }

    /// Tap anywhere.
    func userSkip() {
        guard visible else { return }
        audio.fadeOut(0.5)
        dismiss(fade: 0.35)
    }

    /// The launch was for something (link, notification, PushToTalk, an outing opening): leave now.
    func interrupt() {
        Self.earlySignal = true
        guard visible else { return }
        audio.fadeOut(0.25)
        dismiss(fade: 0.2)
    }

    private func dismiss(fade: Double) {
        guard visible, !dismissing else { return }
        dismissing = true
        withAnimation(.easeInOut(duration: fade)) { visible = false }
    }
}

// MARK: - root hook

extension View {
    /// CINEMATIC INTRO HOOK (Sources/Intro): the launch's night-desert intro over the app.
    func saryCinematicIntro(_ model: AppModel) -> some View {
        modifier(CinematicIntroModifier(model: model))
    }
}

private struct CinematicIntroModifier: ViewModifier {
    @ObservedObject var model: AppModel
    @ObservedObject private var intro = IntroController.shared

    func body(content: Content) -> some View {
        content
            .overlay {
                if intro.visible {
                    IntroOverlay(intro: intro)
                        .transition(.opacity)
                        .onAppear { intro.begin() }
                }
            }
            .onReceive(model.$session.map { $0 != nil }.removeDuplicates()) { if $0 { intro.interrupt() } }
            .onReceive(model.$pendingInvite.map { $0 != nil }.removeDuplicates()) { if $0 { intro.interrupt() } }
            .onReceive(model.$launching.removeDuplicates()) { if !$0 { intro.ready() } }
    }
}
