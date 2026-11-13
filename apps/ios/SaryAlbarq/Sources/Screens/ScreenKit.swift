import SwiftUI
import UIKit

// Shared building blocks for the full-screen pages (everything that is not the
// live map). They only compose design-system tokens and components.

/// A page: themed background, a header (title, optional back/close and trailing
/// buttons) and scrolling content with the design system's spacing.
struct SaryPage<Content: View, Trailing: View>: View {
    var title: String
    var subtitle: String? = nil
    var back: (() -> Void)? = nil
    var close: (() -> Void)? = nil
    var scrolls = true
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(spacing: 0) {
            if NewUI.enabled {
                /* Build 47: the unified window header (title right, round ✕ left). */
                NewPageHeader(title: title, subtitle: subtitle, back: back, close: close) { trailing }
                    .saryReadableWidth()
            } else {
            HStack(alignment: .center, spacing: theme.space(.s)) {
                if let back {
                    SaryIconButton(systemImage: SaryIcon.back, label: "رجوع", id: "page-back", action: back)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .saryText(.title, weight: .bold)
                        .foregroundStyle(p.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle).saryText(.subhead).foregroundStyle(p.textSecondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                trailing
                if let close {
                    SaryIconButton(systemImage: SaryIcon.close, label: "إغلاق", id: "page-close", action: close)
                }
            }
            .padding(.horizontal, theme.space(.l))
            .padding(.top, theme.space(.m))
            .padding(.bottom, theme.space(.s))
            /* Same column as the content below: on iPad the title and close button no longer sit at
               opposite window edges. Every iPhone is narrower than 640, so nothing changes there. */
            .saryReadableWidth()
            }
            if scrolls {
                ScrollView {
                    VStack(alignment: .leading, spacing: theme.space(.xl)) { content }
                        .padding(.horizontal, theme.space(.l))
                        .padding(.top, theme.space(.s))
                        .padding(.bottom, theme.space(.xxl))
                        .saryReadableWidth()
                }
                .scrollDismissesKeyboard(.interactively)
            } else {
                content
            }
        }
        .background(p.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

extension SaryPage where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, back: (() -> Void)? = nil, close: (() -> Void)? = nil, scrolls: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, back: back, close: close, scrolls: scrolls, trailing: { EmptyView() }, content: content)
    }
}

/// Layout math for fitting fixed design sizes on every iPhone (unit-tested in DesignSystemTests).
enum SaryFit {
    /// The visible height of a page's scroll area on a standard 393×852 phone and on a mini; at
    /// or above it, design sizes are kept as they are.
    static let referenceHeight: CGFloat = 640

    /// A fixed design height (map previews, track maps) in a container `container` points tall:
    /// unchanged on standard, mini and Pro Max phones, scaled down proportionally (never below
    /// `minScale`) on a short screen such as a 375×667 SE, so the buttons under it stay in reach.
    static func height(_ design: CGFloat, container: CGFloat, minScale: CGFloat = 0.7, reference: CGFloat = referenceHeight) -> CGFloat {
        guard container.isFinite, container > 0, reference > 0 else { return design }
        let k = min(1, max(minScale, container / reference))
        return (design * k).rounded()
    }

    /// A sheet detent of `fraction` of the sheet's full height, but never shorter than `minimum`
    /// (a fixed fraction left an SE's 375×667 too little room for the sheet's own controls) nor
    /// taller than the sheet. On standard phones the fraction already exceeds `minimum`.
    static func detentHeight(fraction: CGFloat, minimum: CGFloat, maxHeight: CGFloat) -> CGFloat {
        guard maxHeight.isFinite, maxHeight > 0 else { return minimum }
        return min(maxHeight, max(minimum, maxHeight * fraction))
    }
}

extension View {
    /// `.frame(height: design)` that shrinks on short screens (see `SaryFit.height`), measured
    /// against the nearest scroll view / sheet / window.
    func saryFitHeight(_ design: CGFloat, minScale: CGFloat = 0.7, reference: CGFloat = SaryFit.referenceHeight) -> some View {
        containerRelativeFrame(.vertical) { length, _ in SaryFit.height(design, container: length, minScale: minScale, reference: reference) }
    }
}

/// A full-height column that lays out exactly like a plain `VStack` filling the screen (its
/// `Spacer`s spread out) whenever it fits, and scrolls instead of clipping or overlapping when
/// it does not: a 375×667 SE, or large Dynamic Type. `bottom` stays pinned above the home
/// indicator and the keyboard (primary buttons never scroll away).
struct SaryFitColumn<Content: View, Bottom: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var bottom: Bottom

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                content.frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottom }
    }
}

