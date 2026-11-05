import SwiftUI

// Entries into «الوضع الواقعي»: exploration, the point card, saved places, track detail
// (trip summary). Each entry presents the screen from its own (topmost) view with
// `.realisticCover`, so it works over sheets and full-screen covers alike.

extension RealisticScene {
    /// Exploration: the crosshair, the group, my trail, the plan, the markers and saved places.
    @MainActor
    static func live(_ c: LiveOutingController, plan: PlanModel?, places: [SavedPlace]) -> RealisticScene {
        let members = c.mapMembers(theme: .default)
        let trails = c.mapTrails(members: members)
        let dest = plan?.plan.destination
        return RealisticScene(
            title: c.ui.outingName,
            focus: c.exploreReading.reading?.center,
            members: RealisticRules.members(members),
            track: trails.mineTrack,
            plan: plan?.plan.points ?? [],
            markers: RealisticRules.markers(destination: dest, rally: c.rallyPoint, waypoints: c.mapWaypoints, places: places),
            navigating: c.nav.isActive,
            origin: "explore")
    }

    /// The point card's point.
    static func point(_ p: LngLat, name: String?) -> RealisticScene {
        RealisticScene(title: name ?? CoordinateShare.displayDecimal(p), focus: p,
                       markers: [.init(id: "point", title: name ?? "النقطة", position: p, kind: .point, systemImage: "mappin")],
                       origin: "point")
    }

    static func place(_ s: SavedPlace) -> RealisticScene {
        RealisticScene(title: s.name, focus: s.position,
                       markers: [.init(id: "place:\(s.id)", title: s.name, position: s.position, kind: .place, systemImage: s.icon.systemImage)],
                       origin: "place")
    }

    /// A recorded / GPX / friend's track (trip summary «مسارك», the tracks list).
    static func track(_ s: FollowSubject) -> RealisticScene {
        var markers: [Marker] = []
        if let a = s.line.points.first { markers.append(.init(id: "start", title: "البداية", position: a, kind: .point, systemImage: "flag.fill")) }
        if let b = s.line.points.last, s.line.points.count > 1 {
            markers.append(.init(id: "end", title: "النهاية", position: b, kind: .destination, systemImage: "flag.checkered"))
        }
        return RealisticScene(title: s.name, track: s.line, markers: markers, origin: "track")
    }
}

extension View {
    /// Presents «الوضع الواقعي» full screen while `scene` is set.
    func realisticCover(_ scene: Binding<RealisticScene?>) -> some View {
        fullScreenCover(item: scene) { s in
            RealisticMapView(scene: s) { scene.wrappedValue = nil }
        }
    }
}

/// The «الوضع الواقعي» glass button used over maps (track detail).
struct RealisticEntryButton: View {
    var id = "realistic-open"
    var title = "الوضع الواقعي"
    var action: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: RealisticEntryButton.icon).font(.system(size: 14, weight: .bold))
                Text(title).saryText(.subhead, weight: .bold).lineLimit(1)
            }
            .foregroundStyle(theme.palette.textPrimary)
            .padding(.horizontal, theme.space(.m))
            .frame(minHeight: 44)
            .saryGlass(Capsule(), role: .control, interactive: true)
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityIdentifier(id)
    }

    static let icon = "globe.desk.fill"
}
