import UIKit

extension UIColor {
    /// Toward another colour, for the highlights and shadows a curved panel
    /// needs — computed from the chosen paint so every colour lights the same.
    func mixed(with other: UIColor, _ amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = max(0, min(1, amount))
        return UIColor(
            red: r1 + (r2 - r1) * t,
            green: g1 + (g2 - g1) * t,
            blue: b1 + (b2 - b1) * t,
            alpha: a1
        )
    }
}

/// You, on the map: a photo above a car.
///
/// The same two shapes the web draws, in the same proportions — a top-down car
/// on a 40×78 field and a round portrait on a pin above it. Top-down is the
/// only view that is honest about where a car actually is; a three-quarter
/// render looks better and sits beside the road it claims to be on.
enum FarqVehicle {
    struct Color: Identifiable, Equatable {
        let id: String
        let hex: String
        let nameAr: String
    }

    static let colors: [Color] = [
        Color(id: "navy", hex: "#1b2a4a", nameAr: "كحلي"),
        Color(id: "white", hex: "#e8eef0", nameAr: "أبيض"),
        Color(id: "silver", hex: "#9aa5ad", nameAr: "فضي"),
        Color(id: "black", hex: "#15191c", nameAr: "أسود"),
    ]

    static func color(_ id: String?) -> Color {
        colors.first { $0.id == id } ?? colors[0]
    }

    /* Both sprites are redrawn whenever the map rebuilds its content, which is
     * every camera change while you are moving. Drawing a shaded car sixty
     * times a second to show the same car is the cheapest kind of jank to fix. */
    private static var carCache: [String: UIImage] = [:]
    private static var pinCache: (key: ObjectIdentifier, image: UIImage)?

    static func cachedCar(hex: String) -> UIImage {
        if let hit = carCache[hex] { return hit }
        let drawn = car(hex: hex)
        carCache[hex] = drawn
        return drawn
    }

    static func cachedAvatarPin(_ photo: UIImage) -> UIImage {
        let key = ObjectIdentifier(photo)
        if let hit = pinCache, hit.key == key { return hit.image }
        let drawn = avatarPin(photo)
        pinCache = (key, drawn)
        return drawn
    }

