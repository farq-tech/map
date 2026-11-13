import SwiftUI
import UIKit

/// Everything needed to draw one story, already measured and projected.
struct StoryScene {
    var facts: StoryFacts
    var options: StoryOptions
    var layout: StoryLayout
    var privacy: StoryPrivacy.Result
    var camera: StoryCamera?
    /// The satellite snapshot, exactly the map card's pixel size (nil: drawn sand backdrop).
    var mapImage: UIImage?
    var photos: [UIImage]
    var mark: UIImage?
    /// The visible trail in canvas pixels.
    var line: StoryPolyline
    var start: CGPoint?
    var end: CGPoint?
    var stop: (point: CGPoint, label: String)?
    var waypoints: [(point: CGPoint, wp: StoryWaypoint)]
}

/// Draws stories with Core Graphics (one code path for the image and every video frame).
enum StoryRenderer {
    // Dark Sand identity.
    static let bg = UIColor(rgb: 0x1A1612)
    static let surface = UIColor(rgb: 0x2B251F)
    static let ink = UIColor(rgb: 0xF4EFE6)
    static let ink2 = UIColor(rgb: 0xB9AE9C)
    static let ink3 = UIColor(rgb: 0x8C8478)
    static let ember = UIColor(rgb: 0xE8842C)
    static let emberDeep = UIColor(rgb: 0xB8661F)
    static let glow = UIColor(rgb: 0xF2C36B)
    static let headlight = UIColor(rgb: 0xFFE3A3)

    static let attribution = "© Mapbox © OpenStreetMap © Maxar"

    // MARK: scene

    /// The camera for this story (what the snapshot must be taken with), or nil when nothing may be drawn.
    static func camera(_ facts: StoryFacts, _ options: StoryOptions, photoCount: Int) -> StoryCamera? {
        let layout = StoryLayout.make(options.format, photoCount: photoCount)
        let priv = StoryPrivacy.apply(facts.trail, showStartEnd: options.showStartEnd)
        guard !priv.isEmpty else { return nil }
        return StoryCamera.fit(priv.visiblePoints, frame: layout.trailFrame, mapPx: layout.map.size)
    }

    static func scene(_ facts: StoryFacts, _ options: StoryOptions, photos: [UIImage], mapImage: UIImage?, mark: UIImage?) -> StoryScene {
        let photos = Array(photos.prefix(StoryLayout.maxPhotos))
        let layout = StoryLayout.make(options.format, photoCount: photos.count)
        let priv = StoryPrivacy.apply(facts.trail, showStartEnd: options.showStartEnd)
        let cam = priv.isEmpty ? nil : StoryCamera.fit(priv.visiblePoints, frame: layout.trailFrame, mapPx: layout.map.size)
        func px(_ p: LngLat) -> CGPoint? {
            guard let cam else { return nil }
            let q = cam.pixel(p)
            return CGPoint(x: q.x + layout.map.minX, y: q.y + layout.map.minY)
        }
        let line = StoryPolyline(runs: priv.runs.map { r in
            (r.points.compactMap { px($0.position) }, r.points.map(\.gap), r.fadeStart, r.fadeEnd)
        })
        var start: CGPoint?, end: CGPoint?
        if options.showStartEnd, let f = facts.trail.first, let l = facts.trail.last, facts.trail.count >= 2 {
            start = px(f.position)
            end = px(l.position)
        }
        var stop: (CGPoint, String)?
        if let s = facts.longestStop, StoryPrivacy.isVisible(s.position, in: priv), let p = px(s.position), layout.map.insetBy(dx: 30, dy: 30).contains(p) {
            stop = (p, "أطول وقفة: " + SaryFormat.duration(seconds: Int(s.durationS)))
        }
        let wps: [(CGPoint, StoryWaypoint)] = facts.waypoints.compactMap { w in
            guard StoryPrivacy.isVisible(w.position, in: priv), let p = px(w.position), layout.map.insetBy(dx: 24, dy: 24).contains(p) else { return nil }
            return (p, w)
        }
        return StoryScene(facts: facts, options: options, layout: layout, privacy: priv, camera: cam, mapImage: mapImage, photos: photos,
                          mark: mark, line: line, start: start, end: end, stop: stop.map { (point: $0.0, label: $0.1) },
                          waypoints: wps.map { (point: $0.0, wp: $0.1) })
    }

