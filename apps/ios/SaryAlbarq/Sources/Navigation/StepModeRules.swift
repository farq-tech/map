import Foundation

/// «التوجيه خطوة بخطوة» when the GPS is weak (UX backlog R4, docs/UX-BACKLOG-2GIS.md): wadis and
/// foothills drop the fix, the blue dot jumps and the live guidance lies. When the signal is
/// bad for long enough the app SUGGESTS a manual step list (direction, distance to the turn); it goes
/// back to live tracking by itself once the signal is good again.
///
/// Logic only (pure, Foundation-only, no UI, no session): this decides WHEN to suggest. It never
/// touches SOS, the outbox or sharing, and it works fully offline. The suggestion banner and the step
/// screen are a later, separate change.
struct StepModeRules: Equatable {
    struct Config: Equatable {
        /// Horizontal accuracy above this (metres) counts as a bad fix. A missing/negative fix is bad too.
        var badAccuracyM: Double = 60
        /// Accuracy below this counts as a good fix again (hysteresis: not the same as `badAccuracyM`).
        var goodAccuracyM: Double = 30
        /// Bad for this long (seconds) before we suggest.
        var suggestAfterS: Double = 20
        /// Good for this long before we go back to live guidance.
        var recoverAfterS: Double = 10
        /// After the person dismisses or finishes the suggestion, do not suggest again for this long.
        var cooldownS: Double = 600
        init() {}
    }

    enum Mode: Equatable {
        /// Live guidance, nothing to say.
        case live
        /// Weak signal for long enough: offer «التوجيه خطوة بخطوة».
        case suggested
        /// The person accepted: show the step list. Stays until the signal recovers or they leave it.
        case stepping
    }

    private(set) var mode: Mode = .live
    private(set) var config: Config

    private var badSince: Double?
    private var goodSince: Double?
    private var suppressedUntil: Double = -.infinity

    init(config: Config = Config()) { self.config = config }

    /// Feed every location fix: its time (seconds, any monotonic clock) and horizontal accuracy in
    /// metres (CoreLocation: negative means invalid). Returns the mode after this fix.
    @discardableResult
    mutating func ingest(accuracyM: Double, at t: Double) -> Mode {
        let bad = accuracyM < 0 || accuracyM > config.badAccuracyM
        let good = accuracyM >= 0 && accuracyM <= config.goodAccuracyM
        if bad {
            if badSince == nil { badSince = t }
            goodSince = nil
        } else if good {
            if goodSince == nil { goodSince = t }
            badSince = nil
        } else {
            /* In between: neither streak advances, neither is broken (no flapping on a borderline fix). */
        }

        switch mode {
        case .live:
            if let s = badSince, t - s >= config.suggestAfterS, t >= suppressedUntil { mode = .suggested }
        case .suggested:
            /* The signal came back before the person answered: the offer is moot. */
            if let s = goodSince, t - s >= config.recoverAfterS { mode = .live }
        case .stepping:
            if let s = goodSince, t - s >= config.recoverAfterS { mode = .live; badSince = nil }
        }
        return mode
    }

    /// «ابدأ خطوة بخطوة».
    mutating func accept() {
        if mode == .suggested { mode = .stepping }
    }

    /// «لا، كمّل بالتوجيه»: back to live and quiet for a while.
    mutating func dismiss(at t: Double) {
        guard mode != .live else { return }
        mode = .live
        badSince = nil
        suppressedUntil = t + config.cooldownS
    }

    /// The route changed or navigation ended: forget the streaks.
    mutating func reset() {
        mode = .live
        badSince = nil
        goodSince = nil
        suppressedUntil = -.infinity
    }
}
