import SwiftUI

// Contracts for shared waypoints and convoy mode (screens, map pins, alert cards).

/// A convoy alert card in the lane.
struct ConvoyAlertUI: Equatable {
    enum Kind: Equatable { case behindTail, aheadOfLead, tailFar }
    var kind: Kind
    var userId: String
    var name: String
    var color: UInt32
    var meters: Double

    var title: String {
        switch kind {
        case .behindTail: return name == "أنت" ? "تأخرت عن المؤخرة" : "\(name) متأخر عن المؤخرة"
        case .aheadOfLead: return name == "أنت" ? "سبقت المقدمة" : "\(name) سبق المقدمة"
        case .tailFar: return "المؤخرة بعيدة عن المقدمة"
        }
    }

    var detail: String {
        let d = SaryFormat.distance(meters: meters)
        switch kind {
        case .behindTail: return "خلف المؤخرة بـ \(d)"
        case .aheadOfLead: return "قدّام المقدمة بـ \(d)"
        case .tailFar: return "بين المقدمة والمؤخرة \(d)"
        }
    }

    var symbol: String {
        switch kind {
        case .behindTail: return "arrow.down.to.line"
        case .aheadOfLead: return "arrow.up.to.line"
        case .tailFar: return "arrow.up.and.down"
        }
    }
}

/// The small badge on a convoy car's name chip.
enum ConvoyBadgeUI: Equatable {
    case lead, tail

    init(_ r: ConvoyRole) { self = r == .lead ? .lead : .tail }

    var label: String { self == .lead ? "المقدمة" : "المؤخرة" }
    var symbol: String { self == .lead ? "chevron.up.2" : "chevron.down.2" }
}

/// A waypoint on the map.
struct MapWaypoint: Equatable, Identifiable {
    var id: String
    var position: LngLat
    var kind: WaypointKind
    var title: String
}

extension WaypointKind {
    /// The kind's colour, from the design system's tokens (car blue for water).
    func color(_ p: SaryPalette) -> Color {
        switch self {
        case .camp: return p.accent
        case .water: return Color(rgb: SaryCarColors.palette[2])
        case .danger: return p.emergency
        case .passable: return p.live
        case .stuck_spot: return p.warning
        case .other: return p.stale
        }
    }

    /// Ink on that colour.
    func ink(_ p: SaryPalette) -> Color {
        switch self {
        case .camp, .stuck_spot: return p.onAccent
        default: return .white
        }
    }
}

/// The kind as a round glyph (picker, list, card, map pin).
struct SaryWaypointGlyph: View {
    var kind: WaypointKind
    var size: CGFloat = 30
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(kind.ink(p))
            .frame(width: size, height: size)
            .background(Circle().fill(kind.color(p)))
            .overlay(Circle().stroke(p.chromeOpaque, lineWidth: max(1.5, size * 0.07)))
            .accessibilityHidden(true)
    }
}