/// A tappable settings-style row: icon, title, optional detail, chevron.
struct SaryNavRow: View {
    var title: String
    var detail: String? = nil
    var systemImage: String
    var tint: Color? = nil
    var id: String? = nil
    var destructive = false
    var action: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        Button(action: action) {
            HStack(spacing: theme.space(.m)) {
                SaryRowIcon(systemImage: systemImage, color: destructive ? p.emergency : tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).saryText(.body, weight: .medium).foregroundStyle(destructive ? p.emergencyText : p.textPrimary)
                    if let detail {
                        Text(detail).saryText(.footnote).foregroundStyle(p.textSecondary).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(p.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: NewScreens.rowMinHeight(legacy: theme.minTarget + 4))
            .padding(.vertical, theme.space(.xs))
            .contentShape(Rectangle())
        }
        .buttonStyle(SaryRowPressStyle())
        .modifier(OptionalIdentifier(id: id))
    }
}

/// «جارية» / «متوقفة مؤقتًا» / «ما بدأت» / «انتهت», in words and colour.
struct SaryOutingStatusPill: View {
    var status: OutingStatus
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let (text, icon, color): (String, String, Color) = {
            switch status {
            case .active: return ("جارية", "dot.radiowaves.left.and.right", p.liveText)
            case .paused: return ("متوقفة مؤقتًا", SaryIcon.pause, p.warningText)
            case .created: return ("ما بدأت", "clock", p.textSecondary)
            case .ended: return ("انتهت", "flag.checkered", p.textTertiary)
            }
        }()
        HStack(spacing: 4) {
            Image(systemName: icon).saryGlyph(10, weight: .bold)
            Text(text).saryText(.caption, weight: .bold).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.14)))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// Grey strip shown when the phone has no network: what still works, honestly.
struct SaryOfflineStrip: View {
    var text = "بلا إنترنت — نعرض آخر ما وصلنا، ونحدّث أول ما يرجع الاتصال."
    var body: some View {
        SaryBanner(text: text, tone: .warning, systemImage: SaryIcon.offline)
            .accessibilityIdentifier("offline-banner")
    }
}

/// A full-screen modal dialog over a scrim, from `SaryDialog`.
struct SaryDialogModifier: ViewModifier {
    @Binding var isPresented: Bool
    var systemImage: String
    var title: String
    var message: String
    var confirmTitle: String
    var confirmKind: SaryButtonKind = .destructive
    var busy = false
    var confirm: () -> Void
    @Environment(\.sary) private var theme

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                ZStack {
                    theme.palette.scrim.ignoresSafeArea()
                        .onTapGesture { if !busy { isPresented = false } }
                    SaryDialog(systemImage: systemImage, title: title, message: message, confirmTitle: confirmTitle,
                               confirmKind: confirmKind, busy: busy, confirm: confirm, cancel: { isPresented = false })
                        .padding(theme.space(.l))
                }
                .transition(.opacity)
                .accessibilityIdentifier("dialog")
            }
        }
        .animation(theme.animation(.smooth), value: isPresented)
    }
}

extension View {
    func saryDialog(_ isPresented: Binding<Bool>, systemImage: String, title: String, message: String, confirmTitle: String,
                    kind: SaryButtonKind = .destructive, busy: Bool = false, confirm: @escaping () -> Void) -> some View {
        modifier(SaryDialogModifier(isPresented: isPresented, systemImage: systemImage, title: title, message: message,
                                    confirmTitle: confirmTitle, confirmKind: kind, busy: busy, confirm: confirm))
    }

