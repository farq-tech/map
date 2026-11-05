import Combine
import Foundation

// «ذكاء القافلة» (build 9, docs/IA-REDESIGN.md §6 stage 5): distance from the leader, stopped
// and disconnected states, and the separation / unexpected-stop alerts — computed on this
// phone from LIVE positions only. A stale or lost car never raises (or keeps) an alert.

/// «تنبيهات القافلة» in Settings: every rule can be turned off and tuned.
struct ConvoyAlertSettings: Codable, Equatable {
    /// «ابتعد عن القائد»: further than `separationKm` from the leader for `separationGraceS`.
    var separationOn = true
    var separationKm = 2.0
    var separationGraceS = 60.0
    /// «وقف فجأة»: was moving over 20 km/h, then stopped for `stopMinutes` while the group keeps moving.
    var stopOn = true
    var stopMinutes = 3.0
    /// «انقطع الإرسال» (the server's member_silent): alert at 10 or only at 30 minutes.
    var silentOn = true
    var silentMinutes = 10
    /// «تأخر عن المؤخرة» (convoy mode): on/off and a grace period before it alerts (0 = at once, as before).
    var behindTailOn = true
    var behindTailGraceS = 0.0

    static let separationKmRange: ClosedRange<Double> = 0.5...10
    static let separationGraceRange: ClosedRange<Double> = 15...300
    static let stopMinutesRange: ClosedRange<Double> = 1...15
    static let silentChoices = [10, 30]
    static let behindTailGraceRange: ClosedRange<Double> = 0...180

    /// Values a corrupted or hand-edited store could hold are pulled back into range.
    func clamped() -> ConvoyAlertSettings {
        var s = self
        s.separationKm = min(max(s.separationKm, Self.separationKmRange.lowerBound), Self.separationKmRange.upperBound)
        s.separationGraceS = min(max(s.separationGraceS, Self.separationGraceRange.lowerBound), Self.separationGraceRange.upperBound)
        s.stopMinutes = min(max(s.stopMinutes, Self.stopMinutesRange.lowerBound), Self.stopMinutesRange.upperBound)
        if !Self.silentChoices.contains(s.silentMinutes) { s.silentMinutes = 10 }
        s.behindTailGraceS = min(max(s.behindTailGraceS, Self.behindTailGraceRange.lowerBound), Self.behindTailGraceRange.upperBound)
        return s
    }
}

/// This device's rules (UserDefaults), observable for the settings screen.
@MainActor
final class ConvoyAlertPrefs: ObservableObject {
    static let shared = ConvoyAlertPrefs()
    static let key = "sary.convoy.alerts.v1"

    @Published var settings: ConvoyAlertSettings {
        didSet { save() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let d = defaults.data(forKey: Self.key), let s = try? JSONDecoder().decode(ConvoyAlertSettings.self, from: d) {
            settings = s.clamped()
        } else {
            settings = ConvoyAlertSettings()
        }
    }

    private let defaults: UserDefaults

    private func save() {
        if let d = try? JSONEncoder().encode(settings.clamped()) { defaults.set(d, forKey: Self.key) }
    }

    func reset() { settings = ConvoyAlertSettings() }
}

/// Who distances are measured from: «المقدمة» when convoy mode names one, else the outing's owner.
enum ConvoyLeader {
    static func id(convoy: ConvoyInfo?, ownerId: String?) -> String? {
        if let c = convoy, c.isOn, let l = c.lead_user_id { return l }
        return ownerId
    }

    /// What the reference is called: «المقدمة» in convoy mode, else «أمير الرحلة».
    static func title(convoy: ConvoyInfo?) -> String {
        if let c = convoy, c.isOn, c.lead_user_id != nil { return "المقدمة" }
        return "أمير الرحلة"
    }
}

/// The separation and unexpected-stop watch: grace periods, hysteresis and cooldowns,
/// so a car hovering at a threshold or a GPS jump never makes the phone buzz again and again.
struct ConvoyWatch {
    struct Car: Equatable {
        var id: String
        var position: Geo.LatLng
        /// km/h from the car's own live fix; nil when it did not report one.
        var speedKmh: Double?
        /// Live (Policy freshness). Stale / lost cars reset their state and never alert.
        var live: Bool
        var isMe = false
    }

    struct Context: Equatable {
        var leaderId: String?
        /// Destination, rally point, shared waypoints: stopping there is expected.
        var knownStops: [Geo.LatLng] = []
    }

    enum Alert: Equatable {
        case separated(userId: String, meters: Double)
        case unexpectedStop(userId: String, since: Date)

        var key: String {
            switch self {
            case let .separated(u, _): return "convoy:sep:\(u)"
            case let .unexpectedStop(u, _): return "convoy:stop:\(u)"
            }
        }
    }

    /// Back under this share of the threshold before a separation counts as over.
    static let clearRatio = 0.8
    /// A reminder for an alert that stays true, at most this often.
    static let reminderS: TimeInterval = 300
    /// After an alert clears, the same one stays quiet this long (a car parking at the edge).
    static let quietAfterClearS: TimeInterval = 120
    static let movingKmh = 20.0
    static let stoppedKmh = 3.0
    static let movingAgainKmh = 10.0
    static let groupMovingKmh = 15.0
    /// The fast stretch must end within this long before the stop began.
    static let fastBeforeStopS: TimeInterval = 120
    static let knownStopRadiusM = 300.0

    private struct State {
        var farSince: Date?
        var sepFiring = false
        var lastFast: Date?
        var stoppedSince: Date?
        var stopFiring = false
    }

