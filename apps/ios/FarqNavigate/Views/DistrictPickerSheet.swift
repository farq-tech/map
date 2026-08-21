import MapboxMaps
import SwiftUI

/// One حي, as the list needs it. Everything here is the server's own number.
struct DistrictChoice: Identifiable, Equatable {
    let id: String
    let name: String
    let opportunities: Int
    let maxGap: Int
    /// west, south, east, north — the حي's own extent, so choosing it can frame it.
    let bbox: [Double]?

    /// Reads the city's boundaries as the API sent them. A حي missing a name or
    /// an id is skipped rather than shown as "unknown": a list of places you
    /// cannot identify is not a list.
    static func from(_ collection: FeatureCollection?) -> [DistrictChoice] {
        guard let collection else { return [] }
        return collection.features.compactMap { feature -> DistrictChoice? in
            let properties = feature.properties
            guard case .string(let id)? = properties?["district_id"] ?? nil,
                  case .string(let name)? = properties?["name_ar"] ?? nil,
                  !name.isEmpty
            else { return nil }
            var opportunities = 0
            if case .number(let value)? = properties?["opportunities"] ?? nil {
                opportunities = Int(value)
            }
            var maxGap = 0
            if case .number(let value)? = properties?["max_gap"] ?? nil {
                maxGap = Int(value)
            }
            var bbox: [Double]?
            if case .array(let raw)? = properties?["bbox"] ?? nil {
                let numbers = raw.compactMap { entry -> Double? in
                    if case .number(let value)? = entry { return value }
                    return nil
                }
                if numbers.count == 4 { bbox = numbers }
            }
            return DistrictChoice(
                id: id, name: name,
                opportunities: opportunities, maxGap: maxGap, bbox: bbox
            )
        }
        /* Busiest first: the question is where the differences are, and a
         * hundred أحياء in alphabetical order does not answer it. */
        .sorted { $0.opportunities > $1.opportunities }
    }
}

struct DistrictPickerSheet: View {
    let districts: [DistrictChoice]
    let selectedId: String?
    let onPick: (DistrictChoice) -> Void
    let onClear: () -> Void
    @State private var query = ""

    private var shown: [DistrictChoice] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return districts }
        return districts.filter { $0.name.contains(needle) }
    }

    var body: some View {
        VStack(spacing: 12) {
            Capsule()
                .fill(Farq.chipGround)
                .frame(width: 44, height: 5)
                .padding(.top, 10)

            HStack {
                Text("اختر حي")
                    .font(Farq.font(19, .extraBold))
                    .foregroundStyle(Farq.ink)
                Spacer()
                if selectedId != nil {
                    Button("كل الرياض", action: onClear)
                        .font(Farq.font(13, .medium))
                        .foregroundStyle(Farq.mintStrong)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(Farq.inkMuted)
                TextField("", text: $query, prompt:
                    Text("ابحث عن حي").font(Farq.font(14)).foregroundColor(Farq.inkMuted))
                    .font(Farq.font(14))
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Farq.surfaceInset, in: Capsule())

            if shown.isEmpty {
                Text("ما فيه حي بهذا الاسم")
                    .font(Farq.font(13))
                    .foregroundStyle(Farq.inkMuted)
                    .padding(.top, 20)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(shown) { district in
                        Button { onPick(district) } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(district.name)
                                        .font(Farq.font(15, .bold))
                                        .foregroundStyle(Farq.ink)
                                    Text("\(ArabicDigits.localize(district.opportunities)) فرصة · أكبرها \(ArabicDigits.localize(district.maxGap)) ر.س")
                                        .font(Farq.font(12))
                                        .foregroundStyle(Farq.inkMuted)
                                }
                                Spacer(minLength: 0)
                                if district.id == selectedId {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Farq.mintStrong)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(district.id == selectedId ? Farq.surfaceInset : .white)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Farq.chipGround, lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .padding(.horizontal, 20)
        .background(Color.white.ignoresSafeArea())
    }
}
