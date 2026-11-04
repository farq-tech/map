import Foundation

/// A small jitter buffer for one transmission at a time.
///
/// Frames arrive over a WebSocket (TCP: in order, but in bursts after a stall)
/// or the nearby link (unreliable: lost, duplicated, reordered). The player
/// pulls one 30 ms packet per tick:
///
///   * it waits until `targetDepth` packets are queued before it starts
///     (≈90 ms of cushion), and again after an underrun;
///   * a missing packet is a `.gap` (the player plays 30 ms of silence) once a
///     later one is already here — it never waits for a retransmission;
///   * late packets (behind the playout point) and duplicates are dropped;
///   * past `maxDepth` the oldest packets go, so latency stays bounded.
///
/// Frames of another burst are ignored until `reset(burst:)`.
struct PTTJitterBuffer: Equatable {
    enum Pop: Equatable {
        /// Still filling up: play nothing yet.
        case wait
        case frame(PTTFrame)
        /// Packet `seq` never came: conceal it.
        case gap(seq: UInt16)
        /// Ran dry mid-transmission: play nothing, refill to `targetDepth`.
        case underrun
    }

    let targetDepth: Int
    let maxDepth: Int
    private(set) var burst: UInt8?
    private(set) var queue: [UInt16: PTTFrame] = [:]
    /// The next sequence number to play (nil until playout starts).
    private(set) var next: UInt16?
    private(set) var playing = false
    private(set) var stats = Stats()

    struct Stats: Equatable {
        var received = 0
        var played = 0
        var gaps = 0
        var late = 0
        var duplicates = 0
        var overflow = 0
        var underruns = 0
    }

    init(targetDepth: Int = 3, maxDepth: Int = 110) {
        self.targetDepth = max(1, targetDepth)
        self.maxDepth = max(targetDepth + 1, maxDepth)
    }

    /// A new transmission: forget everything from the last one.
    mutating func reset(burst: UInt8?) {
        self.burst = burst
        queue = [:]
        next = nil
        playing = false
        stats = Stats()
    }

    var depth: Int { queue.count }

    mutating func push(_ f: PTTFrame) {
        guard let b = burst, f.burst == b else { return }
        if let n = next, pttSeqDelta(f.seq, n) < 0 {
            stats.late += 1
            return
        }
        if queue[f.seq] != nil {
            stats.duplicates += 1
            return
        }
        queue[f.seq] = f
        stats.received += 1
        if queue.count > maxDepth, let oldest = oldestSeq() {
            queue[oldest] = nil
            stats.overflow += 1
            if let n = next, pttSeqDelta(oldest, n) >= 0 { next = oldest &+ 1 }
        }
    }

    mutating func pop() -> Pop {
        if !playing {
            guard queue.count >= targetDepth, let first = oldestSeq() else { return .wait }
            playing = true
            /* After an underrun we resume from where we were, unless that is already gone. */
            if let n = next, queue[n] != nil || pttSeqDelta(first, n) < 0 { /* keep n */ } else { next = first }
        }
        guard let n = next else { return .wait }
        if let f = queue.removeValue(forKey: n) {
            next = n &+ 1
            stats.played += 1
            return .frame(f)
        }
        if queue.isEmpty {
            playing = false
            stats.underruns += 1
            return .underrun
        }
        /* A later packet is here: this one is lost (or so late it no longer matters). */
        next = n &+ 1
        stats.gaps += 1
        return .gap(seq: n)
    }

    private func oldestSeq() -> UInt16? {
        guard let any = queue.keys.first else { return nil }
        let ref = next ?? any
        return queue.keys.min { pttSeqDelta($0, ref) < pttSeqDelta($1, ref) }
    }
}
