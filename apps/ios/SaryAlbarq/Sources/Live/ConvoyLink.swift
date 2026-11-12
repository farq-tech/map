import SwiftUI

// «الخيط» between the convoy's two ends (المقدمة ↔ المؤخرة) on the live map.
// One thin, quiet line: it follows the TRUE distance between the two cars (the map projects both
// ends, so it stretches as they move apart and shrinks as they close), starts and ends at the edge
// of each car marker (not its centre), is dashed more openly the further they are, shows the
// distance only when it is worth reading (≥ 500 m), and fades far beyond the allowed gap.

/// What the layer needs, computed once per convoy pass (not per frame).
struct ConvoyLinkInfo: Equatable {
    var leadId: String
    var tailId: String
    /// Straight-line distance between the two LIVE cars, rounded to 10 m (so it does not republish every fix).
    var meters: Double
    /// The convoy's allowed gap («المسافة القصوى»).
    var gapM: Double
}

enum ConvoyLink {
    /// Both ends must be live cars (a stale or lost car never gets a thread), distinct, and the convoy on.
    static func info(convoy: ConvoyInfo?, members: [MapMember]) -> ConvoyLinkInfo? {
        guard let c = convoy, c.isOn, let lead = c.lead_user_id, let tail = c.tail_user_id, lead != tail else { return nil }
        let live = Dictionary(OutingFeaturesModel.liveCars(members).map { ($0.id, $0.position) }, uniquingKeysWith: { a, _ in a })
        guard let a = live[lead], let b = live[tail] else { return nil }
        let m = Geo.haversineMeters(a, b)
        return ConvoyLinkInfo(leadId: lead, tailId: tail, meters: (m / 10).rounded() * 10, gapM: c.gapM)
    }
}

enum ConvoyLinkGeometry {
    /// About the car marker's radius: the line starts at its edge, never under it.
    static let markerInset: CGFloat = 20
    /// A visible stretch shorter than this is not worth drawing (the cars are on top of each other).
    static let minVisible: CGFloat = 14
    /// The distance label appears from here.
    static let labelFromM = 500.0

    struct Segment: Equatable {
        var from: CGPoint
        var to: CGPoint
        var length: CGFloat
        var mid: CGPoint { CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2) }
    }

    /// The visible part of the line between two screen points: both ends pulled in by `inset`.
    /// Nil when the cars are too close for a line.
    static func segment(a: CGPoint, b: CGPoint, inset: CGFloat = markerInset) -> Segment? {
        let dx = b.x - a.x, dy = b.y - a.y
        let d = hypot(dx, dy)
        let visible = d - 2 * inset
        guard d.isFinite, visible >= minVisible else { return nil }
        let ux = dx / d, uy = dy / d
        return Segment(from: CGPoint(x: a.x + ux * inset, y: a.y + uy * inset),
                       to: CGPoint(x: b.x - ux * inset, y: b.y - uy * inset),
                       length: visible)
    }

    enum Tone: Equatable { case calm, past }

    struct Style: Equatable {
        var width: CGFloat
        var opacity: Double
        /// Empty = solid.
        var dash: [CGFloat]
        var showsLabel: Bool
        /// `.past`: beyond the allowed gap (a soft accent instead of the neutral grey).
        var tone: Tone
    }

    /// Within half the gap: solid and calm. Up to the gap: a fine dash. Beyond it: a more open dash and
    /// the accent tone. Far beyond (3 gaps): it fades to a whisper, never to an alarm.
    static func style(meters: Double, gapM: Double) -> Style {
        let gap = max(gapM, 1)
        let r = meters / gap
        let width: CGFloat = 1.2
        let label = meters >= labelFromM
        switch r {
        case ..<0.5:
            return Style(width: width, opacity: 0.45, dash: [], showsLabel: label, tone: .calm)
        case ..<1.0:
            return Style(width: width, opacity: 0.55, dash: [6, 4], showsLabel: label, tone: .calm)
        default:
            /* Past the gap the dash opens with the distance (up to 14 pt dashes), and the line fades
               gently from 1.5 gaps so a very long thread never dominates the map. */
            let open = CGFloat(min(14, 8 + (r - 1) * 3))
            let fade = r <= 1.5 ? 0.7 : max(0.25, 0.7 - (r - 1.5) * 0.3)
            return Style(width: width, opacity: fade, dash: [open, 6], showsLabel: label, tone: .past)
        }
    }
}

/// Drawn over the map, under the chips. No hit testing: a thread never steals a tap from a car or a chip.
struct ConvoyLinkLayer: View {
    @ObservedObject var overlay: MapOverlayModel
    var info: ConvoyLinkInfo?
    @Environment(\.sary) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let info,
               let a = overlay.projection.points[info.leadId],
               let b = overlay.projection.points[info.tailId],
               let seg = ConvoyLinkGeometry.segment(a: a, b: b) {
                let st = ConvoyLinkGeometry.style(meters: info.meters, gapM: info.gapM)
                let tint = st.tone == .past ? theme.palette.accent : theme.palette.textPrimary
                ZStack {
                    Path { p in
                        p.move(to: seg.from)
                        p.addLine(to: seg.to)
                    }
                    .stroke(tint.opacity(st.opacity), style: StrokeStyle(lineWidth: st.width, lineCap: .round, dash: st.dash))
                    if st.showsLabel {
                        Text(SaryFormat.distance(meters: info.meters))
                            .saryText(.caption, weight: .medium)
                            .foregroundStyle(tint.opacity(min(1, st.opacity + 0.25)))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.palette.chromeOpaque.opacity(0.55)))
                            .position(seg.mid)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("الخيط بين المقدمة والمؤخرة، \(SaryFormat.distance(meters: info.meters))"))
                .accessibilityIdentifier("convoy.link")
                .transaction { t in if reduceMotion { t.animation = nil } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}
