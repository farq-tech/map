import Foundation

/// «اسأل سرى» on the live outing: the facts it may use, and what its answers may do.
extension LiveOutingController {
    func makeAssistant() -> AssistantController {
        let a = AssistantController(facts: { [weak self] in self?.assistantFacts() ?? AssistantFacts(now: Date()) })
        a.perform = { [weak self] act in self?.performAssistant(act) }
        a.driving = { [weak self] in self.map { $0.liveContext(drive: $0.appearance.autoDrive) == .driving } ?? false }
        a.speech.micBusy = { GroupAudioDuck.pttActive }
        return a
    }

    func openAssistant() {
        modal = .assistant
    }

    /// The app's state, now. Positions: only real fixes, each with its freshness (never a live one invented).
    func assistantFacts() -> AssistantFacts {
        let now = Date()
        let i = input
        var f = AssistantFacts(now: now)
        if let fix = i.myFix, now.timeIntervalSince1970 * 1000 - fix.atMs <= TripMath.myFixShowMaxAgeMs {
            f.me = LngLat(lng: fix.lng, lat: fix.lat)
        }
        f.others = LiveOutingPresenter.mapMembers(i, hideNotes: true).filter { !$0.isMe }.map {
            AssistantFacts.Member(id: $0.id, name: $0.name, position: $0.position, presence: $0.presence, atMs: $0.atMs)
        }
        if let d = tripDestination { f.destinationName = d.name }
        f.arrived = trip.record.me.arrived
        f.remaining = i.myTripRemaining
        if let r = i.myTripRemaining {
            if let eta = r.navETA { f.etaSeconds = max(0, eta.timeIntervalSince(now)) }
            else if let avg = safety.speed.average(nowMs: now.timeIntervalSince1970 * 1000), avg >= MovingSpeed.movingMps {
                f.etaSeconds = r.meters / WayBack.speed(average: avg)
            }
        }
        f.stations = stations
        if let st = weather.chipStore { f.weather = st.report }
        if case .destination = weather.source { f.weatherPlace = "في الوجهة" }
        f.sunset = safety.sunset
        f.wayBackS = safety.wayBackS
        f.rally = rallyPoint
        let radio = GroupAudioCenters.of(self)
        f.radio = .init(available: true, playing: radio.state.playing, muted: radio.muted, title: radio.nowItem?.title, canControl: radio.canControl)
        f.channelsAvailable = session.walkie.showsChannels
        f.currentChannel = session.walkie.channelId
        f.chatAvailable = chat.isAvailable
        f.tripRunning = !tripEnded
        f.hasBackTrail = BackTrack(path: session.displayTrail) != nil
        return f
    }

    /// An answer's action. Sheets open after a beat so the answer card is read (or heard) first.
    func performAssistant(_ a: AssistantAction) {
        let later: (TimeInterval, @escaping () -> Void) -> Void = { s, f in DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }
        switch a {
        case let .navigate(goal):
            switch goal {
            case .destination: later(1.2) { [weak self] in self.map { $0.directions(NavTargets.destination($0.navDestination())) } }
            case .rally: later(1.2) { [weak self] in self.map { $0.directions(NavTargets.rally($0.rallyPoint)) } }
            case .station:
                guard let s = stationList.first else { return later(1.2) { [weak self] in self?.openStations() } }
                later(1.2) { [weak self] in self?.directions(NavTargets.station(name: s.name ?? s.brand, lat: s.lat, lng: s.lng)) }
            case .back: later(1.2) { [weak self] in self?.startBackTrack() }
            case let .member(name):
                guard let m = assistantFacts().others.first(where: { $0.name == name }) else { return }
                later(1.2) { [weak self] in self.map { $0.directions($0.memberTarget(m.id)) } }
            }
        case .radioPlay:
            let r = GroupAudioCenters.of(self)
            if r.muted { r.unmute() } else if r.canControl, r.nowItem != nil, !r.state.playing { Task { await r.togglePlay() } }
        case .radioMute:
            GroupAudioCenters.of(self).mute()
        case .openRadio:
            later(1.2) { [weak self] in guard let self else { return }; self.modal = nil; GroupAudioCenters.of(self).open() }
        case let .setChannel(id):
            session.walkie.switchChannel(id)
        case .openChat:
            later(1.0) { [weak self] in self?.openChat() }
        case .openStations:
            /* Fetch now so the answer can name the nearest one; the list itself stays on demand. */
            if case .loaded = stations {} else { loadStations() }
        case .openWeather:
            feedWeather(force: false)
        case .showRally:
            if let r = rallyPoint { lowerSheetThenAsk(.point(r.position)) }
        }
    }
}