    /// The car, pointing north in its own image. Mapbox rotates it to the
    /// course, which is why nothing here bakes in a heading — a car pointing
    /// north because nobody said otherwise is a claim nobody made.
    ///
    /// Drawn rather than shipped as a render: a photograph of one car is that
    /// car, and this stands for whatever you drive. What makes it read as a
    /// real body from above is not outline but light — a specular band down the
    /// centre line, edges that fall away into shadow because the metal curves,
    /// glass that is darker than the paint and reflects the sky, and panel gaps
    /// where the doors are. A flat silhouette reads as a game piece.
    static func car(hex: String, scale: CGFloat = 3) -> UIImage {
        let size = CGSize(width: 34, height: 74)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let paint = UIColor(hex: hex)
        let space = CGColorSpaceCreateDeviceRGB()

        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext

            /* Tyres first: on a sedan seen from above they are mostly under the
             * arches, and only their outer shoulders show. */
            UIColor(white: 0.07, alpha: 1).setFill()
            for rect in [
                CGRect(x: 0.5, y: 13, width: 4, height: 12),
                CGRect(x: 29.5, y: 13, width: 4, height: 12),
                CGRect(x: 0.5, y: 50, width: 4, height: 12),
                CGRect(x: 29.5, y: 50, width: 4, height: 12),
            ] {
                UIBezierPath(roundedRect: rect, cornerRadius: 1.6).fill()
            }

            let body = silhouette()
            cg.saveGState()
            body.addClip()

            /* Across the car: bright along the crown, falling into shadow at
             * both shoulders. This is the whole illusion of a curved panel. */
            if let across = CGGradient(
                colorsSpace: space,
                colors: [
                    paint.mixed(with: .black, 0.45).cgColor,
                    paint.mixed(with: .white, 0.10).cgColor,
                    paint.mixed(with: .white, 0.30).cgColor,
                    paint.mixed(with: .white, 0.05).cgColor,
                    paint.mixed(with: .black, 0.50).cgColor,
                ] as CFArray,
                locations: [0, 0.28, 0.46, 0.66, 1]
            ) {
                cg.drawLinearGradient(
                    across,
                    start: CGPoint(x: 0, y: 37),
                    end: CGPoint(x: 34, y: 37),
                    options: []
                )
            }

            /* Along the car: the nose and tail curve away from the light too. */
            if let along = CGGradient(
                colorsSpace: space,
                colors: [
                    UIColor.black.withAlphaComponent(0.30).cgColor,
                    UIColor.clear.cgColor,
                    UIColor.clear.cgColor,
                    UIColor.black.withAlphaComponent(0.34).cgColor,
                ] as CFArray,
                locations: [0, 0.16, 0.84, 1]
            ) {
                cg.drawLinearGradient(
                    along,
                    start: CGPoint(x: 17, y: 0),
                    end: CGPoint(x: 17, y: 74),
                    options: []
                )
            }

            /* Glasshouse. Darker than any paint, with a cool reflection of the
             * sky in the upper half — glass that matches the body colour looks
             * painted over. */
            let glass = UIColor(red: 0.06, green: 0.09, blue: 0.13, alpha: 1)
            glass.setFill()
            windscreen().fill()
            rearWindow().fill()
            roof().fill()

            UIColor(red: 0.62, green: 0.74, blue: 0.88, alpha: 0.30).setFill()
            windscreenSheen().fill()
            UIColor(red: 0.62, green: 0.74, blue: 0.88, alpha: 0.16).setFill()
            rearSheen().fill()

            /* Panel gaps: bonnet, boot and the two door shuts. Thin, dark, and
             * the reason the shape reads as assembled from parts. */
            UIColor.black.withAlphaComponent(0.35).setStroke()
            let gaps = UIBezierPath()
            gaps.move(to: CGPoint(x: 5, y: 19)); gaps.addLine(to: CGPoint(x: 29, y: 19))
            gaps.move(to: CGPoint(x: 5, y: 57)); gaps.addLine(to: CGPoint(x: 29, y: 57))
            gaps.move(to: CGPoint(x: 6.5, y: 28)); gaps.addLine(to: CGPoint(x: 6.5, y: 52))
            gaps.move(to: CGPoint(x: 27.5, y: 28)); gaps.addLine(to: CGPoint(x: 27.5, y: 52))
            gaps.lineWidth = 0.5
            gaps.stroke()

            /* Headlights, and the light bar this car wears across its tail. */
            UIColor(red: 1, green: 0.98, blue: 0.90, alpha: 0.95).setFill()
            UIBezierPath(roundedRect: CGRect(x: 5.5, y: 3.5, width: 7, height: 3), cornerRadius: 1.5).fill()
            UIBezierPath(roundedRect: CGRect(x: 21.5, y: 3.5, width: 7, height: 3), cornerRadius: 1.5).fill()
            UIColor(red: 0.85, green: 0.12, blue: 0.16, alpha: 0.92).setFill()
            UIBezierPath(roundedRect: CGRect(x: 6, y: 68, width: 22, height: 2.6), cornerRadius: 1.3).fill()

            cg.restoreGState()

            /* A thin bright edge where the body turns over, then the mirrors —
             * small, and the reason the shape reads as facing forward. */
            UIColor.white.withAlphaComponent(0.22).setStroke()
            body.lineWidth = 0.7
            body.stroke()

            paint.mixed(with: .black, 0.25).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 26, width: 3.4, height: 4.5), cornerRadius: 1.4).fill()
            UIBezierPath(roundedRect: CGRect(x: 30.6, y: 26, width: 3.4, height: 4.5), cornerRadius: 1.4).fill()
        }
    }

    /// A sedan from above: narrow at the nose, widest at the doors, tapering
    /// into the tail.
    private static func silhouette() -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 17, y: 1))
        path.addCurve(
            to: CGPoint(x: 33, y: 26),
            controlPoint1: CGPoint(x: 26, y: 1.5),
            controlPoint2: CGPoint(x: 32.5, y: 12)
        )
        path.addCurve(
            to: CGPoint(x: 31.5, y: 66),
            controlPoint1: CGPoint(x: 33.6, y: 42),
            controlPoint2: CGPoint(x: 33, y: 58)
        )
        path.addCurve(
            to: CGPoint(x: 17, y: 73),
            controlPoint1: CGPoint(x: 30.5, y: 71),
            controlPoint2: CGPoint(x: 25, y: 73)
        )
        path.addCurve(
            to: CGPoint(x: 2.5, y: 66),
            controlPoint1: CGPoint(x: 9, y: 73),
            controlPoint2: CGPoint(x: 3.5, y: 71)
        )
        path.addCurve(
            to: CGPoint(x: 1, y: 26),
            controlPoint1: CGPoint(x: 1, y: 58),
            controlPoint2: CGPoint(x: 0.4, y: 42)
        )
        path.addCurve(
            to: CGPoint(x: 17, y: 1),
            controlPoint1: CGPoint(x: 1.5, y: 12),
            controlPoint2: CGPoint(x: 8, y: 1.5)
        )
        path.close()
        return path
    }

    private static func windscreen() -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 7.5, y: 30))
        path.addCurve(
            to: CGPoint(x: 26.5, y: 30),
            controlPoint1: CGPoint(x: 12, y: 27.5),
            controlPoint2: CGPoint(x: 22, y: 27.5)
        )
        path.addLine(to: CGPoint(x: 24.5, y: 22))
        path.addCurve(
            to: CGPoint(x: 9.5, y: 22),
            controlPoint1: CGPoint(x: 20, y: 20),
            controlPoint2: CGPoint(x: 14, y: 20)
        )
        path.close()
        return path
    }

    private static func windscreenSheen() -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 10, y: 22.6))
        path.addCurve(
            to: CGPoint(x: 24, y: 22.6),
            controlPoint1: CGPoint(x: 14.5, y: 20.8),
            controlPoint2: CGPoint(x: 19.5, y: 20.8)
        )
        path.addLine(to: CGPoint(x: 22.5, y: 26))
        path.addCurve(
            to: CGPoint(x: 11.5, y: 26),
            controlPoint1: CGPoint(x: 18.5, y: 24.6),
            controlPoint2: CGPoint(x: 15.5, y: 24.6)
        )
        path.close()
        return path
    }

    private static func roof() -> UIBezierPath {
        UIBezierPath(roundedRect: CGRect(x: 7, y: 31, width: 20, height: 15), cornerRadius: 3)
    }

    private static func rearWindow() -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 8, y: 47))
        path.addCurve(
            to: CGPoint(x: 26, y: 47),
            controlPoint1: CGPoint(x: 12.5, y: 49.5),
            controlPoint2: CGPoint(x: 21.5, y: 49.5)
        )
        path.addLine(to: CGPoint(x: 24, y: 56))
        path.addCurve(
            to: CGPoint(x: 10, y: 56),
            controlPoint1: CGPoint(x: 20, y: 58),
            controlPoint2: CGPoint(x: 14, y: 58)
        )
        path.close()
        return path
    }

    private static func rearSheen() -> UIBezierPath {
        UIBezierPath(
            roundedRect: CGRect(x: 11, y: 50, width: 12, height: 4),
            cornerRadius: 2
        )
    }

    /// Nothing, in image form.
    ///
    /// The puck draws its default blue dot as the top image unless it is given
    /// one, and a blue dot sitting on the roof of the car is two answers to the
    /// same question.
    static let noTopImage: UIImage = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format)
            .image { _ in }
    }()

    /// The shadow the car casts, so it sits on the road instead of floating
    /// over it.
    static func vehicleShadow(scale: CGFloat = 3) -> UIImage {
        let size = CGSize(width: 52, height: 92)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            ctx.cgContext.setShadow(
                offset: CGSize(width: 0, height: 2),
                blur: 9,
                color: UIColor.black.withAlphaComponent(0.45).cgColor
            )
            UIColor.black.withAlphaComponent(0.30).setFill()
            UIBezierPath(
                roundedRect: CGRect(x: 11, y: 11, width: 30, height: 70),
                cornerRadius: 14
            ).fill()
        }
    }

    /// The portrait, on a pin that sits above the car.
    ///
    /// Drawn into a canvas tall enough that the pin's tip lands just over the
    /// car's roof once Mapbox centres the image on the position — the puck's
    /// top image does not take an offset, so the offset is the image.
    static func avatarPin(_ photo: UIImage, scale: CGFloat = 3) -> UIImage {
        let canvas = CGSize(width: 52, height: 66)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false

        return UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            let cg = ctx.cgContext
            let centre = CGPoint(x: 26, y: 25)
            let radius: CGFloat = 19

            let tail = UIBezierPath()
            tail.move(to: CGPoint(x: centre.x - 7, y: centre.y + 13))
            tail.addLine(to: CGPoint(x: centre.x, y: centre.y + 26))
            tail.addLine(to: CGPoint(x: centre.x + 7, y: centre.y + 13))
            tail.close()

            cg.setShadow(
                offset: CGSize(width: 0, height: 2),
                blur: 8,
                color: UIColor.black.withAlphaComponent(0.35).cgColor
            )
            UIColor.white.setFill()
            tail.fill()
            UIBezierPath(
                arcCenter: centre, radius: radius, startAngle: 0,
                endAngle: .pi * 2, clockwise: true
            ).fill()
            cg.setShadow(offset: .zero, blur: 0, color: nil)

            /* The photo, clipped to the ring's inside. Aspect-fill so a portrait
             * and a landscape both become a face rather than a letterbox. */
            let inner = radius - 3
            cg.saveGState()
            UIBezierPath(
                arcCenter: centre, radius: inner, startAngle: 0,
                endAngle: .pi * 2, clockwise: true
            ).addClip()
            let box = CGRect(
                x: centre.x - inner, y: centre.y - inner,
                width: inner * 2, height: inner * 2
            )
            photo.draw(in: aspectFill(photo.size, into: box))
            cg.restoreGState()

            UIColor(hex: "#043434").withAlphaComponent(0.9).setStroke()
            let ring = UIBezierPath(
                arcCenter: centre, radius: radius - 1.5, startAngle: 0,
                endAngle: .pi * 2, clockwise: true
            )
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    private static func aspectFill(_ source: CGSize, into box: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return box }
        let scale = max(box.width / source.width, box.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(
            x: box.midX - size.width / 2,
            y: box.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
