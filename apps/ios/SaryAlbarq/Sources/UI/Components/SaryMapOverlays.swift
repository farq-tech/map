import SwiftUI

// Components drawn ON the map at screen points supplied by the wiring layer.
// They are small, high-contrast and readable over bright sand and at night.

/// Container for overlays positioned at map screen points. `.position(x:y:)`
/// is mirrored under RTL; map points are physical, so the layer is laid out
/// LTR while each overlay's own content stays Arabic RTL.
/// Place children with `.saryMapPoint(_:)`.
struct SaryMapOverlayLayer<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ZStack { content }
            .environment(\.layoutDirection, .leftToRight)
    }
}

extension View {
    /// Position an overlay at a physical map screen point (inside
    /// `SaryMapOverlayLayer`), keeping its own content RTL.
    func saryMapPoint(_ x: CGFloat, _ y: CGFloat) -> some View {
        environment(\.layoutDirection, .rightToLeft).position(x: x, y: y)
    }
}

// MARK: - Name chip

struct SaryNameChip: View {
    var chip: NameChipUI
    /// The member has a note that has no room on the map right now: a small indicator.
    var noteWaiting = false
    var tapped: () -> Void = {}
    var id: String? = nil
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let style = SaryPresenceStyle(presence: chip.presence)
        let shape = Capsule()
        Button(action: tapped) {
            HStack(spacing: 5) {
                ZStack {
                    Circle().fill(Color(rgb: chip.color)).saturation(style.saturation)
                    if style.paused {
                        Image(systemName: SaryIcon.pause).font(.system(size: 6, weight: .heavy))
                            .foregroundStyle(SaryCarColors.ink(on: chip.color))
                    }
                }
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(p.textPrimary.opacity(0.35), lineWidth: SaryCarColors.needsOutline(chip.color, onDark: !theme.isLight) ? 1 : 0))
                Text(chip.isMe ? "أنت" : chip.name)
                    .saryText(.caption)
                    .lineLimit(1)
                    .foregroundStyle(chip.presence.isLive ? p.textPrimary : p.textSecondary)
                if let s = chip.silentSince {
                    SarySilentBadge(since: s, now: chip.now, compact: true)
                } else if !chip.presence.isLive {
                    Text(style.label(now: chip.now))
                        .saryText(.micro, weight: .medium)
                        .foregroundStyle(p.textSecondary)
                        .lineLimit(1)
                }
                if chip.hasVoice {
                    Image(systemName: "waveform").font(.system(size: 10, weight: .bold)).foregroundStyle(p.accentText)
                }
                if noteWaiting {
                    Image(systemName: SaryIcon.note)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(SaryCarColors.ink(on: chip.color))
                        .frame(width: 18, height: 16)
                        .background(Capsule().fill(Color(rgb: chip.color)))
                        .accessibilityLabel(Text("لديه رسالة"))
                }
            }
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                // Chips over the map are tiny: a solid surface reads better than glass.
                shape.fill(chip.isMe ? p.accent.opacity(0.2) : Color.clear)
            }
            .background(shape.fill(p.chromeOpaque.opacity(chip.presence.isLive ? 0.94 : 0.82)))
            .overlay {
                if style.dashed {
                    shape.strokeBorder(p.stale, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                } else if chip.isMe {
                    shape.strokeBorder(p.accent, lineWidth: 1.5)
                } else {
                    shape.strokeBorder(p.stroke, lineWidth: 0.5)
                }
            }
            .saryShadow(.raised, theme)
        }
        .buttonStyle(SaryPressStyle())
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityLabel(Text(chip.isMe ? "أنت" : "\(chip.name)، \(chip.silentSince.map { SilenceText.badge(since: $0, now: chip.now) } ?? style.accessibilityLabel(now: chip.now))"))
        .modifier(OptionalIdentifier(id: id))
    }
}

// MARK: - Group chip

