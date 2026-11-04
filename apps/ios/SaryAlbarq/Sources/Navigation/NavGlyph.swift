import Foundation

/// SF Symbols for maneuvers and lanes. Real-world directions: views showing them
/// force left-to-right so RTL never mirrors a right turn into a left one.
enum NavGlyph {
    static func symbol(_ m: NavManeuver) -> String {
        switch m.kind {
        case .arrive: return "flag.checkered"
        case .depart: return "location.north.fill"
        case .roundabout, .exitRoundabout: return "arrow.triangle.turn.up.right.circle.fill"
        case .merge: return "arrow.triangle.merge"
        case .fork: return turn(m.direction ?? .straight, fork: true)
        default: return turn(m.direction ?? .straight)
        }
    }

    static func turn(_ d: NavTurnDirection, fork: Bool = false) -> String {
        switch d {
        case .right, .sharpRight: return "arrow.turn.up.right"
        case .left, .sharpLeft: return "arrow.turn.up.left"
        case .slightRight: return fork ? "arrow.triangle.branch" : "arrow.up.right"
        case .slightLeft: return "arrow.up.left"
        case .uTurn: return "arrow.uturn.down"
        case .straight: return "arrow.up"
        }
    }

    /// The lane arrow: the first direction painted on it.
    static func lane(_ l: NavLane) -> String {
        turn(l.directions.first ?? .straight)
    }

    /// `CPManeuverType` case name (CarPlay, iOS 17.4+).
    static func carPlayType(_ m: NavManeuver) -> String {
        switch m.kind {
        case .arrive: return "arriveAtDestination"
        case .depart: return "startRoute"
        case .roundabout: return m.exit.map { "roundaboutExit\(min(19, max(1, $0)))" } ?? "enterRoundabout"
        case .exitRoundabout: return "exitRoundabout"
        case .onRamp: return "onRamp"
        case .offRamp: return m.direction.map { [.left, .slightLeft, .sharpLeft].contains($0) ? "offRampLeft" : "offRampRight" } ?? "offRamp"
        case .merge: return "highwayMerge"
        case .fork: return m.direction.map { [.left, .slightLeft, .sharpLeft].contains($0) ? "keepLeft" : "keepRight" } ?? "followRoad"
        default:
            switch m.direction {
            case .right: return "rightTurn"
            case .left: return "leftTurn"
            case .slightRight: return "slightRightTurn"
            case .slightLeft: return "slightLeftTurn"
            case .sharpRight: return "sharpRightTurn"
            case .sharpLeft: return "sharpLeftTurn"
            case .uTurn: return "uTurn"
            case .straight, .none: return "straightAhead"
            }
        }
    }
}

#if DEBUG
/// DEBUG trace of a navigation (simulator runs): unified log + Documents/nav.log.
enum NavLog {
    static func log(_ format: String, _ args: CVarArg...) {
        let line = String(format: format, arguments: args)
        NSLog("[NAV] %@", line)
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("nav.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
#endif
