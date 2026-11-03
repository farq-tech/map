import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

// MARK: - Buttons

enum SaryButtonKind { case primary, secondary, destructive, quiet }

/// Full-width button, ≥ 44 pt (54 pt in drive mode), Tajawal bold.
struct SaryButtonStyle: ButtonStyle {
    var kind: SaryButtonKind = .primary
    var compact = false
    @Environment(\.saryPalette) private var p
    @Environment(\.saryMetrics) private var m
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let (bg, fg): (Color, Color) = {
            switch kind {
            case .primary: return (p.accent, p.onAccent)
            case .secondary: return (p.card, p.textPrimary)
            case .destructive: return (p.sos.opacity(0.16), p.sos)
            case .quiet: return (.clear, p.textSecondary)
            }
        }()
        return configuration.label
            .saryFont(compact ? 15 : 16, .bold)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: compact ? nil : .infinity, minHeight: m.target)
            .padding(.horizontal, compact ? 14 : 18)
            .foregroundStyle(fg)
            .background(bg, in: RoundedRectangle(cornerRadius: m.cornerSmall, style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == SaryButtonStyle {
    static var saryPrimary: SaryButtonStyle { .init(kind: .primary) }
    static var sarySecondary: SaryButtonStyle { .init(kind: .secondary) }
    static var saryDestructive: SaryButtonStyle { .init(kind: .destructive) }
    static var saryQuiet: SaryButtonStyle { .init(kind: .quiet) }
    static func sary(_ kind: SaryButtonKind, compact: Bool = false) -> SaryButtonStyle { .init(kind: kind, compact: compact) }
}

/// Button label with an optional spinner that keeps the same size.
struct SaryButtonLabel: View {
    var title: String
    var systemImage: String?
    var busy = false
    var body: some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView().tint(.primary)
            } else if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
        }
    }
}

/// Round floating button for the map with a label under the icon.
struct MapFloatingButton: View {
    var title: String
    var systemImage: String
    var id: String
    var showsTitle = true
    var action: () -> Void
    @Environment(\.saryPalette) private var p
    @Environment(\.saryMetrics) private var m

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: m.drive ? 22 : 18, weight: .semibold))
                if showsTitle {
                    Text(title)
                        .saryFont(10.5, .bold, relativeTo: .caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(p.textPrimary)
            .frame(width: m.mapButton + (showsTitle ? 10 : 0), height: m.mapButton + (showsTitle ? 8 : 0))
            .background(FloatingBackground(cornerRadius: m.corner))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(Text(title))
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

/// rgba(28,24,20,0.9) over a light blur, as on the web's floating bars.
struct FloatingBackground: View {
    var cornerRadius: CGFloat = 18
    @Environment(\.saryPalette) private var p
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(p.floating))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(p.textPrimary.opacity(0.08)))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }
}

// MARK: - Avatar

/// Photo or initials, with the participant's colour as a ring.
struct ParticipantAvatar: View {
    var name: String
    var color: UInt32
    var photo: UIImage?
    var size: CGFloat = 44
    var greyed = false
    @Environment(\.saryPalette) private var p

    var body: some View {
        ZStack {
            Circle().fill(Color(rgb: color))
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill().clipShape(Circle())
            } else {
                Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)))
                    .font(.sary(size * 0.42, .bold))
                    .foregroundStyle(SaryCarColors.ink(on: color))
            }
        }
        .frame(width: size, height: size)
        .padding(3)
        .overlay(Circle().strokeBorder(Color(rgb: color), lineWidth: 2.5))
        .saturation(greyed ? 0 : 1)
        .opacity(greyed ? 0.55 : 1)
        .accessibilityHidden(true)
    }
}

// MARK: - Badges

struct LiveBadge: View {
    @Environment(\.saryPalette) private var p
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(p.live).frame(width: 7, height: 7)
            Text("مباشر").saryFont(12, .bold, relativeTo: .caption)
        }
        .foregroundStyle(p.live)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(p.live.opacity(0.14), in: Capsule())
    }
}

/// «آخر تحديث قبل ٤ د» (stale) or «متوقف» (paused), always grey.
struct StaleBadge: View {
    var text: String
    @Environment(\.saryPalette) private var p
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock").font(.system(size: 10, weight: .bold))
            Text(text).saryFont(12, .medium, relativeTo: .caption)
        }
        .foregroundStyle(p.stale)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(p.stale.opacity(0.16), in: Capsule())
    }
}

struct PresenceBadge: View {
    var presence: ParticipantPresence
    var now: Date
    var body: some View {
        switch presence {
        case .live: LiveBadge()
        case .stale(let since): StaleBadge(text: SaryFormat.lastUpdate(since: since, now: now))
        case .paused: StaleBadge(text: "أوقف المشاركة")
        }
    }
}

