import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

// MARK: - Empty / loading / error / offline

enum SaryStateKind: Equatable {
    case loading(String)
    case empty(title: String, message: String?, systemImage: String)
    case error(title: String, message: String?)
    case offline(message: String?)

    var isLoading: Bool { if case .loading = self { return true }; return false }
}

struct SaryStateView: View {
    var kind: SaryStateKind
    var actionTitle: String?
    var actionID: String = "state-action"
    /// The action's symbol; retry by default, nil for none (e.g. «حسنًا»).
    var actionIcon: String? = SaryIcon.retry
    var action: () -> Void = {}
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(spacing: theme.space(.m)) {
            /* A stack, not a Group: `.id` / `.transition` must land on ONE view. */
            VStack(spacing: theme.space(.m)) {
                switch kind {
                case .loading(let title):
                    ProgressView().controlSize(.large).tint(p.accent)
                        .frame(height: 52)
                    Text(title).saryText(.callout).foregroundStyle(p.textSecondary)
                case .empty(let title, let message, let symbol):
                    glyph(symbol, color: p.textTertiary)
                    texts(title, message)
                case .error(let title, let message):
                    glyph(SaryIcon.error, color: p.emergencyText)
                    texts(title, message)
                case .offline(let message):
                    glyph(SaryIcon.offline, color: p.warningText)
                    texts("بلا إنترنت", message ?? "نعرض آخر ما وصلنا، ونحدّث أول ما يرجع الاتصال")
                }
            }
            /* loading → empty / error / offline: the new state settles in where the old one was. */
            .id(Self.phase(kind))
            .transition(SaryTransition.appear(theme))
            if let actionTitle, !kind.isLoading {
                Button(action: action) { SaryButtonLabel(title: actionTitle, systemImage: actionIcon) }
                    .buttonStyle(.sary(.secondary, width: .hug, compact: true))
                    .accessibilityIdentifier(actionID)
                    .padding(.top, theme.space(.xs))
            }
        }
        .padding(theme.space(.xxl))
        .saryAnimation(.appear, value: Self.phase(kind))
        /* Centred column on iPad: the message never runs across a 1000 pt line. */
        .saryReadableWidth(SaryLayout.formWidth)
        .accessibilityElement(children: .contain)
    }

    /// Which state is shown, without its texts: what the state transition keys on.
    static func phase(_ kind: SaryStateKind) -> Int {
        switch kind {
        case .loading: return 0
        case .empty: return 1
        case .error: return 2
        case .offline: return 3
        }
    }

    private func glyph(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 64, height: 64)
            .background(Circle().fill(theme.palette.sunken))
            /* Decorative and hidden from VoiceOver, so it may start transparent. */
            .saryAppearOnMount()
            .accessibilityHidden(true)
    }

    private func texts(_ title: String, _ message: String?) -> some View {
        VStack(spacing: theme.space(.xs)) {
            Text(title).saryText(.headline).foregroundStyle(theme.palette.textPrimary)
            if let message {
                Text(message).saryText(.subhead).foregroundStyle(theme.palette.textSecondary)
            }
        }
        .multilineTextAlignment(.center)
    }
}