    private var states: [String: State] = [:]
    private(set) var lastFired: [String: Date] = [:]
    private var clearedAt: [String: Date] = [:]

    /// When a live car stopped (speed ≤ 3 km/h), for «واقف منذ …» on its row.
    func stoppedSince(_ id: String) -> Date? { states[id]?.stoppedSince }

    /// Feed the latest cars. Returns alerts to show (new or a reminder) and keys to take down.
    mutating func ingest(_ cars: [Car], context ctx: Context, settings s: ConvoyAlertSettings, now: Date) -> (fire: [Alert], clear: [String]) {
        var fire: [Alert] = []
        var clear: [String] = []
        let byId = Dictionary(cars.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let leader = ctx.leaderId.flatMap { byId[$0] }.flatMap { $0.live ? $0 : nil }
        let threshold = s.separationKm * 1000

        func admit(_ a: Alert, firing: Bool) -> Bool {
            if let q = clearedAt[a.key], now.timeIntervalSince(q) < Self.quietAfterClearS, !firing { return false }
            if let last = lastFired[a.key], now.timeIntervalSince(last) < Self.reminderS { return false }
            lastFired[a.key] = now
            return true
        }
        func takeDown(_ key: String) {
            clear.append(key)
            clearedAt[key] = now
            lastFired[key] = nil
        }

        for car in cars.sorted(by: { $0.id < $1.id }) {
            var st = states[car.id] ?? State()
            defer { states[car.id] = st }
            guard car.live else {
                /* An old position says nothing about now: forget, and take down what it raised. */
                if st.sepFiring { takeDown(Alert.separated(userId: car.id, meters: 0).key) }
                if st.stopFiring { takeDown(Alert.unexpectedStop(userId: car.id, since: now).key) }
                st = State()
                continue
            }

            // Separation from the leader.
            if s.separationOn, let leader, car.id != leader.id {
                let d = Geo.haversineMeters(car.position, leader.position)
                if d > threshold {
                    let since = st.farSince ?? now
                    st.farSince = since
                    if now.timeIntervalSince(since) >= s.separationGraceS {
                        let a = Alert.separated(userId: car.id, meters: d)
                        if admit(a, firing: st.sepFiring) { fire.append(a) }
                        st.sepFiring = true
                    }
                } else if d < threshold * Self.clearRatio {
                    st.farSince = nil
                    if st.sepFiring { st.sepFiring = false; takeDown(Alert.separated(userId: car.id, meters: d).key) }
                }
            } else {
                st.farSince = nil
                if st.sepFiring { st.sepFiring = false; takeDown(Alert.separated(userId: car.id, meters: 0).key) }
            }

            // Stopped / unexpected stop.
            if let v = car.speedKmh {
                if v > Self.movingKmh { st.lastFast = now }
                if v <= Self.stoppedKmh {
                    if st.stoppedSince == nil { st.stoppedSince = now }
                } else if v > Self.movingAgainKmh || st.stoppedSince == nil {
                    st.stoppedSince = nil
                    if st.stopFiring { st.stopFiring = false; takeDown(Alert.unexpectedStop(userId: car.id, since: now).key) }
                }
            }
            guard s.stopOn, !car.isMe, let since = st.stoppedSince, !st.stopFiring else {
                if !s.stopOn, st.stopFiring { st.stopFiring = false; takeDown(Alert.unexpectedStop(userId: car.id, since: now).key) }
                continue
            }
            let wasDriving = st.lastFast.map { since.timeIntervalSince($0) <= Self.fastBeforeStopS } ?? false
            let long = now.timeIntervalSince(since) >= s.stopMinutes * 60
            let groupMoving = cars.contains { $0.id != car.id && $0.live && ($0.speedKmh ?? 0) > Self.groupMovingKmh }
            let atKnownStop = ctx.knownStops.contains { Geo.haversineMeters($0, car.position) <= Self.knownStopRadiusM }
            if wasDriving, long, groupMoving, !atKnownStop {
                let a = Alert.unexpectedStop(userId: car.id, since: since)
                if admit(a, firing: false) { fire.append(a) }
                st.stopFiring = true
            }
        }
        /* Cars that left the outing. */
        for id in states.keys where byId[id] == nil {
            if states[id]?.sepFiring == true { takeDown(Alert.separated(userId: id, meters: 0).key) }
            if states[id]?.stopFiring == true { takeDown(Alert.unexpectedStop(userId: id, since: now).key) }
            states[id] = nil
        }
        return (fire, clear)
    }

    mutating func reset() {
        states = [:]
        lastFired = [:]
        clearedAt = [:]
    }
}

/// «ارجعوا لنقطة التجمع»: sent as the leader's note (the existing note channel), so older
/// builds still see it as a note above the leader's car; this build turns it into a prompt.
enum RallyRecall {
    static let noteText = "↩︎ ارجعوا لنقطة التجمع"

    static func isRecall(_ text: String?) -> Bool { text?.trimmingCharacters(in: .whitespaces) == noteText }
}

/// Grace period for the existing «تأخر عن المؤخرة» alert: it must stay true this long first.
struct GraceFilter {
    private var since: [String: Date] = [:]

    mutating func pass(_ keys: [String], grace: TimeInterval, now: Date) -> Set<String> {
        let current = Set(keys)
        since = since.filter { current.contains($0.key) }
        var out = Set<String>()
        for k in keys {
            let s = since[k] ?? now
            since[k] = s
            if now.timeIntervalSince(s) >= grace { out.insert(k) }
        }
        return out
    }
}
