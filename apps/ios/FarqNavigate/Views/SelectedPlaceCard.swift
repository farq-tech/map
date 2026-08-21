import SwiftUI

/// What one tapped pin is, and the one thing you can do about it.
///
/// The same numbers the card in the list shows, because they are the same
/// observation — a place that says 81 riyals on the map and something else in
/// the sheet is a product nobody can trust twice.
struct SelectedPlaceCard: View {
    let opportunity: Opportunity
    let onNavigate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Capsule()
                .fill(Farq.chipGround)
                .frame(width: 44, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)

            if let gap = opportunity.gap, gap > 0 {
                Text("🔥 \(ArabicDigits.localize(Int(gap.rounded()))) ر.س فرق")
                    .font(Farq.font(20, .extraBold))
                    .foregroundStyle(Farq.ink)
            }

            if let product = opportunity.productName, !product.isEmpty {
                Text(product)
                    .font(Farq.font(15, .bold))
                    .foregroundStyle(Farq.ink)
            }

            Text(opportunity.name)
                .font(Farq.font(13))
                .foregroundStyle(Farq.inkSubtle)

            if let cheapest = opportunity.cheapestPrice {
                Text("الأرخص: \(providerName(opportunity.cheapestProvider)) — \(ArabicDigits.localize(Int(cheapest.rounded()))) ر.س")
                    .font(Farq.font(14, .bold))
                    .foregroundStyle(Farq.mintStrong)
            }
            if let dearest = opportunity.expensivePrice {
                Text("أعلى سعر مرصود — \(ArabicDigits.localize(Int(dearest.rounded()))) ر.س")
                    .font(Farq.font(13))
                    .foregroundStyle(Color(hex: 0xB3202B))
            }
            Text("من \(ArabicDigits.localize(opportunity.comparisons)) مقارنة")
                .font(Farq.font(12))
                .foregroundStyle(Farq.inkMuted)

            if let caution = opportunity.navigateTo?.caution {
                Text(caution)
                    .font(Farq.font(12, .medium))
                    .foregroundStyle(Color(hex: 0xC7911E))
            }

            /* The button exists only when the server named a destination. A
             * navigate button that cannot navigate is worse than none. */
            if opportunity.destination != nil {
                Button(action: onNavigate) {
                    HStack(spacing: 8) {
                        Image(systemName: "location.fill")
                        Text("خذني هناك").font(Farq.font(15, .bold))
                    }
                    .foregroundStyle(Farq.brand900)
                    .frame(maxWidth: .infinity)
                    .frame(height: Farq.tapTarget)
                    .background(Farq.mint, in: Capsule())
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.ignoresSafeArea())
    }

    private func providerName(_ key: String?) -> String {
        switch key {
        case "jahez": return "جاهز"
        case "hungerstation": return "هنقرستيشن"
        case "mrsool": return "مرسول"
        case "thechefz": return "ذا شفز"
        case "toyou": return "تويو"
        case "ninja": return "نينجا"
        case "keeta": return "كيتا"
        case "brand_app": return "تطبيق المطعم"
        default: return "غير معروف"
        }
    }
}
