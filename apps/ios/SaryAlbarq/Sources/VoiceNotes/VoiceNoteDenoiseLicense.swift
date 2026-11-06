import SwiftUI

/// «حول سَرى البارق» → «مصادر»: DeepFilterNet3 (the voice-note noise suppression), MIT notice
/// from the bundled LICENSE file (code and weights are MIT OR Apache-2.0; MIT is used).
struct VoiceDenoiseLicenseNotice: View {
    @State private var open = false
    @Environment(\.sary) private var theme

    static var text: String {
        Bundle.main.url(forResource: "DeepFilterNet-LICENSE", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "MIT License — Copyright (c) 2021 Hendrik Schröter"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(.xs)) {
            Text("تنقية الرسائل الصوتية: DeepFilterNet © 2021 Hendrik Schröter، برخصة MIT.")
            Button(open ? "إخفاء نص الرخصة" : "نص الرخصة") { open.toggle() }
                .saryText(.footnote, weight: .bold)
                .accessibilityIdentifier("about.denoise-license")
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
