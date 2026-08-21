import SwiftUI

/// The chrome that sits over the map: the same header, search and chips the web
/// puts there, in the same order and the same shapes.
struct FarqTopChrome: View {
    @Binding var query: String
    @Binding var lens: DistrictLens
    let districtLabel: String
    let onPickDistrict: () -> Void
    /// Your photo, shown where the menu button is once you have chosen one.
    let avatar: UIImage?
    let onOpenProfile: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            header
            searchBar
            chips
        }
        .padding(.horizontal, 12)
    }

    /// The wordmark on its dark pill, exactly where the web puts it.
    private var header: some View {
        HStack {
            Spacer()
            Button(action: onOpenProfile) {
                HStack(spacing: 10) {
                    Text("Farq")
                        .font(.custom("Tajawal-Bold", size: 22))
                        .foregroundStyle(Farq.mint)
                    if let avatar {
                        Image(uiImage: avatar)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 28, height: 28)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Farq.mint, lineWidth: 1.5))
                    } else {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: Farq.tapTarget)
                .background(Farq.brand900, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Farq.inkMuted)
            TextField("", text: $query, prompt:
                Text("ابحث أو اسأل فرق: وين أكبر فرق حولي؟")
                    .font(Farq.font(14))
                    .foregroundColor(Farq.inkMuted)
            )
            .font(Farq.font(14))
            .foregroundStyle(Farq.ink)
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(.white, in: Capsule())
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    /// «اختر حي» and the lens switch, the two controls the web keeps on the map.
    ///
    /// On a phone these two together are wider than the screen, and an overflowing
    /// row does not fail loudly — it quietly cuts the ends off both controls. The
    /// district chip gives up its label first because the lens switch is the one
    /// that changes what the map means.
    private var chips: some View {
        HStack(spacing: 6) {
            Button(action: onPickDistrict) {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 13, weight: .medium))
                    Text(districtLabel)
                        .font(Farq.font(12.5, .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Farq.ink)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(.white, in: Capsule())
            }

            /* One switch, two states, and the selected one carries the dark
             * ground the web gives it — the lens decides what the whole screen
             * means, so it is never a subtle control. */
            HStack(spacing: 4) {
                lensButton(.gap, "الفرص")
                lensButton(.app, "التطبيق الأرخص")
            }
            .padding(3)
            .background(.white, in: Capsule())
            .layoutPriority(1)

            Spacer(minLength: 0)
        }
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private func lensButton(_ value: DistrictLens, _ label: String) -> some View {
        Button { lens = value } label: {
            Text(label)
                .font(Farq.font(13, .medium))
                .foregroundStyle(lens == value ? .white : Farq.ink)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(lens == value ? Farq.brand900 : .clear, in: Capsule())
        }
    }
}

/// What the colour of a حي means. Mirrors the web's lens switch.
enum DistrictLens: String { case gap, app }

/// How the list is ordered. The same four the web offers, in the same order,
/// with the same default — biggest observed gap, because that is what someone
/// came for.
enum OpportunitySort: String, CaseIterable {
    case near, gap, cheap, value

    var label: String {
        switch self {
        case .near: return "الأقرب"
        case .gap: return "أكبر فرق"
        case .cheap: return "الأرخص"
        case .value: return "الأعلى نسبة"
        }
    }
}

struct FarqSortRail: View {
    @Binding var sort: OpportunitySort

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OpportunitySort.allCases, id: \.self) { option in
                Button { sort = option } label: {
                    Text(option.label)
                        .font(Farq.font(13, .medium))
                        .foregroundStyle(Farq.ink)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(
                            Capsule().fill(sort == option ? Farq.mint : .white)
                        )
                        .overlay(
                            Capsule().stroke(
                                sort == option ? Farq.mint : Farq.chipGround,
                                lineWidth: 1
                            )
                        )
                }
            }
        }
    }
}