/// The empty / error state INSIDE a section or card, where `SaryStateView`'s centred column is
/// too big: a glyph in a sunken circle, one line that says what happened and what to do, and an
/// optional secondary action. Never a bare grey sentence.
struct SaryInlineState: View {
    var systemImage: String
    var text: String
    var tone: SaryTone = .info
    var actionTitle: String? = nil
    var actionIcon: String? = nil
    var actionID: String? = nil
    var action: () -> Void = {}
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let ink: Color = {
            switch tone {
            case .info: return p.textTertiary
            case .success: return p.liveText
            case .warning: return p.warningText
            case .error: return p.emergencyText
            }
        }()
        VStack(alignment: .leading, spacing: theme.space(.s)) {
            HStack(alignment: .center, spacing: theme.space(.m)) {
                Image(systemName: systemImage)
                    .saryGlyph(15, weight: .semibold, relativeTo: .subheadline)
                    .foregroundStyle(ink)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(p.sunken))
                    .accessibilityHidden(true)
                Text(text)
                    .saryText(.subhead)
                    .foregroundStyle(p.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let actionTitle {
                Button(action: action) { SaryButtonLabel(title: actionTitle, systemImage: actionIcon) }
                    .buttonStyle(.sary(.secondary, width: .hug, compact: true))
                    .modifier(OptionalIdentifier(id: actionID))
            }
        }
        .padding(.vertical, theme.space(.s))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// Placeholder rows while loading. Shimmer only when motion is allowed.
struct SarySkeletonRow: View {
    @Environment(\.sary) private var theme

    var body: some View {
        let fill = theme.palette.textPrimary.opacity(theme.isLight ? 0.08 : 0.09)
        HStack(spacing: theme.space(.m)) {
            Circle().fill(fill).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(fill).frame(width: 120, height: 12)
                Capsule().fill(fill).frame(width: 70, height: 10)
            }
            Spacer()
            Capsule().fill(fill).frame(width: 48, height: 12)
        }
        .padding(.vertical, theme.space(.s))
        .padding(.horizontal, theme.space(.m))
        /* Stops off-screen, in the background, in drive mode and under Reduce Motion. */
        .saryPulse(.skeleton, style: .dim)
        .accessibilityHidden(true)
    }
}

/// Thin banner (inside sheets / screens): offline, retrying, info.
struct SaryBanner: View {
    var text: String
    var tone: SaryTone = .warning
    var systemImage: String?
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let c: Color = {
            switch tone {
            case .info: return p.textSecondary
            case .success: return p.live
            case .warning: return p.warning
            case .error: return p.emergency
            }
        }()
        HStack(spacing: theme.space(.s)) {
            Image(systemName: systemImage ?? (tone == .error ? SaryIcon.error : SaryIcon.warning))
                .font(.system(size: 13, weight: .bold))
            Text(text).saryText(.footnote, weight: .bold).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .foregroundStyle({ () -> Color in
            switch tone {
            case .info: return c
            /* Text tones keep ≥ 4.5:1; the fills above are only for the tinted background. */
            case .success: return p.liveText
            case .warning: return p.warningText
            case .error: return p.emergencyText
            }
        }())
        .padding(.horizontal, theme.space(.m))
        .padding(.vertical, theme.space(.s))
        .background(RoundedRectangle(cornerRadius: SaryRadius.s, style: .continuous).fill(c.opacity(0.14)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Dialog (in-app confirmation card)

/// For confirmations that need more than the system alert can show (e.g.
/// ending an outing for everyone). Simple yes/no prompts should use the
/// system `.confirmationDialog` / `.alert` — this is for richer ones.
struct SaryDialog: View {
    var systemImage: String
    var title: String
    var message: String
    var confirmTitle: String
    var confirmKind: SaryButtonKind = .destructive
    var cancelTitle = "إلغاء"
    var busy = false
    var confirm: () -> Void = {}
    var cancel: () -> Void = {}
    @Environment(\.sary) private var theme
    @Environment(\.saryWidthClass) private var widthClass

    var body: some View {
        let p = theme.palette
        VStack(spacing: theme.space(.l)) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(confirmKind == .destructive ? p.emergencyText : p.accentText)
                .frame(width: 60, height: 60)
                .background(Circle().fill((confirmKind == .destructive ? p.emergency : p.accent).opacity(0.14)))
                .accessibilityHidden(true)
            VStack(spacing: theme.space(.xs) + 2) {
                Text(title).saryText(.title2).foregroundStyle(p.textPrimary)
                Text(message).saryText(.callout).foregroundStyle(p.textSecondary)
            }
            .multilineTextAlignment(.center)
            VStack(spacing: theme.space(.s)) {
                Button(action: confirm) { SaryButtonLabel(title: confirmTitle, busy: busy) }
                    .buttonStyle(.sary(confirmKind))
                    .accessibilityIdentifier("dialog.confirm")
                    .disabled(busy)
                Button(cancelTitle, action: cancel).buttonStyle(.sary(.secondary))
            }
        }
        /* 24 pt inside + 16 pt outside leave 240 pt of text on a 320 pt screen: tighter there. */
        .padding(theme.space(widthClass == .narrow ? .l : .xxl))
        .background(RoundedRectangle(cornerRadius: SaryRadius.xl, style: .continuous).fill(p.elevated))
        .overlay(RoundedRectangle(cornerRadius: SaryRadius.xl, style: .continuous).stroke(p.stroke, lineWidth: 0.5))
        .saryShadow(.overlay, theme)
        .frame(maxWidth: SaryLayout.dialogWidth)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

// MARK: - QR (generated on device)

struct SaryQRCode: View {
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
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous))
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