struct StatusChipUI: View {
    var status: OutingStatusUI
    @Environment(\.saryPalette) private var p
    var body: some View {
        let c: Color = {
            switch status {
            case .active: return p.live
            case .paused: return p.warning
            case .notStarted: return p.textSecondary
            case .ended: return p.stale
            }
        }()
        Text(status.label)
            .saryFont(12, .bold, relativeTo: .caption)
            .foregroundStyle(c)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(c.opacity(0.15), in: Capsule())
    }
}

// MARK: - Direction arrow (never mirrored in RTL)

struct ArrowShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY - r.height * 0.28))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Points toward `degrees` (clockwise from screen-up). Drawn in LTR space so
/// RTL never flips it.
struct DirectionArrow: View {
    var degrees: Double
    var color: Color
    var size: CGFloat = 14
    var body: some View {
        ArrowShape()
            .fill(color)
            .frame(width: size * 0.8, height: size)
            .rotationEffect(.degrees(degrees))
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityHidden(true)
    }
}

// MARK: - Cards and sections

struct SaryCard<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.saryPalette) private var p
    @Environment(\.saryMetrics) private var m
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.card, in: RoundedRectangle(cornerRadius: m.corner, style: .continuous))
    }
}

struct SarySectionTitle: View {
    var title: String
    @Environment(\.saryPalette) private var p
    var body: some View {
        Text(title)
            .saryFont(13, .bold, relativeTo: .footnote)
            .foregroundStyle(p.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Text field with the theme look.
struct SaryTextField: View {
    var placeholder: String
    @Binding var text: String
    var id: String
    var keyboard: UIKeyboardType = .default
    var maxLength: Int?
    var disabled = false
    @Environment(\.saryPalette) private var p
    @Environment(\.saryMetrics) private var m

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(p.textSecondary.opacity(0.7)))
            .saryFont(17, .medium)
            .foregroundStyle(p.textPrimary)
            .keyboardType(keyboard)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14)
            .frame(minHeight: m.target + 6)
            .background(p.card, in: RoundedRectangle(cornerRadius: m.cornerSmall, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: m.cornerSmall, style: .continuous).strokeBorder(p.textPrimary.opacity(0.1)))
            .disabled(disabled)
            .accessibilityIdentifier(id)
            .accessibilityLabel(Text(placeholder))
            .onChange(of: text) { v in
                if let maxLength, v.count > maxLength { text = String(v.prefix(maxLength)) }
            }
    }
}

/// Grey/red line under a form.
struct SaryInlineMessage: View {
    var text: String
    var isError = true
    @Environment(\.saryPalette) private var p
    var body: some View {
        Label { Text(text) } icon: { Image(systemName: isError ? "exclamationmark.circle.fill" : "info.circle") }
            .saryFont(14, .medium)
            .foregroundStyle(isError ? p.sos : p.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Centered state block for loading / empty / error / offline.
struct SaryStateBlock: View {
    var systemImage: String
    var title: String
    var message: String?
    var actionTitle: String?
    var actionId: String = "state-action"
    var loading = false
    var action: () -> Void = {}
    @Environment(\.saryPalette) private var p

    var body: some View {
        VStack(spacing: 12) {
            if loading {
                ProgressView().controlSize(.large).tint(p.accent)
            } else {
                Image(systemName: systemImage).font(.system(size: 40, weight: .semibold)).foregroundStyle(p.accent)
            }
            Text(title).saryFont(19, .bold, relativeTo: .title3).foregroundStyle(p.textPrimary).multilineTextAlignment(.center)
            if let message {
                Text(message).saryFont(15).foregroundStyle(p.textSecondary).multilineTextAlignment(.center)
            }
            if let actionTitle {
                Button(actionTitle, action: action).buttonStyle(.sary(.primary, compact: true))
                    .accessibilityIdentifier(actionId)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - QR code (generated on device)

struct QRCodeView: View {
    var text: String
    var size: CGFloat = 180

    var body: some View {
        Group {
            if let img = Self.make(text) {
                Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
            } else {
                Color.gray
            }
        }
        .frame(width: size, height: size)
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityLabel(Text("رمز QR للرابط"))
    }

    static func make(_ text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: .init(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Sheet header used by presented screens

struct SarySheetHeader: View {
    var title: String
    var closeTitle = "إغلاق"
    var closeId = "sheet-close"
    var close: () -> Void
    @Environment(\.saryPalette) private var p
    @Environment(\.saryMetrics) private var m
    var body: some View {
        HStack {
            Text(title).saryFont(20, .bold, relativeTo: .title3).foregroundStyle(p.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 15, weight: .bold))
                    .frame(width: m.target, height: m.target)
                    .background(p.card, in: Circle())
                    .foregroundStyle(p.textSecondary)
            }
            .accessibilityLabel(Text(closeTitle))
            .accessibilityIdentifier(closeId)
        }
    }
}