    /// Presented screens re-apply the theme, RTL and the Arabic locale (sheets do not reliably inherit them).
    func saryPresented(_ appearance: AppearanceSettings) -> some View {
        rtl().saryAppearance(appearance)
    }
}

/// A short message that slides in at the bottom and leaves on its own.
struct SaryToast: View {
    var text: String
    @Environment(\.sary) private var theme
    var body: some View {
        Text(text)
            .saryText(.callout, weight: .bold)
            .foregroundStyle(theme.palette.textPrimary)
            .padding(.horizontal, theme.space(.l))
            .padding(.vertical, theme.space(.s))
            .background(Capsule().fill(theme.palette.elevated))
            .overlay(Capsule().stroke(theme.palette.stroke, lineWidth: 1))
            .saryShadow(.overlay, theme)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Profile photos travel as a small JPEG data URL (the server keeps ≤ 24 000 chars).
enum AvatarCodec {
    static let maxChars = 24_000

    /// Square-crop, shrink and compress until it fits.
    static func dataURL(from image: UIImage) -> String? {
        let side = min(image.size.width, image.size.height)
        guard side > 0 else { return nil }
        for (px, q) in [(192.0, 0.7), (160.0, 0.6), (128.0, 0.55), (96.0, 0.5), (72.0, 0.45)] as [(CGFloat, CGFloat)] {
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 1
            let r = UIGraphicsImageRenderer(size: CGSize(width: px, height: px), format: fmt)
            let img = r.image { _ in
                let scale = px / side
                let w = image.size.width * scale, h = image.size.height * scale
                image.draw(in: CGRect(x: (px - w) / 2, y: (px - h) / 2, width: w, height: h))
            }
            if let d = img.jpegData(compressionQuality: q) {
                let s = "data:image/jpeg;base64," + d.base64EncodedString()
                if s.count <= maxChars { return s }
            }
        }
        return nil
    }

    /// Views call this from `body` (the home map's avatar, the profile sheet, an outing's members),
    /// so every redraw used to base64-decode and JPEG-decode the photo again on the main thread.
    /// Decoded images are kept in a small bounded cache keyed by the data URL itself.
    static func image(from dataURL: String?) -> UIImage? {
        guard let s = dataURL, let comma = s.firstIndex(of: ","), s.hasPrefix("data:image/") else { return nil }
        _ = memoryWarning
        let key = s as NSString
        if let hit = decoded.object(forKey: key) { return hit }
        guard let img = Data(base64Encoded: String(s[s.index(after: comma)...])).flatMap(UIImage.init(data:)) else { return nil }
        /* Decode once now, so drawing the cached image never decodes it again. */
        let ready = img.preparingForDisplay() ?? img
        decoded.setObject(ready, forKey: key, cost: Int(ready.size.width * ready.size.height * ready.scale * ready.scale) * 4)
        return ready
    }

    /// Avatars are at most 192 px squares (`dataURL(from:)`): a few dozen fit in well under 8 MB.
    private static let decoded: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 64
        c.totalCostLimit = 8 * 1024 * 1024
        return c
    }()

    /// NSCache also evicts under pressure on its own; on a memory warning it is emptied outright.
    private static let memoryWarning: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
    ) { _ in
        AvatarCodec.decoded.removeAllObjects()
    }
}

extension OutingSummary {
    /// «بدأت قبل ٢ س» / «انتهت قبل ٣ ي» / «أُنشئت قبل ٥ د».
    func timeLabel(now: Date = Date()) -> String? {
        switch status {
        case .ended: return ISODate.parse(ended_at).map { "انتهت " + SaryFormat.elapsed(since: $0, now: now) }
        case .active, .paused: return ISODate.parse(started_at).map { "بدأت " + SaryFormat.elapsed(since: $0, now: now) }
        case .created: return ISODate.parse(created_at).map { "أُنشئت " + SaryFormat.elapsed(since: $0, now: now) }
        }
    }

    var participantsLabel: String { "\(SaryFormat.number(member_count)) \(member_count == 1 ? "مشارك" : (member_count == 2 ? "مشاركان" : "مشاركين"))" }
}
