import CarPlay
import UIKit

/// The CarPlay scene (Info.plist: UIApplicationSceneManifest → CPTemplateApplicationSceneSessionRoleApplication).
/// Category: Navigation (`com.apple.developer.carplay-maps`), the only one that may draw a map.
/// The entitlement is only in builds with CARPLAY_ENABLED=YES (see docs/CARPLAY-ENTITLEMENT.md);
/// without it iOS simply never connects this scene.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var coordinator: CarPlayCoordinator?

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController, to window: CPWindow) {
        MainActor.assumeIsolated {
            let c = CarPlayCoordinator(scene: scene, interface: interfaceController, window: window)
            coordinator = c
            c.start()
        }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnect interfaceController: CPInterfaceController, from window: CPWindow) {
        MainActor.assumeIsolated {
            coordinator?.stop()
            coordinator = nil
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        MainActor.assumeIsolated { CarPlayHub.setActive(true) }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        MainActor.assumeIsolated { CarPlayHub.setActive(false) }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        MainActor.assumeIsolated { CarPlayHub.setActive(false) }
    }
}

/// The one link between the phone app and CarPlay.
@MainActor
enum CarPlayHub {
    /// The CarPlay screen is showing the app (it counts as "the app is open in front of you").
    private(set) static var active = false

    static func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        AppDelegate.model?.carPlayVisible(on)
    }
}
