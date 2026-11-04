import CoreGraphics

/// Where everything goes on a story canvas, in pixels (origin top-left). Pure and
/// unit-tested: no drawing here.
///
/// Vertical 1080×1920 keeps the title and the numbers inside the band that
/// Instagram / Snapchat / WhatsApp leave free (`safeTop`…`safeBottom`): the top
/// ~220 px hold the app's own progress bar and name, the bottom ~250 px the reply box.
struct StoryLayout: Equatable {
    var format: StoryFormat
    var canvas: CGSize
    var margin: CGFloat
    /// Brand mark + «سَرى البارق» (right, RTL) and the date (left).
    var header: CGRect
    var markSize: CGFloat
    /// The map card (satellite snapshot + the trail).
    var map: CGRect
    var mapRadius: CGFloat
    /// Inset inside the map card that the trail is fitted into (clear of the edges and Mapbox's logo).
    var trailInsets: (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat)
    /// Up to `maxPhotos` picked photos, as tilted cards overlapping the map's lower edge.
    var photos: [CGRect]
    var photoTilts: [CGFloat]
    /// Outing name and the «مع …» line.
    var title: CGRect
    var subtitle: CGRect
    /// The four numbers, in reading order (first = right-most under RTL).
    var stats: [CGRect]
    var statRadius: CGFloat
    var titleSize: CGFloat
    var subtitleSize: CGFloat
    var statValueSize: CGFloat
    var statLabelSize: CGFloat

    static let maxPhotos = 3
    static let safeTop: CGFloat = 220
    static let safeBottom: CGFloat = 1920 - 250

    static func == (a: StoryLayout, b: StoryLayout) -> Bool {
        a.format == b.format && a.map == b.map && a.photos == b.photos && a.stats == b.stats && a.title == b.title
    }

    static func make(_ format: StoryFormat, photoCount: Int) -> StoryLayout {
        let n = max(0, min(maxPhotos, photoCount))
        switch format {
        case .vertical: return vertical(photos: n)
        case .square: return square(photos: n)
        }
    }

    private static func vertical(photos n: Int) -> StoryLayout {
        let W: CGFloat = 1080, H: CGFloat = 1920
        let m: CGFloat = 64
        let inner = W - 2 * m
        let header = CGRect(x: m, y: 150, width: inner, height: 76)
        /* Built bottom-up so the numbers end exactly at the bottom of the free band. */
        let gap: CGFloat = 20
        let statW = (inner - gap) / 2
        let statH: CGFloat = 136
        let statsTop = safeBottom - (2 * statH + gap)
        let subtitle = CGRect(x: m, y: statsTop - 26 - 50, width: inner, height: 50)
        let title = CGRect(x: m, y: subtitle.minY - 4 - 94, width: inner, height: 94)
        /* Photos hang over the map's bottom edge; the map gives up that height. */
        let photoSide: CGFloat = n == 0 ? 0 : (n == 1 ? 300 : n == 2 ? 264 : 220)
        let overhang = photoSide * 0.45
        let mapTop = header.maxY + 34
        let mapBottom = title.minY - (n == 0 ? 40 : 26) - overhang
        let map = CGRect(x: m, y: mapTop, width: inner, height: mapBottom - mapTop)
        var photos: [CGRect] = []
        var tilts: [CGFloat] = []
        if n > 0 {
            let pgap: CGFloat = 20
            let rowW = CGFloat(n) * photoSide + CGFloat(n - 1) * pgap
            /* RTL: the row hugs the right edge of the card, a little inside it (clear of Mapbox's logo on the left). */
            var x = map.maxX - 30 - rowW
            let y = map.maxY - (photoSide - overhang)
            let allTilts: [CGFloat] = [-5, 4, -3]
            for i in 0..<n {
                photos.append(CGRect(x: x, y: y, width: photoSide, height: photoSide))
                tilts.append(allTilts[i])
                x += photoSide + pgap
            }
        }
        /* Reading order right → left, then down. */
        let stats = [
            CGRect(x: m + statW + gap, y: statsTop, width: statW, height: statH),
            CGRect(x: m, y: statsTop, width: statW, height: statH),
            CGRect(x: m + statW + gap, y: statsTop + statH + gap, width: statW, height: statH),
            CGRect(x: m, y: statsTop + statH + gap, width: statW, height: statH),
        ]
        return StoryLayout(format: .vertical, canvas: CGSize(width: W, height: H), margin: m, header: header, markSize: 76,
                           map: map, mapRadius: 52, trailInsets: (90, 90, n > 0 ? (photoSide - overhang) + 60 : 100, 90),
                           photos: photos, photoTilts: tilts, title: title, subtitle: subtitle, stats: stats, statRadius: 34,
                           titleSize: 72, subtitleSize: 36, statValueSize: 58, statLabelSize: 28)
    }

    private static func square(photos n: Int) -> StoryLayout {
        let W: CGFloat = 1080, H: CGFloat = 1080
        let m: CGFloat = 44
        let inner = W - 2 * m
        let map = CGRect(x: m, y: m, width: inner, height: n == 0 ? 668 : 600)
        let photoSide: CGFloat = 196
        var photos: [CGRect] = []
        var tilts: [CGFloat] = []
        if n > 0 {
            let gap: CGFloat = 20
            let rowW = CGFloat(n) * photoSide + CGFloat(n - 1) * gap
            var x = map.maxX - 34 - rowW
            let y = map.maxY - photoSide * 0.62
            let allTilts: [CGFloat] = [-5, 4, -3]
            for i in 0..<n {
                photos.append(CGRect(x: x, y: y, width: photoSide, height: photoSide))
                tilts.append(allTilts[i])
                x += photoSide + gap
            }
        }
        let below = max(map.maxY, photos.map(\.maxY).max() ?? 0)
        let title = CGRect(x: m, y: below + 22, width: inner, height: 76)
        let subtitle = CGRect(x: m, y: title.maxY, width: inner, height: 42)
        /* The header shares the subtitle line: the mark on the left of the title block. */
        let header = CGRect(x: m, y: title.minY + 6, width: 64, height: 64)
        let gap: CGFloat = 16
        let statsTop = subtitle.maxY + 22
        let statH = H - m - statsTop
        let statW = (inner - 3 * gap) / 4
        let stats = (0..<4).map { i in
            CGRect(x: m + inner - CGFloat(i + 1) * statW - CGFloat(i) * gap, y: statsTop, width: statW, height: statH)
        }
        return StoryLayout(format: .square, canvas: CGSize(width: W, height: H), margin: m, header: header, markSize: 64,
                           map: map, mapRadius: 40, trailInsets: (64, 64, n > 0 ? photoSide * 0.62 + 46 : 76, 64),
                           photos: photos, photoTilts: tilts, title: title, subtitle: subtitle, stats: stats, statRadius: 26,
                           titleSize: 56, subtitleSize: 30, statValueSize: 42, statLabelSize: 24)
    }

    /// The rectangle (inside `map`, in map-local pixels) the trail is fitted into.
    var trailFrame: CGRect {
        CGRect(x: trailInsets.left, y: trailInsets.top,
               width: map.width - trailInsets.left - trailInsets.right,
               height: map.height - trailInsets.top - trailInsets.bottom)
    }
}
