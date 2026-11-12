import SwiftUI

/// «الطبقات»: the shared layers sheet (docs/ONE-MAP-UNIFICATION.md §6). The base-map cards AND the data layers
/// (weather, camp sites, OSM tracks, high-res imagery, 3D terrain) are generated from `MapLayerRegistry`;
/// only the action rows (camp suggestion, desert route, realistic mode, offline maps) are written by hand.
/// Same accessibility identifiers as the old `ExploreLayersSheet`, so every existing UI test keeps working.
struct MapLayersSheet: View {
    /// The live map's controller (explore / outing); nil on the home map, which has no outing: only the registry's rows show there.
    var controller: LiveOutingController?
    var mode: MapLayerMode = .explore
    /// Closes the sheet (the live screen clears its modal; the home map its own flag).
    var close: () -> Void
    /// Told when a base layer is chosen, so a map that does not read the controller (home) can follow.
    var onBaseChosen: ((MapLayer) -> Void)? = nil
    @ObservedObject private var registry = MapLayerRegistry.shared
    @ObservedObject private var offline = OfflineMaps.shared
    @ObservedObject private var weather = WeatherLayers.shared
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let rows = MapLayersSheetModel.baseRows(registry: registry, mode: mode, areas: offline.completeAreas, topoAreas: offline.topoAreas)
        VStack(spacing: 0) {
        SaryPage(title: "الطبقات", close: close) {
            quickWeatherRow
            VStack(spacing: theme.space(.s)) {
                ForEach(rows) { row in
                    Button { choose(row.id) } label: {
                        HStack(spacing: theme.space(.m)) {
                            Image(systemName: row.systemImage)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(row.isSelected ? p.onAccent : p.accentText)
                                .frame(width: 46, height: 46)
                                .background(RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous).fill(row.isSelected ? p.accent : p.accent.opacity(0.14)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).saryText(.body, weight: .bold).foregroundStyle(p.textPrimary)
                                Text(row.detail).saryText(.footnote).foregroundStyle(p.textSecondary)
                                if let note = row.note {
                                    Text(note).saryText(.caption, weight: .bold)
                                        .foregroundStyle(row.noteIsPositive ? p.liveText : p.textTertiary)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: row.isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(row.isSelected ? p.accent : p.textTertiary)
                        }
                        .padding(theme.space(.m))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SaryRowPressStyle())
                    .sarySurface(radius: SaryRadius.l)
                    .overlay(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous).stroke(row.isSelected ? p.accent : .clear, lineWidth: 2))
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(row.isSelected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier(row.testID)
                }
            }
            ForEach(MapLayersSheetModel.sections(registry: registry, mode: mode)) { section in
                sectionView(section)
            }
            actionSections
        }
        /* The floating SOS disc (its own window, bottom left, over every sheet) used to sit on top of the last visible rows
         * while the sheet scrolled. The scroll area now ends above the disc's strip, so a row is never under it. */
        Color.clear.frame(height: MapLayersSheetModel.sosReserve(disc: theme.bigButton, small: theme.space(.s)))
            .background(p.background)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onAppear { offline.reload(); MapLayerOwners.pull(registry, controller: controller) }
        .onReceive(MapLayerOwners.changes(controller: controller)) { MapLayerOwners.pull(registry, controller: controller) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("explore.layers.sheet")
    }

    // MARK: Quick weather

    /// «السحاب» / «المطر» / «الرياح» as three chips above the base maps: one tap turns the layer on (or off), also from guidance.
    @ViewBuilder private var quickWeatherRow: some View {
        let chips = MapLayersSheetModel.quickWeather(registry: registry, mode: mode)
        if !chips.isEmpty {
            let p = theme.palette
            HStack(spacing: theme.space(.s)) {
                ForEach(chips) { c in
                    Button { toggle(c.id, !c.isOn) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: c.systemImage).font(.system(size: 18, weight: .semibold))
                            Text(WeatherOverlayKind.quickName(MapLayerCatalog.weatherKind(c.id) ?? .none)).saryText(.footnote, weight: .bold)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .foregroundStyle(c.isOn ? p.onAccent : p.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous).fill(c.isOn ? p.accent : p.sunken))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SaryPressStyle())
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(c.isOn ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier(c.testID)
                }
            }
            .padding(.bottom, theme.space(.s))
        }
    }

    // MARK: Generated sections

    @ViewBuilder private func sectionView(_ section: MapLayerSection) -> some View {
        SarySection(title: section.title, footer: footer(for: section)) {
            switch section.style {
            case .singleSelect: singleSelect(section)
            case .switches:
                VStack(spacing: theme.space(.s)) {
                    ForEach(section.rows) { r in
                        if r.id == MapLayerCatalog.terrain.id {
                            terrainRow(r)
                        } else {
                            SaryToggleRow(title: r.title, subtitle: r.detail.isEmpty ? nil : r.detail, systemImage: r.systemImage,
                                          isOn: Binding(get: { registry.isActive(r.id) }, set: { toggle(r.id, $0) }), id: r.testID)
                                .padding(.horizontal, theme.space(.m))
                        }
                        if r.id == MapLayerCatalog.camp.id {
                            if let controller {
                            SaryNavRow(title: "اقترح لي مكان كشتة", detail: "أفضل خمسة مواقع وطقس الليلة", systemImage: "tent", id: "explore-camp-suggest") {
                                controller.performAction("camp")
                            }
                            .padding(.horizontal, theme.space(.m))
                            }
                        }
                    }
                }
            }
        }
    }

    /// 3D terrain keeps its button look («شغّال/طافي») and its identifier, as before.
    private func terrainRow(_ r: MapLayerSwitchRow) -> some View {
        let p = theme.palette
        let on = registry.isActive(r.id)
        return Button { toggle(r.id, !on) } label: {
            HStack(spacing: theme.space(.m)) {
                SaryRowIcon(systemImage: r.systemImage, color: on ? p.accent : nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title).saryText(.body, weight: .medium).foregroundStyle(p.textPrimary)
                    Text(r.detail).saryText(.footnote).foregroundStyle(p.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(on ? "شغّال" : "طافي")
                    .saryText(.footnote, weight: .bold)
                    .foregroundStyle(on ? p.onAccent : p.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(on ? p.accent : p.sunken))
            }
            .frame(minHeight: theme.minTarget)
            .padding(.vertical, theme.space(.xs))
            .contentShape(Rectangle())
        }
        .buttonStyle(SaryRowPressStyle())
        .padding(.horizontal, theme.space(.m))
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(on ? "شغّال" : "طافي"))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(r.testID)
    }

    /// Weather: «بدون» + one row per registered kind, one at a time, and the rain period under «وين نزل مطر».
    private func singleSelect(_ section: MapLayerSection) -> some View {
        let p = theme.palette
        return VStack(spacing: 0) {
            /* «بدون» first, as in the old sheet. */
            if let off = section.off {
                optionRow(title: off.title, detail: off.detail, systemImage: off.systemImage, on: off.isSelected, id: off.testID) {
                    if let current = section.rows.first(where: { $0.isOn }) { toggle(current.id, false) }
                }
            }
            if section.off != nil { SaryDivider() }
            ForEach(Array(section.rows.enumerated()), id: \.element.id) { i, r in
                optionRow(title: r.title, detail: r.detail, systemImage: r.systemImage, on: r.isOn, id: r.testID) { toggle(r.id, true) }
                if MapLayerCatalog.weatherKind(r.id) == .rain && r.isOn {
                    SarySegmented(options: WeatherLayers.allowedDays, selection: $weather.rainDays,
                                  label: { WeatherLayers.daysLabel($0) }, optionID: { "weather.rain.days.\($0)" })
                        .padding(.bottom, theme.space(.s))
                }
                if i < section.rows.count - 1 { SaryDivider() }
            }
        }
        .padding(.horizontal, theme.space(.m))
        .foregroundStyle(p.textPrimary)
    }

    private func optionRow(title: String, detail: String, systemImage: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        let p = theme.palette
        return Button(action: action) {
            HStack(spacing: theme.space(.m)) {
                SaryRowIcon(systemImage: systemImage, color: on ? p.accent : p.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).saryText(.body, weight: .medium).foregroundStyle(p.textPrimary)
                    Text(detail).saryText(.footnote).foregroundStyle(p.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(on ? p.accent : p.textTertiary)
            }
            .frame(minHeight: theme.minTarget)
            .padding(.vertical, theme.space(.xs))
            .contentShape(Rectangle())
        }
        .buttonStyle(SaryRowPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(id)
    }

    /// Sources and licences stay next to the layers they belong to.
    private func footer(for section: MapLayerSection) -> String? {
        switch section.id {
        case "group.الطقس": return WeatherLayersSection.footer(for: weather.kind)
        case "group.\(MapLayerCatalog.imageryGradeGroup)":
            return "تغيّر ألوان صور الأقمار فقط (الرمل والسيارات والمدن تبقى كما هي). «طبيعي» الأقرب للصورة الحقيقية."
        case "category.data":
            var parts: [String] = []
            if section.rows.contains(where: { $0.id == MapLayerCatalog.camp.id }) {
                parts.append("\(CampReason.estimateNote). مواقع مرشحة من صور أقمار وبيانات مفتوحة (الثمامة، الدهناء، النفود)، بعيدة عن مجاري السيول والسبخات والعمران. \(CampReason.legalNote).")
            }
            if section.rows.contains(where: { $0.id == MapLayerCatalog.osmTracks.id }) {
                parts.append("مسارات البر: طبعات البر من بيانات OpenStreetMap، تظهر من تقريب متوسط في الاستكشاف وأثناء القيادة خارج الطرق. \(OffroadTracks.attribution)")
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        case "category.terrain":
            return section.rows.contains(where: { $0.id == MapLayerCatalog.terrain.id })
                ? "الارتفاع عند علامة الوسط من نموذج الارتفاع، ويظهر «غير متاح» لين تنزل بيانات المنطقة." : nil
        default: return nil
        }
    }

    // MARK: Actions (not layers)

    @ViewBuilder private var actionSections: some View {
        if let controller {
        SarySection(title: "دروب البر", footer: "اختر مسارًا مقترحًا للوجهة من بيانات صور الأقمار. تظهر الخيارات عند تحديد وجهة للطلعة.") {
            SaryNavRow(title: "مسار برّي إلى الوجهة", detail: "الأسهل أو المتوازن أو الأقصر",
                       systemImage: "point.topleft.down.to.point.bottomright.filled.curvepath", id: "explore-desert-route") {
                controller.performAction("desertRoute")
            }
            .padding(.horizontal, theme.space(.m))
        }
        SarySection(title: "الوضع الواقعي", footer: "مدن مجسّمة بصور Apple، وأنت واقف (مو أثناء القيادة).") {
            SaryNavRow(title: "الوضع الواقعي", detail: "شوف المكان مجسّم من فوق", systemImage: RealisticEntryButton.icon, id: "explore-realistic") {
                controller.modal = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { controller.realisticRequest += 1 }
            }
            .padding(.horizontal, theme.space(.m))
        }
        SarySection(title: "بلا إنترنت") {
            SaryNavRow(title: "الخرائط بلا إنترنت",
                       detail: offline.completeAreas > 0
                           ? "\(SaryFormat.number(offline.completeAreas)) منطقة محفوظة · \(SaryFormat.number(offline.topoAreas)) منها مع الطبوغرافي"
                           : "ما حفظت مناطق بعد",
                       systemImage: "arrow.down.circle.fill", id: "explore-offline") {
                controller.modal = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { controller.modal = .offlineMaps }
            }
            .padding(.horizontal, theme.space(.m))
        }
        }
    }

    /// A data layer on/off: the registry stores it (under the key the app always used), then the object that draws it is told.
    private func toggle(_ id: MapLayerID, _ on: Bool) {
        registry.setActive(id, on)
        MapLayerOwners.push(registry, controller: controller)
    }

    /// The registry keeps the stored choice; the controller keeps driving the live map (it also writes
    /// the same key through `MapLayer.saved`, so both always agree).
    private func choose(_ id: MapLayerID) {
        registry.setActive(id)
        if let legacy = MapLayerCatalog.legacy(id) {
            controller?.mapLayer = legacy
            onBaseChosen?(legacy)
        }
    }
}
