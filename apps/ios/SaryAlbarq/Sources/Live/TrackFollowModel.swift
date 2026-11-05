import Foundation

/// Anything «اسلك هذا المسار» can follow: a trip's recorded trail, a GPX track, a friend's
/// recent trail — drawn and measured the build-10 way (`TrackDisplay`, `TrackStats`).
struct FollowSubject: Equatable, Identifiable {
    enum Kind: String, Equatable {
        /// My recorded trail of an outing (this phone).
        case outingTrail
        /// An imported / exported GPX track.
        case gpx
        /// A group member's recent trail, as this phone saw their live positions.
        case friend
    }

    var id: String
    var name: String
    var kind: Kind
    var line: TrackLine
    var stats: TrackStats

    /// Short words for where it came from.
    var origin: String {
        switch kind {
        case .outingTrail: return "مسارك المسجّل"
        case .gpx: return "مسار GPX"
        case .friend: return "مسار من الطلعة"
        }
    }

    /// My trail of an outing: from its raw fixes when this phone has them (most precise), else its points.
    static func outing(id: String, name: String, trail: Trail, raw: [RawFix]) -> FollowSubject? {
        let line: TrackLine
        let stats: TrackStats
        if raw.count >= 2 {
            line = TrackDisplay.line(raw: raw)
            stats = TrackStats.make(raw: raw, line: line)
        } else {
            line = TrackDisplay.line(trail: trail.points)
            stats = TrackStats.make(points: trail.points, line: line)
        }
        guard line.isDrawable, line.lengthM > 0 else { return nil }
        return FollowSubject(id: "outing:\(id)", name: name, kind: .outingTrail, line: line, stats: stats)
    }

    static func gpx(_ t: SavedTrack) -> FollowSubject? {
        let line = TrackDisplay.line(plain: t.points)
        guard line.isDrawable, line.lengthM > 0 else { return nil }
        return FollowSubject(id: "gpx:\(t.id)", name: t.name, kind: .gpx, line: line, stats: TrackStats.make(plain: line))
    }

    /// A friend's trail: positions only reach us every few seconds, so no trusted speed («—»).
    static func friend(id: String, name: String, points: [TrailPoint]) -> FollowSubject? {
        let line = TrackDisplay.line(trail: points)
        guard line.isDrawable, line.lengthM >= 100 else { return nil }
        var stats = TrackStats.make(points: points, line: line)
        stats.maxKmh = nil
        /* Their speeds are distance ÷ time between sparse live positions: draw one colour. */
        let plain = TrackLine(points: line.points, gaps: line.gaps)
        return FollowSubject(id: "friend:\(id)", name: "مسار \(name)", kind: .friend, line: plain, stats: stats)
    }
}

/// Follow mode's state, shared by the live outing screen and the stand-alone follow screen.
/// Fed with fixes; never shows an old fix as where I am now.
@MainActor
final class TrackFollowModel: ObservableObject, Identifiable {
    let subject: FollowSubject
    @Published private(set) var follow: TrackFollow
    @Published private(set) var status: TrackFollowStatus?
    /// My last fresh position (for the approach target); nil once it is old.
    private(set) var me: LngLat?
    private var deviation = FollowDeviation()
    /// «خرجت عن المسار» starts / ends (one alert at a time).
    var onDeviation: (FollowDeviation.Event) -> Void = { _ in }

    /// A fix older than this is not where I am.
    static let staleMs = 30_000.0

    nonisolated var id: String { subject.id }

    init?(_ s: FollowSubject, reversed: Bool = false) {
        guard let f = TrackFollow(s.line, reversed: reversed) else { return nil }
        subject = s
        follow = f
    }

    var reversed: Bool { follow.reversed }

    /// The line as followed (its start dot where I begin, its end dot where I am going).
    var drawLine: TrackLine { reversed ? subject.line.reversed : subject.line }

    func ingest(_ fix: DeviceFix?, nowMs: Double) {
        guard let f = fix, nowMs - f.atMs <= Self.staleMs, f.atMs - nowMs <= 5_000 else {
            me = nil
            if status != nil { status = nil }
            emit(deviation.ingest(nil))
            return
        }
        let here = LngLat(lng: f.lng, lat: f.lat)
        me = here
        var fl = follow
        let st = fl.update(here, accuracy: f.accuracy, atMs: f.atMs)
        if fl != follow { follow = fl }
        if st != status { status = st }
        emit(deviation.ingest(st))
    }

    /// «اعكس الاتجاه».
    func reverse() {
        guard let r = follow.reversedFollow() else { return }
        follow = r
        status = nil
        emit(deviation.ingest(nil))
    }

    /// Where to navigate first when the track is far (its nearest point to me).
    var approachTarget: LngLat? {
        guard let me, status?.far == true else { return nil }
        return follow.nearestPoint(to: me).point
    }

    private func emit(_ e: FollowDeviation.Event) {
        if e != .none { onDeviation(e) }
    }

    /// The panel's contract.
    /// - Parameters:
    ///   - course: my trusted course (the arrow is relative to it), nil → relative to the map's top.
    func ui(course: Double?, mapBearing: Double, online: Bool) -> FollowTrackUI {
        guard let st = status else {
            return FollowTrackUI(name: subject.name, phase: .waitingFix, arrowDegrees: 0, directionLabel: "", onGap: false,
                                 reversed: reversed, online: online)
        }
        let phase: FollowTrackUI.Phase = st.arrived ? .arrived : (st.far ? .far : (st.offTrack ? .offTrack : .onTrack))
        let ref = course ?? mapBearing
        return FollowTrackUI(name: subject.name, phase: phase, remainingMeters: st.remainingM, progress: st.progress, offsetMeters: st.offsetM,
                             arrowDegrees: LiveOutingPresenter.relative(st.bearing, mapBearing: ref), directionLabel: Geo.directionLabel(st.bearing),
                             relativeToCourse: course != nil, onGap: st.onGap, reversed: reversed, online: online)
    }
}
