import SwiftUI

// Build 47 — screens group C (communication and safety) in the new interface (`NewUI.enabled`).
// The screens of this group are built on the shared kit (`SaryScreenScaffold`, `SaryListGroup`,
// `SaryPrimaryButton`/`SarySecondaryButton`, `.sary(.destructive)`); only the chat list's page switch lives here.

/// The chat list's page: the legacy `SaryPage` unless the new interface is on, then the unified
/// window title with «N في الطلعة» under it.
struct ChatHomePage<Content: View>: View {
    var outingName: String
    var count: Int
    var close: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        if NewUI.enabled {
            SaryScreenScaffold(title: "المحادثات", subtitle: "\(outingName) · \(SaryFormat.digits(String(count))) في الطلعة",
                               closeID: "chat.home.close", onClose: close) {
                VStack(alignment: .leading, spacing: SarySpace.l.rawValue) { content }
            }
        } else {
            SaryPage(title: "المحادثات", subtitle: outingName, close: close) { content }
        }
    }
}
