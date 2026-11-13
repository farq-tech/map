import Foundation

// Contract for «الرحلة» on the live screen: the compact strip in the sheet's peek
// row, the full card in «المشاركون», drive mode (large, minimal) and the end of
// the trip («وصلت 🎉» → «أنهِ الرحلة» → «ملخص الرحلة» / «طريق العودة»).
// Filled by `TripPresenter` (pure); the views only lay it out.

struct TripPanelUI: Equatable {
    enum Phase: Equatable {
        /// No destination. `canSet`: I lead → «حدّد الوجهة»; else «بانتظار الوجهة».
        case needsDestination(canSet: Bool)
        case notStarted
        /// Started, waiting for my first live fix (the start point).
        case waitingFix
        case underway
        case arrived(at: Date, manual: Bool)
        case ended
    }

    var phase: Phase
    var destinationName: String
    /// 0...100, nil when unknown (no fresh fix of mine yet).
    var percent: Int?
    /// Along my recorded / road-matched trail since the start point.
    var drivenMeters: Double
    var remainingMeters: Double?
    var remainingSource: RemainingSource?
    var eta: Date?
    /// The ETA is ours (remaining ÷ average speed), not the navigation's.
    var etaEstimated: Bool = true
    var elapsedSeconds: Int?
    var movingSeconds: Int?
    var stoppedSeconds: Int?
    var avgMovingKmh: Double?
    var maxKmh: Double?
    /// My last fix is too old for «باقي» / «نوصل»: «آخر موقع قبل …».
    var myFixStaleSince: Date?
    /// «وصل أول: فهد، ثم سلطان • باقي: نورة».
    var arrivalLine: String?
    var everyoneArrived: Bool = false
    var arrivedCount: Int = 0
    var memberCount: Int = 0
    /// I lead: «أنهِ الرحلة».
    var canEnd: Bool
    /// The group's start point (the leader's), distance from me when known.
    var groupStartMeters: Double?
    /// This outing is «طريق العودة» from another one (follow my old trail).
    var isReturnTrip: Bool = false

    var remainingApprox: Bool { remainingSource?.approximate ?? false }
    var isActive: Bool {
        switch phase {
        case .underway, .waitingFix, .arrived: return true
        default: return false
        }
    }

    /// «قطعنا ٦٢٪».
    var progressLine: String? { percent.map { $0 >= 100 ? "وصلنا" : "قطعنا \(SaryFormat.percent($0))" } }

    /// «باقي ١٢ كم» / «باقي ١٢ كم تقريبي».
    var remainingLine: String? {
        remainingMeters.map { "باقي \(SaryFormat.distance(meters: $0))" + (remainingApprox ? " تقريبي" : "") }
    }

    /// «نوصل ٤:٣٠ م».
    var etaLine: String? { eta.map { "نوصل \(NavText.clock($0))" + (etaEstimated && remainingApprox ? " تقريبًا" : "") } }
}

/// What the live screen can do with the trip.
struct TripPanelActions {
    /// «حدّد الوجهة» (leader): the place search.
    var setDestination: () -> Void
    /// «وصلنا».
    var markArrived: () -> Void
    /// «أنهِ الرحلة» (leader), after confirmation: ends the outing for everyone.
    var endTrip: () -> Void
    /// «ملخص الرحلة».
    var openSummary: () -> Void
    /// «طريق العودة» as a new trip back to my start point.
    var returnTrip: () -> Void
    /// Return trip: follow my old trail («على مساري»).
    var followOldTrail: () -> Void
    /// Expand the sheet to the full card.
    var expand: () -> Void
}
