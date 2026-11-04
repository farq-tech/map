import Foundation

/// What the live screen is for right now: **driving** (map first, minimal chrome) or
/// **stopped** (planning, richer information). Chosen automatically, overridable in
/// «المزيد» → «شكل الشاشة». See docs/IA-REDESIGN.md §2.1.
enum LiveContext: Equatable {
    case driving, stopped
}

/// «شكل الشاشة»: automatic, or pinned by the person.
enum LiveContextOverride: String, CaseIterable, Identifiable, Hashable {
    case auto, driving, stopped
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "تلقائي"
        case .driving: return "قيادة"
        case .stopped: return "متوقف"
        }
    }

    static let key = "sary.live.context.v1"
    static var saved: LiveContextOverride {
        get { UserDefaults.standard.string(forKey: key).flatMap(LiveContextOverride.init) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// «أتحرك؟» with hysteresis, from the GPS speed: moving above 15 km/h, and back to
/// stopped only after 20 s at 5 km/h or less (a red light does not flip the screen).
struct MotionHysteresis: Equatable {
    static let enterKmh = 15.0
    static let leaveKmh = 5.0
    static let leaveAfterS: TimeInterval = 20

    private(set) var moving = false
    private var slowSince: TimeInterval?

    /// Feed one speed sample (m/s; nil = unknown) at `t` seconds.
    mutating func ingest(speedMps: Double?, at t: TimeInterval) {
        let kmh = max(0, speedMps ?? 0) * 3.6
        if kmh > Self.enterKmh {
            moving = true
            slowSince = nil
        } else if moving {
            if kmh <= Self.leaveKmh {
                if let s = slowSince {
                    if t - s >= Self.leaveAfterS { moving = false; slowSince = nil }
                } else {
                    slowSince = t
                }
            } else {
                slowSince = nil
            }
        }
    }
}

enum LiveContextRule {
    /// The mode the screen shows.
    /// - Parameters:
    ///   - sheetRaised: the sheet is at half or full (the person is reading: always «stopped»).
    static func resolve(override o: LiveContextOverride, navigating: Bool, moving: Bool, driveMode: Bool, sheetRaised: Bool) -> LiveContext {
        if sheetRaised { return .stopped }
        switch o {
        case .driving: return .driving
        case .stopped: return .stopped
        case .auto: return navigating || moving || driveMode ? .driving : .stopped
        }
    }
}
