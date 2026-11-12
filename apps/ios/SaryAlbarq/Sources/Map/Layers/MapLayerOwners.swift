import Combine
import Foundation

/// The objects that already own a data layer's state and cache it (`WeatherLayers.kind`, `CampSitesHub.layerOn`,
/// `HiResSettings.userOn`, `LiveOutingController.terrain3D`). S3 keeps them: they keep drawing exactly as before.
/// The registry stores to the same keys; this pushes a registry change into the owners so the two never disagree.
@MainActor
enum MapLayerOwners {
    /// Registry -> owners. Writes only when a value differs, so nothing fires needlessly.
    static func push(_ registry: MapLayerRegistry, controller: LiveOutingController?) {
        let weather = MapLayerCatalog.weatherKinds.first { registry.isActive(MapLayerCatalog.weatherID($0)) } ?? .none
        if WeatherLayers.shared.kind != weather { WeatherLayers.shared.kind = weather }
        let camp = registry.isActive(MapLayerCatalog.camp.id)
        if CampSitesHub.shared.layerOn != camp { CampSitesHub.shared.layerOn = camp }
        let hires = registry.isActive(MapLayerCatalog.hiRes.id)
        if HiResSettings.shared.userOn != hires { HiResSettings.shared.userOn = hires }
        if let controller {
            let terrain = registry.isActive(MapLayerCatalog.terrain.id)
            if controller.terrain3D != terrain { controller.terrain3D = terrain }
        }
    }

    /// Owners -> registry (for a change made elsewhere, or a launch argument that set an owner in memory only):
    /// the owner is what the map draws, so the registry follows it.
    static func pull(_ registry: MapLayerRegistry, controller: LiveOutingController?) {
        registry.reload()
        let kind = WeatherLayers.shared.kind
        let chosen = MapLayerCatalog.weatherKinds.first { registry.isActive(MapLayerCatalog.weatherID($0)) } ?? .none
        if kind != chosen {
            if kind == .none { registry.setActive(MapLayerCatalog.weatherID(chosen), false) } else { registry.setActive(MapLayerCatalog.weatherID(kind)) }
        }
        if registry.isActive(MapLayerCatalog.camp.id) != CampSitesHub.shared.layerOn { registry.setActive(MapLayerCatalog.camp.id, CampSitesHub.shared.layerOn) }
        if registry.isActive(MapLayerCatalog.hiRes.id) != HiResSettings.shared.userOn { registry.setActive(MapLayerCatalog.hiRes.id, HiResSettings.shared.userOn) }
        if let controller, registry.isActive(MapLayerCatalog.terrain.id) != controller.terrain3D {
            registry.setActive(MapLayerCatalog.terrain.id, controller.terrain3D)
        }
    }

    /// Fires when any owner changes (the value has already been stored when the main queue gets to it).
    static func changes(controller: LiveOutingController?) -> AnyPublisher<Void, Never> {
        var all: [AnyPublisher<Void, Never>] = [
            WeatherLayers.shared.$kind.map { _ in () }.eraseToAnyPublisher(),
            CampSitesHub.shared.$layerOn.map { _ in () }.eraseToAnyPublisher(),
            HiResSettings.shared.$userOn.map { _ in () }.eraseToAnyPublisher(),
        ]
        if let controller { all.append(controller.$terrain3D.map { _ in () }.eraseToAnyPublisher()) }
        return Publishers.MergeMany(all).receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }
}
