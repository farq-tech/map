import SwiftUI

/// «إنهاء الرحلة» / «إنهاء الطلعة»: the one place that ends something (EndControls). Each row says in one sentence
/// what happens to the guidance, to my location sharing and to the others, and the tap on it is the decision.
struct EndChoiceSheet: View {
    var state: EndControls.State
    var choose: (EndControls.Action) -> Void
    var close: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let actions = EndControls.offered(state)
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space(.m)) {
                HStack {
                    Text(EndControls.sheetTitle(state)).font(.sary(18, .bold)).foregroundStyle(p.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    SaryIconButton(systemImage: SaryIcon.close, label: "رجوع", id: "end.cancel", visual: 36, action: close)
                }
                ForEach(actions, id: \.self) { a in
                    let red = EndControls.isDestructive(a)
                    Button { choose(a) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(EndControls.title(a)).saryText(.body, weight: .bold)
                                .foregroundStyle(red ? p.emergencyText : p.textPrimary)
                            Text(EndControls.sentence(a, guiding: state.guiding)).saryText(.footnote)
                                .foregroundStyle(p.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(theme.space(.m))
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SaryRowPressStyle())
                    .sarySurface(radius: SaryRadius.l)
                    .overlay(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous).stroke(red ? p.emergency.opacity(0.5) : .clear, lineWidth: 1.5))
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier(EndControls.identifier(a))
                }
                if actions.isEmpty {
                    Text("ما فيه شي تنهيه الحين.").saryText(.footnote).foregroundStyle(p.textSecondary)
                }
            }
            .padding(.horizontal, theme.space(.l))
            .padding(.vertical, theme.space(.m))
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("end.sheet")
    }
}
