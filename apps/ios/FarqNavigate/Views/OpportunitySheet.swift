import SwiftUI

/// The bottom sheet, carrying the same three things the web's does: what this
/// view holds, how fresh it is, and how to reorder it.
struct OpportunitySheet: View {
    let opportunities: [Opportunity]
    let comparisonsTotal: Int
    let freshness: String?
    @Binding var sort: OpportunitySort
    let onNavigate: (Opportunity) -> Void
    let onSelect: (Opportunity) -> Void

    private var biggest: Int { Int(opportunities.first?.gap ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(Farq.chipGround)
                .frame(width: 44, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 12)

            headline.padding(.horizontal, 16)

            FarqSortRail(sort: $sort)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(opportunities) { opportunity in
                        OpportunityCard(
                            opportunity: opportunity,
                            onNavigate: { onNavigate(opportunity) },
                            onSelect: { onSelect(opportunity) }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 20, y: -4)
    }

    private var headline: some View {
        VStack(alignment: .trailing, spacing: 3) {
            /* The web's own sentence: a count, then the largest single number in
             * it. Both observed, neither rounded into something friendlier. */
            Text("\(ArabicDigits.localize(opportunities.count)) فرصة في هذا النطاق · أكبرها \(ArabicDigits.localize(biggest)) ر.س")
                .font(Farq.font(15, .bold))
                .foregroundStyle(Farq.ink)
            if comparisonsTotal > 0 {
                Text("مبنية على \(ArabicDigits.localize(comparisonsTotal)) مقارنة مرصودة")
                    .font(Farq.font(11.5))
                    .foregroundStyle(Farq.inkSubtle)
            }
            if let freshness {
                Text(freshness)
                    .font(Farq.font(11.5))
                    .foregroundStyle(Farq.inkMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// One card, with the web's information hierarchy: the number first, then what
/// the number is about, then the evidence under it.
struct OpportunityCard: View {
    let opportunity: Opportunity
    let onNavigate: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            /* No destination means no button — an offer we cannot keep is worse
             * than no offer. The server decides this, not the app. */
            if opportunity.destination != nil {
                Button(action: onNavigate) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Farq.brand900)
                        .frame(width: 40, height: 40)
                        .background(Farq.mint, in: Circle())
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .trailing, spacing: 3) {
                Text("🔥 \(ArabicDigits.localize(Int(opportunity.gap ?? 0))) ر.س فرق")
                    .font(Farq.font(19, .extraBold))
                    .foregroundStyle(Farq.ink)

                Text(opportunity.productName ?? opportunity.name)
                    .font(Farq.font(14.5, .bold))
                    .foregroundStyle(Farq.ink)
                    .lineLimit(1)

                if opportunity.productName != nil, opportunity.productName != opportunity.name {
                    Text(opportunity.name)
                        .font(Farq.font(12.5))
                        .foregroundStyle(Farq.inkSubtle)
                        .lineLimit(1)
                }

                if let provider = opportunity.cheapestProvider, let price = opportunity.cheapestPrice {
                    Text("الأرخص: \(providerName(provider)) — \(ArabicDigits.localize(Int(price))) ر.س")
                        .font(Farq.font(12.5, .medium))
                        .foregroundStyle(Farq.mintStrong)
                }
                if let dearest = opportunity.expensivePrice {
                    Text("أعلى سعر مرصود — \(ArabicDigits.localize(Int(dearest))) ر.س")
                        .font(Farq.font(12.5))
                        .foregroundStyle(Color(hex: 0xB3202B))
                }
                if opportunity.comparisons > 0 {
                    Text("من \(ArabicDigits.localize(opportunity.comparisons)) مقارنة")
                        .font(Farq.font(11))
                        .foregroundStyle(Farq.inkMuted)
                }
                /* Only when the answer is weaker than the button implies. */
                if let caution = opportunity.navigateTo?.caution {
                    Text(caution)
                        .font(Farq.font(11))
                        .foregroundStyle(Color(hex: 0xC7911E))
                        .multilineTextAlignment(.trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
        .background(Farq.surfaceInset, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16).stroke(Farq.chipGround, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    /// The same Arabic names the web shows, not the raw provider keys.
    private func providerName(_ key: String) -> String {
        switch key {
        case "jahez": return "جاهز"
        case "hungerstation": return "هنقرستيشن"
        case "mrsool": return "مرسول"
        case "thechefz": return "ذا شفز"
        case "toyou": return "تويو"
        case "ninja": return "نينجا"
        case "keeta": return "كيتا"
        case "brand_app": return "تطبيق المطعم"
        default: return key
        }
    }
}
