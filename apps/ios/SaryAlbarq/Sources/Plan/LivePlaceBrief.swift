import Foundation

/// When a single tap on the map may open «بريف المكان» (unit-tested).
enum PlaceBriefTapRule {
    /// A fix older than this is not "me" for the distance line.
    static let meMaxAgeS: TimeInterval = 120

    /// Never while driving / guiding (no sheet pops up under a moving thumb), never over
    /// another sheet, and one card per burst of taps.
    static func shouldOpen(moving: Bool, navigating: Bool, modalOpen: Bool, picking: Bool, lastOpen: Date?, now: Date) -> Bool {
        if moving || navigating || modalOpen || picking { return false }
        if let t = lastOpen, now.timeIntervalSince(t) < PlaceBriefThresholds.tapDebounceS { return false }
        return true
    }
}

@MainActor
enum PlaceBriefTapGate {
    static var lastOpen: Date?
}

extension LiveOutingController {
    /// A single tap on an empty map spot (or a map label, `name` from the style): the point card with its brief.
    func mapTappedEmpty(_ p: LngLat, name: String?) {
        let now = Date()
        guard PlaceBriefTapRule.shouldOpen(moving: motion.moving, navigating: nav.isActive, modalOpen: modal != nil, picking: picking.active,
                                           lastOpen: PlaceBriefTapGate.lastOpen, now: now) else { return }
        PlaceBriefTapGate.lastOpen = now
        modal = .plan(.brief(p, name: name))
    }

    /// The brief is one line of weather while driving (or guided / moving).
    func briefCompact(drive: Bool) -> Bool {
        nav.isActive || motion.moving || liveContext(drive: drive) == .driving
    }

    /// My position for «على بعد … منك», only while it is recent.
    func briefMe(_ fix: DeviceFix?, now: Date = Date()) -> LngLat? {
        guard let fix, now.timeIntervalSince1970 - fix.atMs / 1000 <= PlaceBriefTapRule.meMaxAgeS else { return nil }
        return LngLat(lng: fix.lng, lat: fix.lat)
    }
}

#if DEBUG
extension LiveOutingController {
    /// `-SaryBriefAt "lat,lng[,name]"` (screenshots / UI tests): centre the map there and open
    /// «بريف المكان» once the tiles (and Terrain-DEM) had time to load. `-SaryBriefDelay <s>`.
    func placeBriefDebugLaunch() {
        let args = ProcessInfo.processInfo.arguments
        func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let at = arg("-SaryBriefAt") else { return }
        let parts = at.split(separator: ",", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, let lat = Double(parts[0]), let lng = Double(parts[1]) else { return }
        let p = LngLat(lng: lng, lat: lat)
        let delay = arg("-SaryBriefDelay").flatMap(Double.init) ?? 5
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.following = false
            self.camera = MapCameraRequest(kind: .point(p), id: (self.camera?.id ?? 0) + 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.modal = .plan(.brief(p, name: parts.count > 2 ? String(parts[2]) : nil))
        }
    }
}
#endif
