import Foundation

// docs/EXPLORE-MERGE.md EM4: exploration's capabilities stop being a mode. Pure rules, no UI.

/// Which map capabilities are on: the chosen base layer, 3D terrain, weather overlays, the high-res surface, clean
/// satellite labels, the desert tracks, and the saved places and tracks drawn on the map.
/// Today they open only inside exploration (`exploring`). With `sary.oneMap` the live map has them whenever the
/// person is looking around: stopped, not guiding, not following a track, not back-tracking.
enum MapCapabilityRules {
    static func unlocked(exploring: Bool, oneMap: Bool, navigating: Bool, following: Bool, moving: Bool) -> Bool {
        if exploring { return true }
        return oneMap && !navigating && !following && !moving
    }
}

extension LiveOutingController {
    /// `MapCapabilityRules` for this screen right now (the flag is read live: the switch in «متقدم»).
    var mapCapabilitiesOn: Bool {
        MapCapabilityRules.unlocked(exploring: exploreActive, oneMap: OneMapFlag.isOn(), navigating: nav.isActive,
                                    following: trackFollow != nil || backTrack != nil, moving: motion.moving)
    }
}