/// Friends whose chips would pile up, folded into one chip: «٣ سيارات».
/// Tapping it spreads them out (zoom in, or a list when parked together).
struct SaryGroupChip: View {
    var count: Int
    var colors: [UInt32]
    var tapped: () -> Void = {}
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        Button(action: tapped) {
            HStack(spacing: 6) {
                HStack(spacing: -4) {
                    ForEach(Array(colors.prefix(3).enumerated()), id: \.offset) { _, c in
                        Circle().fill(Color(rgb: c)).frame(width: 10, height: 10)
                            .overlay(Circle().stroke(p.chromeOpaque, lineWidth: 1.5))
                    }
                }
                .environment(\.layoutDirection, .leftToRight)
                Text(SaryFormat.cars(count))
                    .saryText(.caption, weight: .bold)
                    .foregroundStyle(p.textPrimary)
                    .lineLimit(1)
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(p.textSecondary)
            }
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(p.chromeOpaque.opacity(0.96)))
            .overlay(Capsule().strokeBorder(p.textPrimary.opacity(0.35), lineWidth: 1))
            .saryShadow(.raised, theme)
        }
        .buttonStyle(SaryPressStyle())
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityLabel(Text("\(SaryFormat.cars(count)) متقاربة، اضغط للتكبير"))
    }
}

// MARK: - Note bubble

struct SaryNoteBubble: View {
    var bubble: NoteBubbleUI
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let paper = Color(rgb: theme.night ? 0xB8AD9B : 0xFFFCF6)
        let text = bubble.text.count > 80 ? String(bubble.text.prefix(79)) + "…" : bubble.text
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Capsule().fill(Color(rgb: bubble.color)).frame(width: 3, height: 16)
                    .overlay(Capsule().stroke(p.textTertiary.opacity(0.5), lineWidth: SaryCarColors.needsOutline(bubble.color, onDark: false) ? 0.5 : 0))
                Text(text)
                    .saryText(.footnote, weight: .bold)
                    .foregroundStyle(Color(rgb: 0x1F1A14))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: 200)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(paper))
            SaryBubbleTail()
                .fill(paper)
                .frame(width: 14, height: 7)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityLabel(Text("رسالة: \(bubble.text)"))
    }
}

struct SaryBubbleTail: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.maxY), control: CGPoint(x: r.midX - r.width * 0.1, y: r.minY + r.height * 0.4))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX + r.width * 0.1, y: r.minY + r.height * 0.4))
        p.closeSubpath()
        return p
    }
}

// MARK: - Edge arrow chip

