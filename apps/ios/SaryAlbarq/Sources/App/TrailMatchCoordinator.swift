import Foundation

/// Runs the road matcher for one outing's «مساري»: every ~45 s of recording and once
/// at the end, only the new stretch (with an overlap for a clean seam), one request at
/// a time, results cached on this device. Offline: nothing happens and the smoothed
/// trail stays; the next round (or the next launch) catches up.
@MainActor
final class TrailMatchCoordinator {
    static let intervalS = 45.0
    /// Don't bother for fewer new inputs than this (unless finishing).
    static let minNewInputs = 6

    let outingId: String
    private let dir: URL?
    private let service: TrailMatchingService
    private(set) var cache: TrailMatchCache
    private var running = false
    private var lastRun = Date.distantPast
    /// Backoff after a failure (offline / server error).
    private var retryAfter = Date.distantPast
    var onChange: () -> Void = {}
    /// Accuracy of the raw fix at a time (for the search radius).
    var accuracyAt: (Double) -> Double? = { _ in nil }

    init(outingId: String, dir: URL?, service: TrailMatchingService) {
        self.outingId = outingId
        self.dir = dir
        self.service = service
        cache = TrailMatchStore.load(outingId, in: dir) ?? TrailMatchCache()
    }

    /// Called as the trail grows; matches when it is time (or `force` at the end of the outing).
    func tick(_ trail: Trail, force: Bool = false, now: Date = Date()) {
        guard !running, now >= retryAfter else { return }
        guard force || now.timeIntervalSince(lastRun) >= Self.intervalS else { return }
        let plan = Self.plan(trail.points, cache: cache, maxPoints: service.maxPoints, accuracy: accuracyAt)
        guard let plan, force || plan.newInputs >= Self.minNewInputs else { return }
        running = true
        lastRun = now
        /* Strong on purpose: the last round at the end of an outing finishes even if the session is gone. */
        Task { [self] in
            var c = self.cache
            var failed = false
            for job in plan.jobs {
                do {
                    let pieces = try await self.service.match(job.inputs)
                    c.integrate(pieces, inputs: job.inputs, cutT: job.cutT)
                } catch {
                    failed = true
                    break
                }
            }
            self.running = false
            if failed { self.retryAfter = Date().addingTimeInterval(60) }
            if c != self.cache {
                self.cache = c
                TrailMatchStore.save(c, outingId: self.outingId, in: self.dir)
                self.onChange()
            }
        }
    }

    func clear() {
        cache = TrailMatchCache()
        TrailMatchStore.delete(outingId, in: dir)
    }

    struct Job: Equatable {
        var inputs: [MatchInput]
        var cutT: Double?
    }

    struct Plan: Equatable {
        var jobs: [Job]
        var newInputs: Int
    }

    /// The requests to send: the stretch after what is done, starting `overlap` inputs back.
    nonisolated static func plan(_ pts: [TrailPoint], cache: TrailMatchCache, maxPoints: Int = 100, accuracy: (Double) -> Double? = { _ in nil }) -> Plan? {
        let all = TrailMatchPlanner.inputs(pts, accuracy: accuracy)
        guard all.count >= 2 else { return nil }
        let firstNew = all.firstIndex { $0.t > cache.doneUpToT } ?? all.count
        guard firstNew < all.count else { return nil }
        let start = max(0, firstNew - TrailMatchPlanner.overlap)
        let sel = Array(all[start...])
        guard sel.count >= 2 else { return nil }
        var jobs: [Job] = []
        let ranges = TrailMatchPlanner.chunks(count: sel.count, size: maxPoints)
        for (n, r) in ranges.enumerated() {
            let chunk = Array(sel[r])
            var cut: Double?
            if n > 0 || start > 0 {
                /* The seam: middle of the overlap with what came before. */
                let ov = min(TrailMatchPlanner.overlap, chunk.count - 1)
                cut = chunk[ov / 2].t
            }
            jobs.append(Job(inputs: chunk, cutT: cut))
        }
        return Plan(jobs: jobs, newInputs: all.count - firstNew)
    }
}
