import Foundation
import UIKit

/// Sends my position while the app is in the background (screen locked,
/// another app, CarPlay) — only when `SendGate.allowsBackgroundPosition` says
/// so, asked again at the last step before every request.
///
/// iOS suspends the WebSocket in the background, so this never uses it: each
/// send is one `POST /api/outings/:id/positions` on a plain URLSession task,
/// kept alive with a short background task. Rules:
///
///   * coalescing: one slot (`LatestFixSlot`); a newer fix replaces an older
///     one, so there is never a queue of old positions;
///   * no stale backlog: a fix older than `Policy.maxSendAgeMs` is dropped,
///     never sent late as if it were live; `age_ms` is measured at send time,
///     so the time others see stays the real time of the fix;
///   * cadence: `BackgroundCadence` (10–12 s moving, 40 s parked, or after 50 m;
///     doubled in Low Power Mode) — far under the server's limits;
///   * retry with capped exponential backoff + jitter on network errors,
///     5xx and 429; a refusal (sharing off, paused, ended) is not retried —
///     the session reconciles and stops.
@MainActor
final class BackgroundPositionSender {
    enum Outcome: Equatable {
        case sent
        /// The server said no for a reason that ends sharing (sharing_off, outing_paused, outing_ended, not_allowed).
        case refused(String)
        case notAMember
        case unauthorized
    }

    struct Deps {
        var post: (WireFix) async throws -> Void
        var scheduler: Scheduler
        /// `SendGate.allowsBackgroundPosition`. Closed by default.
        var canSend: () -> Bool = { false }
        /// Wall clock, ms since 1970 (fix ages and cadence).
        var now: () -> Double = { Date().timeIntervalSince1970 * 1000 }
        var lowPower: () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
        var random: () -> Double = { Double.random(in: 0...1) }
        /// Keeps the app running until the request finishes; returns "done".
        var keepAlive: () -> () -> Void = BackgroundPositionSender.backgroundTask
    }

    var onResult: (Outcome) -> Void = { _ in }
    /// A fix that could not go out live (network down, 5xx, 429): the session keeps it in the
    /// offline queue (`OfflineFixQueue`) and uploads it in one batch when the network is back.
    var onUndelivered: (DeviceFix, ShareMode) -> Void = { _, _ in }

    /// Retrying after a network failure: the phone is (probably) offline.
    var isOffline: Bool { retrying }

    private let deps: Deps
    private var slot = LatestFixSlot()
    private var last: BackgroundCadence.Last?
    private var inFlight = false
    private var timer: Cancellable?
    private var retrying = false
    private var attempt = 0
    /// Bumped on stop: a response that arrives after stop is ignored.
    private var generation = 0
    private(set) var running = false

    init(deps: Deps) { self.deps = deps }

    /// Start (or keep) sending in the background.
    func start() { running = true }

    /// Stop now: nothing pending, nothing scheduled, a request in flight is forgotten.
    func stop() {
        running = false
        generation &+= 1
        slot.clear()
        timer?.cancel()
        timer = nil
        inFlight = false
        retrying = false
        attempt = 0
        last = nil
    }

    /// A new fix while in the background. Only the latest is kept.
    func offer(_ fix: DeviceFix, mode: ShareMode) {
        guard running, deps.canSend() else { return slot.clear() }
        /* Offline: the slot keeps only the newest, so every fix that would be replaced is queued. */
        if retrying { onUndelivered(fix, mode) }
        slot.put(fix, mode: mode)
        pump()
    }

    /// The network came back: try the pending fix now (if still fresh).
    func networkBack() {
        guard running, retrying else { return }
        timer?.cancel()
        timer = nil
        retrying = false
        attempt = 0
        pump()
    }

    var hasPending: Bool { slot.pending != nil }

    private func pump() {
        guard running, !inFlight, !retrying, let pending = slot.pending else { return }
        guard deps.canSend() else { return slot.clear() }
        let now = deps.now()
        let due = BackgroundCadence.dueAtMs(pending.fix, last: last, lowPower: deps.lowPower())
        if now < due {
            timer?.cancel()
            timer = deps.scheduler.after(ms: due - now) { [weak self] in
                guard let self else { return }
                self.timer = nil
                self.pump()
            }
            return
        }
        timer?.cancel()
        timer = nil
        guard let wire = slot.take(nowMs: now) else { return } // too old: dropped, never sent late
        inFlight = true
        let gen = generation
        let done = deps.keepAlive()
        let post = deps.post
        Task { @MainActor [weak self] in
            defer { done() }
            do {
                try await post(wire)
                self?.finished(gen, pending, result: nil)
            } catch let e as OutingAPIError {
                self?.finished(gen, pending, result: e)
            } catch {
                self?.finished(gen, pending, result: OutingAPIError(code: "network", status: 0))
            }
        }
    }

    private func finished(_ gen: Int, _ sent: (fix: DeviceFix, mode: ShareMode), result: OutingAPIError?) {
        guard gen == generation else { return }
        inFlight = false
        guard let e = result else {
            last = .init(fix: sent.fix, sentAtMs: deps.now())
            attempt = 0
            onResult(.sent)
            return pump()
        }
        switch e.code {
        case "not_a_member":
            stop()
            onResult(.notAMember)
        case "unauthorized":
            stop()
            onResult(.unauthorized)
        case "sharing_off", "outing_paused", "outing_ended", "outing_created", "not_allowed":
            slot.clear()
            onResult(.refused(e.code))
        case "hidden":
            /* «أخفِ موقعي» on another device / not yet seen here: nothing goes out, nothing retried. */
            slot.clear()
        case "out_of_order", "too_frequent", "stale", "inaccurate", "invalid", "invalid_coordinates", "invalid_accuracy", "invalid_age", "implausible_speed":
            /* This fix will never be accepted; the next one will. */
            pump()
        default:
            /* network, timeout, 5xx, 429: keep the fix (unless a newer one came) and back off. */
            onUndelivered(sent.fix, sent.mode)
            slot.restore(sent.fix, mode: sent.mode)
            retrying = true
            let wait = BackgroundCadence.retryDelayMs(attempt: attempt, rateLimited: e.code == "rate_limited" || e.status == 429, rand: deps.random())
            attempt += 1
            timer?.cancel()
            timer = deps.scheduler.after(ms: wait) { [weak self] in
                guard let self else { return }
                self.timer = nil
                self.retrying = false
                self.pump()
            }
        }
    }

    /// A short UIKit background task around one request, so it finishes even if iOS is about to suspend us.
    nonisolated static func backgroundTask() -> () -> Void {
        MainActor.assumeIsolated {
            var id: UIBackgroundTaskIdentifier = .invalid
            id = UIApplication.shared.beginBackgroundTask(withName: "sary.position") {
                if id != .invalid { UIApplication.shared.endBackgroundTask(id); id = .invalid }
            }
            return {
                MainActor.assumeIsolated {
                    if id != .invalid { UIApplication.shared.endBackgroundTask(id); id = .invalid }
                }
            }
        }
    }
}
