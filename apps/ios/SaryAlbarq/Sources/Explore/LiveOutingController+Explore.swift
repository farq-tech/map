import Combine
import Foundation
import UIKit

/// The crosshair's latest settled reading (kept apart from the controller).
@MainActor
final class ExploreReadingModel: ObservableObject {
    @Published var reading: MapCenterReading?
}

/// What «احفظ المكان» edits: a new point, or an existing saved place.
struct SavedPlaceDraft: Equatable {
    var id: String?
    var point: LngLat
    var name: String
    var icon: SavedPlaceIcon
}

/// Pure exploration rules (unit-tested in `ExploreTests`).
enum ExploreRules {
    /// Panning the centre this far from every live car (me included) while stopped opens exploration.
    static let autoEnterM = 5_000.0

    /// The crosshair moved far from the group: true when there is at least one live reference
    /// point and the centre is further than `autoEnterM` from all of them.
    static func farFromGroup(center: LngLat, live refs: [LngLat], thresholdM: Double = autoEnterM) -> Bool {
        guard !refs.isEmpty else { return false }
        return refs.allSatisfy { PlanGeo.meters(center, $0) > thresholdM }
    }

    /// «الارتفاع ٦١٢ م» / «الارتفاع غير متاح» — only a value Mapbox Terrain-DEM gave us.
    static func elevationText(_ m: Double?) -> String {
        guard let m, m.isFinite else { return "الارتفاع غير متاح" }
        return "الارتفاع \(SaryFormat.number(Int(m.rounded()))) م"
    }

    static func coordinateText(_ p: LngLat, _ f: CoordinateShare.Format) -> String {
        f == .decimal ? CoordinateShare.displayDecimal(p) : CoordinateShare.displayDMS(p)
    }

    static let formatKey = "sary.explore.coordFormat.v1"
    static var savedFormat: CoordinateShare.Format {
        get { UserDefaults.standard.string(forKey: formatKey).flatMap(CoordinateShare.Format.init) ?? .decimal }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: formatKey) }
    }

    /// What the layer switcher says about offline use of `layer`, from what is really saved.
    static func offlineNote(_ layer: MapLayer, areas: Int, topoAreas: Int) -> String {
        switch layer {
        case .satellite:
            return areas > 0 ? "يعمل بلا إنترنت في مناطقك المحفوظة" : "يحتاج إنترنت • احفظ منطقة لاستخدامه بلا إنترنت"
        case .topo:
            return topoAreas > 0 ? "يعمل بلا إنترنت في المناطق المحفوظة مع الطبوغرافي" : "يحتاج إنترنت • احفظ منطقة مع «الطبوغرافي» لاستخدامه بلا إنترنت"
        case .standard:
            return "يحتاج إنترنت دائمًا • لا يُحفظ بلا إنترنت"
        }
    }
}

extension LiveOutingController {
    /// «استكشاف» from the header or «+». Not while driving (the screen would flip right back).
    func enterExplore(auto: Bool = false) {
        guard !nav.isActive, !motion.moving else {
            toast("الاستكشاف متاح وأنت واقف")
            return
        }
        statusExpanded = false
        bellOpen = false
        following = false
        exploreAuto = auto
        sheetDetent = .peek
        exploreActive = true
        if auto { toast("وضع الاستكشاف • «ارجع للطلعة» يرجعك") }
    }

    /// «ارجع للرحلة»: back to the trip, the group framed again.
    func exitExplore(reframe: Bool = true) {
        guard exploreActive, !idleHome else { return }
        exploreActive = false
        exploreAuto = false
        terrain3D = false
        if reframe { actions.fitGroup() }
    }

    /// Driving always leaves exploration (guidance started, or the car is moving).
    func exploreDrivingCheck() {
        guard exploreActive, !idleHome, nav.isActive || motion.moving else { return }
        exitExplore(reframe: !nav.isActive)
        toast("رجعنا لشاشة القيادة")
    }

    /// The map's centre moved (the crosshair): store it; after a real pan that settled far from
    /// everyone while stopped, open exploration.
    func mapCenterChanged(_ r: MapCenterReading) {
        /* Camera callbacks arrive while Mapbox is rendering several intermediate frames. The
         * crosshair readout is only actionable once the camera is idle; publishing those frames
         * was needlessly invalidating SwiftUI and could publish inside its map update cycle. */
        guard r.settled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.applyMapCenter(r) }
    }

    private func applyMapCenter(_ r: MapCenterReading) {
        if exploreReading.reading != r { exploreReading.reading = r }
        guard r.settled, userPannedMap else { return }
        userPannedMap = false
        guard !exploreActive, sheetDetent == .peek, !picking.active, liveContext(drive: appearance.isDriving) == .stopped else { return }
        let refs = mapMembers(theme: .default).filter { $0.presence == .live }.map(\.position)
        if ExploreRules.farFromGroup(center: r.center, live: refs) { enterExplore(auto: true) }
    }

    /// What exploration draws: shown tracks and saved places.
    func mapExplore(places: [SavedPlace], tracks: TrackLibrary) -> MapExplore {
        guard exploreActive else { return MapExplore() }
        return MapExplore(active: true,
                          tracks: tracks.tracks.filter { tracks.shown.contains($0.id) }.map { .init(id: $0.id, name: $0.name, points: $0.points) },
                          places: places.map { .init(id: $0.id, name: $0.name, position: $0.position) })
    }

    /// «احفظ المكان» at the crosshair.
    func saveCrosshair() {
        guard let p = exploreReading.reading?.center else { return toast("حرّك الخريطة قليلًا أولًا") }
        modal = .placeEdit(SavedPlaceDraft(id: nil, point: p, name: "", icon: .pin))
    }

    /// «احفظ» in the place editor: a new place, or the edited one.
    func savePlace(_ d: SavedPlaceDraft) {
        modal = nil
        if let id = d.id {
            SavedPlacesStore.shared.update(id, name: d.name, icon: d.icon)
            toast("حُفظ التعديل")
        } else if SavedPlacesStore.shared.add(name: d.name, icon: d.icon, at: d.point) != nil {
            toast("حُفظ في أماكني")
        } else {
            toast("تعذّر الحفظ")
        }
    }

    func copyCrosshair() {
        guard let p = exploreReading.reading?.center else { return }
        PlanClipboard.copy(CoordinateShare.copy(p, coordFormat))
        toast("نُسخت الإحداثية")
    }

    /// A saved place / track row: centre the map on it (staying in exploration).
    func showOnMap(_ p: LngLat) {
        modal = nil
        ask(.point(p))
    }

    func showTrack(_ t: SavedTrack) {
        modal = nil
        if !TrackLibrary.shared.shown.contains(t.id) { TrackLibrary.shared.toggleShown(t.id) }
        ask(.fit(t.points))
    }

    /// «ملاحة» to a saved place (the usual options sheet with the real route's ETA).
    func navigateToPlace(_ p: SavedPlace) {
        modal = nil
        exitExplore(reframe: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.navigate(NavTargets.point(p.position, name: p.name))
        }
    }
}
