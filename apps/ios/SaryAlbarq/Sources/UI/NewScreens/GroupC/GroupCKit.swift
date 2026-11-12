import SwiftUI

// Build 47 — screens group C (communication and safety) in the new interface (`NewUI.enabled`).
// One window frame for the group: the unified title (large title right, 44 pt ✕ left), content that
// scrolls, an optional pinned bottom area for the screen's ONE primary button. Built on the
// foundations (`SaryWindowTitle`, `SaryPrimaryButton`, `SarySecondaryButton`, `SaryStateView`);
// swap to the shared components PR when it lands.

struct GroupCPage<Content: View, Bottom: View>: View {
    var title: String
    var subtitle: String?
    var closeID: String
    var onClose: () -> Void
    var scrolls: Bool
    @ViewBuilder var content: Content
    @ViewBuilder var bottom: Bottom
    @Environment(\.sary) private var theme

    init(_ title: String, subtitle: String? = nil, closeID: String = "window-close", scrolls: Bool = true,
         onClose: @escaping () -> Void,
         @ViewBuilder content: () -> Content, @ViewBuilder bottom: () -> Bottom) {
        self.title = title; self.subtitle = subtitle; self.closeID = closeID; self.scrolls = scrolls
        self.onClose = onClose; self.content = content(); self.bottom = bottom()
    }

    var body: some View {
        let p = theme.palette
        VStack(spacing: 0) {
            SaryWindowTitle(title, closeID: closeID, onClose: onClose)
            if let subtitle {
                Text(subtitle)
                    .saryType(.body)
                    .foregroundStyle(p.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SarySpace.l.rawValue)
                    .padding(.bottom, SarySpace.s.rawValue)
            }
            if scrolls {
                ScrollView {
                    VStack(alignment: .leading, spacing: SarySpace.l.rawValue) { content }
                        .padding(.horizontal, SarySpace.l.rawValue)
                        .padding(.top, SarySpace.s.rawValue)
                        .padding(.bottom, SarySpace.l.rawValue)
                        .saryReadableWidth()
                }
                .scrollDismissesKeyboard(.interactively)
            } else {
                content
                    .padding(.horizontal, SarySpace.l.rawValue)
                    .saryReadableWidth()
                Spacer(minLength: 0)
            }
            if Bottom.self != EmptyView.self {
                VStack(spacing: SarySpace.s.rawValue) { bottom }
                    .padding(.horizontal, SarySpace.l.rawValue)
                    .padding(.top, SarySpace.s.rawValue)
                    .padding(.bottom, SarySpace.m.rawValue)
                    .saryReadableWidth()
            }
        }
        .background(p.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

extension GroupCPage where Bottom == EmptyView {
    init(_ title: String, subtitle: String? = nil, closeID: String = "window-close", scrolls: Bool = true,
         onClose: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.init(title, subtitle: subtitle, closeID: closeID, scrolls: scrolls, onClose: onClose,
                  content: content, bottom: { EmptyView() })
    }
}

/// The emergency button: red `emergency` fill, white text, same 58 pt as the primary. Used only for
/// «اتصل ٩١١» / «اطلب إنجاد»; never as a second primary.
struct GroupCEmergencyButton: View {
    var title: String
    var systemImage: String?
    var id: String
    var action: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        Button(action: action) { SaryButtonLabel(title: title, systemImage: systemImage) }
            .buttonStyle(.sary(.destructive))
            .accessibilityIdentifier(id)
    }
}

/// A calm info card (dark surface, hairline) for notes and previews.
struct GroupCCard<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.sary) private var theme
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SaryRadius.card, style: .continuous)
        content
            .padding(SarySpace.m.rawValue)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(theme.palette.surface))
            .overlay(shape.strokeBorder(theme.palette.stroke, lineWidth: 1))
    }
}

/// The chat list's page: the legacy `SaryPage` unless the new interface is on, then the unified
/// window title with «N في الطلعة» under it.
struct ChatHomePage<Content: View>: View {
    var outingName: String
    var count: Int
    var close: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        if NewUI.enabled {
            GroupCPage("المحادثات", subtitle: "\(outingName) · \(SaryFormat.digits(String(count))) في الطلعة",
                       closeID: "chat.home.close", onClose: close) { content }
        } else {
            SaryPage(title: "المحادثات", subtitle: outingName, close: close) { content }
        }
    }
}
