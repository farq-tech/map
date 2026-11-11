import SwiftUI

// MARK: - Rally point card

struct SaryRallyCard: View {
    var rally: RallyPointUI?
    var canManage: Bool
    var actions: ParticipantsTabActions = .init()
    @Environment(\.sary) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.saryWidthClass) private var widthClass
    @State private var confirmRemove = false

    var body: some View {
        let p = theme.palette
        let ax = typeSize.isAccessibilitySize
        let row = ax ? AnyLayout(VStackLayout(alignment: .leading, spacing: theme.space(.s))) : AnyLayout(HStackLayout(spacing: theme.space(.m)))
        /* «اتجه» + «أظهرها» + the menu need ~300 pt: stacked on a 320 pt screen (Display Zoom) too. */
        let buttons = ax || widthClass == .narrow ? AnyLayout(VStackLayout(spacing: theme.space(.s))) : AnyLayout(HStackLayout(spacing: theme.space(.s)))
        Group {
            if let rally {
                VStack(alignment: .leading, spacing: theme.space(.m)) {
                    row {
                        SaryRallyGlyph(size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("نقطة التجمع").saryText(.caption, weight: .bold).foregroundStyle(p.textSecondary)
                            Text(rally.label ?? "نقطة التجمع").saryText(.headline).foregroundStyle(p.textPrimary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        SaryDistanceLabel(meters: rally.distanceMeters, bearing: rally.bearingDegrees, style: .headline)
                    }
                    arrivedBar(rally)
                    if !rally.arrivedNames.isEmpty {
                        Text("عند النقطة: " + rally.arrivedNames.joined(separator: "، "))
                            .saryText(.footnote).foregroundStyle(p.textSecondary).lineLimit(2)
                            .accessibilityIdentifier("rally.arrived")
                    }
                    if canManage, let recall = actions.rallyRecall {
                        Button(action: recall) { SaryButtonLabel(title: "ارجعوا لنقطة التجمع", systemImage: "arrow.uturn.backward.circle.fill") }
                            .buttonStyle(.sary(.secondary, compact: true))
                            .accessibilityIdentifier("rally.recall")
                    }
                    buttons {
                        Button(action: actions.rallyGo) { SaryButtonLabel(title: "اتجه", systemImage: SaryIcon.directions) }
                            .buttonStyle(.sary(.primary, compact: true))
                        Button(action: actions.rallyShow) { SaryButtonLabel(title: "أظهرها", systemImage: SaryIcon.showOnMap) }
                            .buttonStyle(.sary(.secondary, compact: true))
                        if canManage {
                            Menu {
                                Button { actions.rallyMove() } label: { Label("نقل النقطة", systemImage: "arrow.up.and.down.and.arrow.left.and.right") }
                                Button(role: .destructive) { confirmRemove = true } label: { Label("إزالة", systemImage: "trash") }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(p.textPrimary)
                                    .frame(width: max(theme.minTarget, 44), height: max(theme.minTarget, 44))
                                    .background(RoundedRectangle(cornerRadius: SaryRadius.s, style: .continuous).fill(p.sunken))
                            }
                            .accessibilityLabel(Text("إدارة نقطة التجمع"))
                        }
                    }
                }
            } else {
                row {
                    SaryRallyGlyph(size: 40, muted: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ما فيه نقطة تجمع").saryText(.headline).foregroundStyle(p.textPrimary)
                        Text(canManage ? "حدد مكانًا يتجمع عنده الكل" : "أمير الطلعة يقدر يحددها")
                            .saryText(.footnote).foregroundStyle(p.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if canManage {
                        Button(action: actions.rallyCreate) { SaryButtonLabel(title: "حدد", systemImage: "plus") }
                            .buttonStyle(.sary(.primary, width: .hug, compact: true))
                    }
                }
            }
        }
        .padding(theme.space(.l))
        /* Setting / removing the point morphs the card in place. */
        .saryAnimation(.smooth, value: rally == nil)
        .sarySurface(radius: SaryRadius.l)
        .confirmationDialog("إزالة نقطة التجمع؟", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("أزلها", role: .destructive, action: actions.rallyRemove)
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("بتختفي النقطة عند كل الربع")
        }
    }

    private func arrivedBar(_ r: RallyPointUI) -> some View {
        let p = theme.palette
        let frac = r.totalCount > 0 ? Double(r.arrivedCount) / Double(r.totalCount) : 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("وصل \(SaryFormat.number(r.arrivedCount)) من \(SaryFormat.number(r.totalCount))")
                    .saryText(.footnote, weight: .bold).foregroundStyle(p.textSecondary)
                Spacer()
                if r.arrivedCount == r.totalCount && r.totalCount > 0 {
                    Label("الكل وصل", systemImage: SaryIcon.checkCircle).saryText(.footnote, weight: .bold).foregroundStyle(p.liveText)
                        .transition(SaryTransition.chipPop(theme))
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.sunken)
                    Capsule().fill(p.live).frame(width: max(6, g.size.width * frac))
                }
            }
            .frame(height: 6)
        }
        /* Each arrival fills the bar toward the point; the last one settles with `celebrate`. */
        .saryAnimation(r.arrivedCount == r.totalCount && r.totalCount > 0 ? .celebrate : .smooth, value: r.arrivedCount)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("وصل \(SaryFormat.number(r.arrivedCount)) من \(SaryFormat.number(r.totalCount))"))
    }
}

struct SaryRallyGlyph: View {
    var size: CGFloat = 40
    var muted = false
    @Environment(\.sary) private var theme
    var body: some View {
        Image(systemName: SaryIcon.rally)
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(muted ? theme.palette.textTertiary : theme.palette.onAccent)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(muted ? theme.palette.sunken : theme.palette.accent))
            .accessibilityHidden(true)
    }
}

// MARK: - Station row

struct SaryStationRow: View {
    var station: StationUI
    var go: () -> Void = {}
    var show: () -> Void = {}
    @Environment(\.sary) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let p = theme.palette
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: theme.space(.s)))
            : AnyLayout(HStackLayout(spacing: theme.space(.m)))
        layout {
            Button(action: show) {
                HStack(spacing: theme.space(.m)) {
                    Image(systemName: SaryIcon.nearest)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(p.accentText)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(p.accent.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(station.name).saryText(.bodyStrong).foregroundStyle(p.textPrimary).lineLimit(2)
                        HStack(spacing: 6) {
                            SaryDistanceLabel(meters: station.distanceMeters, bearing: station.bearingDegrees, style: .footnote)
                            if let d = station.detail {
                                Text("· \(d)").saryText(.footnote).foregroundStyle(p.textSecondary).lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: go) { SaryButtonLabel(title: "اتجه", systemImage: SaryIcon.directions) }
                .buttonStyle(.sary(.secondary, width: typeSize.isAccessibilitySize ? .fill : .hug, compact: true))
        }
        .padding(.vertical, theme.space(.s))
        .frame(minHeight: theme.minTarget + 8)
        .accessibilityElement(children: .contain)
    }
}
