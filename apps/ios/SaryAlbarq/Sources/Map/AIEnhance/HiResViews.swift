import SwiftUI

/// «الطبقات» → «صور عالية الوضوح» (default ON). Neutral wording by owner decision; the
/// subtitle is the one disclosure: enhanced detail is estimated.
struct HiResLayerSection: View {
    @ObservedObject var settings = HiResSettings.shared
    @Environment(\.sary) private var theme

    var body: some View {
        SarySection(title: "الصورة") {
            SaryToggleRow(title: "صور عالية الوضوح", subtitle: "قد تتضمن الصورة تفاصيل تقديرية عند التقريب",
                          systemImage: "photo.fill", isOn: $settings.userOn, id: "explore-hires")
                .padding(.horizontal, theme.space(.m))
        }
    }
}

/// «حول سَرى البارق» → «مصادر»: the BSD-3-Clause notice the licence requires for the
/// bundled model (copyright line, conditions and disclaimer, from the bundled LICENSE file).
struct HiResLicenseNotice: View {
    @State private var open = false
    @Environment(\.sary) private var theme

    static var text: String {
        Bundle.main.url(forResource: "Real-ESRGAN-LICENSE", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "BSD 3-Clause License — Copyright (c) 2021, Xintao Wang"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(.xs)) {
            Text("تحسين الصور عند التقريب: Real-ESRGAN © 2021 Xintao Wang، برخصة BSD-3-Clause.")
            Button(open ? "إخفاء نص الرخصة" : "نص الرخصة") { open.toggle() }
                .saryText(.footnote, weight: .bold)
                .accessibilityIdentifier("about.hires-license")
            if open {
                Text(Self.text)
                    .font(.system(size: 11, design: .monospaced))
                    .environment(\.layoutDirection, .leftToRight)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }
}
