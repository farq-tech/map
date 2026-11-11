import Foundation

/// «تتبعني» / «باتجاهي» on the live screen: the camera-mode button (where «موقعي» was), the
/// automatic «باتجاهي» when guidance starts or resumes, «رجّعني للتوجيه» after a pan, and the
/// automatic return after a while without touching (`FollowCameraState` decides).
extension LiveOutingController {
    /// Guidance of any kind is leading me now: «الملاحة» (road or off-road leg), «طريق العودة», «اسلك هذا المسار».
    var guidanceOn: Bool {
        nav.phase == .guiding || nav.phase == .offRoad || backTrack != nil || trackFollow != nil
    }

    /// What the map's camera does now: «نظرة عامة» and route planning own it while they show.
    var mapFollowMode: MapFollowMode {
        if nav.phase == .planning { return .free }
        if nav.isActive, nav.camera == .overview { return .free }
        return followCam.mode
    }

    /// The camera button, in «موقعي»'s place (also while guiding).
    var cameraModeItem: SaryMapControlItem {
        let m = mapFollowMode
        return SaryMapControlItem(id: "locate", systemImage: m.systemImage, label: m.label, accessibilityID: "outing-locate",
                                  isActive: m != .free, hint: m.hint, value: m.rawValue)
    }

    /// «رجّعني للتوجيه» (or, without guidance, «رجّعني لاتجاهي»).
    var recenterTitle: String? {
        guard followCam.recenterOffered, mapFollowMode == .free else { return nil }
        return guidanceOn ? "رجّعني للتوجيه" : "رجّعني لاتجاهي"
    }

    /// The button: free → «تتبعني» → «باتجاهي» → free.
    func cycleCameraMode() {
        if location.lastFix == nil { toast("ننتظر أول قراءة للموقع") }
        if nav.isActive, nav.camera == .overview {
            /* From «نظرة عامة» the button means "back on my car". */
            nav.camera = .follow
            followCam.recenter()
        } else {
            followCam.cycle()
            if nav.isActive { nav.camera = followCam.mode == .free ? .free : .follow }
        }
        followCamTimerCheck()
    }

    /// «رجّعني للتوجيه» (the pill, or by itself).
    func recenterCamera() {
        followCam.recenter()
        if nav.isActive { nav.camera = .follow }
        followCamTimerCheck()
    }

    /// A pan / pinch / rotate / tilt on the map.
    func cameraUserMoved() {
        followCam.userMovedMap(at: Date().timeIntervalSince1970)
        followCamTimerCheck()
    }

    /// Any finger on the screen (the auto-recenter waits for it to be gone a while).
    func cameraTouch(down: Bool) {
        followCam.touch(down: down, at: Date().timeIntervalSince1970)
    }

    /// The camera taken for something else (a member, the group, a point).
    func releaseCamera() {
        followCam.release(offerBack: guidanceOn, at: Date().timeIntervalSince1970)
        followCamTimerCheck()
    }

    /// Every nav / guidance change: guidance starting or resuming turns «باتجاهي» on.
    func followCamGuidanceCheck() {
        let on = guidanceOn
        defer { lastGuidanceOn = on }
        if on, !lastGuidanceOn {
            /* «طريق العودة» / «اسلك هذا المسار» first show the whole track; then «باتجاهي». */
            let showTrackFirst = nav.phase != .guiding && nav.phase != .offRoad
            if showTrackFirst { enterHeadingSoon() } else { enterHeadingNow() }
        } else if !on, lastGuidanceOn {
            followCam.guidanceEnded()
            followCamTimerCheck()
        }
    }

    private func enterHeadingNow() {
        followCam.guidanceStarted()
        if nav.isActive { nav.camera = .follow }
        followCamTimerCheck()
    }

    /// After the track's overview has been seen (unless the person touched the map meanwhile).
    private func enterHeadingSoon(after s: TimeInterval = 2.6) {
        let mark = followCam.lastTouchAt
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak self] in
            guard let self, self.guidanceOn, self.followCam.lastTouchAt == mark else { return }
            self.enterHeadingNow()
        }
    }

    // MARK: auto-recenter

    /// A one-second check runs only while the pill shows.
    func followCamTimerCheck() {
        if followCam.recenterOffered {
            guard followCamTimer == nil else { return }
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.followCamTick() }
            RunLoop.main.add(t, forMode: .common)
            followCamTimer = t
        } else {
            followCamTimer?.invalidate()
            followCamTimer = nil
        }
    }

    private func followCamTick() {
        let kmh = speed.current.kmh ?? location.lastFix.flatMap { $0.speed }.map { max(0, $0) * 3.6 }
        if followCam.shouldAutoRecenter(now: Date().timeIntervalSince1970, speedKmh: kmh, prefs: FollowCameraPrefs.snapshot()) {
            recenterCamera()
        }
        if !followCam.recenterOffered { followCamTimerCheck() }
    }
}
