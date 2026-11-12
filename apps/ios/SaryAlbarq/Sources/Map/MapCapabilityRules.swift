import Foundation

// docs/EXPLORE-MERGE.md EM4: exploration's capabilities stop being a mode. Pure rules, no UI.

/// Which map capabilities are on: the chosen base layer, 3D terrain, weather overlays, the high-res surface, clean
/// satellite labels, the desert tracks, and the saved places and tracks drawn on the map.
/// Today they open only inside exploration (`exploring`). With `sary.oneMap` the live map has them whenever the
/// person is looking around: stopped, not guiding, not following a track, not back-tracking.
enum MapCapabilityRules {
    static func unlocked(exploring: Bool, oneMap: Bool, navigating: Bool, following: Bool, moving: Bool) -> Bool {
        /* With the flag the idle map is always "exploring" (it has no way out of it), so driving, guidance and following
         * must take the capabilities away themselves: the chosen base layer and 3D terrain never stay forced on the trip map.
         * Without the flag exploration exits by itself when driving starts (`exploreDrivingCheck`), as before. */
        if oneMap, navigating || following || moving { return false }
        return exploring || oneMap
    }

    /// EM5 (P12/P13): the coordinate card and the crosshair stay on the live map while the capabilities are on, not only
    /// inside exploration (which has its own top bar). Never over the end card, while picking a point, or without the flag
    /// (`capable` is false without it unless exploring, so today's outing map is untouched).
    static func permanentReadout(capable: Bool, exploring: Bool, ended: Bool, picking: Bool) -> Bool {
        capable && !exploring && !ended && !picking
    }
}

extension LiveOutingController {
    /// `MapCapabilityRules` for this screen right now (the flag is read live: the switch in «متقدم»).
    var mapCapabilitiesOn: Bool {
        MapCapabilityRules.unlocked(exploring: exploreActive, oneMap: OneMapFlag.isOn(), navigating: nav.isActive,
                                    following: trackFollow != nil || backTrack != nil, moving: motion.moving)
    }
}