/// At the screen edge for a friend who is off-screen: an arrow rotated toward
/// them + name + distance. Stale friends get the stale styling.
struct SaryEdgeArrowChip: View {
    var chip: EdgeArrowChipUI
    var tapped: () -> Void = {}
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let c = Color(rgb: chip.color)
        Button(action: tapped) {
            HStack(spacing: 6) {
                ZStack {
                    Circle().fill(chip.isStale ? p.stale : c)
                    SaryArrowShape()
                        .fill(chip.isStale ? p.textPrimary : SaryCarColors.ink(on: chip.color))
                        .frame(width: 9, height: 11)
                }
                .frame(width: 22, height: 22)
                .rotationEffect(.degrees(chip.bearingDegrees))
                .environment(\.layoutDirection, .leftToRight)
                .overlay(Circle().stroke(p.textPrimary.opacity(0.3), lineWidth: SaryCarColors.needsOutline(chip.color, onDark: !theme.isLight) ? 1 : 0))
                VStack(alignment: .leading, spacing: 0) {
                    Text(chip.name).saryText(.caption).foregroundStyle(p.textPrimary).lineLimit(1)
                    if let d = chip.distanceMeters {
                        Text(SaryFormat.distance(meters: d)).saryNumber(.micro).foregroundStyle(p.textSecondary)
                    }
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(p.chromeOpaque.opacity(0.94)))
            .overlay {
                if chip.isStale {
                    Capsule().strokeBorder(p.stale, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                } else {
                    Capsule().strokeBorder(c.opacity(0.9), lineWidth: 1.5)
                }
            }
            .saryShadow(.raised, theme)
            .opacity(chip.isStale ? 0.85 : 1)
        }
        .buttonStyle(SaryPressStyle())
        .animation(theme.animation(.smooth), value: chip.bearingDegrees)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityLabel(Text("\(chip.name) خارج الشاشة، \(chip.distanceMeters.map { "على بعد \(SaryFormat.distance(meters: $0))، " } ?? "")\(SaryFormat.relativeDirection(chip.bearingDegrees))"))
    }
}

// MARK: - Rally flag

struct SaryRallyFlag: View {
    var marker: RallyMarkerUI
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(spacing: 2) {
            if let label = marker.label {
                Text(label)
                    .saryText(.caption)
                    .foregroundStyle(p.onAccent)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(p.accent))
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            }
            ZStack(alignment: .bottom) {
                Ellipse().fill(Color.black.opacity(0.28)).frame(width: 18, height: 6).blur(radius: 1.5)
                VStack(spacing: 0) {
                    Image(systemName: SaryIcon.rally)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(p.onAccent)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(p.accent))
                        .overlay(Circle().stroke(Color.white, lineWidth: 2.5))
                    Rectangle().fill(Color.white).frame(width: 2.5, height: 12)
                }
                .padding(.bottom, 2)
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
        .accessibilityLabel(Text(marker.label ?? "نقطة التجمع"))
    }
}

// MARK: - Car marker (2D stand-in; the real map draws 3D cars)

/// Top-down car silhouette, or a dot in «نقاط» display mode. Used by the
/// showcase map stage and as the 2D fallback marker.
struct SaryCarMarker: View {
    var color: UInt32
    var heading: Double = 0
    var presence: ParticipantPresence = .live
    var isMe = false
    @Environment(\.sary) private var theme

    var body: some View {
        let style = SaryPresenceStyle(presence: presence)
        Group {
            if theme.participantMarker == .dots {
                Circle().fill(Color(rgb: color))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Color.white, lineWidth: 3))
            } else {
                SaryCarShape()
                    .fill(Color(rgb: color))
                    .overlay(SaryCarGlassShape().fill(Color.black.opacity(0.35)))
                    .overlay(SaryCarShape().stroke(Color.black.opacity(0.35), lineWidth: 1))
                    .frame(width: 20, height: 36)
                    .rotationEffect(.degrees(heading))
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
        .saturation(style.saturation)
        .opacity(style.opacity)
        .padding(6)
        .background {
            if isMe {
                Circle().fill(theme.palette.accent.opacity(0.22))
                    .overlay(Circle().stroke(theme.palette.accent, lineWidth: 2))
                    .frame(width: 48, height: 48)
            } else if style.dashed {
                Circle().strokeBorder(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    .frame(width: 46, height: 46)
            }
        }
        .overlay(alignment: .topTrailing) {
            if style.paused {
                Image(systemName: SaryIcon.pause).font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(theme.palette.stale))
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
        .accessibilityHidden(true)
    }
}

struct SaryCarShape: Shape {
    func path(in r: CGRect) -> Path {
        Path(roundedRect: r, cornerSize: CGSize(width: r.width * 0.38, height: r.height * 0.22), style: .continuous)
    }
}

struct SaryCarGlassShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        p.addRoundedRect(in: CGRect(x: w * 0.18, y: h * 0.22, width: w * 0.64, height: h * 0.2), cornerSize: CGSize(width: 3, height: 3))
        p.addRoundedRect(in: CGRect(x: w * 0.2, y: h * 0.66, width: w * 0.6, height: h * 0.13), cornerSize: CGSize(width: 3, height: 3))
        return p
    }
}
