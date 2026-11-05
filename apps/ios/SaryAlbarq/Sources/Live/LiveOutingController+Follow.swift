import Foundation

/// «اسلك هذا المسار» on the live outing: follow any saved track off-road (pure geometry,
/// offline), one deviation alert at a time through the alert queue, «اعكس الاتجاه», and —
/// when the track is far and we are online — «الملاحة» to its nearest point first.
extension LiveOutingController {
    func startFollow(_ s: FollowSubject, reversed: Bool = false) {
        guard let m = TrackFollowModel(s, reversed: reversed) else {
            toast("هذا المسار قصير جدًا للتوجيه عليه.")
            return
        }
        if backTrack != nil { stopBackTrack() }
        if exploreActive { exitExplore(reframe: false) }
        m.onDeviation = { [weak self] e in self?.followDeviation(e) }
        trackFollow = m
        followCam.release()
        followCamGuidanceCheck()
        modal = nil
        updateFollow()
        var pts = s.line.points
        if let f = location.lastFix, Date().timeIntervalSince1970 * 1000 - f.atMs < TrackFollowModel.staleMs { pts.append(LngLat(lng: f.lng, lat: f.lat)) }
        lowerSheetThenAsk(.fitTrack(pts))
    }

    func stopFollow() {
        trackFollow = nil
        followCamGuidanceCheck()
        dismissAlert(Self.followAlertId)
    }

    /// «اعكس الاتجاه».
    func reverseFollow() {
        trackFollow?.reverse()
        dismissAlert(Self.followAlertId)
        updateFollow()
        objectWillChange.send()
    }

    func updateFollow() {
        guard let m = trackFollow else { return }
        /* Only a recent fix (the model drops older ones itself too). */
        m.ingest(session.smoothedFix(location.lastFix), nowMs: Date().timeIntervalSince1970 * 1000)
        if let st = m.status, st.arrived, !followArrivedSaid { toast("وصلت نهاية «\(m.subject.name)»") }
        followArrivedSaid = m.status?.arrived == true
    }

    private func followDeviation(_ e: FollowDeviation.Event) {
        guard let m = trackFollow else { return }
        switch e {
        case let .raise(meters):
            pushAlert(LiveAlertUI(id: Self.followAlertId, kind: .offTrack(FollowDeviationAlertUI(trackName: m.subject.name, meters: meters))), ttl: 90)
            UINotificationFeedback.warning()
        case .clear:
            dismissAlert(Self.followAlertId)
        case .none:
            break
        }
    }

    var followUI: FollowTrackUI? {
        guard let m = trackFollow else { return nil }
        let course = location.lastFix.flatMap { Policy.trustedHeading($0.heading, speed: $0.speed) }
        return m.ui(course: course, mapBearing: overlay.projection.bearing, online: followOnline)
    }

    /// The track is far: «الملاحة» to its nearest point (online only; it says so otherwise).
    func approachFollow() {
        guard followOnline else {
            return toast("ما فيه إنترنت لحساب طريق إلى المسار. اتجه بالسهم؛ التوجيه على المسار يشتغل بدون إنترنت.")
        }
        guard let p = trackFollow?.approachTarget else { return }
        navigate(NavTargets.point(p, name: "أقرب نقطة من المسار"))
    }

    /// Routing needs the server reachable (the live channel or polling working).
    var followOnline: Bool { session.isDemo || session.link == .live || session.link == .polling }

    /// A friend's recent trail as this phone saw it (their live positions, this session only).
    func friendFollowSubject(_ id: String) -> FollowSubject? {
        guard let pts = friendTrails.byId[id], let name = session.view?.members[id]?.display_name else { return nil }
        return FollowSubject.friend(id: id, name: name, points: pts)
    }
}
