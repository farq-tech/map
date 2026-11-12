import SwiftUI

/// «الطبقات»: the shared layers sheet (docs/ONE-MAP-UNIFICATION.md §6). The base-map cards are generated
/// from `MapLayerRegistry`; the data sections below them are still the existing ones (S3 moves them in).
/// S2: used inside Explore only. Same accessibility identifiers as the old `ExploreLayersSheet`.
struct MapLayersSheet: View {
    @ObservedObject var controller: LiveOutingController
    var mode: MapLayerMode = .explore
    @ObservedObject private var registry = MapLayerRegistry.shared
    @ObservedObject private var offline = OfflineMaps.shared
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let rows = MapLayersSheetModel.baseRows(registry: registry, mode: mode, areas: offline.completeAreas, topoAreas: offline.topoAreas)
        SaryPage(title: "الطبقات", close: { controller.modal = nil }) {
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
            switches
            ExploreLayerSections(controller: controller)
        }
        .onAppear { offline.reload(); registry.reload() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("explore.layers.sheet")
    }

    /// Registered non-base layers (none yet): one switch each, in catalog order.
    @ViewBuilder private var switches: some View {
        let extra = MapLayersSheetModel.switchLayers(registry: registry, mode: mode)
        if !extra.isEmpty {
            SarySection(title: "طبقات إضافية") {
                ForEach(extra) { d in
                    SaryToggleRow(title: d.title, subtitle: d.detail.isEmpty ? nil : d.detail, systemImage: d.systemImage,
                                  isOn: Binding(get: { registry.isActive(d.id) }, set: { registry.setActive(d.id, $0) }),
                                  id: "layer.\(d.id.rawValue)")
                        .padding(.horizontal, theme.space(.m))
                }
            }
        }
    }

    /// The registry keeps the stored choice; the controller keeps driving the live map (it also writes
    /// the same key through `MapLayer.saved`, so both always agree).
    private func choose(_ id: MapLayerID) {
        registry.setActive(id)
        if let legacy = MapLayerCatalog.legacy(id) { controller.mapLayer = legacy }
    }
}
