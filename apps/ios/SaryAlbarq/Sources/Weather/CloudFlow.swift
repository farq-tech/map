import SwiftUI

/// Where the cloud moves, drawn on the map itself: soft white streaks drifting across the screen in the
/// estimated direction (compass bearing, north up) so the motion is visible at a glance, not only as a
/// number. Indicative only: the on-screen speed is a gentle function of the estimated speed, not a
/// ground-true scale. Shown only when the server's confidence passes (`CloudOutlookPresenter`).
struct CloudFlow: Equatable {
    /// Degrees clockwise from north.
    var bearing: Double
    var speedKmh: Double

    /// On-screen speed in points per second: calm enough to read, never frantic.
    var pointsPerSecond: Double { min(90, max(30, 24 + speedKmh * 0.7)) }
    /// Unit vector on screen (x right, y down) toward where the cloud moves.
    var direction: CGVector {
        let r = bearing * .pi / 180
        return CGVector(dx: sin(r), dy: -cos(r))
    }
}

/// One deterministic pseudo-random value in 0..<1 per (index, salt) — stable across frames.
func cloudFlowNoise(_ i: Int, _ salt: Int) -> Double {
    var x = UInt64(truncatingIfNeeded: i &* 7919 &+ salt &* 104_729 &+ 13)
    x = (x ^ (x >> 15)) &* 0x2C1B_3C6D
    x = (x ^ (x >> 12)) &* 0x297A_2D39
    x ^= x >> 15
    return Double(x % 10_000) / 10_000
}

struct CloudFlowView: View {
    let flow: CloudFlow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let count = 18

    var body: some View {
        if reduceMotion {
            canvas(at: 0)
        } else {
            TimelineView(.animation) { ctx in
                canvas(at: ctx.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func canvas(at t: TimeInterval) -> some View {
        Canvas { gc, size in
            let d = flow.direction
            let p = CGVector(dx: -d.dy, dy: d.dx) // perpendicular
            let diag = Double(hypot(size.width, size.height))
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            for i in 0..<count {
                let len = 70 + cloudFlowNoise(i, 1) * 70
                let lateral = (cloudFlowNoise(i, 2) - 0.5) * diag
                let span = diag + 2 * len
                let travelled = reduceMotion ? cloudFlowNoise(i, 3) * span : t * flow.pointsPerSecond * (0.8 + cloudFlowNoise(i, 4) * 0.4)
                let phase = (travelled / span + cloudFlowNoise(i, 3)).truncatingRemainder(dividingBy: 1)
                let along = phase * span - span / 2
                let head = CGPoint(x: centre.x + d.dx * along + p.dx * lateral, y: centre.y + d.dy * along + p.dy * lateral)
                let tail = CGPoint(x: head.x - d.dx * len, y: head.y - d.dy * len)
                let fade = sin(phase * .pi) // in at the start, out at the end
                var line = Path()
                line.move(to: tail)
                line.addLine(to: head)
                var chevron = Path()
                chevron.move(to: CGPoint(x: head.x - d.dx * 9 + p.dx * 5, y: head.y - d.dy * 9 + p.dy * 5))
                chevron.addLine(to: head)
                chevron.addLine(to: CGPoint(x: head.x - d.dx * 9 - p.dx * 5, y: head.y - d.dy * 9 - p.dy * 5))
                for (offset, color, alpha) in [(CGFloat(1.5), Color(red: 0.08, green: 0.11, blue: 0.2), 0.35), (0, Color.white, 0.85)] {
                    var layer = gc
                    layer.opacity = fade * alpha
                    layer.translateBy(x: offset, y: offset)
                    layer.stroke(line, with: .linearGradient(Gradient(colors: [color.opacity(0), color]), startPoint: tail, endPoint: head),
                                 style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    layer.stroke(chevron, with: .color(color), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Reads the legend model so the streaks follow the estimate (hidden when there is none).
struct CloudFlowHost: View {
    @ObservedObject var model: WeatherLegendModel

    var body: some View {
        if let flow = model.flow {
            CloudFlowView(flow: flow)
                .accessibilityIdentifier("weather.outlook.flow")
        } else {
            Color.clear.allowsHitTesting(false)
        }
    }
}
