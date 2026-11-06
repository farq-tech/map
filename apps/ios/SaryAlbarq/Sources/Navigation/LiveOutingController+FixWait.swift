import SwiftUI

/// Guidance asked for while my fix is old or missing (build 21 regression: the trip's guidance
/// waited for a fresh fix in silence — no banner, no line, no word). Now the wait is said
/// («ننتظر موقعك… · الدقة ±N م»), the GPS is asked at its best at once, and the guidance starts
/// by itself with the first fresh fix. Past `slowAfterS`: «اطلع لمكان مكشوف», still trying.
struct NavFixWait: Equatable {
    enum Pending: Equatable {
        /// The trip's own guidance (`TripAutoNav`).
        case auto
        /// «ابدأ الملاحة» / «روح له» / a long press: the route options for this target.
        case navigate(NavTarget)
        /// «اتجه» on a card.
        case directions(NavTarget)
    }

    var pending: Pending
    var since: Date

    /// A fix younger than this is "where I am" for starting guidance (same as `TripAutoNav.Input.hasFix`).
    static let freshMs = 120_000.0
    static let slowAfterS = 45.0

    static func isFresh(_ f: DeviceFix?, now: Date) -> Bool {
        guard let f else { return false }
        return now.timeIntervalSince1970 * 1000 - f.atMs < freshMs
    }

    func slow(now: Date) -> Bool { now.timeIntervalSince(since) >= Self.slowAfterS }

    static func text(accuracyM: Double?, slow: Bool) -> String {
        if slow { return "ما قدرنا نحدد موقعك، اطلع لمكان مكشوف" }
        guard let a = accuracyM, a >= 0, a.isFinite else { return "ننتظر موقعك…" }
        return "ننتظر موقعك… · الدقة ±\(ArabicFormat.number(a.rounded())) م"
    }
}

extension LiveOutingController {
    var hasFreshFix: Bool { NavFixWait.isFresh(location.lastFix, now: Date()) }

    /// Show «ننتظر موقعك…» and ask the GPS for a fix now.
    func beginFixWait(_ p: NavFixWait.Pending) {
        let isNew = fixWait == nil
        fixWait = NavFixWait(pending: p, since: fixWait?.since ?? Date())
        location.requestFreshFix()
        guard isNew else { return }
        /* The «مكان مكشوف» line appears even if no fix ever comes. */
        DispatchQueue.main.asyncAfter(deadline: .now() + NavFixWait.slowAfterS + 0.2) { [weak self] in self?.objectWillChange.send() }
    }

    /// Every location change: a fresh fix carries the waiting request out.
    func fixWaitTick() {
        guard let w = fixWait else { return }
        switch w.pending {
        case .auto:
            /* `autoNavTick` (right after) starts it; the wait ends there too. */
            return
        case let .navigate(t):
            guard hasFreshFix else { return }
            fixWait = nil
            navigate(.success(t))
        case let .directions(t):
            guard hasFreshFix else { return }
            fixWait = nil
            directions(.success(t))
        }
    }

    /// «إلغاء» on the waiting row. The trip's guidance is paused on this phone (else it would start
    /// by itself with the next fix); «استأنف التوجيه» brings it back.
    func cancelFixWait() {
        guard let w = fixWait else { return }
        fixWait = nil
        location.endFreshFixRequest()
        if w.pending == .auto { pauseAutoNav() }
    }

    var fixWaitLine: String? {
        guard let w = fixWait else { return nil }
        return NavFixWait.text(accuracyM: location.quality.lastAccuracyM ?? location.lastFix?.accuracy, slow: w.slow(now: Date()))
    }

    #if DEBUG
    /// `-SaryStaleFixThenFresh <s>`: my only fix is 5 minutes old (the system GPS ignored) until
    /// a fresh one arrives after s seconds — the regression path of build 21.
    func fixWaitDebugLaunch() {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-SaryStaleFixThenFresh"), i + 1 < a.count, let s = Double(a[i + 1]) else { return }
        let p = (lat: 24.7113, lng: 46.6744)
        location.ignoresSystemFixes = true
        let old = Date().timeIntervalSince1970 * 1000 - 300_000
        location.debugSetLastFix(DeviceFix(lat: p.lat, lng: p.lng, accuracy: 35, heading: nil, speed: 0, atMs: old))
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSince1970 * 1000
            self.location.ingest(DeviceFix(lat: p.lat, lng: p.lng, accuracy: 8, heading: nil, speed: 0, atMs: now), nowMs: now)
            self.location.ignoresSystemFixes = false
        }
    }
    #endif
}

/// «ننتظر موقعك… · الدقة ±٣٥ م» with «إلغاء» (the top stack of the live screen).
struct NavFixWaitRow: View {
    var text: String
    var slow: Bool
    var cancel: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        HStack(spacing: theme.space(.s)) {
            if slow {
                Image(systemName: "location.slash").foregroundStyle(p.warning).accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text).saryText(.subhead, weight: .medium).foregroundStyle(p.textPrimary)
                .lineLimit(2).minimumScaleFactor(0.85)
                .accessibilityIdentifier("nav.waitFix.text")
            Spacer(minLength: 0)
            Button(action: cancel) { Text("إلغاء").saryText(.subhead, weight: .bold) }
                .buttonStyle(.sary(.secondary, width: .hug, compact: true))
                .accessibilityIdentifier("nav.waitFix.cancel")
        }
        .padding(.horizontal, theme.space(.m))
        .padding(.vertical, theme.space(.s))
        .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .chrome)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nav.waitFix")
    }
}
