import SwiftUI
import UIKit

/// The photo that stands for you on the map, and the colour of the car under it.
///
/// Both live on this phone and nowhere else. The photo is written to the app's
/// own container, never uploaded, never attached to a request, and never sent
/// to the API — Farq's map needs a position to answer a question about prices,
/// and it has never needed a face. Deleting the app deletes it; so does the
/// button in the sheet.
@MainActor
final class UserProfile: ObservableObject {
    @Published private(set) var avatar: UIImage?
    @Published var vehicleColorId: String {
        didSet { defaults.set(vehicleColorId, forKey: Keys.vehicleColor) }
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let vehicleColor = "farq.vehicle.color"
    }

    /// The longest edge a stored portrait keeps. A modern phone photo is 4,000
    /// pixels across and is about to be drawn 46 points wide; keeping the
    /// original would cost tens of megabytes to render a thumbnail.
    private static let maxEdge: CGFloat = 512

    init() {
        vehicleColorId = defaults.string(forKey: Keys.vehicleColor) ?? "navy"
        avatar = Self.load()
    }

    var isPersonalised: Bool { avatar != nil }

    var vehicleColor: FarqVehicle.Color { FarqVehicle.color(vehicleColorId) }

    /// Accepts the picked bytes, or refuses them. A file that does not decode
    /// as an image is not stored and not reported as stored.
    @discardableResult
    func setAvatar(from data: Data) -> Bool {
        guard let decoded = UIImage(data: data) else { return false }
        let resized = Self.downscale(decoded)
        guard let png = resized.pngData() else { return false }
        do {
            try png.write(to: Self.location, options: .atomic)
            avatar = resized
            return true
        } catch {
            return false
        }
    }

    func clearAvatar() {
        try? FileManager.default.removeItem(at: Self.location)
        avatar = nil
    }

    // MARK: Storage

    private static var location: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true
        )
        return base.appendingPathComponent("farq-avatar.png")
    }

    private static func load() -> UIImage? {
        guard let data = try? Data(contentsOf: location) else { return nil }
        return UIImage(data: data)
    }

    private static func downscale(_ image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxEdge, longest > 0 else { return image }
        let ratio = maxEdge / longest
        let size = CGSize(
            width: image.size.width * ratio,
            height: image.size.height * ratio
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