    // MARK: whole image

    static func image(_ s: StoryScene) -> UIImage {
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = true
        return UIGraphicsImageRenderer(size: s.layout.canvas, format: f).image { c in
            drawBase(c.cgContext, s)
            drawTrail(c.cgContext, s, progress: 1, head: false)
            drawTop(c.cgContext, s, finale: 1)
        }
    }

    /// Background, header, map card, title and numbers: everything that does not move in the video.
    static func baseImage(_ s: StoryScene) -> UIImage {
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = true
        return UIGraphicsImageRenderer(size: s.layout.canvas, format: f).image { c in drawBase(c.cgContext, s) }
    }

    // MARK: base

    static func drawBase(_ ctx: CGContext, _ s: StoryScene) {
        SaryFonts.registerIfNeeded()
        let L = s.layout
        let W = L.canvas.width, H = L.canvas.height
        bg.setFill()
        ctx.fill(CGRect(origin: .zero, size: L.canvas))
        let space = CGColorSpaceCreateDeviceRGB()
        /* Warm glow from the top right, like the last light over the dunes. */
        if let g = CGGradient(colorsSpace: space, colors: [ember.withAlphaComponent(0.26).cgColor, ember.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: W * 0.92, y: H * 0.02), startRadius: 0, endCenter: CGPoint(x: W * 0.92, y: H * 0.02), endRadius: W * 1.05, options: [])
        }
        if let g = CGGradient(colorsSpace: space, colors: [UIColor(rgb: 0x2B2118).withAlphaComponent(0).cgColor, UIColor(rgb: 0x0F0D0B).withAlphaComponent(0.9).cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H * 0.55), end: CGPoint(x: 0, y: H), options: [])
        }
        drawContours(ctx, in: CGRect(x: 0, y: L.map.maxY - 40, width: W, height: H - L.map.maxY + 40), alpha: 0.05, seed: 3)

        drawHeader(ctx, s)
        drawMapCard(ctx, s)
        drawTitle(ctx, s)
        drawStats(ctx, s)
        if L.format == .vertical {
            drawText("قصة طلعة من سَرى البارق", font: font(.medium, 28), color: ink3,
                     in: CGRect(x: 0, y: StoryLayout.safeBottom + 70, width: W, height: 40), align: .center, vCenter: true)
        }
    }

    /// Topographic contour lines (decoration).
    static func drawContours(_ ctx: CGContext, in r: CGRect, alpha: CGFloat, seed: Int) {
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.setStrokeColor(ink.withAlphaComponent(alpha).cgColor)
        ctx.setLineWidth(2)
        let n = 16
        for i in 0..<n {
            let y0 = r.minY + r.height * CGFloat(i) / CGFloat(n - 1)
            let path = CGMutablePath()
            var x: CGFloat = r.minX - 20
            let ph = CGFloat(i * 37 + seed * 11)
            path.move(to: CGPoint(x: x, y: y0))
            while x <= r.maxX + 20 {
                x += 12
                let y = y0 + 18 * sin((x + ph * 7) / 140) + 9 * sin((x * 1.7 + ph * 13) / 90)
                path.addLine(to: CGPoint(x: x, y: y))
            }
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    static func drawHeader(_ ctx: CGContext, _ s: StoryScene) {
        let L = s.layout
        let h = L.header
        let date = dateLine(s.facts)
        switch L.format {
        case .vertical:
            let m = L.markSize
            let markRect = CGRect(x: h.maxX - m, y: h.midY - m / 2, width: m, height: m)
            drawMark(ctx, s.mark, in: markRect)
            let brand = CGRect(x: h.minX + h.width * 0.4, y: h.minY, width: h.width * 0.6 - m - 22, height: h.height)
            drawText("سَرى البارق", font: font(.heavy, 40), color: ink, in: brand, align: .right, vCenter: true)
            if let date {
                drawText(date, font: font(.medium, 30), color: ink2, in: CGRect(x: h.minX, y: h.minY, width: h.width * 0.45, height: h.height), align: .left, vCenter: true)
            }
        case .square:
            /* The mark sits at the left end of the title block; the date goes on the subtitle line. */
            drawMark(ctx, s.mark, in: CGRect(x: h.minX, y: h.minY, width: L.markSize, height: L.markSize))
        }
    }

    static func drawMark(_ ctx: CGContext, _ mark: UIImage?, in r: CGRect) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: r.width * 0.06), blur: r.width * 0.2, color: UIColor.black.withAlphaComponent(0.45).cgColor)
        let path = UIBezierPath(roundedRect: r, cornerRadius: r.width * 0.225)
        UIColor(rgb: 0x2B2118).setFill()
        path.fill()
        ctx.restoreGState()
        ctx.saveGState()
        path.addClip()
        if let mark { mark.draw(in: r) }
        ctx.restoreGState()
    }

    static func drawMapCard(_ ctx: CGContext, _ s: StoryScene) {
        let L = s.layout
        let r = L.map
        let path = UIBezierPath(roundedRect: r, cornerRadius: L.mapRadius)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 22), blur: 54, color: UIColor.black.withAlphaComponent(0.55).cgColor)
        UIColor(rgb: 0x2E2217).setFill()
        path.fill()
        ctx.restoreGState()

        ctx.saveGState()
        path.addClip()
        if let img = s.mapImage {
            img.draw(in: r)
            /* A touch of warmth and depth so the snapshot sits in the Dark Sand frame. */
            ctx.setFillColor(UIColor(rgb: 0x1A1612).withAlphaComponent(0.10).cgColor)
            ctx.fill(r)
        } else {
            drawBackdrop(ctx, in: r)
        }
        let space = CGColorSpaceCreateDeviceRGB()
        if let g = CGGradient(colorsSpace: space, colors: [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.withAlphaComponent(0.34).cgColor] as CFArray, locations: [0.55, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: r.midX, y: r.midY), startRadius: 0, endCenter: CGPoint(x: r.midX, y: r.midY), endRadius: hypot(r.width, r.height) / 2, options: [])
        }
        if let g = CGGradient(colorsSpace: space, colors: [UIColor.black.withAlphaComponent(0.42).cgColor, UIColor.black.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.minY + 120), options: [])
        }
        if s.mapImage != nil {
            drawText(attribution, font: UIFont.systemFont(ofSize: L.format == .vertical ? 19 : 16, weight: .medium), color: UIColor.white.withAlphaComponent(0.72),
                     in: CGRect(x: r.minX + 26, y: r.minY + 20, width: r.width - 52, height: 30), align: .left, rtl: false)
        }
        if s.line.segs.isEmpty {
            let msg = s.facts.trail.count < 2 ? "ما سُجّل مسار لهذه الطلعة على هذا الجوال" : "المسار قصير، أخفيناه لحماية مكان انطلاقك"
            drawText(msg, font: font(.medium, L.format == .vertical ? 34 : 28), color: ink2, in: r.insetBy(dx: 60, dy: 0), align: .center, vCenter: true)
        }
        ctx.restoreGState()
        ctx.setStrokeColor(ink.withAlphaComponent(0.14).cgColor)
        ctx.setLineWidth(2)
        ctx.addPath(UIBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), cornerRadius: L.mapRadius - 1).cgPath)
        ctx.strokePath()
    }

    /// Sand when there is no snapshot (offline, no token, tests).
    static func drawBackdrop(_ ctx: CGContext, in r: CGRect) {
        let space = CGColorSpaceCreateDeviceRGB()
        if let g = CGGradient(colorsSpace: space, colors: [UIColor(rgb: 0x9A5A2B).cgColor, UIColor(rgb: 0x5E3A1F).cgColor, UIColor(rgb: 0x3A2617).cgColor] as CFArray, locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: r.maxX, y: r.minY), end: CGPoint(x: r.minX, y: r.maxY), options: [])
        }
        /* Seif dunes: long soft ridges running NNW. */
        ctx.saveGState()
        ctx.clip(to: r)
        for i in 0..<14 {
            let x0 = r.minX - r.width * 0.3 + CGFloat(i) * r.width / 9
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x0, y: r.maxY + 40))
            var y = r.maxY + 40
            var x = x0
            while y > r.minY - 40 {
                y -= 14
                x += 4.2 + 6 * sin(y / 70 + CGFloat(i))
                p.addLine(to: CGPoint(x: x, y: y))
            }
            ctx.addPath(p)
            ctx.setStrokeColor(UIColor(rgb: 0xF2C36B).withAlphaComponent(0.10).cgColor)
            ctx.setLineWidth(26)
            ctx.strokePath()
            let shade = CGMutablePath()
            shade.addPath(p, transform: CGAffineTransform(translationX: 18, y: 0))
            ctx.addPath(shade)
            ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.10).cgColor)
            ctx.setLineWidth(12)
            ctx.strokePath()
        }
        ctx.restoreGState()
        drawContours(ctx, in: r, alpha: 0.06, seed: 9)
    }

    static func drawTitle(_ ctx: CGContext, _ s: StoryScene) {
        let L = s.layout
        var titleRect = L.title
        if L.format == .square { titleRect.size.width -= L.markSize + 20; titleRect.origin.x += L.markSize + 20 }
        drawText(s.facts.outingName, font: font(.heavy, L.titleSize), color: ink, in: titleRect, align: .right, vCenter: true, fit: true)
        var sub = companionsLine(s.facts, show: s.options.showNames)
        if L.format == .square, let d = dateLine(s.facts) { sub += "  •  " + d }
        var subRect = L.subtitle
        if L.format == .square { subRect.size.width -= L.markSize + 20; subRect.origin.x += L.markSize + 20 }
        drawText(sub, font: font(.medium, L.subtitleSize), color: glow, in: subRect, align: .right, vCenter: true, fit: true)
    }

    static func drawStats(_ ctx: CGContext, _ s: StoryScene) {
        let L = s.layout
        for (i, st) in stats(s.facts).enumerated() where i < L.stats.count {
            let r = L.stats[i]
            let path = UIBezierPath(roundedRect: r, cornerRadius: L.statRadius)
            surface.withAlphaComponent(0.92).setFill()
            path.fill()
            ctx.setStrokeColor(ink.withAlphaComponent(0.08).cgColor)
            ctx.setLineWidth(2)
            ctx.addPath(UIBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), cornerRadius: L.statRadius - 1).cgPath)
            ctx.strokePath()
            let pad: CGFloat = L.format == .vertical ? 30 : 18
            let icon: CGFloat = L.format == .vertical ? 34 : 26
            let inner = r.insetBy(dx: pad, dy: 0)
            if L.format == .vertical {
                /* RTL: icon at the right, the number big, the label under it. */
                drawSymbol(st.symbol, color: ember, size: icon, center: CGPoint(x: inner.maxX - icon / 2, y: r.minY + r.height * 0.36))
                drawText(st.value, font: font(.heavy, L.statValueSize), color: ink, in: CGRect(x: inner.minX, y: r.minY + 14, width: inner.width - icon - 18, height: r.height * 0.52), align: .right, vCenter: true, fit: true)
                drawText(st.label, font: font(.medium, L.statLabelSize), color: ink2, in: CGRect(x: inner.minX, y: r.minY + r.height * 0.6, width: inner.width, height: r.height * 0.3), align: .right, vCenter: true)
            } else {
                drawSymbol(st.symbol, color: ember, size: icon, center: CGPoint(x: inner.maxX - icon / 2, y: r.minY + 34))
                drawText(st.value, font: font(.heavy, L.statValueSize), color: ink, in: CGRect(x: inner.minX, y: r.minY + r.height * 0.32, width: inner.width, height: r.height * 0.36), align: .right, vCenter: true, fit: true)
                drawText(st.label, font: font(.medium, L.statLabelSize), color: ink2, in: CGRect(x: inner.minX, y: r.minY + r.height * 0.68, width: inner.width, height: r.height * 0.24), align: .right, vCenter: true, fit: true)
            }
        }
    }

    // MARK: trail

    /// The trail up to `progress` (0…1 of its length), with the moving head when `head`.
    static func drawTrail(_ ctx: CGContext, _ s: StoryScene, progress: CGFloat, head: Bool) {
        let line = s.line
        guard !line.segs.isEmpty, progress > 0 else { return }
        let upTo = line.total * min(1, progress)
        let L = s.layout
        let w: CGFloat = L.format == .vertical ? 1 : 0.85
        ctx.saveGState()
        ctx.addPath(UIBezierPath(roundedRect: L.map, cornerRadius: L.mapRadius).cgPath)
        ctx.clip()

        func solidPath() -> CGMutablePath {
            let p = CGMutablePath()
            var open = false
            for sg in line.segs where sg.startLen < upTo {
                let b = sg.startLen + sg.len <= upTo ? sg.b : lerp(sg.a, sg.b, (upTo - sg.startLen) / max(sg.len, 0.001))
                if sg.dashed { open = false; continue }
                if !open || p.currentPoint != sg.a { p.move(to: sg.a) }
                p.addLine(to: b)
                open = true
            }
            return p
        }
        func dashedPath() -> CGMutablePath {
            let p = CGMutablePath()
            for sg in line.segs where sg.dashed && sg.startLen < upTo {
                let b = sg.startLen + sg.len <= upTo ? sg.b : lerp(sg.a, sg.b, (upTo - sg.startLen) / max(sg.len, 0.001))
                p.move(to: sg.a)
                p.addLine(to: b)
            }
            return p
        }
        let solid = solidPath(), dashed = dashedPath()

        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        /* Dark halo so the line reads on bright sand. */
        ctx.addPath(solid)
        ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.38).cgColor)
        ctx.setLineWidth(20 * w)
        ctx.strokePath()
        /* Ember line with a warm glow. */
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 22 * w, color: glow.withAlphaComponent(0.9).cgColor)
        ctx.addPath(solid)
        ctx.setStrokeColor(ember.cgColor)
        ctx.setLineWidth(10 * w)
        ctx.strokePath()
        ctx.restoreGState()
        ctx.addPath(solid)
        ctx.setStrokeColor(headlight.cgColor)
        ctx.setLineWidth(3.4 * w)
        ctx.strokePath()
        /* Unrecorded stretches: thin dashes, never a path we pretend to know. */
        ctx.saveGState()
        ctx.addPath(dashed)
        ctx.setLineDash(phase: 0, lengths: [14 * w, 14 * w])
        ctx.setLineCap(.butt)
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.75).cgColor)
        ctx.setLineWidth(5 * w)
        ctx.strokePath()
        ctx.restoreGState()
        /* Ends cut by a privacy zone dissolve, so the edge of the zone never reads as a place. */
        ctx.setBlendMode(.destinationOut)
        let space = CGColorSpaceCreateDeviceRGB()
        if let g = CGGradient(colorsSpace: space, colors: [UIColor.black.cgColor, UIColor.black.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) {
            let rad: CGFloat = 150 * w
            for r in line.runs {
                if r.fadeStart { let c = line.segs[r.first].a; ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: rad, options: []) }
                if r.fadeEnd { let c = line.segs[r.last].b; ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: rad, options: []) }
            }
        }
        ctx.setBlendMode(.normal)
        ctx.endTransparencyLayer()

        if head, progress < 1, let p = line.point(at: upTo) {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 30 * w, color: glow.cgColor)
            ctx.setFillColor(headlight.cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 13 * w, y: p.y - 13 * w, width: 26 * w, height: 26 * w))
            ctx.restoreGState()
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 6 * w, y: p.y - 6 * w, width: 12 * w, height: 12 * w))
        }
        ctx.restoreGState()
    }

    // MARK: markers + photos (over the line)

    static func drawTop(_ ctx: CGContext, _ s: StoryScene, finale: CGFloat) {
        let L = s.layout
        let w: CGFloat = L.format == .vertical ? 1 : 0.85
        ctx.saveGState()
        ctx.addPath(UIBezierPath(roundedRect: L.map, cornerRadius: L.mapRadius).cgPath)
        ctx.clip()
        for (p, wp) in s.waypoints { drawBadge(ctx, symbol: wp.symbol, at: p, radius: 22 * w, ring: ring(for: wp.kind)) }
        if let st = s.stop {
            /* Sits above a waypoint badge on the same spot (the camp), not on it. */
            let lift: CGFloat = s.waypoints.contains { hypot($0.point.x - st.point.x, $0.point.y - st.point.y) < 34 * w } ? 24 * w : 0
            drawPin(ctx, text: st.label, symbol: "cup.and.saucer.fill", at: CGPoint(x: st.point.x, y: st.point.y - lift), scale: w, alpha: 1)
        }
        if let a = s.start {
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: a.x - 15 * w, y: a.y - 15 * w, width: 30 * w, height: 30 * w))
            ctx.setStrokeColor(ember.cgColor)
            ctx.setLineWidth(7 * w)
            ctx.strokeEllipse(in: CGRect(x: a.x - 15 * w, y: a.y - 15 * w, width: 30 * w, height: 30 * w))
            /* A round trip ends where it began: one marker says it all. */
            if s.end.map({ hypot($0.x - a.x, $0.y - a.y) > 110 * w }) ?? true {
                drawPin(ctx, text: "البداية", symbol: nil, at: CGPoint(x: a.x, y: a.y - 14 * w), scale: w, alpha: 1)
            }
        }
        if let b = s.end, finale > 0 {
            ctx.saveGState()
            ctx.setAlpha(finale)
            ctx.setShadow(offset: .zero, blur: 20 * w, color: glow.cgColor)
            ctx.setFillColor(ember.cgColor)
            ctx.fillEllipse(in: CGRect(x: b.x - 24 * w, y: b.y - 24 * w, width: 48 * w, height: 48 * w))
            ctx.restoreGState()
            ctx.saveGState()
            ctx.setAlpha(finale)
            drawSymbol("flag.checkered", color: .white, size: 24 * w, center: b)
            ctx.restoreGState()
        }
        ctx.restoreGState()
        for (i, img) in s.photos.enumerated() where i < L.photos.count {
            drawPhoto(ctx, img, in: L.photos[i], tilt: L.photoTilts[i])
        }
    }

    static func ring(for kind: String) -> UIColor {
        switch kind {
        case "water": return UIColor(rgb: 0x4C8FD6)
        case "danger", "stuck_spot": return UIColor(rgb: 0xD6452F)
        case "passable": return UIColor(rgb: 0x2FA56A)
        default: return ember
        }
    }

    static func drawBadge(_ ctx: CGContext, symbol: String, at p: CGPoint, radius r: CGFloat, ring: UIColor) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 12, color: UIColor.black.withAlphaComponent(0.5).cgColor)
        ctx.setFillColor(UIColor(rgb: 0x1A1612).withAlphaComponent(0.86).cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        ctx.restoreGState()
        ctx.setStrokeColor(ring.cgColor)
        ctx.setLineWidth(4)
        ctx.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        drawSymbol(symbol, color: .white, size: r * 0.95, center: p)
    }

    /// A small dark label with a pointer, above `p`.
    static func drawPin(_ ctx: CGContext, text: String, symbol: String?, at p: CGPoint, scale w: CGFloat, alpha: CGFloat) {
        let f = font(.bold, 25 * w)
        let attr = NSAttributedString(string: text, attributes: [.font: f])
        let tw = ceil(attr.size().width)
        let icon: CGFloat = symbol == nil ? 0 : 26 * w
        let h: CGFloat = 50 * w
        let width = tw + icon + (symbol == nil ? 0 : 10 * w) + 34 * w
        let r = CGRect(x: p.x - width / 2, y: p.y - h - 18 * w, width: width, height: h)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setShadow(offset: CGSize(width: 0, height: 5), blur: 14, color: UIColor.black.withAlphaComponent(0.45).cgColor)
        let path = UIBezierPath(roundedRect: r, cornerRadius: h / 2)
        path.move(to: CGPoint(x: p.x - 10 * w, y: r.maxY - 1))
        path.addLine(to: CGPoint(x: p.x, y: r.maxY + 12 * w))
        path.addLine(to: CGPoint(x: p.x + 10 * w, y: r.maxY - 1))
        path.close()
        UIColor(rgb: 0x1A1612).withAlphaComponent(0.88).setFill()
        path.fill()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setAlpha(alpha)
        if let symbol {
            drawSymbol(symbol, color: glow, size: icon * 0.8, center: CGPoint(x: r.maxX - 17 * w - icon / 2, y: r.midY))
            drawText(text, font: f, color: ink, in: CGRect(x: r.minX + 17 * w, y: r.minY, width: tw + 2, height: h), align: .right, vCenter: true)
        } else {
            drawText(text, font: f, color: ink, in: r, align: .center, vCenter: true)
        }
        ctx.restoreGState()
    }

    static func drawPhoto(_ ctx: CGContext, _ img: UIImage, in r: CGRect, tilt: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: r.midX, y: r.midY)
        ctx.rotate(by: tilt * .pi / 180)
        let local = CGRect(x: -r.width / 2, y: -r.height / 2, width: r.width, height: r.height)
        ctx.setShadow(offset: CGSize(width: 0, height: 16), blur: 34, color: UIColor.black.withAlphaComponent(0.55).cgColor)
        let frame = UIBezierPath(roundedRect: local, cornerRadius: 22)
        ink.setFill()
        frame.fill()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        let inner = local.insetBy(dx: 11, dy: 11)
        ctx.saveGState()
        UIBezierPath(roundedRect: inner, cornerRadius: 14).addClip()
        let s = img.size
        let k = max(inner.width / max(s.width, 1), inner.height / max(s.height, 1))
        let dw = s.width * k, dh = s.height * k
        img.draw(in: CGRect(x: inner.midX - dw / 2, y: inner.midY - dh / 2, width: dw, height: dh))
        ctx.restoreGState()
        ctx.restoreGState()
    }

    // MARK: content

    struct Stat: Equatable { var symbol: String; var value: String; var label: String }

    /// The four numbers, in reading order.
    static func stats(_ f: StoryFacts) -> [Stat] {
        let fourth: Stat
        if let s = f.longestStop {
            fourth = Stat(symbol: "cup.and.saucer.fill", value: SaryFormat.duration(seconds: Int(s.durationS)), label: "أطول وقفة")
        } else if let m = f.movingS {
            fourth = Stat(symbol: "gauge.with.needle", value: SaryFormat.duration(seconds: m), label: "وقت الحركة")
        } else {
            fourth = Stat(symbol: "cup.and.saucer.fill", value: "—", label: "أطول وقفة")
        }
        return [
            Stat(symbol: "road.lanes", value: f.distanceM.map { SaryFormat.distance(meters: $0) } ?? "—", label: "المسافة"),
            Stat(symbol: "clock.fill", value: f.durationS.map { SaryFormat.duration(seconds: $0) } ?? "—", label: "المدة"),
            Stat(symbol: "person.2.fill", value: SaryFormat.number(f.memberCount), label: f.memberCount == 1 ? "مشارك" : "في الطلعة"),
            fourth,
        ]
    }

    /// «مع ٥ رفاق» by default; names only when the person chose to show them.
    static func companionsLine(_ f: StoryFacts, show: Bool) -> String {
        let names = StoryPrivacy.names(f.companionNames, show: show)
        if !names.isEmpty {
            if names.count <= 3 { return "مع " + joinAnd(names) }
            let rest = names.count - 3
            return "مع " + names.prefix(3).joined(separator: "، ") + " و" + (rest == 1 ? "واحد آخر" : rest == 2 ? "اثنين آخرين" : "\(SaryFormat.number(rest)) آخرين")
        }
        let n = max(0, f.memberCount - 1)
        switch n {
        case 0: return "طلعة فردية"
        case 1: return "مع واحد من الأصدقاء"
        case 2: return "مع اثنين من الأصدقاء"
        case 3...10: return "مع \(SaryFormat.number(n)) من الأصدقاء"
        default: return "مع \(SaryFormat.number(n)) من الأصدقاء"
        }
    }

    static func joinAnd(_ xs: [String]) -> String {
        guard xs.count > 1 else { return xs.first ?? "" }
        return xs.dropLast().joined(separator: "، ") + " و" + xs.last!
    }

    /// «السبت ٣١ أكتوبر ٢٠٢٦» (Gregorian, Arabic month names, Arabic-Indic digits).
    static func dateLine(_ f: StoryFacts) -> String? {
        guard let d = f.startedAt ?? f.trail.first.map({ Date(timeIntervalSince1970: $0.t / 1000) }) else { return nil }
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "ar")
        df.timeZone = .current
        df.dateFormat = "EEEE d MMMM y"
        return SaryFormat.digits(df.string(from: d))
    }

    // MARK: primitives

    static func font(_ w: SaryWeight, _ size: CGFloat) -> UIFont {
        SaryFonts.registerIfNeeded()
        return UIFont(name: w.postScript, size: size) ?? .systemFont(ofSize: size, weight: w == .heavy ? .heavy : w == .bold ? .bold : .medium)
    }

    enum Align { case left, right, center }

    static func drawText(_ text: String, font: UIFont, color: UIColor, in r: CGRect, align: Align, vCenter: Bool = false, fit: Bool = false, rtl: Bool = true) {
        var f = font
        let para = NSMutableParagraphStyle()
        para.alignment = align == .right ? .right : align == .left ? .left : .center
        para.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        para.lineBreakMode = .byTruncatingTail
        func attr() -> NSAttributedString { NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: color, .paragraphStyle: para]) }
        if fit {
            var size = f.pointSize
            while size > font.pointSize * 0.55, attr().size().width > r.width { size -= 2; f = f.withSize(size) }
        }
        let a = attr()
        let h = ceil(a.boundingRect(with: CGSize(width: r.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil).height)
        let y = vCenter ? r.midY - h / 2 : r.minY
        a.draw(with: CGRect(x: r.minX, y: y, width: r.width, height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    static func drawSymbol(_ name: String, color: UIColor, size: CGFloat, center: CGPoint) {
        let cfg = UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        guard let img = UIImage(systemName: name, withConfiguration: cfg)?.withTintColor(color, renderingMode: .alwaysOriginal) else { return }
        let s = img.size
        img.draw(in: CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height))
    }

    static func lerp(_ a: CGPoint, _ b: CGPoint, _ u: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u) }

    /// The app mark (same drawing as the icon), rendered once.
    @MainActor
    static func markImage(size: CGFloat = 152) -> UIImage? {
        let r = ImageRenderer(content: Canvas { ctx, s in SaryMarkDrawing.draw(in: ctx, size: s) }.frame(width: size, height: size))
        r.scale = 1
        return r.uiImage
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
